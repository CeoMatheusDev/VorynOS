//************************************************************************//
//  recovery-mode.zig                                                     //
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

//! Host diagnostic that boots the image with the recovery ramdisk.
//!
//! The file was `recovery-mode.sh` with Zig content, outside the build graph
//! and it did not compile. It is installed as `recovery-mode` by `build.zig`.
//!
//! Boots VorynOS from a RAM disk when the normal system is broken.
//! Launches QEMU with the recovery image attached, waits for the kernel to
//! boot, then stops the emulator.
//!
//! Usage:
//!
//!     recovery-mode --image=<vorynos.img> [--timeout=<seconds>] [--fat=<label>]
//!
//! The `RECOVERY_MEM` environment variable overrides the memory size given
//! to QEMU (in MiB, default 512).

const std = @import("std");

/// Command line options.
const Options = struct {
    image: []const u8,
    timeout: u64 = 60,
    /// Accepted for parity with the shell script; currently unused.
    fat_label: ?[]const u8 = null,
};

fn printUsage() void {
    std.debug.print(
        "Usage: recovery-mode --image=<vorynos.img> [--timeout=<seconds>] [--fat=<label>]\n",
        .{},
    );
}

fn parseArgs(init: std.process.Init) !Options {
    var image: ?[]const u8 = null;
    var timeout: u64 = 60;
    var fat: ?[]const u8 = null;

    var it = init.minimal.args.iterate();
    _ = it.next(); // skip program name

    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--image=")) {
            image = arg["--image=".len..];
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            const value = arg["--timeout=".len..];
            timeout = std.fmt.parseInt(u64, value, 10) catch {
                std.debug.print("recovery-mode: invalid timeout: {s}\n", .{value});
                return error.InvalidTimeout;
            };
        } else if (std.mem.startsWith(u8, arg, "--fat=")) {
            fat = arg["--fat=".len..];
        } else if (std.mem.eql(u8, arg, "--help") or
            std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--usage"))
        {
            printUsage();
            std.process.exit(0);
        } else {
            std.debug.print("recovery-mode: unknown argument: {s}\n", .{arg});
            return error.InvalidArgument;
        }
    }

    return .{
        .image = image orelse {
            std.debug.print("recovery-mode: --image is required\n", .{});
            return error.MissingImage;
        },
        .timeout = timeout,
        .fat_label = fat,
    };
}

/// Returns true if `pid` is still running. Uses `kill(pid, 0)` exactly like
/// `kill -0` in the shell script.
fn isAlive(pid: std.posix.pid_t) bool {
    // Signal 0 asks the kernel about the process without delivering
    // anything. Zig 0.17 types the signal as an enum, and there is no named
    // member for it, therefore the value is spelled numerically.
    const probe: std.posix.SIG = @fromBackingInt(@intCast(0));
    std.posix.kill(pid, probe) catch return false;
    return true;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const opts = parseArgs(init) catch |err| {
        printUsage();
        return err;
    };
    // The `--fat=` option is intentionally unused: it exists only so the
    // command line matches the original shell script.
    _ = opts.fat_label;

    const drive_arg = try std.fmt.allocPrint(
        allocator,
        "format=raw,file={s}",
        .{opts.image},
    );
    defer allocator.free(drive_arg);

    // Zig 0.17 entrega o ambiente em `std.process.Init`; `std.posix.getenv`
    // nao existe mais, e era o motivo de este arquivo nunca ter compilado.
    const mem = init.environ_map.get("RECOVERY_MEM") orelse "512";

    const argv = [_][]const u8{
        "qemu-system-x86_64",
        "-drive",
        drive_arg,
        "-serial",
        "mon:stdio",
        "-m",
        mem,
        "-cpu",
        "qemu64",
        "-no-reboot",
        "-no-shutdown",
        "-d",
        "int",
    };

    // Zig 0.17 substituiu `Child.init`/`Child.spawn` por `process.spawn`.
    var child = try std.process.spawn(init.io, .{
        .argv = &argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = init.environ_map,
    });
    // Zig 0.17 tipa o id como opcional: o spawn nativo sempre o define.
    const pid = child.id orelse {
        std.debug.print("recovery-mode: the child has no process identifier\n", .{});
        return error.MissingChildId;
    };

    // Give the kernel `timeout` seconds to come up.
    init.io.sleep(.fromSeconds(@intCast(opts.timeout)), .awake) catch {};

    if (!isAlive(pid)) {
        std.debug.print("recovery-mode: QEMU terminated early\n", .{});
        return error.QemuTerminated;
    }

    child.kill(init.io);
    std.debug.print(
        "recovery-mode: the kernel booted successfully; the system can be diagnosed\n",
        .{},
    );
}
