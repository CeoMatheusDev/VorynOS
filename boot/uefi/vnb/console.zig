//************************************************************************//
//  console.zig                                                           //
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

//! Voryn Native Boot console.
//!
//! The loader writes to two independent channels:
//!
//!   1. the serial port (COM1), driven directly by the VorynOS x86_64 serial
//!      driver. This is the channel used by the automated boot tests and it
//!      survives the transition to the kernel, therefore it is the primary
//!      diagnostic channel of the whole project;
//!   2. the firmware console (`EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL`), so that a
//!      user booting on real hardware sees the loader progress even when no
//!      serial cable is attached.
//!
//! Both channels are best effort: a failure in the firmware console must
//! never abort the boot.

const std = @import("std");
const uefi = std.os.uefi;
const voryn = @import("voryn_shared");
const protocols = @import("protocols.zig");

const serial = voryn.serial;

/// Maximum length of a single firmware console message.
const max_console_message = 256;

/// The loader console.
pub const Console = struct {
    /// Firmware text output, `null` when the firmware does not provide it.
    text_output: ?protocols.Protocol(protocols.SimpleTextOutputBody) = null,

    /// Prepares the console. The serial port is always available, the
    /// firmware console is used when the system table exposes one.
    pub fn init() Console {
        serial.init();

        var text_output: ?protocols.Protocol(protocols.SimpleTextOutputBody) = null;
        if (uefi.system_table.con_out) |console_out| {
            text_output = protocols.Protocol(protocols.SimpleTextOutputBody).init(@ptrCast(console_out));
        }

        return .{ .text_output = text_output };
    }

    /// Writes a formatted message to every available channel.
    pub fn print(self: *const Console, comptime format: []const u8, args: anytype) void {
        serial.print(format, args);
        self.printToFirmware(format, args);
    }

    /// Writes a formatted line to every available channel.
    pub fn printLine(self: *const Console, comptime format: []const u8, args: anytype) void {
        serial.printLine(format, args);
        self.printToFirmware(format, args);
        self.writeFirmware("\r\n");
    }

    /// Detaches the firmware console.
    ///
    /// The firmware console must not be used after `ExitBootServices`, the
    /// firmware is not allowed to keep its console alive at that point. The
    /// serial port is a hardware device and stays usable.
    pub fn disableFirmware(self: *Console) void {
        self.text_output = null;
    }

    fn printToFirmware(self: *const Console, comptime format: []const u8, args: anytype) void {
        var buffer: [max_console_message]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, args) catch return;
        self.writeFirmware(text);
    }

    fn writeFirmware(self: *const Console, text: []const u8) void {
        const output = self.text_output orelse return;

        var utf16: [max_console_message]u16 = undefined;
        const count = @min(text.len, utf16.len - 1);
        for (text[0..count], 0..) |byte, index| {
            utf16[index] = byte;
        }
        utf16[count] = 0;

        const encoded: [:0]const u16 = utf16[0..count :0];
        _ = output.body.output_string(output.thisPointer(), @ptrCast(encoded));
    }
};
