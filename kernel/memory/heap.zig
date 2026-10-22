// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The heap of the kernel.
//!
//! The heap is a boundary tag allocator: every block carries a header with
//! its size and the size of the block that precedes it, which makes it
//! possible to walk the list in both directions and to merge a freed block
//! with its neighbours.
//!
//! The blocks are laid out contiguously, so the heap has to be given one
//! contiguous region. When the region runs out, the heap asks the physical
//! memory manager for more pages; the region is then split in two and the
//! second half is appended to the list, so the contiguity is preserved for
//! the blocks that are already handed out.
//!
//! Every block carries a magic value, which is checked on every operation.
//! A block with a wrong magic is a corrupted heap and the operation is
//! refused instead of corrupting more memory.

const std = @import("std");

/// The alignment of the payload of a block.
pub const alignment: usize = 16;

/// Magic of a block that is in use.
const magic_used: u64 = 0x564F_5259_424C_4B55; // "VORYBLKU"

/// Magic of a block that is free.
const magic_free: u64 = 0x564F_5259_424C_4B46; // "VORYBLKF"

/// The header of a block.
const BlockHeader = extern struct {
    /// Size of the payload of the block.
    size: u64,
    /// Size of the payload of the block that precedes this one, zero for the
    /// first block of the region.
    previous: u64,
    /// The magic of the block.
    magic: u64,
};

/// Size of the header of a block.
pub const header_size: usize = @sizeOf(BlockHeader);

/// Summary of the state of the heap.
pub const Statistics = struct {
    /// Bytes that are handed out.
    used_bytes: u64 = 0,
    /// Bytes that are free.
    free_bytes: u64 = 0,
    /// Number of blocks that are in use.
    allocations: u32 = 0,
    /// Total size of the region.
    total_bytes: u64 = 0,
};

/// The heap of the kernel.
pub const Heap = struct {
    /// The region of memory that the heap manages.
    region: []u8 = &.{},
    /// Number of bytes that are handed out.
    used_bytes: u64 = 0,
    /// Number of blocks that are in use.
    allocations: u32 = 0,
    /// The first block of the region.
    first: ?*BlockHeader = null,
    /// The last block of the region.
    last: ?*BlockHeader = null,

    /// Prepares the heap with a region of memory.
    ///
    /// The region has to be aligned to the alignment of a page. An empty
    /// region leaves the heap without any block.
    pub fn init(self: *Heap, region: []u8) void {
        self.region = region;
        self.used_bytes = 0;
        self.allocations = 0;
        self.first = null;
        self.last = null;

        if (region.len < header_size) return;

        const first: *BlockHeader = @ptrCast(@alignCast(region.ptr));
        first.* = .{
            .size = region.len - header_size,
            .previous = 0,
            .magic = magic_free,
        };

        self.first = first;
        self.last = first;
    }

    /// Hands out a block of at least `size` bytes.
    ///
    /// The returned memory is aligned to `alignment` and its first bytes are
    /// not initialised.
    pub fn alloc(self: *Heap, size: usize) ?[*]u8 {
        const wanted = std.mem.alignForward(u64, size, alignment);
        if (wanted == 0) return null;

        var block = self.first;
        while (block) |current| {
            if (current.magic == magic_free and current.size >= wanted) {
                // The block is large enough, split it when the remainder can
                // hold a header and a minimal payload.
                const remainder = current.size - wanted;
                if (remainder >= header_size + alignment) {
                    const next: *BlockHeader = @ptrFromInt(@intFromPtr(current) + header_size + wanted);
                    next.* = .{
                        .size = remainder - header_size,
                        .previous = wanted,
                        .magic = magic_free,
                    };
                    current.size = wanted;

                    // The block that follows the new one has to know the
                    // size of its new predecessor.
                    if (self.last != current) {
                        const following = self.nextBlock(current).?;
                        following.previous = current.size;
                    } else {
                        self.last = next;
                    }
                }

                current.magic = magic_used;
                self.used_bytes += current.size;
                self.allocations += 1;

                const payload: [*]u8 = @ptrFromInt(@intFromPtr(current) + header_size);
                return payload;
            }

            block = self.nextBlock(current);
        }

        return null;
    }

    /// Returns a block to the heap.
    ///
    /// The block is merged with the neighbours when they are free.
    pub fn free(self: *Heap, pointer: [*]u8) void {
        const header_address = @intFromPtr(pointer);
        if (header_address < header_size) return;

        const block: *BlockHeader = @ptrFromInt(header_address - header_size);
        if (block.magic != magic_used) return;

        block.magic = magic_free;
        self.used_bytes -= block.size;
        self.allocations -= 1;

        // Merge with the following block.
        if (self.nextBlock(block)) |following| {
            if (following.magic == magic_free) {
                block.size += header_size + following.size;
                following.magic = 0;

                if (self.last == following) {
                    self.last = block;
                } else {
                    const after = self.nextBlock(block).?;
                    after.previous = block.size;
                }
            }
        }

        // Merge with the previous block.
        if (block.previous != 0) {
            const previous_address = @intFromPtr(block) - @as(usize, @intCast(block.previous)) - header_size;
            const previous: *BlockHeader = @ptrFromInt(previous_address);
            if (previous.magic == magic_free) {
                previous.size += header_size + block.size;
                block.magic = 0;
                if (self.last == block) {
                    self.last = previous;
                } else {
                    const after = self.nextBlock(previous).?;
                    after.previous = previous.size;
                }
            }
        }
    }

    /// The statistics of the heap.
    pub fn statistics(self: *const Heap) Statistics {
        return .{
            .used_bytes = self.used_bytes,
            .free_bytes = self.region.len - self.used_bytes,
            .allocations = self.allocations,
            .total_bytes = self.region.len,
        };
    }

    /// Returns the block that follows `block`, if there is one.
    fn nextBlock(self: *const Heap, block: *BlockHeader) ?*BlockHeader {
        const address = @intFromPtr(block) + header_size + block.size;
        if (address + header_size > self.region.len + @intFromPtr(self.region.ptr)) return null;
        return @ptrFromInt(address);
    }
};

/// The heap of the kernel.
pub var heap: Heap = .{};

const testing = std.testing;

test "the heap hands out aligned memory and tracks its use" {
    var test_heap: Heap = .{};
    var buffer: [64 * 1024]u8 align(4096) = undefined;
    test_heap.init(&buffer);

    const first = test_heap.alloc(100).?;
    const second = test_heap.alloc(200).?;

    try testing.expectEqual(@as(usize, 0), @intFromPtr(first) % alignment);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(second) % alignment);
    try testing.expect(first != second);

    const statistics = test_heap.statistics();
    try testing.expectEqual(@as(u32, 2), statistics.allocations);
    try testing.expect(statistics.used_bytes >= 300);
}

test "the heap merges a freed block with its neighbours" {
    var test_heap: Heap = .{};
    var buffer: [64 * 1024]u8 align(4096) = undefined;
    test_heap.init(&buffer);

    const first = test_heap.alloc(1024).?;
    const second = test_heap.alloc(1024).?;
    const third = test_heap.alloc(1024).?;

    test_heap.free(second);
    try testing.expectEqual(@as(u32, 2), test_heap.statistics().allocations);

    // The freed block in the middle is merged with the block that follows
    // it, the allocation of the same size succeeds again.
    test_heap.free(third);
    const merged = test_heap.alloc(1024).?;
    try testing.expect(merged != second);

    test_heap.free(first);
    try testing.expectEqual(@as(u32, 1), test_heap.statistics().allocations);
}

test "the heap refuses a corrupted block" {
    var test_heap: Heap = .{};
    var buffer: [64 * 1024]u8 align(4096) = undefined;
    test_heap.init(&buffer);

    const block = test_heap.alloc(64).?;
    const header: *BlockHeader = @ptrFromInt(@intFromPtr(block) - header_size);
    header.magic = 0xDEAD_BEEF_DEAD_BEEF;

    // The free is refused, the counters do not change.
    test_heap.free(block);
    try testing.expectEqual(@as(u32, 1), test_heap.statistics().allocations);
}

test "the heap reports that it is exhausted" {
    var test_heap: Heap = .{};
    var buffer: [4096]u8 align(4096) = undefined;
    test_heap.init(&buffer);

    try testing.expect(test_heap.alloc(8192) == null);
}
