//************************************************************************//
//  dma.zig                                                               //
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

//! Reserva segura de paginas fisicas contiguas para DMA x86-64.
//!
//! Esta camada fornece apenas a propriedade fisica do buffer. Ela nao afirma
//! que o endereco virtual correspondente esta mapeado, nem programa um
//! dispositivo. O chamador deve obter um mapeamento virtual valido antes de
//! escrever os bytes e deve manter o objeto vivo ate a conclusao DMA.

const std = @import("std");
const physical = @import("physical.zig");
const handoff = @import("voryn_shared").handoff;

/// Limite exclusivo para dispositivos com enderecos DMA de 32 bits.
pub const dma32_limit: u64 = 0x1_0000_0000;

/// Size of one page, shared with the physical manager and the page tables.
pub const page_size: u64 = handoff.page_size;

/// Base of the kernel virtual window used for DMA buffers.
///
/// The address is above the kernel image and below the usual framebuffer
/// addresses. It is a virtual address only: the physical address of a
/// buffer is programmed into the device and is unrelated to this base.
pub const virtual_window_base: u64 = 0x4000_0000;

/// Size of the kernel DMA virtual window.
///
/// The window is deliberately bounded: every mapping must fit in the
/// static bitmap, and an exhausted window fails instead of silently
/// wrapping or overwriting another buffer.
pub const virtual_window_size: u64 = 64 * 1024 * 1024;

/// Number of pages described by the DMA window.
pub const virtual_window_pages: u32 = @intCast(virtual_window_size / page_size);

/// Translation operations supplied by the architecture layer.
pub const Mapper = struct {
    map: *const fn (virtual: u64, physical: u64) bool,
    unmap: *const fn (virtual: u64) void,
};

pub const Buffer = struct {
    physical_address: u64,
    byte_length: u64,
    page_count: u32,

    /// Devolve todas as paginas ao mesmo gerenciador que as reservou.
    ///
    /// The caller must unmap the virtual range before releasing the pages.
    pub fn release(self: *Buffer, manager: *physical.Manager) void {
        if (self.page_count == 0) return;
        var index: u32 = 0;
        while (index < self.page_count) : (index += 1) {
            manager.free(self.physical_address + @as(u64, index) * page_size);
        }
        self.* = .{ .physical_address = 0, .byte_length = 0, .page_count = 0 };
    }
};

pub const MappedBuffer = struct {
    virtual: [*]u8,
    physical: u64,
    length: u64,
};

/// A monotonic virtual-address allocator for DMA buffers.
///
/// The window serialises its own bookkeeping with a small atomic lock. The
/// allocator is monotonic on purpose: `unmap` clears the page table entry
/// and the bitmap, but does not recycle the virtual address, because the
/// kernel does not yet perform a TLB shootdown on the other processors.
/// Recycling an address without that shootdown could let another processor
/// keep writing through a stale translation.
pub fn Window(comptime pages: u32) type {
    return struct {
        const Self = @This();

        pub const capacity = pages;
        pub const bitmap_bytes = (pages + 7) / 8;

        bitmap: [bitmap_bytes]u8 = @splat(0),
        next_page: u32 = 0,
        base: u64 = 0,
        mapper: ?Mapper = null,
        lock: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        /// Creates a window. The base must be page aligned and the whole
        /// range must fit in a 64-bit address without wrapping.
        pub fn init(base: u64, mapper: Mapper) ?Self {
            if (pages == 0 or base == 0) return null;
            if (base % page_size != 0) return null;
            const bytes = std.math.mul(u64, @as(u64, pages), page_size) catch return null;
            _ = std.math.add(u64, base, bytes) catch return null;
            return .{ .base = base, .mapper = mapper };
        }

        fn lockWindow(self: *Self) void {
            while (self.lock.swap(1, .acquire) != 0) {
                while (self.lock.load(.monotonic) != 0) std.atomic.spinLoopHint();
            }
        }

        fn unlockWindow(self: *Self) void {
            self.lock.store(0, .release);
        }

        fn setMapped(self: *Self, page: u32, mapped: bool) void {
            const mask: u8 = @as(u8, 1) << @intCast(page % 8);
            if (mapped) {
                self.bitmap[page / 8] |= mask;
            } else {
                self.bitmap[page / 8] &= ~mask;
            }
        }

        fn pageIsMapped(self: *const Self, page: u32) bool {
            const mask: u8 = @as(u8, 1) << @intCast(page % 8);
            return self.bitmap[page / 8] & mask != 0;
        }

        /// Maps a physically contiguous buffer into the window.
        ///
        /// Every page is translated through the supplied mapper. A partial
        /// failure is rolled back, and the next call reuses the same virtual
        /// range because `next_page` is only advanced on success.
        pub fn map(self: *Self, buffer: Buffer) ?MappedBuffer {
            const mapper = self.mapper orelse return null;
            if (buffer.physical_address == 0 or buffer.byte_length == 0) return null;
            if (buffer.page_count == 0) return null;
            if (buffer.physical_address % page_size != 0) return null;

            const rounded = std.math.add(u64, buffer.byte_length, page_size - 1) catch
                return null;
            const expected_pages = rounded / page_size;
            if (@as(u64, buffer.page_count) != expected_pages) return null;

            const mapped_bytes = std.math.mul(
                u64,
                @as(u64, buffer.page_count),
                page_size,
            ) catch return null;
            _ = std.math.add(u64, buffer.physical_address, mapped_bytes) catch return null;

            self.lockWindow();
            defer self.unlockWindow();

            if (buffer.page_count > capacity) return null;
            if (self.next_page > capacity) return null;
            if (buffer.page_count > capacity - self.next_page) return null;

            const start = self.next_page;
            const virtual = self.base + @as(u64, start) * page_size;

            var mapped_pages: u32 = 0;
            while (mapped_pages < buffer.page_count) : (mapped_pages += 1) {
                const v = virtual + @as(u64, mapped_pages) * page_size;
                const p = buffer.physical_address + @as(u64, mapped_pages) * page_size;
                if (!mapper.map(v, p)) {
                    var rollback: u32 = 0;
                    while (rollback < mapped_pages) : (rollback += 1) {
                        mapper.unmap(virtual + @as(u64, rollback) * page_size);
                    }
                    return null;
                }
            }

            var page = start;
            while (page < start + buffer.page_count) : (page += 1) {
                self.setMapped(page, true);
            }
            self.next_page += buffer.page_count;

            return .{
                .virtual = @as([*]u8, @ptrFromInt(virtual)),
                .physical = buffer.physical_address,
                .length = buffer.byte_length,
            };
        }

        /// Removes a mapping created by `map`.
        ///
        /// The virtual address is not recycled; see the type comment.
        pub fn unmap(self: *Self, mapped: *MappedBuffer) void {
            const mapper = self.mapper orelse return;
            if (mapped.length == 0) return;

            const virtual = @intFromPtr(mapped.virtual);
            if (virtual < self.base) return;
            const offset = virtual - self.base;
            if (offset % page_size != 0) return;

            const rounded = std.math.add(u64, mapped.length, page_size - 1) catch return;
            const pages_u64 = rounded / page_size;
            if (pages_u64 == 0 or pages_u64 > capacity) return;
            const page_count: u32 = @intCast(pages_u64);
            const start_u64 = offset / page_size;
            if (start_u64 >= capacity) return;
            const start: u32 = @intCast(start_u64);
            if (page_count > capacity - start) return;

            self.lockWindow();
            defer self.unlockWindow();

            var page = start;
            while (page < start + page_count) : (page += 1) {
                mapper.unmap(self.base + @as(u64, page) * page_size);
                self.setMapped(page, false);
            }

            mapped.virtual = undefined;
            mapped.physical = 0;
            mapped.length = 0;
        }

        pub fn isMapped(self: *Self, page: u32) bool {
            self.lockWindow();
            defer self.unlockWindow();
            if (page >= capacity) return false;
            return self.pageIsMapped(page);
        }

        pub fn mappedCount(self: *Self) u32 {
            self.lockWindow();
            defer self.unlockWindow();
            var count: u32 = 0;
            var page: u32 = 0;
            while (page < capacity) : (page += 1) {
                if (self.pageIsMapped(page)) count += 1;
            }
            return count;
        }
    };
}

pub const KernelWindow = Window(virtual_window_pages);

/// The window used by the kernel.
pub var kernel_window: KernelWindow = .{};

/// Installs the architecture mapper and resets the window.
///
/// The function is called once during boot, before any DMA buffer is
/// mapped. Calling it again discards the existing bookkeeping.
pub fn initWindow(mapper: Mapper) bool {
    kernel_window = KernelWindow.init(virtual_window_base, mapper) orelse return false;
    return true;
}

/// Maps a DMA buffer into the kernel virtual window.
pub fn mapVirtual(buffer: Buffer) ?MappedBuffer {
    return kernel_window.map(buffer);
}

/// Removes the virtual mapping. The physical pages are released by
/// `Buffer.release`, separately, after the mapping is gone.
pub fn unmapVirtual(mapped: *MappedBuffer, _manager: *physical.Manager) void {
    _ = _manager;
    kernel_window.unmap(mapped);
}

/// Reserva um buffer fisicamente contiguo.
///
/// `max_address` e exclusivo. Nenhum ponteiro virtual e inventado ou
/// devolvido: a validade do mapeamento virtual deve ser estabelecida por uma
/// camada de paging antes do acesso aos bytes.
pub fn allocate(manager: *physical.Manager, byte_length: u64, max_address: u64) ?Buffer {
    if (byte_length == 0 or max_address == 0) return null;
    const rounded = std.math.add(u64, byte_length, page_size - 1) catch return null;
    const page_count_u64 = rounded / page_size;
    if (page_count_u64 == 0 or page_count_u64 > std.math.maxInt(u32)) return null;
    const page_count: u32 = @intCast(page_count_u64);
    const address = manager.allocateContiguous(page_count, max_address) orelse return null;
    return .{
        .physical_address = address,
        .byte_length = byte_length,
        .page_count = page_count,
    };
}

const testing = std.testing;

test "DMA allocation is contiguous and respects a 32-bit limit" {
    var manager: physical.Manager = .{};
    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 16,
    }};
    manager.init(&map);

    var buffer = allocate(&manager, 5000, dma32_limit).?;
    try testing.expectEqual(@as(u64, 0x100000), buffer.physical_address);
    try testing.expectEqual(@as(u64, 5000), buffer.byte_length);
    try testing.expectEqual(@as(u32, 2), buffer.page_count);
    try testing.expect(manager.isUsed(buffer.physical_address));
    try testing.expect(manager.isUsed(buffer.physical_address + handoff.page_size));

    buffer.release(&manager);
    try testing.expectEqual(@as(u32, 0), buffer.page_count);
    try testing.expect(!manager.isUsed(0x100000));
}

test "DMA allocation rejects zero, overflow and unavailable ranges" {
    var manager: physical.Manager = .{};
    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 2,
    }};
    manager.init(&map);

    try testing.expect(allocate(&manager, 0, dma32_limit) == null);
    try testing.expect(allocate(&manager, 1, 0) == null);
    try testing.expect(allocate(&manager, std.math.maxInt(u64), dma32_limit) == null);
    try testing.expect(allocate(&manager, 3 * handoff.page_size, dma32_limit) == null);
}

const MockMapper = struct {
    const MapCall = struct { virtual: u64, physical: u64 };

    var map_calls: [16]MapCall = undefined;
    var unmap_calls: [16]u64 = undefined;
    var map_count: usize = 0;
    var unmap_count: usize = 0;
    var fail_at: usize = std.math.maxInt(usize);

    fn reset() void {
        map_count = 0;
        unmap_count = 0;
        fail_at = std.math.maxInt(usize);
    }

    fn map(virtual: u64, physical_address: u64) bool {
        if (map_count == fail_at) return false;
        if (map_count >= map_calls.len) return false;
        map_calls[map_count] = .{ .virtual = virtual, .physical = physical_address };
        map_count += 1;
        return true;
    }

    fn unmap(virtual: u64) void {
        if (unmap_count >= unmap_calls.len) return;
        unmap_calls[unmap_count] = virtual;
        unmap_count += 1;
    }

    const mapper = Mapper{ .map = map, .unmap = unmap };
};

test "DMA window maps pages through the installed mapper" {
    MockMapper.reset();
    var window = Window(4).init(0x4000_0000, MockMapper.mapper).?;
    const buffer: Buffer = .{
        .physical_address = 0x100000,
        .byte_length = 5000,
        .page_count = 2,
    };

    var mapped = window.map(buffer).?;
    try testing.expectEqual(@as(usize, 2), MockMapper.map_count);
    try testing.expectEqual(@as(u64, 0x4000_0000), MockMapper.map_calls[0].virtual);
    try testing.expectEqual(@as(u64, 0x100000), MockMapper.map_calls[0].physical);
    try testing.expectEqual(@as(u64, 0x4000_1000), MockMapper.map_calls[1].virtual);
    try testing.expectEqual(@as(u64, 0x101000), MockMapper.map_calls[1].physical);
    try testing.expectEqual(@as(u64, 0x100000), mapped.physical);
    try testing.expectEqual(@as(u64, 5000), mapped.length);
    try testing.expect(window.isMapped(0));
    try testing.expect(window.isMapped(1));
    try testing.expectEqual(@as(u32, 2), window.mappedCount());

    window.unmap(&mapped);
    try testing.expectEqual(@as(usize, 2), MockMapper.unmap_count);
    try testing.expectEqual(@as(u64, 0x4000_0000), MockMapper.unmap_calls[0]);
    try testing.expectEqual(@as(u64, 0x4000_1000), MockMapper.unmap_calls[1]);
    try testing.expectEqual(@as(u32, 0), window.mappedCount());
    try testing.expectEqual(@as(u64, 0), mapped.length);
    try testing.expectEqual(@as(u64, 0), mapped.physical);

    // The window is monotonic: the freed address is not reused.
    var second = window.map(buffer).?;
    try testing.expectEqual(@as(usize, 0x4000_2000), @intFromPtr(second.virtual));
    window.unmap(&second);
}

test "DMA window rolls back a partial mapping" {
    MockMapper.reset();
    var window = Window(4).init(0x4000_0000, MockMapper.mapper).?;
    const buffer: Buffer = .{
        .physical_address = 0x100000,
        .byte_length = 5000,
        .page_count = 2,
    };

    MockMapper.fail_at = 1;
    try testing.expect(window.map(buffer) == null);
    try testing.expectEqual(@as(usize, 1), MockMapper.map_count);
    try testing.expectEqual(@as(usize, 1), MockMapper.unmap_count);
    try testing.expectEqual(@as(u64, 0x4000_0000), MockMapper.unmap_calls[0]);
    try testing.expectEqual(@as(u32, 0), window.mappedCount());
    try testing.expectEqual(@as(u32, 0), window.next_page);

    MockMapper.fail_at = std.math.maxInt(usize);
    var mapped = window.map(buffer).?;
    try testing.expectEqual(@as(usize, 0x4000_0000), @intFromPtr(mapped.virtual));
    window.unmap(&mapped);
}

test "DMA window refuses invalid buffers and exhaustion" {
    MockMapper.reset();
    var window = Window(2).init(0x4000_0000, MockMapper.mapper).?;

    const zero: Buffer = .{ .physical_address = 0, .byte_length = 1, .page_count = 1 };
    try testing.expect(window.map(zero) == null);

    const unaligned: Buffer = .{
        .physical_address = 0x100001,
        .byte_length = 1,
        .page_count = 1,
    };
    try testing.expect(window.map(unaligned) == null);

    const inconsistent: Buffer = .{
        .physical_address = 0x100000,
        .byte_length = 1,
        .page_count = 2,
    };
    try testing.expect(window.map(inconsistent) == null);

    const overflow: Buffer = .{
        .physical_address = std.math.maxInt(u64) - 0xFFF,
        .byte_length = 0x2000,
        .page_count = 2,
    };
    try testing.expect(window.map(overflow) == null);

    const one: Buffer = .{
        .physical_address = 0x100000,
        .byte_length = page_size,
        .page_count = 1,
    };
    var first = window.map(one).?;
    var second = window.map(one).?;
    try testing.expect(window.map(one) == null);
    window.unmap(&first);
    try testing.expect(window.map(one) == null);
    window.unmap(&second);

    try testing.expect(Window(2).init(0x4000_0001, MockMapper.mapper) == null);
    try testing.expect(
        Window(2).init(std.math.maxInt(u64) - 0xFFF, MockMapper.mapper) == null,
    );
}

test "DMA window without a mapper refuses to map" {
    var window: Window(2) = .{};
    const buffer: Buffer = .{
        .physical_address = 0x100000,
        .byte_length = page_size,
        .page_count = 1,
    };
    try testing.expect(window.map(buffer) == null);
    try testing.expectEqual(@as(u32, 0), window.mappedCount());
}

test "DMA release is idempotent for one owner" {
    var manager: physical.Manager = .{};
    const map = [_]handoff.MemoryDescriptor{.{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 1,
    }};
    manager.init(&map);

    var buffer = allocate(&manager, 1, dma32_limit).?;
    buffer.release(&manager);
    buffer.release(&manager);
    try testing.expectEqual(@as(u32, 0), buffer.page_count);
}
