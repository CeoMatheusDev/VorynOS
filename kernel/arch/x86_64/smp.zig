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
