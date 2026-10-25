//************************************************************************//
//  virtio.zig                                                             //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Virtio device interface (F7 — PROPOSED).
//!
//! This module provides the base definitions for Virtio devices
//! (block, net, console) in QEMU/OVMF. It defines the device status
//! and feature bits, but does not yet implement the queue mechanics
//! or PCI initialization. The interface is documented here for the
//! upcoming F7 milestone (Virtio, network, audio, physical hardware,
//! GPU) per docs/roadmap/phase-status.md.
//!
//! The module is intentionally minimal: it declares the registers and
//! structures without altering the boot sequence or allocating dynamic
//! memory. It can be imported by storage, network, or console drivers
//! when the physical driver is implemented.

const std = @import("std");

/// Device status bits.
pub const DeviceStatus = struct {
    /// Acknowledge: guest has seen device.
    pub const acknowledge: u8 = 1 << 0;
    /// Driver: guest driver is loaded.
    pub const driver: u8 = 1 << 1;
    /// Driver OK: driver initialization complete.
    pub const driver_ok: u8 = 1 << 2;
    /// Features OK: feature bits accepted.
    pub const features_ok: u8 = 1 << 3;
    /// Device needs reset.
    pub const device_needs_reset: u8 = 1 << 6;
    /// Failed: device is in failed state.
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
/// This definition describes the fields that drivers read after
/// `DEVICE_STATUS` reaches `driver_ok`.
pub const ConfigSpace = struct {
    /// Number of queues (read-only for block/net).
    pub const queue_count: u32 = 0;
};

/// Minimal device descriptor for F7 planning.
/// No dynamic allocation; only layout definitions.
pub const Device = struct {
    /// PCI/vendor-specific identification (to be read from PCI config space).
    pub const vendor: u16 = 0x1AF4; // VirtIO (Red Hat)
    pub const device_id_blkv: u16 = 0x1001;
    pub const device_id_net: u16 = 0x1000;

    /// Status byte (device + driver handshake).
    status: u8 = 0,

    /// Feature bits selected by driver (after negotiation).
    features: u32 = 0,

    /// Pointer to the first queue (to be initialized by driver).
    queues: [*]u8 = undefined,
};

/// Descritor de fila Virtio.
///
/// Cada fila tem um `VRING`, que e uma pilha de descritores (`VRING_DESC`),
/// com uma area disponivel (`VRING_AVAIL`) e uma area usada (`VRING_USED`).
/// Um driver escaneia a area esta para chegar a descritores pronto para
/// serem consumidos, e aponta-os na area usada quando a operacao termina.
pub const VRingDesc = struct {
    /// Address of next descriptor in ring.
    addr: u64,
    /// Length of data described.
    len: u32,
    /// Flags (VIRTIO_DESC_F_NEXT, F_WRITE, F_INDIRECT).
    flags: u16 = 0,
};

test "virtioDeviceStatusBitsDefined" {
    try std.testing.expectEqual(@as(u8, 1), DeviceStatus.acknowledge);
    try std.testing.expectEqual(@as(u8, 4), DeviceStatus.features_ok);
}


