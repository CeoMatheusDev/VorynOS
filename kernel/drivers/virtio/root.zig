//************************************************************************//
//  root.zig                                                              //
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

//! Raiz do subsistema VirtIO do VorynOS.
//!
//! Este incremento entrega a fundacao do transporte PCI moderno:
//!
//!   * `types`    - tipos de dispositivo e identificadores PCI;
//!   * `status`   - estados da inicializacao e transicoes validas;
//!   * `features` - features de transporte e negociacao;
//!   * `caps`     - capabilities VirtIO PCI modernas.
//!
//! Nada aqui toca em hardware: os modulos interpretam valores e bytes que o
//! chamador leu do espaco de configuracao PCI, e por isso os testes rodam no
//! host. O que ainda NAO existe, e que nao pode ser anunciado como pronto:
//!
//!   * mapeamento de BAR e acesso MMIO;
//!   * escrita do registro de status e negociacao real com o dispositivo;
//!   * virtqueues programadas, notificacoes e conclusoes;
//!   * qualquer driver funcional, inclusive o de blocos.
//!
//! O modulo nao importa `pci.zig`: a raiz de um modulo Zig precisa estar
//! acima de todos os arquivos que ele importa, e o subsistema e testado e
//! compilado a partir de `kernel/drivers/virtio/`. A ligacao com o PCI
//! acontece pelo chamador, que passa os bytes e o validador de BAR (veja
//! `caps.build`), e nao por uma copia daquele modulo.

pub const types = @import("types.zig");
pub const status = @import("status.zig");
pub const features = @import("features.zig");
pub const caps = @import("caps.zig");
pub const mmio = @import("mmio.zig");
pub const transport = @import("transport.zig");
pub const pci_transport = @import("pci_transport.zig");

// Os testes dos modulos vivem neles mesmos; este bloco e o que os traz para
// o binario de teste. Sem ele o binario e construido com zero testes e passa
// independentemente do que os modulos facam.
test {
    _ = types;
    _ = status;
    _ = features;
    _ = caps;
    _ = mmio;
    _ = transport;
    _ = pci_transport;
}

const std = @import("std");
const testing = std.testing;

/// Escreve uma capability no buffer e devolve a fatia correspondente.
fn encodeCapability(
    buffer: *[caps.notify_structure_size]u8,
    capability: caps.Capability,
) []const u8 {
    const length: usize = if (capability.isNotify())
        caps.notify_structure_size
    else
        caps.structure_size;

    @memset(buffer, 0);
    buffer[0] = caps.capability_id;
    buffer[1] = 0;
    buffer[2] = @intCast(length);
    buffer[3] = capability.cfg_type;
    buffer[4] = capability.bar;
    buffer[5] = capability.id;
    writeLe32(buffer[8..12], capability.offset);
    writeLe32(buffer[12..16], capability.length);
    writeLe32(buffer[16..20], capability.notify_off_multiplier);
    return buffer[0..length];
}

fn writeLe32(bytes: []u8, value: u32) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}

test "a modern virtio block device reaches the feature and status plan" {
    // O dispositivo de teste e o que o QEMU apresenta para um disco
    // `if=virtio`: identificador moderno do tipo bloco (0x1042) e as quatro
    // regioes em um BAR de memoria.
    const identification = try types.identify(types.vendor_id, 0x1042);
    try testing.expectEqual(types.DeviceType.block, identification.device_type);
    try testing.expect(identification.modern_id);

    const structures = [_]caps.Capability{
        .{ .cfg_type = caps.cfg_type.common, .bar = 4, .id = 0, .offset = 0x1000, .length = 0x38 },
        .{ .cfg_type = caps.cfg_type.notify, .bar = 4, .id = 0, .offset = 0x2000, .length = 0x1000, .notify_off_multiplier = 4 },
        .{ .cfg_type = caps.cfg_type.isr, .bar = 4, .id = 0, .offset = 0x3000, .length = 1 },
        .{ .cfg_type = caps.cfg_type.device, .bar = 4, .id = 0, .offset = 0x4000, .length = 0x10 },
    };

    // As capabilities chegam como bytes, do mesmo modo que chegam do espaco
    // de configuracao; o modulo apenas as interpreta.
    var parsed: [structures.len]caps.Capability = undefined;
    var buffer: [caps.notify_structure_size]u8 = undefined;
    for (structures, 0..) |structure, index| {
        const bytes = encodeCapability(&buffer, structure);
        parsed[index] = try caps.parse(bytes);
    }

    const collection = try caps.build(parsed[0..], null);
    try testing.expectEqual(@as(u8, 4), collection.regionCount());
    try testing.expectEqual(@as(u32, 4), collection.notify.notify_off_multiplier);

    // O dispositivo oferece as features de transporte e o driver aceita o
    // bit que identifica o transporte moderno.
    const offered = features.version_1 | features.event_idx | features.ring_reset;
    const negotiated = try features.negotiate(offered, features.version_1);
    try testing.expectEqual(features.version_1, negotiated);
    try testing.expect(features.isModern(negotiated));

    // A sequencia de status que a camada de transporte vai executar quando
    // os registradores existirem. Aqui ela e apenas validada.
    var state: u8 = 0;
    const plan = [_]status.Phase{ .acknowledge, .driver, .features_ok, .driver_ok };
    for (plan) |expected| {
        state = status.bitsOf(try status.transition(state, status.bitsOf(expected)));
        try testing.expectEqual(expected, try status.phase(state));
    }
    try testing.expect(status.isReady(state));
    try testing.expectEqual(@as(u8, 0x0F), state);

    // Recusar um dispositivo legado e parte do plano: sem VIRTIO_F_VERSION_1
    // nao existe transporte moderno a inicializar.
    const legacy_offered = features.event_idx;
    try testing.expectError(
        error.Version1NotOffered,
        features.negotiate(legacy_offered, features.version_1),
    );
}

test "a device without the required regions cannot build the transport" {
    var buffer: [caps.notify_structure_size]u8 = undefined;
    // A configuracao comum aparece, mas a regiao de notificacao nao.
    const bytes = encodeCapability(&buffer, .{
        .cfg_type = caps.cfg_type.common,
        .bar = 4,
        .id = 0,
        .offset = 0x1000,
        .length = 0x38,
    });
    var parsed: [1]caps.Capability = undefined;
    parsed[0] = try caps.parse(bytes);

    try testing.expectError(
        error.MissingNotifyConfiguration,
        caps.build(parsed[0..], null),
    );
}
