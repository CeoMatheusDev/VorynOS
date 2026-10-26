//************************************************************************//
//  bin2zig.zig                                                           //
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

//! Converts a binary file into a Zig source file that exports its bytes.
//!
//! The generated file has the form:
//!
//!     pub const bytes = [_]u8{ 0x.., ... };
//!
//! The kernel imports the generated module and writes the bytes into the
//! RamFS, so the native application is a real ELF produced by the
//! toolchain and not a structure assembled by hand.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var it = init.minimal.args.iterate();
    _ = it.next(); // skip program name

    const input_arg = it.next() orelse {
        std.log.err("usage: bin2zig <input> <output>", .{});
        return error.InvalidArguments;
    };
    const output_arg = it.next() orelse {
        std.log.err("usage: bin2zig <input> <output>", .{});
        return error.InvalidArguments;
    };
    if (it.next() != null) {
        std.log.err("usage: bin2zig <input> <output>", .{});
        return error.InvalidArguments;
    }

    const cwd = std.Io.Dir.cwd();

    const input = try cwd.readFileAlloc(init.io, input_arg, allocator, .limited(1024 * 1024));
    defer allocator.free(input);

    const file = try cwd.createFile(init.io, output_arg, .{ .truncate = true });
    defer file.close(init.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    const out = &writer.interface;

    try out.writeAll("pub const bytes = [_]u8{\n");

    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        if (index % 16 == 0) try out.writeAll("    ");
        try out.print("0x{x:0>2},", .{input[index]});
        if (index % 16 == 15 or index + 1 == input.len) try out.writeAll("\n");
    }

    try out.writeAll("};\n");
    try out.flush(); // obrigatório na nova API
}
