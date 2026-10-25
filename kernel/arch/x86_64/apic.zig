//************************************************************************//
//  apic.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! APIC local (xAPIC): registradores de mapeamento de memoria do
//! Advanced Programmable Interrupt Controller.
//!
//! Este modulo estabelece o acesso ao APIC local de cada CPU logica:
//! registradores de identificacao, tarefa de prioridade, registro de fim
//! de interrupcao, timer local, erros e comandos inter-processador (ICR).
//!
//! O endereco base do APIC local vem da tabela MADT da ACPI quando
//! disponivel; ate que a leitura da ACPI esteja integrada, usa-se o
//! endereco padrao do QEMU/OVMF (0xFEE0000), que tambem e o endereco
//! tipico de sistemas reais.
//!
//! O acesso ao APIC local e feito por memoria mapeada. Cada registro tem
//! 4 bytes mas esta espacado a cada 16 bytes (espacamento 16 bytes entre
//! registros de 4 bytes).

const std = @import("std");
const cpu = @import("cpu.zig");
const timer = @import("timer.zig");

/// Endereco base do APIC local (mapeamento de memoria).
///
/// Valor padrao do QEMU/OVMF e de muitos sistemas reais. Quando a leitura
/// da tabela MADT estiver integrada, este valor sera substituido pelo
/// lido da ACPI.
pub const apic_base: u64 = 0xFEE0000;

/// Offset dos registradores do APIC local, em bytes, a partir da base.
/// Cada registro de 32 bits ocupa 16 bytes (espacamento de 16).
pub const ApicOffset = struct {
    /// ID da APIC local (apenas o byte mais significativo importa).
    pub const id: u64 = 0x020;
    /// Versao da APIC local.
    pub const version: u64 = 0x030;
    /// Prioridade de tarefa (TPR): mascara interrupcoes abaixo do limiar.
    pub const tpr: u64 = 0x080;
    /// Prioridade de arbitragem (APR).
    pub const apr: u64 = 0x090;
    /// Prioridade do processador (PPR).
    pub const ppr: u64 = 0x0a0;
    /// Endereco de destino do EOI.
    pub const eoi: u64 = 0x0b0;
    /// Registrador de detector logico (LDR).
    pub const ldr: u64 = 0x0d0;
    /// Formato de destino (DFR).
    pub const dfr: u64 = 0x0e0;
    /// Vetor de interrupcao spuria (SVR): habilita a APIC e define o vetor.
    pub const svr: u64 = 0x0f0;
    /// Registro de erro (ESR).
    pub const esr: u64 = 0x280;
    /// Timer: contagem inicial (ICR).
    pub const timer_icr: u64 = 0x320;
    /// Timer: configuracao e vetor (TDR).
    pub const timer_config: u64 = 0x330;
    /// Timer: contador atual.
    pub const timer_current: u64 = 0x340;
    /// Interrupcao local 0 (LINT0).
    pub const lint0: u64 = 0x350;
    /// Interrupcao local 1 (LINT1).
    pub const lint1: u64 = 0x360;
    /// Registrador de erro (ESR).
    pub const error_reg: u64 = 0x370;
    /// ICR baixo (comando de interrupcao inter-processador).
    pub const icr_low: u64 = 0x300;
    /// ICR alto (destino da IPI).
    pub const icr_high: u64 = 0x310;
};

/// Bits do SVR (Spurious Interrupt Vector Register).
pub const SvrBits = struct {
    /// Habilita a APIC local.
    pub const apic_enabled: u32 = 1 << 8;
    /// Vetor de interrupcao spuria (bits 0-7).
    pub const spurious_vector_mask: u32 = 0xFF;
};

/// Tipos de comando da ICR (bits 8-10 do ICR baixo).
pub const IcrDeliveryMode = enum(u32) {
    fixed = 0x000,
    lowest_priority = 0x100,
    smi = 0x200,
    nmi = 0x400,
    init = 0x500,
    startup = 0x600,
};

/// Modo de nivel da ICR (bit 14 do ICR baixo).
pub const IcrLevel = enum(u32) {
    deassert = 0x000,
    assert = 0x400,
};

/// Modo de trigger da ICR (bit 15 do ICR baixo).
pub const IcrTriggerMode = enum(u32) {
    edge = 0x000,
    level = 0x800,
};

/// Destino da IPI (bits 17-18 do ICR baixo).
pub const IcrDestinationMode = enum(u32) {
    physical = 0x000,
    logical = 0x100,
};

/// Estados de execucao da IPI (shorthand de destino, bits 17-18 do ICR baixo).
pub const IcrDestinationShorthand = enum(u32) {
    none = 0x000,
    self = 0x200,
    all_including_self = 0x400,
    all_excluding_self = 0x600,
};

/// Estado de delivery pendente da ICR (bit 12 do ICR baixo).
pub const IcrDeliveryStatus = enum(u32) {
    idle = 0x000,
    pending = 0x100,
};

/// Vetor da interrupcao do timer local do APIC.
pub const timer_vector: u32 = @as(u32, timer.first_hardware_vector + timer.hardware_interrupt_count);

/// Acesso ao APIC local como ponteiro para a regiao mapeada de memoria.
var apic: [*]u8 = undefined;

/// Mapeia o APIC local na regiao de memoria do kernel.
///
/// O caller deve ja ter mapeado a pagina fisica do APIC no espaco de
/// enderecos do kernel e passar o endereco virtual. Esta funcao apenas
/// registra o ponteiro para acesso aos registradores.
pub fn map(base: u64) void {
    apic = @ptrFromInt(@as(usize, base));
}

/// Retorna true se o APIC local foi mapeado.
pub fn isMapped() bool {
    return @intFromPtr(apic) != 0;
}

/// Le um registrador de 32 bits do APIC local.
fn read32(offset: u64) u32 {
    const addr = @intFromPtr(apic) + offset;
    const ptr: *u32 = @ptrFromInt(addr);
    return ptr.*;
}

/// Escreve um valor de 32 bits em um registrador do APIC local.
fn write32(offset: u64, value: u32) void {
    const addr = @intFromPtr(apic) + offset;
    const ptr: *u32 = @ptrFromInt(addr);
    ptr.* = value;
}

/// Le o ID da APIC local.
///
/// O ID esta no byte mais significativo do registrador de ID.
pub fn readApicId() u32 {
    return read32(ApicOffset.id) >> 24;
}

/// Le a versao da APIC local.
pub fn readApicVersion() u32 {
    return read32(ApicOffset.version) & 0xFF;
}

/// Habilita a APIC local definindo o bit de habilitacao do SVR.
///
/// O vetor de interrupcao spuria fica definido como 0xFF (ignorado).
pub fn enable() void {
    const svr = read32(ApicOffset.svr);
    write32(ApicOffset.svr, svr | SvrBits.apic_enabled);
}

/// Envia o sinal de fim de interrupcao (EOI) ao APIC local.
///
/// O EOI deve ser chamado ao final do tratamento de uma interrupcao
/// recebida pelo APIC local para que ele possa entregar a proxima.
pub fn eoi() void {
    write32(ApicOffset.eoi, 0);
}

/// Define o limiar de prioridade de tarefa (TPR).
///
/// Interrupcoes com prioridade menor ou igual ao limiar sao mascaradas.
/// Escrever zero permite todas as interrupcoes gerenciadas pela APIC.
pub fn setTpr(priority: u32) void {
    write32(ApicOffset.tpr, priority & 0xFF);
}

/// Configura o timer local da APIC no modo one-shot.
///
/// `divisor` divide o frequencia do barramento do timer (tipicamente
/// 10 MHz em QEMU). O timer dispara o vetor `timer_vector` apos
/// `divisor` contagens e nao se rearma automaticamente.
pub fn timerOneShot(divisor: u32) void {
    // Desabilita o timer antes de reconfigurar.
    write32(ApicOffset.timer_config, 0x0001_0000); // mascarado, one-shot
    write32(ApicOffset.timer_icr, divisor);
}

/// Configura o timer local da APIC no modo periodico.
///
/// `divisor` divide a frequencia do barramento do timer. O timer dispara
/// o vetor `timer_vector` periodicamente e se rearma automaticamente.
pub fn timerPeriodic(divisor: u32) void {
    // Bit 17 = periodico, mascarado por enquanto (bit 16 = 0).
    write32(ApicOffset.timer_config, 0x0002_0000 | timer_vector);
    write32(ApicOffset.timer_icr, divisor);
}

/// Envia uma IPI para uma CPU de destino (modo fisico).
///
/// `apic_id` e o ID de APIC local da CPU de destino. `delivery_mode` e o
/// tipo de comando (fixed, lowest_priority, init, startup etc.).
pub fn sendIpi(apic_id: u32, delivery_mode: u32, vector: u8) void {
    // Espera ate que a IPI anterior tenha sido entregue.
    while (read32(ApicOffset.icr_low) & @as(u32, @intFromEnum(IcrDeliveryStatus.pending)) != 0) {
        cpu.pause();
    }
    // ICR alto: ID de destino no byte mais significativo.
    write32(ApicOffset.icr_high, apic_id << 24);
    // ICR baixo: delivery mode + vector + edge trigger + physical destination.
    const command: u32 = delivery_mode | IcrLevel.assert |
        IcrTriggerMode.edge | IcrDestinationMode.physical | @as(u32, vector);
    write32(ApicOffset.icr_low, command);
}

/// Envia uma IPI INIT para todos exceto o emissor (modo broadcast fisico).
pub fn sendInitAllExcludingSelf() void {
    while (read32(ApicOffset.icr_low) & @as(u32, @intFromEnum(IcrDeliveryStatus.pending)) != 0) {
        cpu.pause();
    }
    write32(ApicOffset.icr_high, 0);
    const command: u32 = IcrDeliveryMode.init | IcrLevel.assert |
        IcrTriggerMode.edge | IcrDestinationMode.physical |
        IcrDestinationShorthand.all_excluding_self;
    write32(ApicOffset.icr_low, command);
}

/// Envia uma IPI de STARTUP (SIPI) para um AP.
///
/// `apic_id` e o ID de APIC local do AP. `vector` e o vetor de
/// inicializacao (o endereco do trampoline eh vector * 4096 bytes).
pub fn sendSipi(apic_id: u32, vector: u8) void {
    while (read32(ApicOffset.icr_low) & @as(u32, @intFromEnum(IcrDeliveryStatus.pending)) != 0) {
        cpu.pause();
    }
    write32(ApicOffset.icr_high, apic_id << 24);
    const command: u32 = IcrDeliveryMode.startup |
        IcrLevel.assert |
        IcrTriggerMode.edge |
        IcrDestinationMode.physical |
        vector;
    write32(ApicOffset.icr_low, command);
}

/// Segunda mensagem SIPI: envia o SIPI duas vezes com um intervalo,
/// conforme requerido pela especificacao do protocolo de boot multiprocessador.
pub fn sendSipiTwice(apic_id: u32, vector: u8) void {
    sendSipi(apic_id, vector);
    // Delay curto entre as mensagens SIPI.
    var i: u32 = 0;
    while (i < 1000) {
        cpu.pause();
        i += 1;
    }
    sendSipi(apic_id, vector);
}

test "apicOffsetsAreAligned" {
    try std.testing.expectEqual(@as(u64, 0x020), ApicOffset.id);
    try std.testing.expectEqual(@as(u64, 0x300), ApicOffset.icr_low);
    try std.testing.expectEqual(@as(u64, 0x310), ApicOffset.icr_high);
}

test "timerVectorIsAfterHardwareInterrupts" {
    try std.testing.expectEqual(timer_vector, timer.first_hardware_vector + timer.hardware_interrupt_count);
}
