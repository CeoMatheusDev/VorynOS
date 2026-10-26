//************************************************************************//
//  timer.zig                                                             //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! The timer of the kernel and the interrupt controllers.
//!
//! The kernel uses the programmable interval timer of the PC, the 8254, in
//! its most simple mode: channel zero generates a periodic interrupt at a
//! fixed frequency. The interrupt is delivered by the first of the two
//! interrupt controllers, the 8259, which the kernel reprograms so that the
//! hardware interrupts occupy the vectors that follow the exceptions of the
//! processor.

const std = @import("std");
const voryn = @import("voryn_shared");

const serial = voryn.serial;
const cpu = @import("cpu.zig");
const apic = @import("apic.zig");
const perf_tsc_hz: u32 = 2_800_000_000; // Valores de calibracao QEMU

/// The frequency of the timer of the PC.
pub const pit_frequency: u32 = 1_193_182;

/// Ports of the programmable interval timer.
const pit = struct {
    const channel0 = 0x40;
    const command = 0x43;
};

/// Ports of the interrupt controllers.
const pic = struct {
    const master_command = 0x20;
    const master_data = 0x21;
    const slave_command = 0xA0;
    const slave_data = 0xA1;
};

/// The vector of the first hardware interrupt.
pub const first_hardware_vector: u8 = 32;

/// The number of hardware interrupts.
pub const hardware_interrupt_count: u8 = 16;

/// Number of ticks since the timer was started.
var tick_count: u64 = 0;

/// The frequency of the timer in interrupts per second.
var frequency: u32 = 100;

/// Prepares the interrupt controllers and the timer.
///
/// The controllers are reprogrammed so that the hardware interrupts use the
/// vectors that follow the exceptions of the processor, and the timer is
/// started at the given frequency.
pub fn init(ticks_per_second: u32) void {
    frequency = ticks_per_second;
    tick_count = 0;

    // Remap the interrupt controllers.
    //
    // The first controller receives the vectors 32 to 39 and the second one
    // the vectors 40 to 47. The second controller is connected to the
    // interrupt request line 2 of the first one.
    writePort(pic.master_command, 0x11); // initialisation, expects the fourth word
    writePort(pic.master_data, first_hardware_vector);
    writePort(pic.master_data, 0x04); // the second controller is on line 2
    writePort(pic.master_data, 0x01); // 8086 mode

    writePort(pic.slave_command, 0x11);
    writePort(pic.slave_data, first_hardware_vector + 8);
    writePort(pic.slave_data, 0x02); // the cascade identity
    writePort(pic.slave_data, 0x01);

    // Enable IRQ0 (timer) and IRQ1 (legacy PS/2 keyboard).
    // Other IRQ lines remain masked until a driver claims them.
    writePort(pic.master_data, 0xFC);
    writePort(pic.slave_data, 0xFF);

    // Program the timer: channel zero, low and high byte of the divisor,
    // square wave mode.
    if (ticks_per_second == 0) return;
    const divisor = pit_frequency / ticks_per_second;
    writePort(pit.command, 0x34);
    writePort(pit.channel0, @truncate(divisor & 0xFF));
    writePort(pit.channel0, @truncate((divisor >> 8) & 0xFF));
}

/// Counts one tick of the timer.
pub fn onTick() void {
    tick_count += 1;
}

/// The number of ticks since the timer was started.
pub fn ticks() u64 {
    return tick_count;
}

/// The frequency of the timer in interrupts per second.
pub fn ticksPerSecond() u32 {
    return frequency;
}

/// Acknowledges the interrupt to the controllers.
///
/// The first controller is acknowledged when the interrupt comes from the
/// second one, because the second controller is connected to it.
pub fn acknowledge(vector: u8) void {
    if (vector >= first_hardware_vector + 8) {
        writePort(pic.slave_command, 0x20);
    }
    writePort(pic.master_command, 0x20);
}

/// Enables the interrupts of the processor.
pub fn enableInterrupts() void {
    cpu.enableInterrupts();
}

/// Writes a byte to a port.
fn writePort(port: u16, value: u8) void {
    voryn.port.outb(port, value);
}

/// Configura o timer local da APIC para a CPU atual.
///
/// Deve ser chamado pelo BSP e por cada AP apos o mapeamento do APIC
/// local e a habilitacao de interrupcoes. O timer dispara periodicamente
/// no vetor `apic.timer_vector`, fazendo com que cada CPU trate seus
/// proprio ticks de escalonamento de forma independente.
///
/// `ticks_per_second` e a frequencia desejada de interrupcoes do timer.
/// O divisor e calculado a partir de uma frequencia de barramento de
/// 10 MHz (valor tipico do QEMU; sistemas reais devem ler isso da ACPI).
pub fn initApicTimer(ticks_per_second: u32) void {
    if (!apic.isMapped()) return;
    if (ticks_per_second == 0) return;

    // FASE 2 — Calibracao do APIC Timer. Utiliza o contador TSC para medir
    // a frequencia real do barramento do APIC, substituindo a presuncao de
    // 10 MHz. Nao depende de ACPI MADT nesta etapa.
    //
    // A calibracao envolve:
    // 1. Parar o APIC timer.
    // 2. Armar o timer em modo one-shot com um divisor conhecido (maximo).
    // 3. Aguardar o timer disparar (usando `cpu.halt()`).
    // 4. Medir o tempo decorrido usando `cpu.readTimestamp()`.
    // 5. Calcular a frequencia do barramento com base nessa medição.

    var bus_freq: u32 = 10_000_000; // Valor padrao se a calibracao falhar.

    apic.timerStop(); // Garante que o timer APIC esteja parado.
    apic.setTimerDivide(0); // Divisor 2, como padrao (00b = /2).

    // Armar o timer em modo one-shot com um valor maximo para contar
    // o numero de ciclos TSC para um periodo longo.
    const calibration_ticks: u32 = 0xFFFFF;
    apic.timerOneShot(calibration_ticks);

    const tsc_start = cpu.readTimestamp();
    var attempts: u64 = 0;
    while (apic.read32(apic.ApicOffset.timer_current) != 0 and attempts < 1_000_000) : (attempts += 1) {
        cpu.halt();
    }
    const tsc_end = cpu.readTimestamp();

    // Se o timer nao disparou, ou houve algum problema, use a frequencia padrao.
    if (attempts >= 1_000_000 or (tsc_end - tsc_start) == 0) {
        serial.printLine("[VNK] APIC: falha na calibracao, usando 10 MHz padrao.", .{});
    } else {
        // Calcula a frequencia do barramento APIC.
        // Sabemos que o TSC ja foi calibrado em kernel/main.zig.
        // bus_freq = (calibration_ticks * perf_tsc_hz) / (tsc_end - tsc_start)
        // Onde perf_tsc_hz eh a frequencia do TSC em Hz.
        const tsc_elapsed = tsc_end - tsc_start;
        bus_freq = @intCast(@as(u128, calibration_ticks) * perf_tsc_hz / tsc_elapsed);
        serial.printLine("[VNK] APIC: bus freq calibrada: {d} Hz", .{bus_freq});
    }

    // Agora com a frequencia calibrada, configura o timer para o uso normal.
    // FASE 2 — Evita divisor zero (se ticks > bus, truncado seria zero).
    if (ticks_per_second > bus_freq) {
        // Frequencia desejada excede a capacidade do timer APIC, usa o maximo possivel.
        // Isso ainda pode levar a um divisor de 0 se bus_freq for muito baixo.
        apic.timerPeriodic(1); // menor divisor possivel, 1Hz
        return;
    }
    // divisor protegido contra zero: ticks_per_second > bus_freq nesta condicao.
    const divisor: u32 = @intCast(@as(u128, bus_freq) / @as(u128, ticks_per_second));
    // Garante divisor >= 1 para evitar timerPeriodic(0), a qual nao dispara o timer.
    const safe_divisor: u32 = if (divisor < 1) 1 else divisor;

    // Configura o divisor e arma o modo periodico diretamente.
    // timerPeriodic() ja define periodico + vetor; nao precisa de timerStop/timerDivide separados.
    apic.timerPeriodic(safe_divisor);

    frequency = ticks_per_second;
}
