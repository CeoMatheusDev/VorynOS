//************************************************************************//
//  virtio.zig                                                             //
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

//! Estruturas e mecanismo de virtqueue para VirtIO em x86-64.
//!
//! Esta etapa implementa a fila em memoria fornecida pelo kernel e o seu
//! protocolo de descritores. Ela ainda nao aloca memoria DMA nem acessa BARs
//! PCI: `VRing` so pode ser conectado a hardware depois que a camada DMA
//! fornecer enderecos fisicos validos e lifetime ate a conclusao.

const std = @import("std");
const pci = @import("pci.zig");

/// Device status bits.
pub const DeviceStatus = struct {
    pub const acknowledge: u8 = 1 << 0;
    pub const driver: u8 = 1 << 1;
    pub const driver_ok: u8 = 1 << 2;
    pub const features_ok: u8 = 1 << 3;
    pub const device_needs_reset: u8 = 1 << 6;
    pub const failed: u8 = 1 << 7;
};

/// Feature bits for block devices (virtio-blk).
pub const BlockFeatures = struct {
    pub const geometry: u32 = 1 << 0;
    pub const ro: u32 = 1 << 1;
    pub const blk_size: u32 = 1 << 2;
    pub const flush: u32 = 1 << 3;
    pub const topology: u32 = 1 << 4;
    pub const discard: u32 = 1 << 13;
};

/// Feature bits for network devices (virtio-net).
pub const NetFeatures = struct {
    pub const csums: u32 = 1 << 0;
    pub const guest_csum: u32 = 1 << 1;
    pub const mtu: u32 = 1 << 3;
    pub const mac: u32 = 1 << 5;
    pub const status: u32 = 1 << 16;
};

/// The device configuration structure lives in the device's memory region.
pub const ConfigSpace = struct {
    pub const queue_count: u32 = 0;
};

/// Minimal device descriptor.
pub const Device = struct {
    pub const vendor: u16 = 0x1AF4;
    pub const device_id_blkv: u16 = 0x1001;
    pub const device_id_net: u16 = 0x1000;

    status: u8 = 0,
    features: u32 = 0,
    queues: [*]u8 = undefined,
};

/// Number of descriptors in the fixed queue used by this increment.
pub const queue_size: usize = 16;

/// Descriptor flags defined by the VirtIO specification.
pub const DescriptorFlags = struct {
    pub const next: u16 = 1 << 0;
    pub const write: u16 = 1 << 1;
    pub const indirect: u16 = 1 << 2;
};

/// VirtIO descriptor. The `next` field is part of the wire layout.
pub const VRingDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

/// Available ring header as defined by the legacy split virtqueue layout.
pub const VRingAvail = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]u16,
};

/// Used ring element.
pub const VRingUsedElem = extern struct {
    id: u32,
    len: u32,
};

/// Used ring header and elements.
pub const VRingUsed = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]VRingUsedElem,
};

pub const QueueError = error{
    InvalidDescriptor,
    DescriptorBusy,
    QueueFull,
    InvalidChain,
    InvalidUsedEntry,
    InvalidDmaBuffer,
    InvalidLayout,
    UnalignedQueue,
    BufferTooSmall,
};

/// Largest queue size defined by the split virtqueue specification.
pub const max_queue_size: u16 = 32768;

/// Alignment required for the used ring of the legacy layout.
pub const used_alignment: usize = 4096;

/// Offsets and sizes of one contiguous split virtqueue.
///
/// The descriptor table starts at offset zero and is aligned to 16 bytes.
/// The available ring follows it. The used ring is aligned to 4096 bytes,
/// which satisfies the legacy requirement and the stronger alignment used
/// by the modern device interface. `total_size` is rounded up to a page.
pub const QueueLayout = struct {
    size: u16,
    descriptor_offset: usize,
    available_offset: usize,
    used_offset: usize,
    descriptor_bytes: usize,
    available_bytes: usize,
    used_bytes: usize,
    total_size: usize,
};

fn checkedAdd(a: usize, b: usize) ?usize {
    return std.math.add(usize, a, b) catch null;
}

fn checkedMul(a: usize, b: usize) ?usize {
    return std.math.mul(usize, a, b) catch null;
}

fn alignForward(value: usize, alignment: usize) ?usize {
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) return null;
    const mask = alignment - 1;
    const sum = std.math.add(usize, value, mask) catch return null;
    return sum & ~mask;
}

/// Computes the wire layout for a split virtqueue of `size` descriptors.
///
/// The available ring includes the two-byte `used_event` field and the used
/// ring includes the two-byte `avail_event` field. Those fields are part of
/// the specification's structure even when the event index feature is not
/// negotiated; the driver simply does not use them.
pub fn splitQueueLayout(size: u16) ?QueueLayout {
    if (size == 0 or size > max_queue_size) return null;

    const count: usize = @intCast(size);
    const descriptor_bytes = checkedMul(@sizeOf(VRingDesc), count) orelse return null;
    const available_ring_bytes = checkedMul(@sizeOf(u16), count) orelse return null;
    const available_bytes = checkedAdd(6, available_ring_bytes) orelse return null;
    const used_unaligned = checkedAdd(descriptor_bytes, available_bytes) orelse return null;
    const used_offset = alignForward(used_unaligned, used_alignment) orelse return null;
    const used_ring_bytes = checkedMul(@sizeOf(VRingUsedElem), count) orelse return null;
    const used_bytes = checkedAdd(6, used_ring_bytes) orelse return null;
    const total_unaligned = checkedAdd(used_offset, used_bytes) orelse return null;
    const total_size = alignForward(total_unaligned, used_alignment) orelse return null;

    return .{
        .size = size,
        .descriptor_offset = 0,
        .available_offset = descriptor_bytes,
        .used_offset = used_offset,
        .descriptor_bytes = descriptor_bytes,
        .available_bytes = available_bytes,
        .used_bytes = used_bytes,
        .total_size = total_size,
    };
}

fn validateLayout(layout: QueueLayout) bool {
    const expected = splitQueueLayout(layout.size) orelse return false;
    return layout.descriptor_offset == expected.descriptor_offset and
        layout.available_offset == expected.available_offset and
        layout.used_offset == expected.used_offset and
        layout.descriptor_bytes == expected.descriptor_bytes and
        layout.available_bytes == expected.available_bytes and
        layout.used_bytes == expected.used_bytes and
        layout.total_size == expected.total_size;
}

/// A split virtqueue that lives in one contiguous, page-aligned buffer.
///
/// The buffer is the memory that the device reads and writes. The driver
/// must program the device with the physical addresses returned by
/// `deviceAddresses` and must keep the buffer alive until the device is
/// reset. The bookkeeping of free descriptors and chains belongs to the
/// driver; this type only provides the wire layout and the atomic index
/// publication.
pub const DeviceQueue = struct {
    memory: []u8,
    layout: QueueLayout,

    /// Initialises a queue in a caller-provided buffer.
    ///
    /// The buffer must be aligned to `used_alignment` and must be at least
    /// `layout.total_size` bytes long. The whole layout is zeroed, which
    /// resets both indices and every ring entry.
    pub fn init(memory: []u8, layout: QueueLayout) QueueError!DeviceQueue {
        if (!validateLayout(layout)) return error.InvalidLayout;
        if (memory.len < layout.total_size) return error.BufferTooSmall;
        if (@intFromPtr(memory.ptr) % used_alignment != 0) return error.UnalignedQueue;
        @memset(memory[0..layout.total_size], 0);
        return .{ .memory = memory, .layout = layout };
    }

    pub fn descriptor(self: *DeviceQueue, index: u16) QueueError!*VRingDesc {
        if (index >= self.layout.size) return error.InvalidDescriptor;
        const offset = self.layout.descriptor_offset +
            @as(usize, index) * @sizeOf(VRingDesc);
        return @ptrCast(@alignCast(self.memory.ptr + offset));
    }

    fn availableFlagsPtr(self: *DeviceQueue) *u16 {
        return @ptrCast(@alignCast(self.memory.ptr + self.layout.available_offset));
    }

    fn availableIdxPtr(self: *DeviceQueue) *u16 {
        return @ptrCast(@alignCast(self.memory.ptr + self.layout.available_offset + 2));
    }

    fn availableRingPtr(self: *DeviceQueue, index: u16) *u16 {
        const offset = self.layout.available_offset + 4 + @as(usize, index) * @sizeOf(u16);
        return @ptrCast(@alignCast(self.memory.ptr + offset));
    }

    fn usedFlagsPtr(self: *DeviceQueue) *u16 {
        return @ptrCast(@alignCast(self.memory.ptr + self.layout.used_offset));
    }

    fn usedIdxPtr(self: *DeviceQueue) *u16 {
        return @ptrCast(@alignCast(self.memory.ptr + self.layout.used_offset + 2));
    }

    fn usedElemPtr(self: *DeviceQueue, index: u16) *VRingUsedElem {
        const offset = self.layout.used_offset + 4 +
            @as(usize, index) * @sizeOf(VRingUsedElem);
        return @ptrCast(@alignCast(self.memory.ptr + offset));
    }

    pub fn availableIndex(self: *DeviceQueue) u16 {
        return @atomicLoad(u16, self.availableIdxPtr(), .acquire);
    }

    pub fn usedIndex(self: *DeviceQueue) u16 {
        return @atomicLoad(u16, self.usedIdxPtr(), .acquire);
    }

    /// Writes one descriptor. The caller publishes the chain with `publish`.
    pub fn setDescriptor(
        self: *DeviceQueue,
        index: u16,
        addr: u64,
        len: u32,
        flags: u16,
        next: u16,
    ) QueueError!void {
        if (len != 0) _ = std.math.add(u64, addr, len) catch return error.InvalidDmaBuffer;
        if (flags & DescriptorFlags.next != 0 and next >= self.layout.size) {
            return error.InvalidChain;
        }
        const entry = try self.descriptor(index);
        entry.* = .{
            .addr = addr,
            .len = len,
            .flags = flags,
            .next = if (flags & DescriptorFlags.next != 0) next else 0,
        };
    }

    /// Publishes the head of a descriptor chain in the available ring.
    ///
    /// The release store of `available.idx` orders the descriptor writes and
    /// the ring entry before the device can observe the new index. The queue
    /// refuses to overwrite an entry while the ring is full.
    pub fn publish(self: *DeviceQueue, index: u16) QueueError!void {
        if (index >= self.layout.size) return error.InvalidDescriptor;
        const available = @atomicLoad(u16, self.availableIdxPtr(), .acquire);
        const used = @atomicLoad(u16, self.usedIdxPtr(), .acquire);
        if (available -% used >= self.layout.size) return error.QueueFull;

        self.availableRingPtr(available % self.layout.size).* = index;
        @atomicStore(u16, self.availableIdxPtr(), available +% 1, .release);
    }

    /// Takes one completion from the used ring.
    ///
    /// `cursor` is the free-running index owned by the driver. The acquire
    /// load of `used.idx` orders the element read after the device's update.
    pub fn takeUsed(self: *DeviceQueue, cursor: *u16) ?VRingUsedElem {
        const used = @atomicLoad(u16, self.usedIdxPtr(), .acquire);
        if (cursor.* == used) return null;
        const element = self.usedElemPtr(cursor.* % self.layout.size).*;
        cursor.* +%= 1;
        return element;
    }
};

/// Physical addresses that the device needs for one queue.
pub const DeviceAddresses = struct {
    descriptor: u64,
    available: u64,
    used: u64,
};

/// Computes the device-visible addresses of a queue.
///
/// `physical_base` is the physical address of the contiguous queue buffer
/// and must be aligned to `used_alignment`, because the used ring has to be
/// 4096-byte aligned. The function refuses an overflow instead of truncating
/// an address.
pub fn deviceAddresses(layout: QueueLayout, physical_base: u64) ?DeviceAddresses {
    if (!validateLayout(layout)) return null;
    if (physical_base == 0 or physical_base % used_alignment != 0) return null;

    const descriptor = std.math.add(u64, physical_base, layout.descriptor_offset) catch return null;
    const available = std.math.add(u64, physical_base, layout.available_offset) catch return null;
    const used = std.math.add(u64, physical_base, layout.used_offset) catch return null;
    return .{
        .descriptor = descriptor,
        .available = available,
        .used = used,
    };
}

/// Identity map used to initialise the chain owner of every descriptor.
///
/// A default-initialised `VRing` is valid: descriptor `i` starts as a
/// standalone chain owned by itself. Without this default, the field would
/// start as all zeroes and every descriptor above zero would appear to
/// belong to descriptor zero, which makes `linkDescriptor` reject valid
/// chains.
const default_heads: [queue_size]u16 = blk: {
    var heads: [queue_size]u16 = undefined;
    for (&heads, 0..) |*head, index| head.* = @intCast(index);
    break :blk heads;
};

/// Fixed-size split virtqueue state.
///
/// The arrays are deliberately kept separate from a DMA allocation. The
/// device-visible indices `available.idx` and `used.idx` are published with
/// release stores, and consumers read them with acquire loads. This makes
/// the ordering explicit even though this host-tested representation is not
/// yet device-visible; `DeviceQueue` is the contiguous wire-layout form.
pub const VRing = struct {
    descriptors: [queue_size]VRingDesc = @splat(.{ .addr = 0, .len = 0, .flags = 0, .next = 0 }),
    available: VRingAvail = .{ .flags = 0, .idx = 0, .ring = @splat(0) },
    used: VRingUsed = .{ .flags = 0, .idx = 0, .ring = @splat(.{ .id = 0, .len = 0 }) },
    last_used_idx: u16 = 0,
    in_use: [queue_size]bool = @splat(false),
    submitted: [queue_size]bool = @splat(false),
    completed: [queue_size]bool = @splat(false),
    /// Head of the chain that owns each descriptor. A standalone descriptor
    /// points to itself. This is what lets the queue reject a mutation of a
    /// linked descriptor after the head has been submitted.
    head_of: [queue_size]u16 = default_heads,
};

pub fn initVRing() VRing {
    return .{};
}

/// Reserves one descriptor for a request.
pub fn allocateDescriptor(ring: *VRing) ?u16 {
    for (&ring.in_use, 0..) |*used, index| {
        if (!used.*) {
            used.* = true;
            ring.submitted[index] = false;
            ring.completed[index] = false;
            ring.head_of[index] = @intCast(index);
            ring.descriptors[index] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };
            return @intCast(index);
        }
    }
    return null;
}

/// Configures a reserved descriptor.
pub fn setupDescriptor(ring: *VRing, index: u16, addr: u64, len: u32, flags: u16) QueueError!void {
    try checkStandalone(ring, index);
    ring.descriptors[index] = .{ .addr = addr, .len = len, .flags = flags, .next = 0 };
}

/// Adds the next link to a reserved descriptor chain.
pub fn linkDescriptor(ring: *VRing, index: u16, next: u16) QueueError!void {
    try checkMutable(ring, index);
    try checkMutable(ring, next);
    if (index == next) return error.InvalidChain;

    // `next` must not already belong to a chain, and linking it must not
    // close a cycle through the current head.
    if (ring.head_of[next] != next) return error.InvalidChain;
    if (ring.descriptors[next].flags & DescriptorFlags.next != 0) return error.InvalidChain;
    if (ring.head_of[index] == next) return error.InvalidChain;
    if (ring.descriptors[index].flags & DescriptorFlags.next != 0) return error.InvalidChain;

    ring.descriptors[index].flags |= DescriptorFlags.next;
    ring.descriptors[index].next = next;
    ring.head_of[next] = ring.head_of[index];
}

/// Publishes a descriptor chain in the available ring.
pub fn submitDescriptor(ring: *VRing, index: u16) QueueError!void {
    try checkDescriptor(ring, index);
    if (ring.head_of[index] != index) return error.InvalidChain;
    if (ring.submitted[index]) return error.DescriptorBusy;

    const avail = @atomicLoad(u16, &ring.available.idx, .acquire);
    const consumed = @atomicLoad(u16, &ring.last_used_idx, .acquire);
    if (avail -% consumed >= queue_size) return error.QueueFull;
    try validateChain(ring, index);

    ring.available.ring[@as(usize, avail) % queue_size] = index;
    ring.submitted[index] = true;
    @atomicStore(u16, &ring.available.idx, avail +% 1, .release);
}

/// Models a device publishing one completion into the used ring.
pub fn deviceComplete(ring: *VRing, index: u16, len: u32) QueueError!void {
    if (index >= queue_size) return error.InvalidUsedEntry;
    if (ring.head_of[index] != index) return error.InvalidUsedEntry;
    if (!ring.in_use[index] or !ring.submitted[index] or ring.completed[index]) {
        return error.InvalidUsedEntry;
    }
    try validateChain(ring, index);

    const used = @atomicLoad(u16, &ring.used.idx, .acquire);
    const consumed = @atomicLoad(u16, &ring.last_used_idx, .acquire);
    if (used -% consumed >= queue_size) return error.QueueFull;
    ring.used.ring[@as(usize, used) % queue_size] = .{ .id = index, .len = len };
    ring.completed[index] = true;
    @atomicStore(u16, &ring.used.idx, used +% 1, .release);
}

/// Retrieves one completed chain and releases every descriptor in it.
pub fn popUsed(ring: *VRing) QueueError!?VRingUsedElem {
    const used = @atomicLoad(u16, &ring.used.idx, .acquire);
    const cursor = @atomicLoad(u16, &ring.last_used_idx, .acquire);
    if (cursor == used) return null;

    const element = ring.used.ring[@as(usize, cursor) % queue_size];
    if (element.id >= queue_size) return error.InvalidUsedEntry;
    const index: u16 = @intCast(element.id);
    if (ring.head_of[index] != index) return error.InvalidUsedEntry;
    if (!ring.in_use[index] or !ring.submitted[index] or !ring.completed[index]) {
        return error.InvalidUsedEntry;
    }
    try validateChain(ring, index);

    var current = index;
    while (true) {
        const descriptor = ring.descriptors[current];
        const has_next = descriptor.flags & DescriptorFlags.next != 0;
        const next = descriptor.next;

        ring.in_use[current] = false;
        ring.submitted[current] = false;
        ring.completed[current] = false;
        ring.head_of[current] = current;
        ring.descriptors[current] = .{ .addr = 0, .len = 0, .flags = 0, .next = 0 };

        if (!has_next) break;
        current = next;
    }

    @atomicStore(u16, &ring.last_used_idx, cursor +% 1, .release);
    return element;
}

fn checkDescriptor(ring: *const VRing, index: u16) QueueError!void {
    if (index >= queue_size) return error.InvalidDescriptor;
    if (!ring.in_use[index]) return error.InvalidDescriptor;
}

/// Rejects a mutation when the head of the descriptor's chain is in flight.
fn checkMutable(ring: *const VRing, index: u16) QueueError!void {
    try checkDescriptor(ring, index);
    const head = ring.head_of[index];
    if (head >= queue_size) return error.InvalidChain;
    if (ring.submitted[head]) return error.DescriptorBusy;
}

/// Rejects a setup that would rewrite a linked descriptor or a chain head.
fn checkStandalone(ring: *const VRing, index: u16) QueueError!void {
    try checkMutable(ring, index);
    if (ring.head_of[index] != index) return error.InvalidChain;
    if (ring.descriptors[index].flags & DescriptorFlags.next != 0) return error.InvalidChain;
}

fn validateChain(ring: *const VRing, first: u16) QueueError!void {
    var seen: [queue_size]bool = @splat(false);
    var current = first;
    var count: usize = 0;
    while (true) {
        if (current >= queue_size) return error.InvalidChain;
        if (!ring.in_use[current]) return error.InvalidChain;
        if (ring.head_of[current] != first) return error.InvalidChain;
        if (seen[current]) return error.InvalidChain;
        seen[current] = true;
        count += 1;
        if (count > queue_size) return error.InvalidChain;
        const descriptor = ring.descriptors[current];
        if (descriptor.flags & DescriptorFlags.next == 0) return;
        current = descriptor.next;
    }
}

/// PCI base placeholder. BAR discovery is not part of this phase.
pub const pci_virtio_base: u64 = 0xFE_0000_00;

pub const PciVirtioInfo = struct {
    present: bool = false,
    bus: u8 = 0,
    device: u8 = 0,
    base: u64 = 0,
    vendor: u16 = 0,
    device_id: u16 = 0,
    device_type: u8 = 0,
};

pub fn detectVirtioDevice() PciVirtioInfo {
    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32) : (dev += 1) {
            const vendor = pci.readConfigWord(@intCast(bus), dev, 0, 0x00);
            if (vendor == 0xFFFF) continue;
            if (vendor != Device.vendor) continue;
            const device_id = pci.readConfigWord(@intCast(bus), dev, 0, 0x02);
            const bar_low = pci.readConfigDword(@intCast(bus), dev, 0, 0x10);
            const bar_high = if ((bar_low & 1) == 0 and ((bar_low >> 1) & 0x3) == 0x2)
                pci.readConfigDword(@intCast(bus), dev, 0, 0x14)
            else
                0;
            const bar = pci.decodeBar(bar_low, bar_high);
            return .{
                .present = true,
                .bus = @intCast(bus),
                .device = dev,
                .base = if (bar) |value| value.address else 0,
                .vendor = vendor,
                .device_id = device_id,
                .device_type = classifyDevice(device_id),
            };
        }
    }
    return .{};
}

pub fn classifyDevice(device_id: u16) u8 {
    return switch (device_id) {
        0x1001 => 1,
        0x1000 => 2,
        0x1002 => 3,
        0x1003 => 4,
        else => 0,
    };
}

/// Prepares a descriptor for a DMA buffer without mapping it.
/// The caller must ensure the physical address is valid until completion.
/// `flags` carries `DescriptorFlags.write` for a device-writable RX buffer;
/// `next` and `indirect` are rejected because this helper publishes a single
/// descriptor, not a chain.
/// This is not a complete driver: no PCI BAR read, no feature negotiation,
/// and no device notification is performed by this function alone.
pub fn submitDmaDescriptor(
    ring: *VRing,
    index: u16,
    dma_phys: u64,
    len: u32,
    flags: u16,
) QueueError!void {
    if (dma_phys == 0 or len == 0) return error.InvalidDmaBuffer;
    _ = std.math.add(u64, dma_phys, len) catch return error.InvalidDmaBuffer;
    if (flags & (DescriptorFlags.next | DescriptorFlags.indirect) != 0) {
        return error.InvalidDescriptor;
    }
    try checkStandalone(ring, index);
    ring.descriptors[index] = .{
        .addr = dma_phys,
        .len = len,
        .flags = flags,
        .next = 0,
    };
    try submitDescriptor(ring, index);
}

/// Models one descriptor-handled DMA transfer for host testing.
/// The physical buffer must have been reserved by the caller.
pub fn completeDmaDescriptor(ring: *VRing, index: u16, completed_len: u32) QueueError!void {
    try deviceComplete(ring, index, completed_len);
}

pub const BlockDriverInterface = struct {
    init_queues: *const fn () void,
    submit_request: *const fn (addr: u32, len: u32, flags: u16) bool,
};

test "virtio layout matches split queue specification" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(VRingDesc));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(VRingDesc, "addr"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(VRingDesc, "len"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(VRingDesc, "flags"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(VRingDesc, "next"));
    try std.testing.expectEqual(@as(usize, 2 + 2 + queue_size * 2), @sizeOf(VRingAvail));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(VRingUsedElem));
}

test "virtio descriptor allocation, chain submission and completion" {
    var ring = initVRing();
    const first = allocateDescriptor(&ring).?;
    const second = allocateDescriptor(&ring).?;
    try setupDescriptor(&ring, first, 0x1000, 512, 0);
    try setupDescriptor(&ring, second, 0x2000, 16, DescriptorFlags.write);
    try linkDescriptor(&ring, first, second);
    try submitDescriptor(&ring, first);
    try std.testing.expectEqual(@as(u16, 1), ring.available.idx);

    try deviceComplete(&ring, first, 16);
    const completion = (try popUsed(&ring)).?;
    try std.testing.expectEqual(first, @as(u16, @intCast(completion.id)));
    try std.testing.expectEqual(@as(u32, 16), completion.len);
    try std.testing.expect(!ring.in_use[first]);
    try std.testing.expect(!ring.in_use[second]);
    try std.testing.expectEqual(second, ring.head_of[second]);
}

test "virtio queue rejects resubmission and invalid completions" {
    var ring = initVRing();
    var descriptors: [queue_size]u16 = undefined;
    for (&descriptors) |*descriptor| {
        descriptor.* = allocateDescriptor(&ring).?;
        try setupDescriptor(&ring, descriptor.*, 0x1000, 1, 0);
        try submitDescriptor(&ring, descriptor.*);
    }
    try std.testing.expect(allocateDescriptor(&ring) == null);
    try std.testing.expectError(error.DescriptorBusy, submitDescriptor(&ring, descriptors[0]));
    try std.testing.expectError(
        error.InvalidUsedEntry,
        deviceComplete(&ring, @intCast(queue_size), 0),
    );
}

test "virtio queue rejects mutation of an in-flight chain" {
    var ring = initVRing();
    const first = allocateDescriptor(&ring).?;
    const second = allocateDescriptor(&ring).?;
    try setupDescriptor(&ring, first, 0x1000, 512, 0);
    try setupDescriptor(&ring, second, 0x2000, 16, DescriptorFlags.write);
    try linkDescriptor(&ring, first, second);
    try submitDescriptor(&ring, first);

    try std.testing.expectError(
        error.DescriptorBusy,
        setupDescriptor(&ring, first, 0xDEAD, 1, 0),
    );
    try std.testing.expectError(
        error.DescriptorBusy,
        setupDescriptor(&ring, second, 0xDEAD, 1, 0),
    );
    try std.testing.expectError(
        error.DescriptorBusy,
        linkDescriptor(&ring, first, second),
    );

    // The device may only complete the head of the chain.
    try std.testing.expectError(error.InvalidUsedEntry, deviceComplete(&ring, second, 0));
}

test "virtio queue rejects cycles and out of range used ids" {
    var ring = initVRing();
    const first = allocateDescriptor(&ring).?;
    const second = allocateDescriptor(&ring).?;
    try setupDescriptor(&ring, first, 0, 1, 0);
    try setupDescriptor(&ring, second, 0, 1, 0);
    try linkDescriptor(&ring, first, second);
    try std.testing.expectError(error.InvalidChain, linkDescriptor(&ring, second, first));

    ring.used.ring[0] = .{ .id = queue_size + 1, .len = 0 };
    ring.used.idx = 1;
    try std.testing.expectError(error.InvalidUsedEntry, popUsed(&ring));
}

test "virtio descriptor uses dma descriptor interface" {
    var ring = initVRing();
    const desc = allocateDescriptor(&ring).?;
    try submitDmaDescriptor(&ring, desc, 0x1000, 512, 0);
    try std.testing.expectEqual(@as(u16, 1), ring.available.idx);

    try completeDmaDescriptor(&ring, desc, 512);
    const elem = (try popUsed(&ring)).?;
    try std.testing.expectEqual(desc, @as(u16, @intCast(elem.id)));
}

test "virtio dma descriptor carries the write flag for rx buffers" {
    var ring = initVRing();
    const desc = allocateDescriptor(&ring).?;
    try submitDmaDescriptor(&ring, desc, 0x1000, 512, DescriptorFlags.write);
    try std.testing.expectEqual(DescriptorFlags.write, ring.descriptors[desc].flags);
}

test "virtio dma descriptor rejects invalid ranges and chained flags" {
    var ring = initVRing();
    const desc = allocateDescriptor(&ring).?;
    try std.testing.expectError(error.InvalidDmaBuffer, submitDmaDescriptor(&ring, desc, 0, 1, 0));
    try std.testing.expectError(error.InvalidDmaBuffer, submitDmaDescriptor(&ring, desc, 0x1000, 0, 0));
    try std.testing.expectError(error.InvalidDmaBuffer, submitDmaDescriptor(&ring, desc, std.math.maxInt(u64), 1, 0));
    try std.testing.expectError(error.InvalidDescriptor, submitDmaDescriptor(&ring, desc, 0x1000, 1, DescriptorFlags.next));
    try std.testing.expectError(error.InvalidDescriptor, submitDmaDescriptor(&ring, desc, 0x1000, 1, DescriptorFlags.indirect));
}

test "virtio device classification is pure" {
    try std.testing.expectEqual(@as(u8, 1), classifyDevice(0x1001));
    try std.testing.expectEqual(@as(u8, 2), classifyDevice(0x1000));
    try std.testing.expectEqual(@as(u8, 0), classifyDevice(0xFFFF));
    try std.testing.expect(!(PciVirtioInfo{}).present);
}

test "virtio split queue layout is contiguous and aligned" {
    const layout = splitQueueLayout(queue_size).?;
    try std.testing.expectEqual(@as(usize, 0), layout.descriptor_offset);
    try std.testing.expectEqual(@as(usize, 16 * queue_size), layout.available_offset);
    try std.testing.expectEqual(@as(usize, 4096), layout.used_offset);
    try std.testing.expectEqual(@as(usize, 8192), layout.total_size);
    try std.testing.expectEqual(@as(usize, 16 * queue_size), layout.descriptor_bytes);
    try std.testing.expectEqual(@as(usize, 6 + 2 * queue_size), layout.available_bytes);
    try std.testing.expectEqual(@as(usize, 6 + 8 * queue_size), layout.used_bytes);
    try std.testing.expect(layout.used_offset % used_alignment == 0);
    try std.testing.expect(layout.total_size % used_alignment == 0);
}

test "virtio split queue layout scales and rejects invalid sizes" {
    const layout = splitQueueLayout(256).?;
    try std.testing.expectEqual(@as(usize, 4096), layout.available_offset);
    try std.testing.expectEqual(@as(usize, 8192), layout.used_offset);
    try std.testing.expectEqual(@as(usize, 12288), layout.total_size);
    try std.testing.expect(splitQueueLayout(0) == null);
    try std.testing.expect(splitQueueLayout(std.math.maxInt(u16)) == null);
    try std.testing.expect(splitQueueLayout(max_queue_size) != null);
}

test "virtio default ring initializes chain heads" {
    const ring: VRing = .{};
    for (ring.head_of, 0..) |head, index| {
        try std.testing.expectEqual(@as(u16, @intCast(index)), head);
    }
}

test "virtio device queue exposes the wire layout" {
    var storage: [8192]u8 align(4096) = undefined;
    const layout = splitQueueLayout(queue_size).?;
    var queue = try DeviceQueue.init(storage[0..], layout);

    try std.testing.expectEqual(@as(u16, 0), queue.availableIndex());
    try std.testing.expectEqual(@as(u16, 0), queue.usedIndex());

    try queue.setDescriptor(0, 0x1000, 512, 0, 0);
    const descriptor = try queue.descriptor(0);
    try std.testing.expectEqual(@as(u64, 0x1000), descriptor.addr);
    try std.testing.expectEqual(@as(u32, 512), descriptor.len);

    try queue.publish(0);
    try std.testing.expectEqual(@as(u16, 1), queue.availableIndex());
    const available_ring: *u16 = @ptrCast(@alignCast(&storage[layout.available_offset + 4]));
    try std.testing.expectEqual(@as(u16, 0), available_ring.*);

    // The device owns the used ring. The test writes it directly, then the
    // driver consumes the completion through the public accessor.
    queue.usedElemPtr(0).* = .{ .id = 0, .len = 512 };
    @atomicStore(u16, queue.usedIdxPtr(), 1, .release);

    var cursor: u16 = 0;
    const element = queue.takeUsed(&cursor).?;
    try std.testing.expectEqual(@as(u32, 0), element.id);
    try std.testing.expectEqual(@as(u32, 512), element.len);
    try std.testing.expect(queue.takeUsed(&cursor) == null);
}

test "virtio device queue refuses invalid layouts and full rings" {
    var storage: [8192]u8 align(4096) = undefined;
    const layout = splitQueueLayout(queue_size).?;

    const bad = QueueLayout{
        .size = queue_size,
        .descriptor_offset = 0,
        .available_offset = 0,
        .used_offset = 0,
        .descriptor_bytes = 0,
        .available_bytes = 0,
        .used_bytes = 0,
        .total_size = 1,
    };
    try std.testing.expectError(error.InvalidLayout, DeviceQueue.init(storage[0..], bad));
    try std.testing.expectError(
        error.BufferTooSmall,
        DeviceQueue.init(storage[0 .. layout.total_size - 1], layout),
    );

    var unaligned_storage: [8192 + 1]u8 align(4096) = undefined;
    try std.testing.expectError(
        error.UnalignedQueue,
        DeviceQueue.init(unaligned_storage[1..], layout),
    );

    var small_storage: [8192]u8 align(4096) = undefined;
    const small_layout = splitQueueLayout(2).?;
    var small = try DeviceQueue.init(small_storage[0..], small_layout);
    try small.setDescriptor(0, 0x1000, 1, 0, 0);
    try small.setDescriptor(1, 0x2000, 1, 0, 0);
    try small.publish(0);
    try small.publish(1);
    try std.testing.expectError(error.QueueFull, small.publish(0));
}

test "virtio device addresses follow the layout offsets" {
    const layout = splitQueueLayout(queue_size).?;
    const addresses = deviceAddresses(layout, 0x100000).?;
    try std.testing.expectEqual(@as(u64, 0x100000), addresses.descriptor);
    try std.testing.expectEqual(
        @as(u64, 0x100000) + @as(u64, @intCast(layout.available_offset)),
        addresses.available,
    );
    try std.testing.expectEqual(
        @as(u64, 0x100000) + @as(u64, @intCast(layout.used_offset)),
        addresses.used,
    );

    try std.testing.expect(deviceAddresses(layout, 0x100001) == null);
    try std.testing.expect(deviceAddresses(layout, std.math.maxInt(u64) - 0xFFF) == null);
}
