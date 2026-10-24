//************************************************************************//
//  ps2.zig                                                               //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! F6.7: IRQ1 PS/2 keyboard (legacy 8042). Acesso ao buffer em contexto
//! normal exige interrupções locais desabilitadas; IRQ1 é o único produtor.

const voryn = @import("voryn_shared");
const keyboard = @import("voryn_keyboard");
const cpu = @import("../arch/x86_64/cpu.zig");

const status_port: u16 = 0x64;
const data_port: u16 = 0x60;
const output_full: u8 = 1;
const auxiliary_data: u8 = 0x20;

var decoder: keyboard.Set1Decoder = .{};
var queue: keyboard.EventQueue = .{};
var received: usize = 0;

/// Accumulated cost of the IRQ1 handler since the previous take.
pub const IrqStats = struct {
    interrupts: usize = 0,
    bytes: usize = 0,
    cycles: u64 = 0,
};

var irq_stats: IrqStats = .{};

/// IRQ1: consome apenas bytes de teclado presentes no output buffer.
/// O EOI é responsabilidade do despachante de interrupções.
pub fn onInterrupt() void {
    const start = cpu.readTimestamp();
    var bytes: usize = 0;

    // Limite de trabalho por IRQ: evita prender o processador em hardware
    // defeituoso ou em uma fila de saída que nunca esvazia.
    for (0..16) |_| {
        const status = voryn.port.inb(status_port);
        if (status & output_full == 0) break;
        const byte = voryn.port.inb(data_port);
        if (status & auxiliary_data != 0) continue;
        received +|= 1;
        bytes +|= 1;
        keyboard.ingest(&decoder, &queue, byte);
    }

    irq_stats.interrupts +|= 1;
    irq_stats.bytes +|= bytes;
    irq_stats.cycles +|= cpu.readTimestamp() - start;
}

/// Returns the cost accumulated since the previous call and resets it.
/// The counters are updated by IRQ1, therefore the caller must disable the
/// local interrupts while taking and resetting them.
pub fn takeIrqStatsIrqsDisabled() IrqStats {
    const stats = irq_stats;
    irq_stats = .{};
    return stats;
}

/// Somente com IRQs locais desabilitadas (por exemplo, CLI/STI no consumidor).
pub fn popIrqsDisabled() ?keyboard.KeyEvent {
    return queue.pop();
}

/// Somente com IRQs locais desabilitadas.
pub fn receivedIrqsDisabled() usize {
    return received;
}

/// Somente com IRQs locais desabilitadas.
pub fn droppedIrqsDisabled() usize {
    return queue.dropped;
}
