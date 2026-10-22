// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! VorynOS 16550 compatible serial driver (COM1).
//!
//! The driver is intentionally simple: the first port of the 16550 is
//! programmed for 115200 baud, 8 data bits, no parity and one stop bit, and
//! the transmitter holding register is polled before every byte is written.
//!
//! It is used by the bootloader (VNB) and by the kernel (VNK) so both can
//! report their progress on the same console, which is the primary
//! diagnostic channel of the project.

const std = @import("std");
const port = @import("port.zig");

/// Default I/O port of the first UART (COM1).
pub const com1_port: u16 = 0x3F8;

/// Register offsets relative to the base port.
const rbr = 0; // Receiver buffer register (read)
const thr = 0; // Transmitter holding register (write)
const dll = 0; // Divisor latch low byte
const dlm = 1; // Divisor latch high byte
const ier = 1; // Interrupt enable register
const fcr = 2; // FIFO control register
const lcr = 3; // Line control register
const mcr = 4; // Modem control register
const lsr = 5; // Line status register

const lcr_8n1 = 0x03; // 8 bits, no parity, one stop bit
const fcr_enable = 0xC7; // Enable and clear both FIFOs, 14 byte trigger
const mcr_dtr_rts_out2 = 0x0F; // DTR + RTS + OUT2 (enables the IRQ line)

/// Line status register: transmitter holding register empty.
const lsr_thre: u8 = 0x20;

var initialized: bool = false;

/// Program the UART for 115200 8N1 and enable the transmitter.
pub fn init() void {
    port.outb(com1_port + ier, 0x00); // No interrupts, polled operation.
    port.outb(com1_port + lcr, 0x80); // Enable the divisor latch.
    port.outb(com1_port + dll, 0x01); // 115200 baud for a 1.8432 MHz clock.
    port.outb(com1_port + dlm, 0x00);
    port.outb(com1_port + lcr, lcr_8n1);
    port.outb(com1_port + fcr, fcr_enable);
    port.outb(com1_port + mcr, mcr_dtr_rts_out2);
    initialized = true;
}

/// Writes a single byte, waiting for the transmitter to become ready.
pub fn writeByte(byte: u8) void {
    while ((port.inb(com1_port + lsr) & lsr_thre) == 0) {}
    port.outb(com1_port + thr, byte);
}

/// Writes a slice of bytes.
pub fn write(bytes: []const u8) void {
    for (bytes) |byte| writeByte(byte);
}

/// Writes a slice of bytes followed by a carriage return and a line feed.
pub fn writeLine(bytes: []const u8) void {
    write(bytes);
    writeByte('\r');
    writeByte('\n');
}

// ---------------------------------------------------------------------------
// Formatted output
// ---------------------------------------------------------------------------

const buffer_size = 512;

var storage: [buffer_size]u8 = undefined;

/// Formatted output writer connected to the serial port.
pub var writer: std.Io.Writer = .{
    .vtable = &vtable,
    .buffer = &storage,
    .end = 0,
};

const vtable: std.Io.Writer.VTable = .{
    .drain = drain,
    .flush = flush,
    .rebase = rebase,
};

/// Sends the buffered content and the given data to the serial port.
fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    var consumed: usize = 0;

    // The pending buffer content is always sent first.
    if (w.end != 0) {
        write(w.buffer[0..w.end]);
        w.end = 0;
    }

    if (data.len == 0) return consumed;

    for (data[0 .. data.len - 1]) |chunk| {
        write(chunk);
        consumed += chunk.len;
    }

    // The last element is repeated `splat` times.
    const pattern = data[data.len - 1];
    var index: usize = 0;
    while (index < splat) : (index += 1) {
        write(pattern);
    }
    consumed += splat * pattern.len;

    return consumed;
}

fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (w.end == 0) return;
    write(w.buffer[0..w.end]);
    w.end = 0;
}

fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
    _ = preserve;
    try flush(w);
    if (capacity > w.buffer.len) return error.WriteFailed;
}

/// Prints a formatted message to the serial port and flushes it.
///
/// The writer cannot fail: the sink is a hardware register, so the error
/// union of the writer is always empty and the errors are discarded.
pub fn print(comptime format: []const u8, args: anytype) void {
    writer.print(format, args) catch {};
    writer.flush() catch {};
}

/// Prints a formatted line to the serial port and flushes it.
///
/// The writer cannot fail, see `print`.
pub fn printLine(comptime format: []const u8, args: anytype) void {
    writer.print(format, args) catch {};
    writer.writeAll("\r\n") catch {};
    writer.flush() catch {};
}
