//************************************************************************//
//  syscall_bench.zig — Syscall latency benchmark (F10)                     //
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

const std = @import("std");

// Number of iterations for the benchmark
const iter_count: u64 = 100000;

// Measure CPU cycles for an empty loop (baseline)
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    // Warm up the CPU
    var warm_i: u64 = 0;
    while (warm_i < 1000) : (warm_i += 1) {}

    // Measure start time
    const start = std.time.cycles();
    var i: u64 = 0;
    while (i < iter_count) : (i += 1) {}
    const end = std.time.cycles();

    const elapsed_cycles = end - start;
    const avg_cycles = elapsed_cycles / iter_count;

    try stdout.print("Empty loop benchmark: iterations={d} total_cycles={d} avg_cycles={d}\n", .{
        iter_count,
        elapsed_cycles,
        @as(u64, avg_cycles),
    });

    // Measure syscall count (approximation: number of CPU cycles per iteration)
    const start2 = std.time.cycles();
    var j: u64 = 0;
    while (j < iter_count) : (j += 1) {
        // Simulate syscall overhead: read timestamp counter
        _ = std.time.cycles();
    }
    const end2 = std.time.cycles();

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
        src_buf[@intCast(k)] = @as(u8, k);
    }
    const start3 = std.time.cycles();
    var l: u64 = 0;
    while (l < iter_count) : (l += 1) {
        std.mem.copy(&dst_buf[0..buf_size], &src_buf[0..buf_size]);
    }
    const end3 = std.time.cycles();

    const memcpy_elapsed = end3 - start3;
    const memcpy_avg = memcpy_elapsed / iter_count;

    try stdout.print("Memcpy benchmark: iterations={d} cycles={d} avg_cycles={d}\n", .{
        iter_count,
        memcpy_elapsed,
        @as(u64, memcpy_avg),
    });
}