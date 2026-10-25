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
//! O modulo da acesso ao APIC local de cada CPU logica: identificacao,
//! prioridade de tarefa, registro de fim de interrupcao, timer local,
//! erros e comandos inter-processador (ICR).
//!
//! O endereco base do APIC local vem da tabela MADT da ACPI. O chamador
//! mapeia a pagina fisica na memoria do kernel, sem cache, e passa o
//! endereco virtual para `map`.
//!
//! Os registradores do APIC local tem 32 bits e ficam espacados a cada
//! 16 bytes; o acesso e feito por memoria mapeada e o ponteiro e volatil,
//! para que o compilador nao elimine nem reordene as leituras e escritas.
//!
//! Referencias: Intel 64 and IA-32 Architectures Software Developer's
//! Manual, volume 3A, capitulo 11 (Advanced Programmable Interrupt
//! Controller); ACPI Specification 6.5, secao 5.2.12.

const std = @import("std");
const cpu = @import("cpu.zig");
const timer = @import("timer.zig");

/// Endereco base padrao do APIC local quando a ACPI nao informa outro.
pub const default_base: u64 = 0xFEE0_0000;

/// Endereco da pagina do APIC local na memoria fisica.
///
/// O valor e substituido pelo endereco lido da MADT durante a descoberta.
pub var base: u64 = default_base;

/// Offset dos registradores do APIC local, em bytes, a partir da base.
pub const ApicOffset = struct {
    /// Identificador do APIC local (bits 24-31).
    pub const id: u64 = 0x020;
    /// Versao do APIC local.
    pub const version: u64 = 0x030;
    /// Prioridade de tarefa (TPR).
    pub const tpr: u64 = 0x080;
    /// Prioridade de arbitragem (APR).
    pub const apr: u64 = 0x090;
    /// Prioridade do processador (PPR).
    pub const ppr: u64 = 0x0A0;
    /// Fim de interrupcao (EOI).
    pub const eoi: u64 = 0x0B0;
    /// Detector logico (LDR).
    pub const ldr: u64 = 0x0D0;
    /// Formato de destino (DFR).
    pub const dfr: u64 = 0x0E0;
    /// Vetor de interrupcao espuria (SVR).
    pub const svr: u64 = 0x0F0;
    /// Registro de erro (ESR).
    pub const esr: u64 = 0x280;
    /// ICR baixo: comando da interrupcao inter-processador.
    pub const icr_low: u64 = 0x300;
    /// ICR alto: destino da interrupcao inter-processador.
    pub const icr_high: u64 = 0x310;
    /// LVT do timer local.
    pub const timer_lvt: u64 = 0x320;
    /// LVT da interrupcao termica.
    pub const thermal_lvt: u64 = 0x330;
    /// LVT do contador de desempenho.
    pub const perf_lvt: u64 = 0x340;
    /// LVT da interrupcao local 0 (LINT0), ligada ao 8259.
    pub const lint0: u64 = 0x350;
    /// LVT da interrupcao local 1 (LINT1), ligada ao NMI.
    pub const lint1: u64 = 0x360;
    /// LVT do erro do APIC.
    pub const error_lvt: u64 = 0x370;
    /// Contagem inicial do timer local.
    pub const timer_initial: u64 = 0x380;
    /// Contagem corrente do timer local.
    pub const timer_current: u64 = 0x390;
    /// Configuracao do divisor do timer local.
    pub const timer_divide: u64 = 0x3E0;
};

/// Bits do registro SVR (Spurious Interrupt Vector Register).
pub const SvrBits = struct {
    /// Vetor da interrupcao espuria (bits 0-7, obrigatoriamente 0xF0-0xFF).
    pub const vector_mask: u32 = 0xFF;
    /// Habilita o APIC local.
    pub const enabled: u32 = 1 << 8;
    /// Modo de foco para processadores antigos (nao usado).
    pub const focus: u32 = 1 << 9;
};

/// Bits do LVT do timer local.
pub const TimerLvt = struct {
    /// Vetor da interrupcao (bits 0-7).
    pub const vector_mask: u32 = 0xFF;
    /// Mascara a interrupcao.
    pub const masked: u32 = 1 << 16;
    /// Modo periodico (bit 17).
    pub const periodic: u32 = 1 << 17;
};

/// Modos de entrega da ICR (bits 8-10 do ICR baixo).
pub const IcrDeliveryMode = enum(u32) {
    fixed = 0x000,
    lowest_priority = 0x100,
    smi = 0x200,
    nmi = 0x400,
    init = 0x500,
    startup = 0x600,
};

/// Bits de nivel e de disparo da ICR.
pub const IcrBits = struct {
    /// Destino fisico (bit 11 = 0).
    pub const destination_physical: u32 = 0;
    /// Destino logico (bit 11 = 1).
    pub const destination_logical: u32 = 1 << 11;
    /// Status de entrega pendente (bit 12).
    pub const delivery_pending: u32 = 1 << 12;
    /// Nivel assert (bit 14).
    pub const level_assert: u32 = 1 << 14;
    /// Disparo por borda (bit 15 = 0).
    pub const trigger_edge: u32 = 0;
    /// Disparo por nivel (bit 15 = 1).
    pub const trigger_level: u32 = 1 << 15;
    /// Shorthand: somente o proprio processador (bits 18-19 = 01).
    pub const shorthand_self: u32 = 0x4_0000;
    /// Shorthand: todos incluindo o proprio (10).
    pub const shorthand_all_including_self: u32 = 0x8_0000;
    /// Shorthand: todos exceto o proprio (11).
    pub const shorthand_all_excluding_self: u32 = 0xC_0000;
};

/// Vetor da interrupcao do timer local do APIC.
pub const timer_vector: u8 = timer.first_hardware_vector + timer.hardware_interrupt_count;

/// Ponteiro para a pagina mapeada do APIC local.
///
/// `null` enquanto o APIC nao foi mapeado. O acesso e volatil: os
/// registradores mudam por acao do hardware e nao podem ser cacheados
/// pelo compilador.
var mapped: ?[*]volatile u8 = null;

/// MSR do endereco base do APIC local (IA32_APIC_BASE).
pub const msr_apic_base: u32 = 0x1B;

/// Le o MSR do endereco base do APIC local.
pub fn baseMsr() u64 {
    return cpu.readMsr(msr_apic_base);
}

/// Retorna true quando o processador esta no modo x2APIC.
///
/// No modo x2APIC os registradores sao acessados por MSR e o mapeamento
/// de memoria do xAPIC deixa de responder; o kernel usa o caminho xAPIC.
pub fn isX2ApicEnabled() bool {
    return (baseMsr() & (@as(u64, 1) << 10)) != 0;
}

/// Retorna true quando o APIC local esta habilitado globalmente.
pub fn isGloballyEnabled() bool {
    return (baseMsr() & (@as(u64, 1) << 11)) != 0;
}

/// Registra a pagina virtual do APIC local.
///
/// O chamador ja mapeou a pagina fisica `base` na memoria do kernel, sem
/// cache. A funcao apenas guarda o ponteiro; a validacao do alinhamento e
/// do intervalo fica com o mapeamento.
pub fn map(address: u64) void {
    base = address;
    mapped = @ptrFromInt(address);
}

/// Remove o mapeamento logico do APIC local.
pub fn unmap() void {
    mapped = null;
}

/// Retorna true quando o APIC local foi mapeado.
pub fn isMapped() bool {
    return mapped != null;
}

/// Le um registrador de 32 bits do APIC local.
fn read32(offset: u64) u32 {
    const pointer = mapped orelse return 0;
    const address = @intFromPtr(pointer) + offset;
    const register: *volatile u32 = @ptrFromInt(address);
    return register.*;
}

/// Escreve um valor de 32 bits em um registrador do APIC local.
fn write32(offset: u64, value: u32) void {
    const pointer = mapped orelse return;
    const address = @intFromPtr(pointer) + offset;
    const register: *volatile u32 = @ptrFromInt(address);
    register.* = value;
}

/// Le o identificador do APIC local.
///
/// O identificador ocupa os bits 24-31 do registrador de identificacao.
pub fn readApicId() u32 {
    return read32(ApicOffset.id) >> 24;
}

/// Le a versao do APIC local.
pub fn readVersion() u32 {
    return read32(ApicOffset.version) & 0xFF;
}

/// Habilita o APIC local.
///
/// O vetor da interrupcao espuria e definido como 0xFF, que e o valor
/// reservado pela especificacao para esse vetor. Uma escrita que apenas
/// ligasse o bit de habilitacao deixaria o vetor em zero, que nao e um
/// vetor valido.
pub fn enable() void {
    const svr = read32(ApicOffset.svr);
    write32(ApicOffset.svr, (svr & ~SvrBits.vector_mask) | SvrBits.vector_mask | SvrBits.enabled);
}

/// Retorna true quando o bit de habilitacao do SVR esta ligado.
pub fn isEnabled() bool {
    return (read32(ApicOffset.svr) & SvrBits.enabled) != 0;
}

/// Envia o sinal de fim de interrupcao (EOI) ao APIC local.
pub fn eoi() void {
    write32(ApicOffset.eoi, 0);
}

/// Define o limiar de prioridade de tarefa (TPR).
///
/// Interrupcoes com prioridade menor ou igual ao limiar sao mascaradas.
/// Zero permite todas as prioridades.
pub fn setTpr(priority: u32) void {
    write32(ApicOffset.tpr, priority & 0xFF);
}

/// Le o limiar de prioridade de tarefa.
pub fn tpr() u32 {
    return read32(ApicOffset.tpr) & 0xFF;
}

/// Configura o LINT0 para entregar as interrupcoes do 8259.
///
/// O modo ExtINT (delivery mode 111) entrega ao processador a interrupcao
/// que o controlador programavel 8259 sinaliza. O kernel usa o PIT e o
/// teclado PS/2 por esse caminho, e o APIC ligado nao pode mascara-lo.
pub fn configureLegacyPic() void {
    // ExtINT (0x700): vetor sem significado, modo de entrega 111, borda,
    // sem mascara.
    write32(ApicOffset.lint0, 0x700);
}

/// Desabilita o timer local.
pub fn timerStop() void {
    write32(ApicOffset.timer_lvt, TimerLvt.masked);
    write32(ApicOffset.timer_initial, 0);
}

/// Configura o divisor do timer local.
///
/// O valor e o codigo de 4 bits da tabela do manual: 0b0000 divide por 2,
/// 0b0001 por 4, 0b0010 por 8, 0b0011 por 16, 0b1000 por 32, 0b1001 por
/// 64, 0b1010 por 128 e 0b1011 por 1.
pub fn timerDivide(divider: u4) void {
    write32(ApicOffset.timer_divide, divider);
}

/// Configura o timer local no modo one-shot.
///
/// `count` e o numero de ciclos do barramento do APIC ate a interrupcao.
/// O timer para depois de disparar uma vez.
pub fn timerOneShot(count: u32) void {
    write32(ApicOffset.timer_lvt, timer_vector);
    write32(ApicOffset.timer_initial, count);
}

/// Configura o timer local no modo periodico.
pub fn timerPeriodic(count: u32) void {
    write32(ApicOffset.timer_lvt, TimerLvt.periodic | timer_vector);
    write32(ApicOffset.timer_initial, count);
}

/// Le a contagem corrente do timer local.
pub fn timerCurrent() u32 {
    return read32(ApicOffset.timer_current);
}

/// Le e limpa o registro de erro do APIC local.
///
/// A leitura do ESR limpa os bits de erro; a escrita de zero antes da
/// leitura garante que um erro pendente seja observado.
pub fn takeError() u32 {
    write32(ApicOffset.esr, 0);
    return read32(ApicOffset.esr);
}

/// Envia uma IPI de modo fixo para uma CPU de destino fisico.
pub fn sendFixed(apic_id: u32, vector: u8) void {
    send(apic_id, @intFromEnum(IcrDeliveryMode.fixed), vector);
}

/// Envia uma IPI INIT para uma CPU.
///
/// O INIT coloca o AP no estado de espera por SIPI. O nivel e assertado,
/// como o protocolo de inicializacao multiprocessador exige.
pub fn sendInit(apic_id: u32) void {
    send(apic_id, @intFromEnum(IcrDeliveryMode.init) | IcrBits.level_assert, 0);
}

/// Envia uma IPI STARTUP (SIPI) para uma CPU.
///
/// O AP comeca a executar em modo real no endereco `vector * 4096`.
pub fn sendStartup(apic_id: u32, vector: u8) void {
    send(apic_id, @intFromEnum(IcrDeliveryMode.startup) | IcrBits.level_assert, vector);
}

/// Envia um comando pela ICR e espera a entrega.
fn send(apic_id: u32, command: u32, vector: u8) void {
    if (!isMapped()) return;

    // Espera a entrega anterior terminar antes de escrever um comando
    // novo: a ICR tem um unico conjunto de registradores.
    waitDelivery();

    // O destino ocupa os bits 24-31 do ICR alto no modo fisico.
    write32(ApicOffset.icr_high, (apic_id & 0xFF) << 24);
    write32(ApicOffset.icr_low, command | IcrBits.destination_physical | @as(u32, vector));
    waitDelivery();
}

/// Espera o bit de status de entrega da ICR ficar livre.
fn waitDelivery() void {
    var attempts: u32 = 0;
    while ((read32(ApicOffset.icr_low) & IcrBits.delivery_pending) != 0) : (attempts += 1) {
        if (attempts > 1_000_000) return;
        cpu.pause();
    }
}

test "apic register offsets" {
    try std.testing.expectEqual(@as(u64, 0x020), ApicOffset.id);
    try std.testing.expectEqual(@as(u64, 0x0F0), ApicOffset.svr);
    try std.testing.expectEqual(@as(u64, 0x300), ApicOffset.icr_low);
    try std.testing.expectEqual(@as(u64, 0x310), ApicOffset.icr_high);
    try std.testing.expectEqual(@as(u64, 0x320), ApicOffset.timer_lvt);
    try std.testing.expectEqual(@as(u64, 0x380), ApicOffset.timer_initial);
    try std.testing.expectEqual(@as(u64, 0x390), ApicOffset.timer_current);
    try std.testing.expectEqual(@as(u64, 0x3E0), ApicOffset.timer_divide);
}

test "timer vector follows the hardware interrupts" {
    try std.testing.expectEqual(timer_vector, timer.first_hardware_vector + timer.hardware_interrupt_count);
}

test "APIC is unmapped by default" {
    unmap();
    try std.testing.expect(!isMapped());
    try std.testing.expectEqual(@as(u32, 0), readApicId());
}
