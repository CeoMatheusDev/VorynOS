//************************************************************************//
//  bin2zig.zig                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
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
    _ = it.next();
    const input_arg = it.next() orelse {
        std.debug.print("usage: bin2zig <input> <output>\n", .{});
        return error.InvalidArguments;
    };
    const output_arg = it.next() orelse {
        std.debug.print("usage: bin2zig <input> <output>\n", .{});
        return error.InvalidArguments;
    };
    if (it.next() != null) {
        std.debug.print("usage: bin2zig <input> <output>\n", .{});
        return error.InvalidArguments;
    }

    const input_path = input_arg;
    const output_path = output_arg;

    const cwd = std.Io.Dir.cwd();
    const input = try cwd.readFileAlloc(init.io, input_path, allocator, .limited(1024 * 1024));
    defer allocator.free(input);

    const file = try cwd.createFile(init.io, output_path, .{ .truncate = true });
    defer file.close(init.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try writer.interface.writeAll("pub const bytes = [_]u8{\n");
    var index: usize = 0;
    while (index < input.len) : (index += 1) {
        if (index % 16 == 0) try writer.interface.writeAll("    ");
        try writer.interface.print("0x{x:0>2},", .{input[index]});
        if (index % 16 == 15 or index + 1 == input.len) try writer.interface.writeAll("\n");
    }
    try writer.interface.writeAll("};\n");
    try writer.interface.flush();
}
