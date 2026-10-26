//************************************************************************//
//  port.zig                                                              //
//************************************************************************//
//                        This file is part of:                           //
//                              VorynOS                                   //
//             https://github.com/CeoMatheusDev/VorynOS                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 VorynOS - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

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

/// Writes a 32-bit value to an I/O port.
pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

/// Reads a 32-bit value from an I/O port.
pub inline fn inl(port: u16) u32 {
    var result: u32 = undefined;
    asm volatile ("inl %[port], %[value]"
        : [value] "={eax}" (result),
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
