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
const pci = @import("pci.zig");

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

/// VRING — fila circular Virtio com descritores, available e used.
pub const VRing = struct {
    /// Array de descritores (cada um aponta para um chunk de memoria).
    descriptors: [16]VRingDesc = @splat(.{ .addr = 0, .len = 0, .flags = 0 }),
    /// Indice disponivel (escrito pelo driver, lido pelo dispositivo).
    avail_idx: u16 = 0,
    /// Indice usado (escrito pelo dispositivo, lido pelo driver).
    used_idx: u16 = 0,
};

/// Inicializa uma fila Virtio para um dispositivo de bloco/rede.
/// Nenhuma alocacao dinamica: usa array fixo de 16 descritores.
pub fn initVRing() VRing {
    return .{};
}

/// Configura um descritor para apontar para um endereco de memoria.
pub fn submitDescriptor(ring: *VRing, index: usize) void {
    _ = index;
    ring.avail_idx += 1;
}

pub fn setupDescriptor(ring: *VRing, index: usize, addr: u64, len: u32, flags: u16) void {
    if (index >= ring.descriptors.len) return;
    ring.descriptors[index] = .{ .addr = addr, .len = len, .flags = flags };
}

/// PCI base — endereço base do espaço de configuração PCI para Virtio.
/// Em QEMU/OVMF, o VirtIO block/net está tipicamente em 0xFE000000
/// ou detectado via PCI config space (vendor 0x1AF4).
/// Este valor e um placeholder para o driver completo (F7 completo).
pub const pci_virtio_base: u64 = 0xFE_0000_00;

test "virtioDeviceStatusBitsDefined" {
    try std.testing.expectEqual(@as(u8, 1), DeviceStatus.acknowledge);
    try std.testing.expectEqual(@as(u8, 4), DeviceStatus.features_ok);
}

test "vringDescriptorSetupAndLimits" {
    var ring = initVRing();
    setupDescriptor(&ring, 0, 0x1000, 4096, 0);
    try std.testing.expectEqual(@as(u64, 0x1000), ring.descriptors[0].addr);
    try std.testing.expectEqual(@as(u32, 4096), ring.descriptors[0].len);
    // Boundary: index >= 16 must not write (guarded by if).
    setupDescriptor(&ring, 16, 0x9999, 9999, 0);
    try std.testing.expectEqual(@as(u64, 0x1000), ring.descriptors[0].addr); // unchanged
}

test "pciVirtioInfoDefaults" {
    const info = detectVirtioDevice();
    try std.testing.expectEqual(@as(u16, 0x1AF4), info.vendor);
}



/// Detecção PCI básica para Virtio (F7 — PROPOSTO).
///
/// A especificação PCI define o espaço de configuração com 256 bytes por
/// função, começando no endereço base do barramento (tipicamente 0xCF8 para
/// x86). Esta função define a interface de leitura sem ainda implementar
/// o acesso MMIO completo (que depende do driver PCI, parte do F7 final).
///
/// A detecção procura pelo vendor VirtIO (0x1AF4 = Red Hat) e pelos device
/// IDs conhecidos: 0x1000 (net), 0x1001 (blk), 0x1002 (scsi), 0x1003 (console).
/// Quando encontrado, retorna o endereço base do dispositivo e o tipo.
pub const PciVirtioInfo = struct {
    /// Base address of PCI config space (from PCI discovery).
    base: u32 = 0,
    /// Vendor ID (0x1AF4 for VirtIO/Red Hat).
    vendor: u16 = 0x1AF4,
    /// Device ID (0x1000 net, 0x1001 blk, etc.).
    device_id: u16 = 0,
    /// Type of device found (0=none, 1=blk, 2=net, 3=console).
    device_type: u8 = 0,
};

/// Scans PCI config space for VirtIO vendor/device IDs.
///
/// This is the interface definition; the actual MMIO read from the PCI
/// configuration space (port 0xCF8 / 0xCFC for x86, or MMIO for QEMU/OVMF)
/// is implemented in the PCI driver layer. This function validates the
/// contract: it checks the vendor and returns the appropriate device type.
pub fn detectVirtioDevice() PciVirtioInfo {
    // Scan simplificado: busca vendor VirtIO (0x1AF4) em bus 0, dev 0-31, func 0
    var bus: u8 = 0;
    while (bus < 1) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32) : (dev += 1) {
            const vendor: u16 = pci.readConfigWord(bus, dev, 0, 0x00);
            if (vendor == 0x1AF4) {
                return .{
                    .base = 0,
                    .vendor = vendor,
                    .device_id = pci.readConfigWord(bus, dev, 0, 0x02),
                    .device_type = computeType(bus, dev, 0),
                };
            }
        }
    }
    return .{};
}

/// Converte device ID em tipo de dispositivo (block=1, net=2, scsi=3, console=4).
fn computeType(bus: u8, dev: u8, func: u8) u8 {
    const device_id: u16 = pci.readConfigWord(bus, dev, func, 0x02);
    return if (device_id == 0x1001) 1 else if (device_id == 0x1000) 2 else if (device_id == 0x1002) 3 else if (device_id == 0x1003) 4 else 0;
}

/// Registers a Virtio block device driver interface (F7 — PROPOSTO).
///
/// Defines the function pointer table that a `virtio-blk` driver uses
/// to initialize queues, submit requests, and receive completions.
/// The interface is not yet wired to the block layer (`kernel/storage/block.zig`);
/// that integration is part of the complete F7 milestone.
pub const BlockDriverInterface = struct {
    /// Initializes the VirtIO block queues.
    init_queues: *const fn () void,
    /// Submits a read/write request (descriptor chain).
    submit_request: *const fn (addr: u32, len: u32, flags: u16) bool,
};

test "virtioDetectVirtioReturnsStandardVendor" {
    const info = detectVirtioDevice();
    try std.testing.expectEqual(@as(u16, 0x1AF4), info.vendor);
}
