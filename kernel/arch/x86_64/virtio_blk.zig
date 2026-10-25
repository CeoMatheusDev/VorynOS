//************************************************************************//
//  virtio_blk.zig — Virtio block driver interface (F7)                    //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

const std = @import("std");
const virtio = @import("virtio.zig");

pub const BlockDevice = struct {
    info: virtio.PciVirtioInfo = .{},
    ring: virtio.VRing = .{},
    device_id: u8 = 0,
};
