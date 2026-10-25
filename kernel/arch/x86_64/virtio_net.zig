//************************************************************************//
//  virtio_net.zig — Virtio network device interface (F7)                  //
//************************************************************************//
// SPDX-License-Identifier: GPL-3.0-only                                   //
//************************************************************************//

//! Interface de rede Virtio com fila `VRing` e descritor de cabecalho
//! + descricao de pacote. Nenhuma alocacao dinamica no caminho critico.

const std = @import("std");
const virtio = @import("virtio.zig");

/// Cabecalho do pacote (header) usado pelo Virtio-net.
/// Em um driver real, aponta para a estrutura `virtio_net_hdr`.
pub const PacketHeader = struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    csum_start: u16 = 0,
    csum_offset: u16 = 0,
};

/// Dispositivo Virtio de rede.
pub const NetworkDevice = struct {
    info: virtio.PciVirtioInfo = .{},
    ring: virtio.VRing = virtio.initVRing(),
    /// Endereco do buffer do pacote (stub — configurado pelo driver).
    packet_buf: u64 = 0,

    pub fn init(dev: *NetworkDevice, info: virtio.PciVirtioInfo) void {
        dev.info = info;
        dev.ring = virtio.initVRing();
        dev.packet_buf = 0;
    },

    /// Submete uma transmissao: cabecalho + payload via `VRing`.
    /// Usa dois descritores: 0 = cabecalho, 1 = payload, 2 = usado com F_NEXT.
    pub fn submitPacket(dev: *NetworkDevice, payload_addr: u64, payload_len: u32) void {
        // Cabeçalho no descritor 0; payload no 1; usado no 2 (F_NEXT).
        virtio.setupDescriptor(&dev.ring, 0, 0xFE_0000_00, @sizeOf(PacketHeader), 0);
        virtio.setupDescriptor(&dev.ring, 1, payload_addr, payload_len, 1); // F_NEXT implícito na ordem
        virtio.submitDescriptor(&dev.ring, 0);
    },
};

test "virtioNetPacketDescriptorChain" {
    var dev: NetworkDevice = .{};
    dev.init(dev, virtio.detectVirtioDevice());
    // Submete um pacote de 512 bytes no endereco 0x1000.
    dev.submitPacket(dev, 0x1000, 512);
    try std.testing.expect(dev.ring.avail_idx > 0);
}
