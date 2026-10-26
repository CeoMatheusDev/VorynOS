//************************************************************************//
//  caps.zig                                                              //
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

//! Capabilities do transporte VirtIO PCI moderno.
//!
//! O dispositivo descreve onde estao as regioes do transporte em uma
//! capability vendor-specific (id 0x09) do espaco de configuracao PCI:
//!
//! ```text
//! struct virtio_pci_cap {          // 16 bytes
//!     u8  cap_vndr;                // 0x00: 0x09
//!     u8  cap_next;                // 0x01: proxima capability
//!     u8  cap_len;                 // 0x02: tamanho desta capability
//!     u8  cfg_type;                // 0x03: tipo da regiao
//!     u8  bar;                     // 0x04: BAR que contem a regiao
//!     u8  id;                      // 0x05: identificador por tipo
//!     u8  padding[2];              // 0x06
//!     le32 offset;                 // 0x08: deslocamento dentro do BAR
//!     le32 length;                 // 0x0c: tamanho da regiao
//! };
//! ```
//!
//! A capability de notificacao e seguida de um `le32 notify_off_multiplier`,
//! e a de acesso pela configuracao PCI de quatro bytes de dados. As demais
//! usam apenas a estrutura de 16 bytes.
//!
//! Este modulo interpreta e valida os bytes ja lidos do espaco de
//! configuracao; ele nao le o BAR nem acessa memoria do dispositivo, e por
//! isso roda no host nos testes. A leitura dos bytes pertence ao chamador,
//! que conhece o mecanismo de acesso (portas 0xCF8/0xCFC ou ECAM).
//!
//! Regras da especificacao aplicadas aqui:
//!
//!   * uma capability com `cfg_type` reservado ou `bar` reservado e
//!     ignorada, e nao um erro (a especificacao manda ignorar);
//!   * o driver usa a primeira instancia que consegue suportar de cada tipo,
//!     e ignora as seguintes;
//!   * `offset` da configuracao comum e da configuracao do dispositivo
//!     precisa estar alinhado em 4 bytes e o da notificacao em 2 bytes;
//!   * `notify_off_multiplier` e 0 ou uma potencia de dois par;
//!   * um `cap_len` maior que o necessario e aceito, como a especificacao
//!     exige.

const std = @import("std");

/// Identificador de capability vendor-specific no espaco PCI.
pub const capability_id: u8 = 0x09;

/// Bytes de `struct virtio_pci_cap`.
pub const structure_size: usize = 16;

/// Bytes de `struct virtio_pci_notify_cap`, que acrescenta o multiplicador.
pub const notify_structure_size: usize = 20;

/// Maior prefixo de uma capability que este modulo interpreta.
///
/// A especificacao define a variante `struct virtio_pci_cap64`, que acrescenta
/// `offset_hi` e `length_hi` para regioes acima de 4 GiB:
///
/// ```text
/// struct virtio_pci_cap64 {        // 24 bytes
///     struct virtio_pci_cap cap;   // 0x00
///     le32 offset_hi;              // 0x10
///     le32 length_hi;              // 0x14
/// };
/// ```
///
/// Uma notificacao nao tem essa variante: os bytes 0x10 ja sao o
/// `notify_off_multiplier`. O chamador precisa entregar ate este tamanho para
/// que `parse` possa conferir as metades altas em vez de ignorar uma regiao
/// que nao cabe em 32 bits.
pub const max_structure_size: usize = structure_size + 8;

/// Maior indice de BAR de uma funcao PCI; acima disso o valor e reservado.
pub const max_bar_index: u8 = 5;

/// Menor tamanho util da configuracao comum.
///
/// A estrutura da VirtIO 1.0 termina em `queue_device` (offset 48, 8 bytes),
/// o que da 56 bytes. Versoes posteriores acrescentam campos ao final, e um
/// tamanho maior e aceito.
pub const common_config_min_length: u32 = 56;

/// Menor tamanho util da regiao de notificacao: um inteiro de 16 bits.
pub const notify_config_min_length: u32 = 2;

/// Menor tamanho util da regiao de ISR: um byte.
pub const isr_config_min_length: u32 = 1;

/// Valores do campo `cfg_type`.
pub const cfg_type = struct {
    /// Configuracao comum: features, status, selecao e enderecos das filas.
    pub const common: u8 = 1;
    /// Notificacoes ao dispositivo.
    pub const notify: u8 = 2;
    /// Status de interrupcao (ISR).
    pub const isr: u8 = 3;
    /// Configuracao especifica do tipo de dispositivo.
    pub const device: u8 = 4;
    /// Janela de acesso as regioes pela configuracao PCI.
    pub const pci: u8 = 5;
    /// Regiao de memoria compartilhada.
    pub const shared_memory: u8 = 8;
    /// Dados do vendor, para diagnostico.
    pub const vendor: u8 = 9;
};

/// True quando `value` e um tipo definido pela especificacao.
pub fn isKnownType(value: u8) bool {
    return switch (value) {
        cfg_type.common,
        cfg_type.notify,
        cfg_type.isr,
        cfg_type.device,
        cfg_type.pci,
        cfg_type.shared_memory,
        cfg_type.vendor,
        => true,
        else => false,
    };
}

pub const Error = error{
    /// Os bytes nao contem uma estrutura completa.
    TruncatedCapability,
    /// O byte de vendor da capability nao e 0x09.
    WrongVendor,
    /// `length` zero ou `offset + length` acima de 32 bits.
    InvalidLength,
    /// O deslocamento nao respeita o alinhamento do tipo da regiao.
    UnalignedOffset,
    /// O multiplicador nao e 0 nem potencia de dois par.
    InvalidNotifyMultiplier,
    /// Nao existe capability utilizavel da configuracao comum.
    MissingCommonConfiguration,
    /// Nao existe capability utilizavel de notificacao.
    MissingNotifyConfiguration,
    /// A regiao declara `offset` ou `length` acima de 4 GiB (`cap64`), que
    /// este modulo nao representa.
    UnsupportedLargeRegion,
};

/// Uma capability VirtIO ja decodificada.
pub const Capability = struct {
    /// Tipo da regiao (`cfg_type.*`).
    cfg_type: u8,
    /// Indice do BAR que contem a regiao.
    bar: u8,
    /// Identificador da capability dentro do tipo.
    id: u8,
    /// Deslocamento da regiao dentro do BAR.
    offset: u32,
    /// Tamanho da regiao.
    length: u32,
    /// Multiplicador de `queue_notify_off`; so a notificacao usa.
    notify_off_multiplier: u32 = 0,

    /// True quando o tipo e o BAR permitem usar a capability.
    ///
    /// A especificacao manda ignorar tipos e indices de BAR reservados; um
    /// dispositivo que apresente um deles continua valido, desde que as
    /// regioes obrigatorias aparecam em capabilities utilizaveis.
    pub fn isUsable(self: Capability) bool {
        return isKnownType(self.cfg_type) and self.bar <= max_bar_index;
    }

    /// True quando a capability descreve a notificacao ao dispositivo.
    pub fn isNotify(self: Capability) bool {
        return self.cfg_type == cfg_type.notify;
    }
};

fn readLe32(bytes: []const u8) u32 {
    return (@as(u32, bytes[3]) << 24) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[1]) << 8) |
        @as(u32, bytes[0]);
}

/// Decodifica e valida uma capability a partir dos bytes lidos do espaco de
/// configuracao.
///
/// `bytes` comeca no offset da capability (`cap_vndr`) e precisa conter os
/// primeiros `min(cap_len, max_structure_size)` bytes dela.
///
/// O `cap_len` declarado **nao** limita o que a funcao aceita: a especificacao
/// exige que o driver aceite um `cap_len` maior que o definido, porque o
/// dispositivo pode acrescentar dados extras ou padding. O que a funcao
/// confere e que os campos que ela interpreta existam nesses bytes.
///
/// A adequacao ao BAR e a escolha entre instancias ficam em `build`, porque
/// dependem do que o chamador consegue mapear.
pub fn parse(bytes: []const u8) Error!Capability {
    if (bytes.len < structure_size) return error.TruncatedCapability;
    if (bytes[0] != capability_id) return error.WrongVendor;

    const declared: usize = bytes[2];
    if (declared < structure_size) return error.TruncatedCapability;

    const offset = readLe32(bytes[8..12]);
    const length = readLe32(bytes[12..16]);
    if (length == 0) return error.InvalidLength;
    // A regiao precisa caber em 32 bits antes de qualquer comparacao com o
    // tamanho do BAR, para que a soma nao transborde.
    _ = std.math.add(u32, offset, length) catch return error.InvalidLength;

    var capability: Capability = .{
        .cfg_type = bytes[3],
        .bar = bytes[4],
        .id = bytes[5],
        .offset = offset,
        .length = length,
    };

    if (capability.isNotify()) {
        // O multiplicador faz parte da capability de notificacao: ele precisa
        // estar declarado no `cap_len` e presente nos bytes entregues, mesmo
        // que os 16 bytes da base existam.
        if (declared < notify_structure_size) return error.TruncatedCapability;
        if (bytes.len < notify_structure_size) return error.TruncatedCapability;
        capability.notify_off_multiplier = readLe32(bytes[16..20]);
        return capability;
    }

    if (declared >= max_structure_size) {
        // Uma capability `cap64` precisa ser reconhecida, e nao lida como se
        // as metades altas fossem padding: interpretar so os 32 bits baixos
        // de uma regiao acima de 4 GiB produziria um deslocamento errado sem
        // erro nenhum.
        if (bytes.len < max_structure_size) return error.TruncatedCapability;
        const offset_hi = readLe32(bytes[16..20]);
        const length_hi = readLe32(bytes[20..24]);
        if (offset_hi != 0 or length_hi != 0) return error.UnsupportedLargeRegion;
    }
    return capability;
}

/// Verifica a regiao de uma capability contra o BAR que a contem.
///
/// A funcao recebe o indice do BAR, o deslocamento e o tamanho, e devolve
/// true apenas quando os tres descrevem uma regiao que o BAR pode conter. O
/// chamador a liga ao `pci.zig` (`barSupportsRegion`) sem que este modulo
/// dependa daquele: a validacao de tamanho de BAR exige escrever nele para
/// descobrir a mascara, o que e responsabilidade da camada de hardware.
pub const BarValidator = *const fn (bar: u8, offset: u32, length: u32) bool;

fn isValidNotifyMultiplier(multiplier: u32) bool {
    if (multiplier == 0) return true;
    if (!std.math.isPowerOfTwo(multiplier)) return false;
    // "potencia de dois par": 1 nao serve, 2, 4, 8... servem.
    return multiplier % 2 == 0;
}

fn validate(capability: Capability) Error!void {
    switch (capability.cfg_type) {
        cfg_type.common => {
            if (capability.offset % 4 != 0) return error.UnalignedOffset;
            if (capability.length < common_config_min_length) return error.InvalidLength;
        },
        cfg_type.device => {
            if (capability.offset % 4 != 0) return error.UnalignedOffset;
        },
        cfg_type.notify => {
            // Sem VIRTIO_F_NOTIFICATION_DATA a notificacao tem 16 bits e o
            // deslocamento precisa estar alinhado em 2 bytes.
            if (capability.offset % 2 != 0) return error.UnalignedOffset;
            if (!isValidNotifyMultiplier(capability.notify_off_multiplier)) {
                return error.InvalidNotifyMultiplier;
            }
            if (capability.length < notify_config_min_length) return error.InvalidLength;
        },
        cfg_type.isr => {
            if (capability.length < isr_config_min_length) return error.InvalidLength;
        },
        // A janela de configuracao PCI, a memoria compartilhada e os dados do
        // vendor nao fazem parte deste incremento: a especificacao manda
        // ignorar o que o driver nao suporta.
        else => {},
    }
}

/// As regioes do transporte moderno que um dispositivo apresentou.
pub const Collection = struct {
    /// Configuracao comum; obrigatoria.
    common: Capability,
    /// Notificacoes; obrigatoria.
    notify: Capability,
    /// Status de interrupcao; opcional.
    isr: ?Capability,
    /// Configuracao do tipo de dispositivo; opcional na estrutura, exigida
    /// pelos tipos que tem configuracao propria.
    device: ?Capability,

    /// Quantidade de regioes obrigatorias e opcionais presentes.
    pub fn regionCount(self: Collection) u8 {
        var count: u8 = 2;
        if (self.isr != null) count += 1;
        if (self.device != null) count += 1;
        return count;
    }
};

/// Seleciona as regioes do transporte entre as capabilities do dispositivo.
///
/// Instancias com tipo ou BAR reservados sao ignoradas, e entre instancias
/// utilizaveis do mesmo tipo vale a primeira, como a especificacao pede. Uma
/// instancia de tipo conhecido que viola uma exigencia normativa (regiao
/// invalida, alinhamento errado, tamanho insuficiente) e um erro: seguir com
/// ela produziria acessos que o dispositivo nao garante.
pub fn build(capabilities: []const Capability, bar_check: ?BarValidator) Error!Collection {
    var common: ?Capability = null;
    var notify: ?Capability = null;
    var isr: ?Capability = null;
    var device: ?Capability = null;

    for (capabilities) |capability| {
        if (!capability.isUsable()) continue;
        if (bar_check) |check| {
            // Uma regiao que a plataforma nao consegue mapear nao invalida o
            // dispositivo: a especificacao permite varias instancias do mesmo
            // tipo exatamente para que o driver use a que consegue suportar.
            if (!check(capability.bar, capability.offset, capability.length)) continue;
        }

        switch (capability.cfg_type) {
            cfg_type.common => {
                if (common != null) continue;
                try validate(capability);
                common = capability;
            },
            cfg_type.notify => {
                if (notify != null) continue;
                try validate(capability);
                notify = capability;
            },
            cfg_type.isr => {
                if (isr != null) continue;
                try validate(capability);
                isr = capability;
            },
            cfg_type.device => {
                if (device != null) continue;
                try validate(capability);
                device = capability;
            },
            else => {},
        }
    }

    const selected_common = common orelse return error.MissingCommonConfiguration;
    const selected_notify = notify orelse return error.MissingNotifyConfiguration;
    return .{
        .common = selected_common,
        .notify = selected_notify,
        .isr = isr,
        .device = device,
    };
}

const testing = std.testing;

/// Escreve uma capability nos bytes dados e devolve a fatia usada.
fn encode(
    buffer: []u8,
    capability: Capability,
) []const u8 {
    const length: usize = if (capability.isNotify()) notify_structure_size else structure_size;
    @memset(buffer, 0);
    buffer[0] = capability_id;
    buffer[1] = 0;
    buffer[2] = @intCast(length);
    buffer[3] = capability.cfg_type;
    buffer[4] = capability.bar;
    buffer[5] = capability.id;
    buffer[8] = @truncate(capability.offset);
    buffer[9] = @truncate(capability.offset >> 8);
    buffer[10] = @truncate(capability.offset >> 16);
    buffer[11] = @truncate(capability.offset >> 24);
    buffer[12] = @truncate(capability.length);
    buffer[13] = @truncate(capability.length >> 8);
    buffer[14] = @truncate(capability.length >> 16);
    buffer[15] = @truncate(capability.length >> 24);
    buffer[16] = @truncate(capability.notify_off_multiplier);
    buffer[17] = @truncate(capability.notify_off_multiplier >> 8);
    buffer[18] = @truncate(capability.notify_off_multiplier >> 16);
    buffer[19] = @truncate(capability.notify_off_multiplier >> 24);
    return buffer[0..length];
}

fn sample(cfg: u8) Capability {
    return switch (cfg) {
        cfg_type.common => .{
            .cfg_type = cfg_type.common,
            .bar = 4,
            .id = 0,
            .offset = 0x1000,
            .length = common_config_min_length,
        },
        cfg_type.notify => .{
            .cfg_type = cfg_type.notify,
            .bar = 4,
            .id = 0,
            .offset = 0x2000,
            .length = 0x100,
            .notify_off_multiplier = 4,
        },
        cfg_type.isr => .{
            .cfg_type = cfg_type.isr,
            .bar = 4,
            .id = 0,
            .offset = 0x3000,
            .length = 1,
        },
        cfg_type.device => .{
            .cfg_type = cfg_type.device,
            .bar = 4,
            .id = 0,
            .offset = 0x4000,
            .length = 0x10,
        },
        else => .{
            .cfg_type = cfg,
            .bar = 4,
            .id = 0,
            .offset = 0x5000,
            .length = 0x10,
        },
    };
}

test "virtio capability decodes the wire structure" {
    var buffer: [notify_structure_size]u8 = undefined;
    const bytes = encode(&buffer, sample(cfg_type.notify));

    const capability = try parse(bytes);
    try testing.expectEqual(cfg_type.notify, capability.cfg_type);
    try testing.expectEqual(@as(u8, 4), capability.bar);
    try testing.expectEqual(@as(u32, 0x2000), capability.offset);
    try testing.expectEqual(@as(u32, 0x100), capability.length);
    try testing.expectEqual(@as(u32, 4), capability.notify_off_multiplier);
    try testing.expect(capability.isNotify());
    try testing.expect(capability.isUsable());

    // A estrutura de 16 bytes da configuracao comum nao carrega multiplicador.
    const common_bytes = encode(&buffer, sample(cfg_type.common));
    try testing.expectEqual(@as(usize, structure_size), common_bytes.len);
    const common = try parse(common_bytes);
    try testing.expectEqual(@as(u32, 0), common.notify_off_multiplier);
    try testing.expectEqual(common_config_min_length, common.length);
}

test "virtio capability rejects truncated and malformed structures" {
    var buffer: [notify_structure_size]u8 = undefined;

    // Menos bytes que a estrutura base.
    try testing.expectError(error.TruncatedCapability, parse(buffer[0..15]));

    // Vendor errado.
    const bytes = encode(&buffer, sample(cfg_type.common));
    buffer[0] = 0x05;
    try testing.expectError(error.WrongVendor, parse(buffer[0..bytes.len]));
    buffer[0] = capability_id;

    // cap_len menor que a estrutura base.
    buffer[2] = 8;
    try testing.expectError(error.TruncatedCapability, parse(bytes));
    buffer[2] = 16;

    // cap_len que declara a variante de 64 bits sem que os bytes dela tenham
    // sido lidos: as metades altas nao podem ser supostas iguais a zero.
    buffer[2] = max_structure_size;
    buffer[3] = cfg_type.common;
    try testing.expectError(error.TruncatedCapability, parse(bytes[0..16]));
    buffer[2] = 16;

    // Regiao de tamanho zero.
    const zero_length = encode(&buffer, .{
        .cfg_type = cfg_type.common,
        .bar = 4,
        .id = 0,
        .offset = 0x1000,
        .length = 0,
    });
    try testing.expectError(error.InvalidLength, parse(zero_length));

    // offset + length acima de 32 bits.
    const overflow = encode(&buffer, .{
        .cfg_type = cfg_type.common,
        .bar = 4,
        .id = 0,
        .offset = 0xFFFF_FFF0,
        .length = 0x20,
    });
    try testing.expectError(error.InvalidLength, parse(overflow));

    // A notificacao sem os quatro bytes do multiplicador esta truncada,
    // mesmo que a estrutura base exista.
    var notify_buffer: [notify_structure_size]u8 = undefined;
    const notify_bytes = encode(&notify_buffer, sample(cfg_type.notify));
    notify_buffer[2] = structure_size;
    try testing.expectError(error.TruncatedCapability, parse(notify_bytes));
}

test "virtio capability accepts a larger cap_len than required" {
    // A especificacao exige que o driver aceite um cap_len maior que o
    // definido: o dispositivo pode acrescentar dados extras ou padding.
    var buffer: [max_structure_size]u8 = @splat(0);
    _ = encode(&buffer, sample(cfg_type.common));

    // Quatro bytes de dados extras, com os bytes entregues iguais ao cap_len.
    buffer[2] = structure_size + 4;
    const padded = try parse(buffer[0 .. structure_size + 4]);
    try testing.expectEqual(cfg_type.common, padded.cfg_type);
    try testing.expectEqual(@as(u32, 0x1000), padded.offset);

    // Um cap_len maior que os bytes lidos tambem e aceito, desde que os
    // campos interpretados estejam presentes: os bytes que faltam sao dados
    // extras que este modulo nao le.
    buffer[2] = structure_size + 4;
    const short_read = try parse(buffer[0..structure_size]);
    try testing.expectEqual(@as(u32, 0x1000), short_read.offset);

    // A notificacao continua exigindo o multiplicador presente e declarado.
    var notify_buffer: [max_structure_size]u8 = @splat(0);
    _ = encode(&notify_buffer, sample(cfg_type.notify));
    notify_buffer[2] = notify_structure_size + 4;
    const notify = try parse(notify_buffer[0 .. notify_structure_size + 4]);
    try testing.expectEqual(@as(u32, 4), notify.notify_off_multiplier);
    try testing.expectError(error.TruncatedCapability, parse(notify_buffer[0..16]));
}

test "virtio capability rejects a region above four gigabytes" {
    // `struct virtio_pci_cap64` acrescenta `offset_hi` e `length_hi`. Este
    // modulo so representa regioes de 32 bits, e ler apenas as metades baixas
    // produziria um deslocamento errado sem erro nenhum.
    var buffer: [max_structure_size]u8 = @splat(0);
    _ = encode(&buffer, sample(cfg_type.common));
    buffer[2] = max_structure_size;

    // Sem as metades altas: nao ha como saber se elas sao zero.
    try testing.expectError(error.TruncatedCapability, parse(buffer[0..structure_size]));

    // Metades altas zeradas sao a forma explicita de "cabe em 32 bits".
    const within = try parse(buffer[0..max_structure_size]);
    try testing.expectEqual(@as(u32, 0x1000), within.offset);

    // Um deslocamento acima de 4 GiB.
    buffer[16] = 0x01;
    try testing.expectError(error.UnsupportedLargeRegion, parse(buffer[0..max_structure_size]));
    buffer[16] = 0x00;

    // Um tamanho acima de 4 GiB.
    buffer[20] = 0x01;
    try testing.expectError(error.UnsupportedLargeRegion, parse(buffer[0..max_structure_size]));
}

test "virtio capability types follow the specification table" {
    try testing.expectEqual(@as(u8, 1), cfg_type.common);
    try testing.expectEqual(@as(u8, 2), cfg_type.notify);
    try testing.expectEqual(@as(u8, 3), cfg_type.isr);
    try testing.expectEqual(@as(u8, 4), cfg_type.device);
    try testing.expectEqual(@as(u8, 5), cfg_type.pci);
    try testing.expectEqual(@as(u8, 8), cfg_type.shared_memory);

    try testing.expect(isKnownType(cfg_type.common));
    try testing.expect(isKnownType(cfg_type.shared_memory));
    try testing.expect(!isKnownType(0));
    try testing.expect(!isKnownType(6));
    try testing.expect(!isKnownType(7));
}

test "virtio capability collection requires common and notify regions" {
    var buffer: [notify_structure_size]u8 = undefined;

    var capabilities: [4]Capability = undefined;
    const types = [_]u8{ cfg_type.common, cfg_type.notify, cfg_type.isr, cfg_type.device };
    for (types, 0..) |kind, index| {
        capabilities[index] = try parse(encode(&buffer, sample(kind)));
    }

    const collection = try build(capabilities[0..], null);
    try testing.expectEqual(cfg_type.common, collection.common.cfg_type);
    try testing.expectEqual(@as(u32, 0x2000), collection.notify.offset);
    try testing.expectEqual(@as(u32, 4), collection.notify.notify_off_multiplier);
    try testing.expect(collection.isr != null);
    try testing.expect(collection.device != null);
    try testing.expectEqual(@as(u8, 4), collection.regionCount());

    // Sem a configuracao comum e sem a notificacao as duas regioes
    // obrigatorias faltam, e o erro diz qual.
    try testing.expectError(
        error.MissingCommonConfiguration,
        build(capabilities[1..], null),
    );
    try testing.expectError(
        error.MissingNotifyConfiguration,
        build(capabilities[0..1], null),
    );

    // As regioes opcionais nao sao exigidas.
    const minimal = try build(capabilities[0..2], null);
    try testing.expect(minimal.isr == null);
    try testing.expect(minimal.device == null);
    try testing.expectEqual(@as(u8, 2), minimal.regionCount());
}

test "virtio capability collection ignores reserved types and bar indices" {
    const ignored = [_]Capability{
        // Tipo reservado pela especificacao.
        .{ .cfg_type = 6, .bar = 4, .id = 0, .offset = 0x1000, .length = 0x10 },
        // BAR fora da faixa 0..5.
        .{ .cfg_type = cfg_type.common, .bar = 6, .id = 0, .offset = 0x1000, .length = 0x38 },
        // Presentes e utilizaveis.
        sample(cfg_type.common),
        sample(cfg_type.notify),
    };
    const collection = try build(ignored[0..], null);
    try testing.expectEqual(@as(u8, 4), collection.common.bar);
    try testing.expectEqual(@as(u32, 0x1000), collection.common.offset);

    try testing.expect(!ignored[0].isUsable());
    try testing.expect(!ignored[1].isUsable());
}

test "virtio capability collection keeps the first usable instance" {
    const first = sample(cfg_type.common);
    var second = first;
    second.offset = 0x8000;

    const duplicated = [_]Capability{ first, second, sample(cfg_type.notify) };
    const collection = try build(duplicated[0..], null);
    try testing.expectEqual(@as(u32, 0x1000), collection.common.offset);

    // Uma instancia de tipo conhecido que viola uma exigencia normativa nao e
    // ignorada: ela indica um dispositivo que nao cumpre a especificacao, e
    // seguir com ela produziria acessos que o dispositivo nao garante.
    var unaligned = first;
    unaligned.offset = 0x1001;
    const invalid = [_]Capability{ unaligned, sample(cfg_type.notify) };
    try testing.expectError(error.UnalignedOffset, build(invalid[0..], null));
}

test "virtio capability validation enforces the alignment of each region" {
    // Configuracao comum alinhada em 2 bytes em vez de 4.
    const unaligned_common = [_]Capability{
        .{ .cfg_type = cfg_type.common, .bar = 4, .id = 0, .offset = 0x1002, .length = 0x38 },
        sample(cfg_type.notify),
    };
    try testing.expectError(error.UnalignedOffset, build(unaligned_common[0..], null));

    // Notificacao em offset impar.
    const unaligned_notify = [_]Capability{
        sample(cfg_type.common),
        .{ .cfg_type = cfg_type.notify, .bar = 4, .id = 0, .offset = 0x2001, .length = 0x100, .notify_off_multiplier = 4 },
    };
    try testing.expectError(error.UnalignedOffset, build(unaligned_notify[0..], null));

    // Configuracao do dispositivo alinhada em 2 bytes.
    const unaligned_device = [_]Capability{
        sample(cfg_type.common),
        sample(cfg_type.notify),
        .{ .cfg_type = cfg_type.device, .bar = 4, .id = 0, .offset = 0x4002, .length = 0x10 },
    };
    try testing.expectError(error.UnalignedOffset, build(unaligned_device[0..], null));

    // A regiao de ISR nao tem exigencia de alinhamento.
    const isr_odd = [_]Capability{
        sample(cfg_type.common),
        sample(cfg_type.notify),
        .{ .cfg_type = cfg_type.isr, .bar = 4, .id = 0, .offset = 0x3001, .length = 1 },
    };
    const collection = try build(isr_odd[0..], null);
    try testing.expectEqual(@as(u32, 0x3001), collection.isr.?.offset);
}

test "virtio capability validation rejects short regions and bad multipliers" {
    // Configuracao comum menor que a estrutura da VirtIO 1.0.
    const short_common = [_]Capability{
        .{ .cfg_type = cfg_type.common, .bar = 4, .id = 0, .offset = 0x1000, .length = 0x30 },
        sample(cfg_type.notify),
    };
    try testing.expectError(error.InvalidLength, build(short_common[0..], null));

    // Notificacao com menos de 16 bits.
    const short_notify = [_]Capability{
        sample(cfg_type.common),
        .{ .cfg_type = cfg_type.notify, .bar = 4, .id = 0, .offset = 0x2000, .length = 1, .notify_off_multiplier = 4 },
    };
    try testing.expectError(error.InvalidLength, build(short_notify[0..], null));

    // Multiplicador 1 nao e potencia de dois par.
    const odd_multiplier = [_]Capability{
        sample(cfg_type.common),
        .{ .cfg_type = cfg_type.notify, .bar = 4, .id = 0, .offset = 0x2000, .length = 0x100, .notify_off_multiplier = 1 },
    };
    try testing.expectError(error.InvalidNotifyMultiplier, build(odd_multiplier[0..], null));

    // Multiplicador que nao e potencia de dois.
    const broken_multiplier = [_]Capability{
        sample(cfg_type.common),
        .{ .cfg_type = cfg_type.notify, .bar = 4, .id = 0, .offset = 0x2000, .length = 0x100, .notify_off_multiplier = 6 },
    };
    try testing.expectError(error.InvalidNotifyMultiplier, build(broken_multiplier[0..], null));

    // Multiplicador zero e valido: todas as filas usam o mesmo endereco.
    const shared_notify = [_]Capability{
        sample(cfg_type.common),
        .{ .cfg_type = cfg_type.notify, .bar = 4, .id = 0, .offset = 0x2000, .length = 0x100, .notify_off_multiplier = 0 },
    };
    const collection = try build(shared_notify[0..], null);
    try testing.expectEqual(@as(u32, 0), collection.notify.notify_off_multiplier);
}

test "virtio capability collection falls back when a bar cannot be mapped" {
    const Platform = struct {
        var unmappable_bar: u8 = 2;

        fn validate(bar: u8, offset: u32, length: u32) bool {
            if (bar == unmappable_bar) return false;
            // Regiao simulada: BAR de 16 KiB em 0x0000..0x3FFF.
            return @as(u64, offset) + @as(u64, length) <= 0x4000;
        }
    };

    // Duas instancias da configuracao comum: a primeira vive em um BAR que a
    // plataforma nao consegue mapear, e a segunda e usavel.
    var preferred = sample(cfg_type.common);
    preferred.bar = 2;
    var fallback = sample(cfg_type.common);
    fallback.bar = 4;
    fallback.offset = 0x2000;

    const instances = [_]Capability{ preferred, fallback, sample(cfg_type.notify) };
    const collection = try build(instances[0..], Platform.validate);
    try testing.expectEqual(@as(u8, 4), collection.common.bar);
    try testing.expectEqual(@as(u32, 0x2000), collection.common.offset);

    // Quando a plataforma nao mapeia o BAR da unica notificacao, a regiao
    // obrigatoria esta ausente mesmo com a configuracao comum disponivel.
    Platform.unmappable_bar = 4;
    try testing.expectError(
        error.MissingNotifyConfiguration,
        build(instances[0..], Platform.validate),
    );
    Platform.unmappable_bar = 2;

    // Uma regiao que passa do fim do BAR tambem e recusada; sem outra
    // instancia utilizavel da configuracao comum, ela esta ausente.
    var beyond = fallback;
    beyond.offset = 0x3FE0;
    const overflow = [_]Capability{ preferred, beyond, sample(cfg_type.notify) };
    try testing.expectError(
        error.MissingCommonConfiguration,
        build(overflow[0..], Platform.validate),
    );
}
