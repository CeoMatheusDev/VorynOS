//************************************************************************//
//  smp.zig                                                               //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Suporte a multiprocessamento simétrico (SMP): dados por CPU e numeração.
//!
//! Este incremento estabelece as fundações para execução em múltiplos
//! processadores lógicos. Cada CPU lógica tem:
//!
//!   * um número de CPU (0 para o BSP, 1..N para os APs);
//!   * um ID de APIC local;
//!   * um ponteiro para a tarefa que está executando;
//!   * um ponteiro para o escalonador da CPU.
//!
//! A inicialização dos APs (SIPI/trampoline) e as IPIs entre CPUs são
//! trabalho futuro. Este módulo fornece as estruturas de dados e as
//! funções de consulta que o escalonador e o kernel usarão quando o SMP
//! estiver ativo.

const std = @import("std");
const spinlock = @import("spinlock.zig");
const apic = @import("apic.zig");
const voryn = @import("voryn_shared");
const x86_cpu = @import("cpu.zig");

/// Número máximo de CPUs lógicas suportadas.
pub const max_cpus: u8 = 8;

/// Estado de uma CPU lógica.
pub const CpuState = enum {
    /// A CPU não foi detectada ou não está presente.
    absent,
    /// A CPU está online e executando tarefas.
    online,
    /// A CPU está sendo inicializada (AP em processo de boot).
    initializing,
    /// A CPU foi desligada.
    offline,
};

/// Dados privados de uma CPU lógica.
pub const Cpu = struct {
    /// Número da CPU (0 para o BSP, 1..N para os APs).
    id: u8 = 0,
    /// ID de APIC local da CPU.
    apic_id: u32 = 0,
    /// Estado atual da CPU.
    state: CpuState = .absent,
    /// Tarefa que está executando nesta CPU (null se nenhuma).
    current_task: ?*anyopaque = null,
    /// Espinlock que protege os dados desta CPU.
    lock: spinlock.Spinlock = .{},
};

/// Tabela de CPUs: um slot por número de CPU lógica.
var cpus: [max_cpus]Cpu = @splat(.{});

/// Número de CPUs online atualmente.
var online_cpu_count: u8 = 1;

/// Retorna o número da CPU atual.
///
/// Implementação provisória: retorna 0 (apenas o BSP existe). Quando o
/// suporte a APs for adicionado, esta função lerá o ID de APIC local
/// e o traduzirá para o número de CPU usando a tabela `cpus`.
pub fn cpuId() u8 {
    return 0;
}

/// Retorna o ponteiro para a estrutura da CPU atual.
pub fn currentCpu() *Cpu {
    return &cpus[cpuId()];
}

/// Retorna o número de CPUs online.
pub fn cpuCount() u8 {
    return online_cpu_count;
}

/// Registra uma CPU na tabela. Chamado durante a inicialização do BSP
/// e, futuramente, durante o boot de cada AP.
pub fn registerCpu(id: u8, apic_id: u32) ?*Cpu {
    if (id >= max_cpus) return null;
    const cpu = &cpus[id];
    cpu.* = .{
        .id = id,
        .apic_id = apic_id,
        .state = .online,
        .current_task = null,
    };
    if (id == 0 or online_cpu_count < max_cpus) {
        online_cpu_count = @min(online_cpu_count + 1, max_cpus);
    }
    return cpu;
}

/// Marca uma CPU como offline.
pub fn offlineCpu(id: u8) void {
    if (id >= max_cpus) return;
    cpus[id].state = .offline;
    online_cpu_count = @max(online_cpu_count - 1, 1);
}

test "cpuId returns zero on single-CPU system" {
    try std.testing.expectEqual(cpuId(), 0);
}

test "registerCpu adds a CPU to the table" {
    online_cpu_count = 1;
    const c = registerCpu(0, 0) orelse return;
    try std.testing.expectEqual(c.id, 0);
    try std.testing.expectEqual(c.apic_id, 0);
    try std.testing.expectEqual(c.state, .online);
}

test "registerCpu rejects IDs above max_cpus" {
    try std.testing.expectEqual(registerCpu(max_cpus, 0), null);
}

test "offlineCpu reduces the online count but keeps at least one" {
    online_cpu_count = 4;
    offlineCpu(3);
    try std.testing.expectEqual(cpuCount(), 3);
    offlineCpu(2);
    offlineCpu(1);
    try std.testing.expectEqual(cpuCount(), 1);
}

/// Pilhas de kernel dos APs (uma por CPU, excluindo o BSP que ja tem sua
/// pilha em `kernel/main.zig`).
///
/// Cada pilha tem 16 KiB e esta alinhada a 16 bytes. O topo da pilha
/// (`_end`) e usado pelo trampoline como ponteiro inicial de pilha.
var ap_stacks: [max_cpus - 1][16 * 1024]u8 align(16) = undefined;

/// Endereco do topo da pilha de cada AP (indexado por cpu_id - 1).
/// Exportado para o trampoline em Assembly.
pub export var ap_stack_top: [max_cpus - 1]u64 = undefined;

/// Ponto de entrada de um AP, chamado pelo trampoline em modo longo.
///
/// `cpu_id` e o numero logico da CPU (passado pelo trampoline em RDI).
/// A funcao registra a CPU na tabela, configura sua pilha e entra no
/// escalonador. Nunca retorna.
pub export fn voryn_ap_entry(cpu_id: u8) void {
    const ap_index = @as(usize, cpu_id) - 1;

    // Estabelece a pilha do kernel desta CPU.
    const stack = &ap_stacks[ap_index];
    const stack_top = @intFromPtr(stack.ptr) + stack.len;
    const aligned_top = stack_top & ~@as(u64, 0xF);

    // Registra a CPU na tabela SMP.
    const apic_id = apic.readApicId();
    const cpu = registerCpu(cpu_id, apic_id) orelse {
        // Nao ha espaco na tabela: entra em loop de espera.
        while (true) {}
    };
    cpu.current_task = null;

    // Marca a pilha como disponivel para o escalonador.
    ap_stack_top[ap_index] = aligned_top;

    // Sinaliza que esta CPU esta online.
    cpu.state = .online;

    // Entra no loop da CPU: aguarda por trabalho do escalonador.
    // O escalonador ainda e monoprocessador; quando o suporte a multiprocessador
    // estiver completo, esta funcao escolhera tarefas da fila desta CPU.
    while (true) {
        x86_cpu.halt();
    }
}

/// Inicializa o suporte a AP no BSP.
///
/// Deve ser chamado pelo kernel apos a inicializacao do BSP. Configura
/// os enderecos de pilha dos APs e prepara o trampoline para copia.
pub fn initAps() void {
    var i: usize = 0;
    while (i < max_cpus - 1) : (i += 1) {
        const stack = &ap_stacks[i];
        const stack_top = @intFromPtr(stack.ptr) + stack.len;
        ap_stack_top[i] = stack_top & ~@as(u64, 0xF);
    }
}

pub fn startAps() void {
    // M0.5: envia SIPI (Startup IPI) para cada AP. O BSP assume APIC IDs
    // sequenciais (BSP=0, APs=1..max-1), convencao usada pelo QEMU/OVMF.
    const trampoline_size = @intFromPtr(&voryn_ap_trampoline_size);
    voryn.serial.printLine("[VNK] smp: starting APs (trampoline size={d})", .{trampoline_size});
    var ap_id: u32 = 1;
    while (ap_id < max_cpus) : (ap_id += 1) {
        apic.sendSipiTwice(ap_id, 0x10); // vetor 0x10 = endereco 0x10000 (abaixo de 1 MiB)
        voryn.serial.printLine("[VNK] smp: SIPI sent to APIC id={d}", .{ap_id});
    }
}

/// Retorna o ponteiro para o trampoline de AP e seu tamanho.
///
/// Usado pelo BSP para copiar o trampoline para memoria abaixo de 1 MiB
/// e enviar SIPI para cada AP.
pub fn apTrampolineInfo() [*]u8 {
    return @ptrFromInt(@intFromPtr(&voryn_ap_trampoline_start));
}

/// Simbolo do inicio do trampoline (definido em ap_trampoline.s).
/// O BSP usa seu endereco para copiar o trampoline para memoria abaixo de 1 MiB.
pub extern const voryn_ap_trampoline_start: u8;

/// Simbolo do tamanho do trampoline (definido em ap_trampoline.s).
pub extern const voryn_ap_trampoline_size: u64;
