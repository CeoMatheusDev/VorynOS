//************************************************************************//
//  virtio_net.zig — Virtio network device interface (F7)                  //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

const std = @import("std");
const virtio = @import("virtio.zig");

pub const PacketHeader = struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
};

pub const NetworkDevice = struct {
    info: virtio.PciVirtioInfo = .{},
    ring: virtio.VRing = .{},
    packet_buf: u64 = 0,
};
