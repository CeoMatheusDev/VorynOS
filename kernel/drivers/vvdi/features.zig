//************************************************************************//
//  features.zig                                                          //
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

//! Features de transporte do VirtIO 1.x.
//!
//! Um dispositivo VirtIO oferece um conjunto de 64 bits. Os bits 0 a 23 e os
//! bits 50 em diante pertencem ao tipo de dispositivo; os bits 24 a 43 sao
//! do transporte e estao definidos na secao "Reserved Feature Bits" da
//! especificacao. O bit mais importante aqui e VIRTIO_F_VERSION_1, o bit 32:
//! ele e o que distingue o transporte moderno do legado, e um dispositivo
//! que nao o oferece so pode ser conduzido pela interface legada, que este
//! subsistema nao implementa.
//!
//! Este modulo contem apenas as features de transporte. As features
//! especificas de cada tipo de dispositivo (por exemplo as de bloco) entram
//! com o driver correspondente, com os valores conferidos na especificacao
//! antes de qualquer negociacao.

const std = @import("std");

/// O driver pode usar descritores indiretos.
pub const indirect_desc: u64 = 1 << 28;
/// `used_event` e `avail_event` estao habilitados.
pub const event_idx: u64 = 1 << 29;
/// O dispositivo e o driver seguem esta especificacao (transporte moderno).
pub const version_1: u64 = 1 << 32;
/// O acesso do dispositivo a memoria e limitado ou traduzido pela plataforma.
pub const access_platform: u64 = 1 << 33;
/// O dispositivo suporta o layout de fila empacotado.
pub const ring_packed: u64 = 1 << 34;
/// O dispositivo consome os buffers na ordem em que foram publicados.
pub const in_order: u64 = 1 << 35;
/// As ordenacoes de memoria seguem a plataforma, e nao a de SMP.
pub const order_platform: u64 = 1 << 36;
/// O dispositivo suporta SR-IOV.
pub const sr_iov: u64 = 1 << 37;
/// As notificacoes ao dispositivo levam dados alem do indice da fila.
pub const notification_data: u64 = 1 << 38;
/// O identificador da fila nas notificacoes vem da configuracao comum.
pub const notif_config_data: u64 = 1 << 39;
/// O driver pode reiniciar uma fila individualmente.
pub const ring_reset: u64 = 1 << 40;

/// Features de transporte que este subsistema sabe honrar hoje.
///
/// A lista e deliberadamente curta: negociar um bit que o driver nao
/// implementa produziria um dispositivo que responde de um jeito que o
/// driver nao entende. Cada incremento futuro acrescenta aqui o bit que
/// passou a ser conduzido de verdade.
///
///   * `ring_packed` exige o layout empacotado, que nao existe ainda;
///   * `access_platform` exige que o driver desligue ou programe um IOMMU,
///     e o VorynOS ainda nao tem IOMMU;
///   * `event_idx`, `indirect_desc`, `in_order`, `order_platform`,
///     `notification_data`, `notif_config_data` e `ring_reset` alteram o
///     protocolo da fila, que pertence ao incremento das virtqueues.
pub const supported: u64 = version_1;

/// Device-specific feature positions reserved by VirtIO 1.2 (bits 0..23).
/// Their semantics are opted into explicitly by the device driver, rather
/// than by this transport-only module.
pub const device_feature_mask: u64 = 0x00FF_FFFF;

pub const Error = error{
    /// O dispositivo nao oferece VIRTIO_F_VERSION_1; ele e legado.
    Version1NotOffered,
    /// O driver tentou negociar sem aceitar VIRTIO_F_VERSION_1.
    Version1NotNegotiated,
    /// O driver pediu um bit que o dispositivo nao oferece.
    FeatureNotOffered,
    /// O bit existe, mas este subsistema ainda nao o implementa.
    FeatureNotImplemented,
    /// VIRTIO_F_ACCESS_PLATFORM exige um IOMMU, que nao existe aqui.
    AccessPlatformUnsupported,
    /// VIRTIO_F_RING_PACKED exige o layout empacotado.
    PackedRingUnsupported,
};

/// Negocia features entre o que o dispositivo oferece e o que o driver pede.
///
/// A funcao e pura e devolve o conjunto efetivo, sempre contendo
/// VIRTIO_F_VERSION_1. A ordem das verificacoes define o erro mais
/// especifico possivel: primeiro a presenca do bit 32 no dispositivo,
/// depois a aceitacao dele pelo driver, depois os bits que este subsistema
/// reconhece como nao suportados, e por fim a comparacao com o que o
/// dispositivo ofereceu.
pub fn negotiate(offered: u64, requested: u64) Error!u64 {
    return negotiateWithDevice(offered, requested, 0);
}

/// Negotiates a transport feature set plus an explicit device-driver feature
/// allowlist. Device-specific semantics are never enabled implicitly by the
/// transport layer.
pub fn negotiateWithDevice(offered: u64, requested: u64, device_supported: u64) Error!u64 {
    if (offered & version_1 == 0) return error.Version1NotOffered;
    if (requested & version_1 == 0) return error.Version1NotNegotiated;
    if (requested & access_platform != 0) return error.AccessPlatformUnsupported;
    if (requested & ring_packed != 0) return error.PackedRingUnsupported;
    if (requested & ~offered != 0) return error.FeatureNotOffered;
    if (device_supported & ~device_feature_mask != 0) return error.FeatureNotImplemented;
    if (requested & ~(supported | device_supported) != 0) return error.FeatureNotImplemented;
    return requested | version_1;
}

/// Seleciona uma das duas palavras de 32 bits do conjunto de features.
///
/// O transporte PCI moderno expoe os 64 bits em duas palavras de 32 bits, e
/// nao em um registrador de 64 bits: o indice 0 traz os bits 0 a 31 e o
/// indice 1 os bits 32 a 63. VIRTIO_F_VERSION_1 esta na segunda palavra.
pub fn word(features: u64, index: u1) u32 {
    const shift: u6 = @as(u6, index) * 32;
    return @truncate(features >> shift);
}

/// Monta o conjunto de 64 bits a partir das duas palavras lidas do
/// dispositivo.
pub fn fromWords(low: u32, high: u32) u64 {
    return (@as(u64, high) << 32) | low;
}

/// True quando o conjunto negociado usa o transporte moderno.
pub fn isModern(features: u64) bool {
    return features & version_1 != 0;
}

const testing = std.testing;

test "virtio transport feature bits match the specification" {
    try testing.expectEqual(@as(u64, 1 << 28), indirect_desc);
    try testing.expectEqual(@as(u64, 1 << 29), event_idx);
    try testing.expectEqual(@as(u64, 1 << 32), version_1);
    try testing.expectEqual(@as(u64, 1 << 33), access_platform);
    try testing.expectEqual(@as(u64, 1 << 34), ring_packed);
    try testing.expectEqual(@as(u64, 1 << 35), in_order);
    try testing.expectEqual(@as(u64, 1 << 36), order_platform);
    try testing.expectEqual(@as(u64, 1 << 37), sr_iov);
    try testing.expectEqual(@as(u64, 1 << 38), notification_data);
    try testing.expectEqual(@as(u64, 1 << 39), notif_config_data);
    try testing.expectEqual(@as(u64, 1 << 40), ring_reset);
}

test "virtio feature word selection puts version 1 in the second word" {
    try testing.expectEqual(@as(u32, 0), word(version_1, 0));
    try testing.expectEqual(@as(u32, 1), word(version_1, 1));
    try testing.expectEqual(@as(u32, 1 << 28), word(indirect_desc, 0));
    // Bits 32 e 40 vivem na segunda palavra: bit 32 vira bit 0 e o bit 40
    // vira bit 8.
    try testing.expectEqual(@as(u32, 0x101), word(version_1 | ring_reset, 1));
    try testing.expectEqual(@as(u32, 0), word(ring_reset, 0));

    const features = fromWords(0x0000_0001, 0x0000_0002);
    try testing.expectEqual(@as(u64, 0x0000_0002_0000_0001), features);
    try testing.expectEqual(@as(u32, 0x0000_0001), word(features, 0));
    try testing.expectEqual(@as(u32, 0x0000_0002), word(features, 1));
}

test "virtio feature negotiation accepts only the supported transport set" {
    const offered = version_1 | event_idx | indirect_desc | in_order;

    const negotiated = try negotiate(offered, version_1);
    try testing.expectEqual(version_1, negotiated);
    try testing.expect(isModern(negotiated));

    // VIRTIO_F_VERSION_1 e acrescentado mesmo quando o pedido o omite...
    // Isso nao acontece: o driver precisa aceita-lo explicitamente.
    try testing.expectError(error.Version1NotNegotiated, negotiate(offered, 0));
    try testing.expectError(error.Version1NotNegotiated, negotiate(offered, event_idx));
}

test "virtio feature negotiation rejects legacy devices and unknown bits" {
    // Um dispositivo legado nao oferece o bit 32.
    try testing.expectError(error.Version1NotOffered, negotiate(0, 0));
    try testing.expectError(error.Version1NotOffered, negotiate(event_idx, version_1));

    // O bit nao oferecido pelo dispositivo e recusado, mesmo que exista.
    try testing.expectError(
        error.FeatureNotOffered,
        negotiate(version_1, version_1 | event_idx),
    );

    // Bits que existem no dispositivo mas que o driver nao implementa.
    try testing.expectError(
        error.FeatureNotImplemented,
        negotiate(version_1 | event_idx, version_1 | event_idx),
    );
    try testing.expectError(
        error.FeatureNotImplemented,
        negotiate(version_1 | in_order, version_1 | in_order),
    );
}

test "device drivers may explicitly negotiate defined device-specific feature bits" {
    const block_flush: u64 = 1 << 9;
    try testing.expectEqual(
        version_1 | block_flush,
        try negotiateWithDevice(version_1 | block_flush, version_1 | block_flush, block_flush),
    );
    try testing.expectError(
        error.FeatureNotImplemented,
        negotiate(version_1 | block_flush, version_1 | block_flush),
    );
    try testing.expectError(
        error.FeatureNotOffered,
        negotiateWithDevice(version_1, version_1 | block_flush, block_flush),
    );
}

test "virtio feature negotiation names the transport it cannot honour" {
    try testing.expectError(
        error.AccessPlatformUnsupported,
        negotiate(version_1 | access_platform, version_1 | access_platform),
    );
    try testing.expectError(
        error.PackedRingUnsupported,
        negotiate(version_1 | ring_packed, version_1 | ring_packed),
    );

    // A recusa nao depende de o dispositivo oferecer o bit: um driver que
    // pede o que nao implementa e recusado de qualquer modo.
    try testing.expectError(
        error.AccessPlatformUnsupported,
        negotiate(version_1, version_1 | access_platform),
    );
    try testing.expectError(
        error.PackedRingUnsupported,
        negotiate(version_1, version_1 | ring_packed),
    );
}
