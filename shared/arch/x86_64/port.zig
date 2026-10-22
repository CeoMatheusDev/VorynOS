// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! x86_64 port I/O primitives.
//!
//! Thin wrappers around the `in`/`out` instruction families. They are the
//! lowest layer of the VorynOS architecture support and are shared by the
//! bootloader and the kernel.

/// Writes a byte to an I/O port.
pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

/// Reads a byte from an I/O port.
pub inline fn inb(port: u16) u8 {
    var result: u8 = undefined;
    asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (result),
        : [port] "{dx}" (port),
        : .{ .memory = true });
    return result;
}

/// Disables interrupts by clearing the interrupt enable flag.
pub inline fn cli() void {
    asm volatile ("cli" ::: .{ .memory = true });
}

/// Halts the processor until the next interrupt.
pub inline fn hlt() void {
    asm volatile ("hlt" ::: .{ .memory = true });
}

/// Stops the processor forever.
pub inline fn haltForever() noreturn {
    while (true) {
        hlt();
    }
}
