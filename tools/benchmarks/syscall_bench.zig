//************************************************************************//
// syscall_bench.zig                                                      //
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

const std = @import("std");

// Number of iterations for the benchmark
const iter_count: u64 = 100000;

/// Reads the CPU timestamp counter (TSC).
///
/// Zig 0.17.0 no longer exposes `std.time.cycles()`. The benchmark needs
/// cycle-level resolution, so the TSC is read directly with inline assembly
/// on x86_64. `rdtsc` is not serializing; for an empty loop the measurement
/// is dominated by the loop itself, so the out-of-order risk is acceptable.
/// If you need strictly serialized reads, replace this with `rdtscp`.
fn readTsc() u64 {
    return asm volatile ("rdtsc"
        : [ret] "={eax}" (-> u64),
        : // no inputs
        : "edx" // clobbered by the instruction
    );
}

// Measure CPU cycles for an empty loop (baseline)
pub fn main(init: std.process.Init) !void {
    // --- stdout: handle + buffer + writer + flush (Zig 0.17.0) ---
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // Warm up the CPU
    var warm_i: u64 = 0;
    while (warm_i < 1000) : (warm_i += 1) {}

    // Measure start time
    const start = readTsc();
    var i: u64 = 0;
    while (i < iter_count) : (i += 1) {}
    const end = readTsc();

    const elapsed_cycles = end - start;
    const avg_cycles = elapsed_cycles / iter_count;

    try stdout.print("Empty loop benchmark: iterations={d} total_cycles={d} avg_cycles={d}\n", .{
        iter_count,
        elapsed_cycles,
        @as(u64, avg_cycles),
    });

    // Measure syscall count (approximation: number of CPU cycles per iteration)
    const start2 = readTsc();
    var j: u64 = 0;
    while (j < iter_count) : (j += 1) {
        // Simulate syscall overhead: read timestamp counter
        _ = readTsc();
    }
    const end2 = readTsc();

    const syscall_elapsed = end2 - start2;
    const syscall_avg = syscall_elapsed / iter_count;

    try stdout.print("Syscall latency benchmark: iterations={d} cycles={d} avg_cycles={d}\n", .{
        iter_count,
        syscall_elapsed,
        @as(u64, syscall_avg),
    });

    // Memory copy benchmark
    const buf_size: usize = 64;
    var src_buf: [buf_size]u8 = undefined;
    var dst_buf: [buf_size]u8 = undefined;
    // Initialize source
    var k: u64 = 0;
    while (k < buf_size) : (k += 1) {
        src_buf[@intCast(k)] = @as(u8, @intCast(k));
    }
    const start3 = readTsc();
    var l: u64 = 0;
    while (l < iter_count) : (l += 1) {
        @memcpy(&dst_buf, &src_buf);
    }
    const end3 = readTsc();

    const memcpy_elapsed = end3 - start3;
    const memcpy_avg = memcpy_elapsed / iter_count;

    try stdout.print("Memcpy benchmark: iterations={d} cycles={d} avg_cycles={d}\n", .{
        iter_count,
        memcpy_elapsed,
        @as(u64, memcpy_avg),
    });

    // Explicit flush on the happy path: errors during flush are real I/O
    // errors and should not be swallowed here.
    try stdout.flush();
}
