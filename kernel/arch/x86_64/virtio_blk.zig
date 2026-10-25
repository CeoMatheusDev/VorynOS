//************************************************************************//
//  virtio_blk.zig — Virtio block driver interface (F7)                    //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                   //
//************************************************************************//

//! Interfazeba de driver de bloco Virtio conectando VRing a operacoes
//! de leitura/escrita. Nenhuma alocacao dinamica no caminho critico.

const std = @import("std");
const virtio = @import("virtio.zig");

pub const BlockDevice = struct {
    info: virtio.PciVirtioInfo = .{},
    ring: virtio.VRing = virtio.initVRing(),
    /// Identifier do dispositivo (0 = primeiro encontrado).
    device_id: u8 = 0,

    /// Inicializa o dispositivo Virtio de bloco com info PCI.
    pub fn init(dev: *BlockDevice, info: virtio.PciVirtioInfo) void {
        dev.info = info;
        dev.ring = virtio.initVRing();
        dev.device_id = 0;
    },

    /// Submete uma requisicao de leitura de bloco (stub verificado).
    /// `lba` = endereco do bloco; `buf` = endereco de memoria.
    pub fn readBlock(dev: *BlockDevice, lba: u64, buf: u64) void {
        // Configura descritor 0 para apontar para LBA + buffer
        virtio.setupDescriptor(&dev.ring, 0, lba, @sizeOf(u32), 0);
        virtio.setupDescriptor(&dev.ring, 1, buf, 512, virtio.VRingDesc.flags); // F_WRITE omitido para leitura
        virtio.submitDescriptor(&dev.ring, 0);
    },

    /// Submete uma requisicao de escrita de bloco (stub verificado).
    pub fn writeBlock(dev: *BlockDevice, lba: u64, buf: u64) void {
        virtio.setupDescriptor(&dev.ring, 0, lba, @sizeOf(u32), 0);
        virtio.setupDescriptor(&dev.ring, 1, buf, 512, 1); // F_WRITE = 1
        virtio.submitDescriptor(&dev.ring, 0);
    },
};

test "virtioBlkInitAndDescriptorChain" {
    var dev: BlockDevice = .{};
    const info = virtio.detectVirtioDevice(0);
    dev.init(info);
    try std.testing.expectEqual(@as(u16, 0x1AF4), dev.info.vendor);

    // Submete leitura e escreve — nao acessa MMIO real (stub seguro).
    dev.readBlock(0x42, 0x1000);
    try std.testing.expect(dev.ring.avail_idx > 0);
}
