//************************************************************************//
//  types.zig                                                             //
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

//! Tipos de dispositivo e identificadores PCI do VirtIO 1.x.
//!
//! Os valores abaixo vem da especificacao VirtIO (secoes 4.1.2 "PCI Device
//! Discovery" e 5 "Device Types"). O identificador PCI moderno e
//! `0x1040 + tipo de dispositivo`; a faixa `0x1000..0x103F` e a dos
//! identificadores transicionais, cuja correspondencia com o tipo nao segue
//! uma formula e por isso e tabelada.
//!
//! A faixa do identificador NAO decide qual transporte sera usado. Um
//! dispositivo transicional pode apresentar as capabilities do transporte
//! moderno, e a decisao depende delas; `Identification.modern_id` informa
//! apenas de qual faixa veio o identificador.

const std = @import("std");

/// Identificador de vendor da VirtIO (Red Hat / OASIS).
pub const vendor_id: u16 = 0x1AF4;

/// Base dos identificadores PCI modernos.
pub const modern_id_base: u16 = 0x1040;

/// Ultimo identificador PCI moderno (`0x1040 + 0x3F`).
pub const modern_id_last: u16 = 0x107F;

/// Primeiro identificador PCI transicional.
pub const transitional_id_first: u16 = 0x1000;

/// Ultimo identificador PCI transicional.
pub const transitional_id_last: u16 = 0x103F;

/// Tipos de dispositivo definidos pela especificacao VirtIO.
///
/// O enum e nao exaustivo: um dispositivo pode apresentar um tipo que esta
/// reservado nesta versao da especificacao, e o chamador precisa poder
/// representa-lo sem inventar um nome. `isDefined` separa os dois casos.
pub const DeviceType = enum(u8) {
    network = 1,
    block = 2,
    console = 3,
    entropy = 4,
    balloon = 5,
    scsi = 8,
    gpu = 16,
    input = 18,
    socket = 19,
    crypto = 20,
    memory = 24,
    sound = 25,
    file_system = 26,
    pmem = 27,
    _,

    /// Identificador PCI moderno do tipo, quando ele cabe na faixa.
    pub fn modernPciId(self: DeviceType) ?u16 {
        const id = @backingInt(self);
        if (id == 0) return null;
        const pci_id = modern_id_base + @as(u16, id);
        if (pci_id > modern_id_last) return null;
        return pci_id;
    }

    /// Identificador PCI transicional do tipo, quando a especificacao define
    /// um. A maioria dos tipos nao tem identificador transicional.
    pub fn transitionalPciId(self: DeviceType) ?u16 {
        return switch (self) {
            .network => 0x1000,
            .block => 0x1001,
            .balloon => 0x1002,
            .console => 0x1003,
            .scsi => 0x1004,
            .entropy => 0x1005,
            .file_system => 0x1009,
            else => null,
        };
    }

    /// True quando o tipo tem nome e semantica definidos na especificacao.
    pub fn isDefined(self: DeviceType) bool {
        return switch (self) {
            .network,
            .block,
            .console,
            .entropy,
            .balloon,
            .scsi,
            .gpu,
            .input,
            .socket,
            .crypto,
            .memory,
            .sound,
            .file_system,
            .pmem,
            => true,
            else => false,
        };
    }

    /// Nome estavel para diagnostico.
    ///
    /// `@tagName` nao e usado em um valor desconhecido de um enum nao
    /// exaustivo, porque nao existe nome para ele: o rotulo e "unknown".
    pub fn label(self: DeviceType) []const u8 {
        if (!self.isDefined()) return "unknown";
        return @tagName(self);
    }
};

/// Identificacao de uma funcao PCI como dispositivo VirtIO.
pub const Identification = struct {
    /// Tipo derivado do identificador PCI.
    device_type: DeviceType,
    /// Identificador PCI lido do espaco de configuracao.
    device_id: u16,
    /// True quando o identificador esta na faixa moderna (0x1040..0x107F).
    modern_id: bool,
};

pub const Error = error{
    /// O vendor nao e 0x1AF4, ou o identificador esta fora das duas faixas.
    NotVirtioDevice,
    /// O dispositivo e VirtIO, mas o tipo nao esta definido.
    UnknownDeviceType,
};

/// Identifica uma funcao PCI VirtIO sem acessar o dispositivo.
///
/// A funcao e pura: ela interpreta dois valores ja lidos do espaco de
/// configuracao. A faixa do identificador define o tipo e informa se o
/// dispositivo e moderno por identificador; a presenca das capabilities e
/// verificada depois, na camada de capabilities.
pub fn identify(vendor: u16, device_id: u16) Error!Identification {
    if (vendor != vendor_id) return error.NotVirtioDevice;
    if (device_id < transitional_id_first or device_id > modern_id_last) {
        return error.NotVirtioDevice;
    }

    if (device_id >= modern_id_base) {
        const type_id: u8 = @intCast(device_id - modern_id_base);
        // O tipo 0 e reservado e invalido.
        if (type_id == 0) return error.UnknownDeviceType;
        return .{
            .device_type = @fromBackingInt(@intCast(type_id)),
            .device_id = device_id,
            .modern_id = true,
        };
    }

    const known: ?DeviceType = switch (device_id) {
        0x1000 => .network,
        0x1001 => .block,
        0x1002 => .balloon,
        0x1003 => .console,
        0x1004 => .scsi,
        0x1005 => .entropy,
        0x1009 => .file_system,
        else => null,
    };
    return .{
        .device_type = known orelse return error.UnknownDeviceType,
        .device_id = device_id,
        .modern_id = false,
    };
}

const testing = std.testing;

test "virtio modern identifiers are the device type plus 0x1040" {
    const network = try identify(vendor_id, 0x1041);
    try testing.expectEqual(DeviceType.network, network.device_type);
    try testing.expect(network.modern_id);
    try testing.expectEqual(@as(u16, 0x1041), network.device_id);

    const block = try identify(vendor_id, 0x1042);
    try testing.expectEqual(DeviceType.block, block.device_type);
    try testing.expect(block.modern_id);

    const file_system = try identify(vendor_id, 0x1040 + 26);
    try testing.expectEqual(DeviceType.file_system, file_system.device_type);

    // O ultimo identificador moderno util: 0x1040 + 0x3F.
    const last = try identify(vendor_id, modern_id_last);
    try testing.expect(last.modern_id);
    try testing.expectEqual(@as(u8, 0x3F), @backingInt(last.device_type));
    try testing.expect(!last.device_type.isDefined());
    try testing.expectEqualStrings("unknown", last.device_type.label());
}

test "virtio transitional identifiers follow the table of the specification" {
    const cases = [_]struct { id: u16, expected: DeviceType }{
        .{ .id = 0x1000, .expected = .network },
        .{ .id = 0x1001, .expected = .block },
        .{ .id = 0x1002, .expected = .balloon },
        .{ .id = 0x1003, .expected = .console },
        .{ .id = 0x1004, .expected = .scsi },
        .{ .id = 0x1005, .expected = .entropy },
        .{ .id = 0x1009, .expected = .file_system },
    };
    for (cases) |case| {
        const identification = try identify(vendor_id, case.id);
        try testing.expectEqual(case.expected, identification.device_type);
        // A faixa transicional nao prova transporte legado: apenas informa
        // que o identificador nao e o moderno.
        try testing.expect(!identification.modern_id);
        try testing.expectEqual(@as(u16, case.id), identification.device_id);
    }

    // A tabela transicional nao e 0x1000 + (tipo - 1): o balloon e o tipo 5
    // e usa 0x1002, e o console e o tipo 3 e usa 0x1003.
    try testing.expectEqual(@as(u16, 0x1002), DeviceType.balloon.transitionalPciId().?);
    try testing.expectEqual(@as(u16, 0x1003), DeviceType.console.transitionalPciId().?);
    try testing.expect(DeviceType.gpu.transitionalPciId() == null);
}

test "virtio identification rejects other vendors and undefined types" {
    try testing.expectError(error.NotVirtioDevice, identify(0x8086, 0x1042));
    try testing.expectError(error.NotVirtioDevice, identify(vendor_id, 0x0FFF));
    try testing.expectError(error.NotVirtioDevice, identify(vendor_id, 0x1080));

    // Identificadores VirtIO sem tipo definido.
    try testing.expectError(error.UnknownDeviceType, identify(vendor_id, 0x1006));
    try testing.expectError(error.UnknownDeviceType, identify(vendor_id, 0x1040));
}

test "virtio device types map back to their pci identifiers" {
    try testing.expectEqual(@as(u16, 0x1041), DeviceType.network.modernPciId().?);
    try testing.expectEqual(@as(u16, 0x1042), DeviceType.block.modernPciId().?);
    try testing.expectEqual(@as(u16, 0x1050), DeviceType.gpu.modernPciId().?);

    // O tipo 0 e reservado e nao tem identificador.
    const reserved: DeviceType = @fromBackingInt(@intCast(0));
    try testing.expect(reserved.modernPciId() == null);

    // Um tipo acima de 0x3F nao cabe na faixa moderna.
    const beyond: DeviceType = @fromBackingInt(@intCast(0x40));
    try testing.expect(beyond.modernPciId() == null);
    try testing.expect(!beyond.isDefined());
}
