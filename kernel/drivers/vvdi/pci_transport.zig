//************************************************************************//
//  pci_transport.zig                                                     //
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

//! Transporte VirtIO sobre o barramento PCI.
//!
//! O dispositivo moderno nao tem registradores fixos: ele descreve onde estao
//! as regioes do transporte em capabilities vendor-specific (id 0x09), e o
//! driver mapeia o BAR que as contem. Este modulo liga as tres camadas:
//!
//!   * `caps`  - interpreta e valida as capabilities (fundacao do PR A);
//!   * `mmio`  - valida e executa cada acesso a regiao mapeada;
//!   * `transport` - executa a sequencia de inicializacao da especificacao.
//!
//! O que ele acrescenta e o **layout**: os offsets da configuracao comum
//! (secao 4.1.4.3) e a conta do endereco de notificacao (secao 4.1.4.4). Esses
//! numeros nao sao uma estrutura Zig sobreposta a memoria: cada campo e lido
//! com a largura que a especificacao define, porque o alinhamento de uma
//! estrutura Zig e uma regra do compilador, e nao do dispositivo.
//!
//! Nenhuma operacao de disco existe aqui. O transporte sabe negociar features,
//! ler o status e informar as filas; o que a fila transporta pertence ao
//! driver do tipo de dispositivo.

const std = @import("std");

const caps = @import("caps.zig");
const mmio = @import("mmio.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");

pub const Error = error{
    /// A capability da configuracao comum nao existe: sem ela nao ha
    /// transporte.
    MissingCommonRegion,
    /// A capability de notificacao nao existe.
    MissingNotifyRegion,
    /// As capabilities usaveis nao estao no mesmo BAR, e este incremento
    /// mapeia um BAR por dispositivo.
    RegionsInDifferentBars,
    /// A capability de configuracao do dispositivo nao existe.
    MissingDeviceRegion,
    /// O indice de fila nao existe.
    InvalidQueue,
    /// O tamanho pedido para a fila passa do maximo que o dispositivo informa.
    QueueSizeTooLarge,
    /// O dispositivo nao manteve `queue_enable` em 1 depois da escrita.
    QueueEnableNotConfirmed,
    /// A fila ja se apresenta habilitada: o driver nao escreve 0 em
    /// `queue_enable`, e habilitar de novo esconderia um dispositivo que nao
    /// esta no estado que este driver deixou.
    QueueAlreadyEnabled,
    /// O deslocamento nao esta alinhado para a largura do registrador.
    Misaligned,
};

/// Offsets da `struct virtio_pci_common_cfg` (especificacao 4.1.4.3).
///
/// A ordem e a da especificacao, e nao uma escolha: `device_feature_select`
/// vem antes de `device_feature`, `queue_select` antes de `queue_size`, e os
/// tres enderecos de fila ocupam 0x20, 0x28 e 0x30.
pub const offset = struct {
    pub const device_feature_select: u64 = 0x00;
    pub const device_feature: u64 = 0x04;
    pub const driver_feature_select: u64 = 0x08;
    pub const driver_feature: u64 = 0x0C;
    pub const config_msix_vector: u64 = 0x10;
    pub const num_queues: u64 = 0x12;
    pub const device_status: u64 = 0x14;
    pub const config_generation: u64 = 0x15;
    pub const queue_select: u64 = 0x16;
    pub const queue_size: u64 = 0x18;
    pub const queue_msix_vector: u64 = 0x1A;
    pub const queue_enable: u64 = 0x1C;
    pub const queue_notify_off: u64 = 0x1E;
    pub const queue_desc: u64 = 0x20;
    pub const queue_driver: u64 = 0x28;
    pub const queue_device: u64 = 0x30;
};

/// As regioes do transporte, ja mapeadas e validadas dentro do BAR.
pub const Regions = struct {
    common: mmio.Region,
    notify: mmio.Region,
    isr: ?mmio.Region,
    device: ?mmio.Region,
    /// `notify_off_multiplier` da capability de notificacao.
    notify_off_multiplier: u32,
};

/// Transporte ligado a um dispositivo PCI ja identificado.
pub const Transport = struct {
    identification: types.Identification,
    regions: Regions,
    /// Indice do BAR que contem as regioes. Mantido para o diagnostico.
    bar: u8,

    /// Constroi o transporte a partir das capabilities validadas e do BAR
    /// mapeado.
    ///
    /// As capabilities ja passaram por `caps.build`, que recusou tipo e BAR
    /// reservados, alinhamento e tamanho minimo. O que falta aqui e a ligacao
    /// com o mapeamento: cada capability vira uma visao da faixa mapeada, e a
    /// visao e validada contra ela — uma capability que aponte para fora do
    /// BAR e recusada antes de qualquer acesso.
    pub fn attach(
        identity: types.Identification,
        capabilities: caps.Collection,
        bar: mmio.Region,
    ) Error!Transport {
        if (capabilities.common.bar != capabilities.notify.bar) return error.RegionsInDifferentBars;
        if (capabilities.isr) |isr| {
            if (isr.bar != capabilities.common.bar) return error.RegionsInDifferentBars;
        }
        if (capabilities.device) |device| {
            if (device.bar != capabilities.common.bar) return error.RegionsInDifferentBars;
        }

        const common = bar.view(capabilities.common.offset, capabilities.common.length) catch |err|
            return mapRegionError(err);
        const notify = bar.view(capabilities.notify.offset, capabilities.notify.length) catch |err|
            return mapRegionError(err);

        var isr: ?mmio.Region = null;
        if (capabilities.isr) |capability| {
            isr = bar.view(capability.offset, capability.length) catch |err|
                return mapRegionError(err);
        }

        var device: ?mmio.Region = null;
        if (capabilities.device) |capability| {
            device = bar.view(capability.offset, capability.length) catch |err|
                return mapRegionError(err);
        }

        return .{
            .identification = identity,
            .regions = .{
                .common = common,
                .notify = notify,
                .isr = isr,
                .device = device,
                .notify_off_multiplier = capabilities.notify.notify_off_multiplier,
            },
            .bar = capabilities.common.bar,
        };
    }

    fn mapRegionError(err: anyerror) Error {
        return switch (err) {
            error.Misaligned => error.Misaligned,
            else => error.MissingCommonRegion,
        };
    }

    /// Enderecos das tres areas de uma virtqueue.
    ///
    /// A especificacao chama os tres de "queue addresses": descritores,
    /// *driver area* (a fila `avail`) e *device area* (a fila `used`). Cada um
    /// tem 64 bits, lidos como dois DWORDs.
    pub const QueueAddresses = struct {
        desc: u64,
        driver: u64,
        device: u64,
    };

    /// Le os tres enderecos da fila `index`.
    ///
    /// `queue_select` e escrito antes das leituras, como a especificacao
    /// exige: os registradores de endereco pertencem a fila selecionada.
    ///
    /// A funcao le e nao escreve. Programar a fila e o passo seguinte da
    /// sequencia, e ele so faz sentido junto com a alocacao das tres areas e
    /// com o `DRIVER_OK` que vem depois delas — o incremento das virtqueues.
    /// Ler agora permite conferir o que o dispositivo deixou na fila e prova
    /// que o layout da configuracao comum esta correto de ponta a ponta.
    pub fn queueAddresses(self: *Transport, index: u16) Error!QueueAddresses {
        const common = self.regions.common;
        common.write16(offset.queue_select, index) catch |err| return mapRegionError(err);

        return .{
            .desc = try readAddress(common, offset.queue_desc),
            .driver = try readAddress(common, offset.queue_driver),
            .device = try readAddress(common, offset.queue_device),
        };
    }

    fn readAddress(common: mmio.Region, at: u64) Error!u64 {
        const low = common.read32(at) catch |err| return mapRegionError(err);
        const high = common.read32(at + 4) catch |err| return mapRegionError(err);
        return (@as(u64, high) << 32) | low;
    }

    /// Contrato de registradores que a sequencia de inicializacao consome.
    ///
    /// O `ctx` e o proprio transporte: os offsets e as larguras ficam aqui, e
    /// `transport.zig` nao precisa conhecer o layout do PCI.
    pub fn registers(self: *Transport) transport.Registers {
        return .{
            .ctx = @ptrCast(self),
            .read_device_feature = registerReadDeviceFeature,
            .write_driver_feature = registerWriteDriverFeature,
            .read_driver_feature = registerReadDriverFeature,
            .read_status = registerReadStatus,
            .write_status = registerWriteStatus,
            .num_queues = registerNumQueues,
            .queue_size = registerQueueSize,
            .queue_notify_offset = registerQueueNotifyOffset,
        };
    }

    /// Notifies an already configured queue through its validated MMIO window.
    /// The queue publication barrier is performed by `virtqueue.Queue.publish`.
    pub fn notifyQueue(self: *Transport, index: u16) Error!void {
        const common = self.regions.common;
        const queue_count = common.read16(offset.num_queues) catch |err| return mapRegionError(err);
        if (index >= queue_count) return error.InvalidQueue;
        common.write16(offset.queue_select, index) catch |err| return mapRegionError(err);
        const notify_off = common.read16(offset.queue_notify_off) catch |err| return mapRegionError(err);
        const scaled = std.math.mul(u64, notify_off, self.regions.notify_off_multiplier) catch
            return error.InvalidQueue;
        const end = std.math.add(u64, scaled, 2) catch return error.InvalidQueue;
        if (end > self.regions.notify.length) return error.InvalidQueue;
        self.regions.notify.write16(scaled, index) catch |err| return mapRegionError(err);
    }

    /// Calculates the virtual address for a notification offset using
    /// `notify_off * notify_off_multiplier`, with bounds checked against the
    /// mapped notification region.
    pub fn notifyAddress(self: *Transport, notify_off: u16) Error!u64 {
        const region = self.regions.notify;
        if (!region.mapped) return error.MissingNotifyRegion;

        const scaled = std.math.mul(
            u64,
            notify_off,
            self.regions.notify_off_multiplier,
        ) catch return error.InvalidQueue;
        const end = std.math.add(u64, scaled, 2) catch return error.InvalidQueue;
        if (end > region.length) return error.InvalidQueue;
        return std.math.add(u64, region.virtual, scaled) catch return error.InvalidQueue;
    }

    /// Programa a fila `index`: tamanho e as tres areas, na ordem da
    /// especificacao 4.1.4.3.2.
    ///
    /// O driver escolhe um tamanho menor ou igual ao maximo que o dispositivo
    /// informa em `queue_size` (§2.7.5). Os enderecos sao fisicos, e cada um
    /// e checado contra o alinhamento que a area exige (16 para descritores,
    /// 2 para o anel `available` e 4 para o `used`, §2.7.4 a §2.7.8): um
    /// descritor desalinhado nao e um erro que o dispositivo reporte, e sim
    /// um barramento que le outra coisa.
    ///
    /// A funcao escreve e confere o tamanho relido; nao habilita a fila.
    /// `queue_enable` e o passo seguinte, e separa-lo deixa o chamador
    /// conferir o que foi programado antes de o dispositivo comecar a usar a
    /// memoria.
    ///
    /// Uma fila que ja se apresenta habilitada e recusada
    /// (`QueueAlreadyEnabled`), e nada e escrito: os campos desta funcao
    /// apontam o dispositivo para a memoria da fila, e trocar o destino de uma
    /// fila ativa entregaria ao dispositivo paginas de outro dono. O driver
    /// nao pode desabilitar a fila para corrigir isso — escrever 0 em
    /// `queue_enable` e proibido pela especificacao —, entao a recusa e o
    /// unico desfecho seguro.
    ///
    /// `queue_select` e escrito no inicio: ele escolhe a fila dos campos
    /// seguintes (`queue_size`, `queue_desc`, `queue_driver`, `queue_device`),
    /// e todos eles sao escritos na mesma chamada, sem depender de uma
    /// selecao anterior.
    pub fn configureQueue(
        self: *Transport,
        index: u16,
        size: u16,
        addresses: QueueAddresses,
    ) Error!void {
        const common = self.regions.common;
        const queues = common.read16(offset.num_queues) catch |err| return mapRegionError(err);
        if (index >= queues) return error.InvalidQueue;
        if (size == 0) return error.InvalidQueue;

        if (addresses.desc % 16 != 0) return error.Misaligned;
        if (addresses.driver % 2 != 0) return error.Misaligned;
        if (addresses.device % 4 != 0) return error.Misaligned;

        common.write16(offset.queue_select, index) catch |err| return mapRegionError(err);

        // Uma fila habilitada esta em uso pelo dispositivo: escrever o tamanho
        // ou os enderecos dela trocaria a memoria embaixo de um dispositivo que
        // ja a esta lendo. A especificacao exige que estes campos sejam
        // configurados antes do `queue_enable`, e o driver nao tem como
        // desabilitar a fila (escrever 0 em `queue_enable` e proibido), entao a
        // programacao e recusada em vez de aplicada.
        const enabled = common.read16(offset.queue_enable) catch |err| return mapRegionError(err);
        if (enabled != 0) return error.QueueAlreadyEnabled;

        const max_size = common.read16(offset.queue_size) catch |err| return mapRegionError(err);
        if (size > max_size) return error.QueueSizeTooLarge;

        common.write16(offset.queue_size, size) catch |err| return mapRegionError(err);
        const confirmed = common.read16(offset.queue_size) catch |err| return mapRegionError(err);
        if (confirmed != size) return error.QueueSizeTooLarge;

        try writeAddress(common, offset.queue_desc, addresses.desc);
        try writeAddress(common, offset.queue_driver, addresses.driver);
        try writeAddress(common, offset.queue_device, addresses.device);
    }

    /// Habilita a fila `index` e confirma o estado lido de volta.
    ///
    /// A especificacao 4.1.4.3.2 exige que o dispositivo devolva 1 em
    /// `queue_enable` depois da escrita. Um dispositivo que aceita a escrita e
    /// nao a mantem seria conduzido como se a fila existisse, e o primeiro
    /// pedido ficaria esperando uma conclusao que nunca chega — por isso a
    /// leitura de volta faz parte da operacao, e nao do chamador.
    ///
    /// O valor e lido **antes** da escrita. A especificacao exige que o
    /// dispositivo apresente 0 depois do reset e proibe o driver de escrever
    /// 0: uma fila que ja se apresenta habilitada nao esta no estado que este
    /// driver deixou, e a habilitacao e recusada em vez de repetida.
    ///
    /// `queue_select` e escrito aqui porque ele seleciona a fila dos campos
    /// seguintes e o dispositivo nao promete mante-lo: cada operacao escolhe a
    /// fila de novo, e nenhuma delas depende da selecao deixada pela anterior.
    pub fn enableQueue(self: *Transport, index: u16) Error!void {
        const common = self.regions.common;

        common.write16(offset.queue_select, index) catch |err| return mapRegionError(err);

        const current = common.read16(offset.queue_enable) catch |err| return mapRegionError(err);
        if (current != 0) return error.QueueAlreadyEnabled;

        common.write16(offset.queue_enable, 1) catch |err| return mapRegionError(err);
        const confirmed = common.read16(offset.queue_enable) catch |err| return mapRegionError(err);
        if (confirmed != 1) return error.QueueEnableNotConfirmed;
    }

    /// True quando o dispositivo mantem a fila `index` habilitada.
    ///
    /// A selecao e refeita aqui: `queue_select` escolhe a fila dos campos
    /// seguintes, e o driver nao presume que a selecao de uma chamada
    /// anterior continue valendo para a proxima.
    pub fn queueEnabled(self: *Transport, index: u16) Error!bool {
        const common = self.regions.common;

        common.write16(offset.queue_select, index) catch |err| return mapRegionError(err);
        const enabled = common.read16(offset.queue_enable) catch |err| return mapRegionError(err);
        return enabled == 1;
    }

    /// Escreve os 64 bits de um endereco de fila como dois DWORDs.
    fn writeAddress(common: mmio.Region, at: u64, value: u64) Error!void {
        common.write32(at, @truncate(value)) catch |err| return mapRegionError(err);
        common.write32(at + 4, @truncate(value >> 32)) catch |err| return mapRegionError(err);
    }

    /// Le a configuracao especifica do tipo de dispositivo.
    ///
    /// A leitura acontece byte a byte porque o comprimento e escolhido pelo
    /// driver do tipo, e nao pelo transporte: um bloco le a geometria, uma
    /// rede le o endereco MAC, e o transporte so precisa respeitar os limites
    /// da regiao.
    pub fn readDeviceConfig(self: *Transport, source_offset: u64, out: []u8) Error!void {
        const region = self.regions.device orelse return error.MissingDeviceRegion;
        if (region.length == 0) return error.MissingDeviceRegion;

        const end = std.math.add(u64, source_offset, out.len) catch return error.InvalidQueue;
        if (end > region.length) return error.InvalidQueue;

        for (out, 0..) |*slot, index| {
            slot.* = region.read8(source_offset + index) catch |err| return switch (err) {
                error.Misaligned => error.Misaligned,
                else => error.MissingDeviceRegion,
            };
        }
    }
};

fn fromContext(ctx: *anyopaque) *Transport {
    const self: *Transport = @ptrCast(@alignCast(ctx));
    return self;
}

fn mapMmio(err: mmio.Error) transport.Error {
    return switch (err) {
        error.Misaligned => error.RegisterAccess,
        error.NotMapped => error.RegisterAccess,
        error.OutOfRange => error.RegisterAccess,
        error.Overflow => error.RegisterAccess,
        error.NotWritable => error.RegisterAccess,
        error.EmptyRegion => error.RegisterAccess,
        error.WindowExhausted => error.RegisterAccess,
        error.MapFailed => error.RegisterAccess,
        error.InvalidWindow => error.RegisterAccess,
    };
}

/// Escreve o seletor e le a palavra escolhida.
///
/// O seletor e um registrador compartilhado: escrever `device_feature_select`
/// e ler `device_feature` precisa acontecer sem outra escrita no meio, e por
/// isso as duas funcoes abaixo nao podem ser separadas em chamadas paralelas.
fn registerReadDeviceFeature(ctx: *anyopaque, index: u1) transport.Error!u32 {
    const self = fromContext(ctx);
    const common = self.regions.common;

    common.write32(offset.device_feature_select, index) catch |err| return mapMmio(err);
    return common.read32(offset.device_feature) catch |err| return mapMmio(err);
}

fn registerWriteDriverFeature(ctx: *anyopaque, index: u1, value: u32) transport.Error!void {
    const self = fromContext(ctx);
    const common = self.regions.common;

    common.write32(offset.driver_feature_select, index) catch |err| return mapMmio(err);
    common.write32(offset.driver_feature, value) catch |err| return mapMmio(err);
}

fn registerReadDriverFeature(ctx: *anyopaque, index: u1) transport.Error!u32 {
    const self = fromContext(ctx);
    const common = self.regions.common;

    common.write32(offset.driver_feature_select, index) catch |err| return mapMmio(err);
    return common.read32(offset.driver_feature) catch |err| return mapMmio(err);
}

fn registerReadStatus(ctx: *anyopaque) transport.Error!u8 {
    const self = fromContext(ctx);
    return self.regions.common.read8(offset.device_status) catch |err| return mapMmio(err);
}

fn registerWriteStatus(ctx: *anyopaque, value: u8) transport.Error!void {
    const self = fromContext(ctx);
    self.regions.common.write8(offset.device_status, value) catch |err| return mapMmio(err);
}

fn registerNumQueues(ctx: *anyopaque) transport.Error!u16 {
    const self = fromContext(ctx);
    return self.regions.common.read16(offset.num_queues) catch |err| return mapMmio(err);
}

fn registerQueueSize(ctx: *anyopaque, index: u16) transport.Error!u16 {
    const self = fromContext(ctx);
    const common = self.regions.common;

    common.write16(offset.queue_select, index) catch |err| return mapMmio(err);
    return common.read16(offset.queue_size) catch |err| return mapMmio(err);
}

fn registerQueueNotifyOffset(ctx: *anyopaque, index: u16) transport.Error!u16 {
    const self = fromContext(ctx);
    const common = self.regions.common;

    common.write16(offset.queue_select, index) catch |err| return mapMmio(err);
    return common.read16(offset.queue_notify_off) catch |err| return mapMmio(err);
}

const testing = std.testing;
const features = @import("features.zig");
const virtqueue = @import("virtqueue.zig");

// ----------------------------------------------------------------------
// BAR simulado.
//
// O BAR falso e um vetor de bytes cujo barramento volatil foi trocado por um
// acesso a memoria comum. Ele modela a unica parte do dispositivo que os
// registradores exigem: as janelas de selecao. `device_feature` e
// `driver_feature` mostram a palavra escolhida por `*_select`, e nao um valor
// unico -- sem isso, os 64 bits de features nao existiriam, e a negociacao
// seria um teste de mentira.
// ----------------------------------------------------------------------

const fake_bar_size: usize = 0x2000;

const FakeBar = struct {
    var bytes: [fake_bar_size]u8 = @splat(0);
    var base: u64 = 0x4400_0000;

    /// As duas palavras que o dispositivo oferece.
    var device_words: [2]u32 = @splat(0);
    /// As duas palavras que o driver publicou.
    var driver_words: [2]u32 = @splat(0);
    /// Dispositivo que aceita a escrita de `queue_enable` e nao a mantem.
    var ignore_queue_enable: bool = false;

    fn reset() void {
        bytes = @splat(0);
        device_words = @splat(0);
        driver_words = @splat(0);
        ignore_queue_enable = false;
    }

    fn selected(select_offset: usize) usize {
        return bytes[select_offset] & 1;
    }

    fn read(_: ?*const anyopaque, address: u64, width: mmio.Width) u64 {
        const start: usize = @intCast(address - base);

        // Janela de selecao das features, como o dispositivo real faz.
        if (width == .dword and start == offset.device_feature) {
            return device_words[selected(@intCast(offset.device_feature_select))];
        }
        if (width == .dword and start == offset.driver_feature) {
            return driver_words[selected(@intCast(offset.driver_feature_select))];
        }

        var value: u64 = 0;
        var index: usize = 0;
        while (index < width.size()) : (index += 1) {
            value |= @as(u64, bytes[start + index]) << @intCast(index * 8);
        }
        return value;
    }

    fn write(_: ?*const anyopaque, address: u64, width: mmio.Width, value: u64) void {
        const start: usize = @intCast(address - base);

        if (ignore_queue_enable and start == offset.queue_enable) return;

        // A escrita em driver_feature cai na palavra selecionada, e nao em
        // quatro bytes soltos.
        if (width == .dword and start == offset.driver_feature) {
            driver_words[selected(@intCast(offset.driver_feature_select))] = @truncate(value);
            return;
        }

        var index: usize = 0;
        while (index < width.size()) : (index += 1) {
            bytes[start + index] = @truncate(value >> @intCast(index * 8));
        }
    }

    fn bus() mmio.Bus {
        return .{ .ctx = null, .read_fn = read, .write_fn = write };
    }

    /// Regiao que representa o BAR inteiro.
    fn region() mmio.Region {
        return .{
            .bus = bus(),
            .virtual = base,
            .physical = 0xFE00_0000,
            .length = fake_bar_size,
            .permissions = mmio.Permissions.read_write,
            .mapped = true,
        };
    }

    fn poke16(at: usize, value: u16) void {
        bytes[at] = @truncate(value);
        bytes[at + 1] = @truncate(value >> 8);
    }

    fn poke32(at: usize, value: u32) void {
        bytes[at] = @truncate(value);
        bytes[at + 1] = @truncate(value >> 8);
        bytes[at + 2] = @truncate(value >> 16);
        bytes[at + 3] = @truncate(value >> 24);
    }

    fn peek8(at: usize) u8 {
        return bytes[at];
    }

    fn peek16(at: usize) u16 {
        return (@as(u16, bytes[at + 1]) << 8) | bytes[at];
    }

    fn peek32(at: usize) u32 {
        return std.mem.readInt(u32, bytes[at..][0..4], .little);
    }
};

const identification: types.Identification = .{
    .device_type = .block,
    .device_id = 0x1042,
    .modern_id = true,
};

/// Colecao com as quatro regioes dentro do BAR simulado.
fn collection(common_length: u32) caps.Collection {
    return .{
        .common = .{
            .cfg_type = caps.cfg_type.common,
            .bar = 4,
            .id = 0,
            .offset = 0x0000,
            .length = common_length,
        },
        .notify = .{
            .cfg_type = caps.cfg_type.notify,
            .bar = 4,
            .id = 0,
            .offset = 0x1000,
            .length = 0x1000,
            .notify_off_multiplier = 4,
        },
        .isr = .{
            .cfg_type = caps.cfg_type.isr,
            .bar = 4,
            .id = 0,
            .offset = 0x0800,
            .length = 1,
        },
        .device = .{
            .cfg_type = caps.cfg_type.device,
            .bar = 4,
            .id = 0,
            .offset = 0x1800,
            .length = 0x10,
        },
    };
}

fn fakeTransport() Transport {
    FakeBar.reset();
    return Transport.attach(identification, collection(0x1000), FakeBar.region()) catch unreachable;
}

test "virtio pci common configuration offsets match the specification" {
    // Secao 4.1.4.3, campo a campo. Um erro aqui faria o driver conversar com
    // o registrador errado.
    try testing.expectEqual(@as(u64, 0x00), offset.device_feature_select);
    try testing.expectEqual(@as(u64, 0x04), offset.device_feature);
    try testing.expectEqual(@as(u64, 0x08), offset.driver_feature_select);
    try testing.expectEqual(@as(u64, 0x0C), offset.driver_feature);
    try testing.expectEqual(@as(u64, 0x10), offset.config_msix_vector);
    try testing.expectEqual(@as(u64, 0x12), offset.num_queues);
    try testing.expectEqual(@as(u64, 0x14), offset.device_status);
    try testing.expectEqual(@as(u64, 0x15), offset.config_generation);
    try testing.expectEqual(@as(u64, 0x16), offset.queue_select);
    try testing.expectEqual(@as(u64, 0x18), offset.queue_size);
    try testing.expectEqual(@as(u64, 0x1A), offset.queue_msix_vector);
    try testing.expectEqual(@as(u64, 0x1C), offset.queue_enable);
    try testing.expectEqual(@as(u64, 0x1E), offset.queue_notify_off);
    try testing.expectEqual(@as(u64, 0x20), offset.queue_desc);
    try testing.expectEqual(@as(u64, 0x28), offset.queue_driver);
    try testing.expectEqual(@as(u64, 0x30), offset.queue_device);

    // A fundacao exige 56 bytes de configuracao comum: o ultimo registrador
    // usado aqui (queue_device, 8 bytes em 0x30) termina exatamente ali.
    try testing.expectEqual(@as(u64, 56), offset.queue_device + 8);
    try testing.expect(caps.common_config_min_length >= 56);
}

test "virtio pci attach builds a region per capability" {
    FakeBar.reset();
    const result = try Transport.attach(identification, collection(0x1000), FakeBar.region());

    try testing.expectEqual(@as(u8, 4), result.bar);
    try testing.expectEqual(FakeBar.base, result.regions.common.virtual);
    try testing.expectEqual(@as(u64, 0x1000), result.regions.common.length);
    try testing.expectEqual(FakeBar.base + 0x1000, result.regions.notify.virtual);
    try testing.expectEqual(@as(u32, 4), result.regions.notify_off_multiplier);
    try testing.expect(result.regions.isr != null);
    try testing.expect(result.regions.device != null);
    try testing.expectEqual(FakeBar.base + 0x1800, result.regions.device.?.virtual);
}

test "virtio pci attach refuses regions outside the mapped bar" {
    FakeBar.reset();

    // A configuracao comum declara um comprimento que passa do BAR.
    const oversized = collection(fake_bar_size + 1);
    try testing.expectError(
        error.MissingCommonRegion,
        Transport.attach(identification, oversized, FakeBar.region()),
    );

    // A notificacao aponta para fora do BAR.
    var outside = collection(0x1000);
    outside.notify.offset = fake_bar_size - 4;
    outside.notify.length = 0x100;
    try testing.expectError(
        error.MissingCommonRegion,
        Transport.attach(identification, outside, FakeBar.region()),
    );
}

test "virtio pci attach requires every region in the same bar" {
    FakeBar.reset();

    var split = collection(0x1000);
    split.notify.bar = 1;
    try testing.expectError(
        error.RegionsInDifferentBars,
        Transport.attach(identification, split, FakeBar.region()),
    );

    split = collection(0x1000);
    split.device.?.bar = 3;
    try testing.expectError(
        error.RegionsInDifferentBars,
        Transport.attach(identification, split, FakeBar.region()),
    );
}

test "virtio pci registers reach the layout of the bar" {
    var device = fakeTransport();
    const registers = device.registers();

    // Features: cada palavra aparece depois de o seletor ser escrito.
    FakeBar.device_words[0] = 0xDEAD_BEEF;
    FakeBar.device_words[1] = 0x1234_5678;

    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try registers.read_device_feature(
        registers.ctx,
        0,
    ));
    try testing.expectEqual(@as(u8, 0), FakeBar.peek8(@intCast(offset.device_feature_select)));

    try testing.expectEqual(@as(u32, 0x1234_5678), try registers.read_device_feature(
        registers.ctx,
        1,
    ));
    try testing.expectEqual(@as(u8, 1), FakeBar.peek8(@intCast(offset.device_feature_select)));

    // Escrita de features: cai na palavra selecionada.
    try registers.write_driver_feature(registers.ctx, 1, 0x0000_0001);
    try testing.expectEqual(@as(u8, 1), FakeBar.peek8(@intCast(offset.driver_feature_select)));
    try testing.expectEqual(@as(u32, 0x0000_0001), FakeBar.driver_words[1]);
    try testing.expectEqual(@as(u32, 0), FakeBar.driver_words[0]);
    try testing.expectEqual(@as(u32, 0x0000_0001), try registers.read_driver_feature(
        registers.ctx,
        1,
    ));

    // Status: um byte em 0x14.
    try registers.write_status(registers.ctx, 0x0B);
    try testing.expectEqual(@as(u8, 0x0B), FakeBar.peek8(@intCast(offset.device_status)));
    try testing.expectEqual(@as(u8, 0x0B), try registers.read_status(registers.ctx));

    // Filas: num_queues e 16 bits em 0x12.
    FakeBar.poke16(@intCast(offset.num_queues), 3);
    try testing.expectEqual(@as(u16, 3), try registers.num_queues(registers.ctx));

    FakeBar.poke16(@intCast(offset.queue_size), 0x0100);
    FakeBar.poke16(@intCast(offset.queue_notify_off), 0x0007);
    try testing.expectEqual(@as(u16, 0x0100), try registers.queue_size(registers.ctx, 2));
    try testing.expectEqual(@as(u8, 2), FakeBar.peek8(@intCast(offset.queue_select)));
    try testing.expectEqual(@as(u16, 0x0007), try registers.queue_notify_offset(
        registers.ctx,
        2,
    ));
}

test "virtio pci register access past the region is refused" {
    // Uma configuracao comum de 18 bytes alcanca device_feature (0x04) mas
    // nao num_queues (0x12) nem device_status (0x14): os dois ultimos
    // terminam depois do fim da faixa declarada.
    FakeBar.reset();
    var device = try Transport.attach(identification, collection(18), FakeBar.region());
    const registers = device.registers();

    try testing.expectError(
        error.RegisterAccess,
        registers.read_status(registers.ctx),
    );
    try testing.expectError(
        error.RegisterAccess,
        registers.num_queues(registers.ctx),
    );
    // device_feature termina em 0x08, dentro dos 24 bytes.
    try testing.expectEqual(@as(u32, 0), try registers.read_device_feature(registers.ctx, 0));
}

test "virtio pci notify address follows the multiplier" {
    var device = fakeTransport();

    // Fila 0: o inicio da regiao.
    try testing.expectEqual(FakeBar.base + 0x1000, try device.notifyAddress(0));
    // Fila 1: um passo do multiplicador (4).
    try testing.expectEqual(FakeBar.base + 0x1004, try device.notifyAddress(1));
    // A ultima fila que ainda tem os dois bytes da notificacao dentro da
    // regiao de 0x1000: 1023 * 4 + 2 = 0xFFE.
    try testing.expectEqual(FakeBar.base + 0x1FFC, try device.notifyAddress(1023));
    // Um passo alem: 1024 * 4 + 2 = 0x1002, que passa do comprimento.
    try testing.expectError(error.InvalidQueue, device.notifyAddress(1024));
    try testing.expectError(error.InvalidQueue, device.notifyAddress(0xFFFF));

    // Multiplicador zero: todas as filas usam o mesmo endereco, como a
    // especificacao permite.
    device.regions.notify_off_multiplier = 0;
    try testing.expectEqual(FakeBar.base + 0x1000, try device.notifyAddress(0));
    try testing.expectEqual(FakeBar.base + 0x1000, try device.notifyAddress(0xFFFF));
}

test "virtio pci device configuration is read within the region" {
    var device = fakeTransport();

    // Geometria de bloco: quatro bytes em 0x00 da configuracao do dispositivo.
    FakeBar.poke32(0x1800, 0x0000_0200);
    var geometry: [4]u8 = undefined;
    try device.readDeviceConfig(0, &geometry);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x02, 0x00, 0x00 }, &geometry);

    // Fora da regiao declarada pela capability.
    var beyond: [4]u8 = undefined;
    try testing.expectError(error.InvalidQueue, device.readDeviceConfig(0x10, &beyond));
    try testing.expectError(error.InvalidQueue, device.readDeviceConfig(0x0E, &beyond));
}

test "virtio pci device configuration requires the capability" {
    FakeBar.reset();
    var without_device = collection(0x1000);
    without_device.device = null;

    var device = try Transport.attach(identification, without_device, FakeBar.region());
    var buffer: [4]u8 = undefined;
    try testing.expectError(error.MissingDeviceRegion, device.readDeviceConfig(0, &buffer));
}

test "virtio pci transport completes a real negotiation over the bar" {
    // O teste de composicao: um dispositivo simulado no BAR, os registradores
    // reais do layout PCI e a sequencia do transporte.
    FakeBar.reset();
    var device = try Transport.attach(identification, collection(0x1000), FakeBar.region());

    // O dispositivo se apresenta: VERSION_1 na segunda palavra e features de
    // bloco (RO, BLK_SIZE...) na primeira.
    FakeBar.device_words[0] = 0x0000_0004;
    FakeBar.device_words[1] = 0x0000_0001;
    FakeBar.poke16(@intCast(offset.num_queues), 1);
    FakeBar.poke16(@intCast(offset.queue_size), 256);

    var protocol = transport.Device{ .registers = device.registers() };
    const outcome = protocol.initialize(features.version_1);
    try testing.expect(outcome.isInitialized());

    // Status final: ACKNOWLEDGE|DRIVER|FEATURES_OK, sem DRIVER_OK.
    try testing.expectEqual(@as(u8, 0x0B), FakeBar.peek8(@intCast(offset.device_status)));
    try testing.expectEqual(@as(u8, 0x0B), protocol.status);
    try testing.expect(protocol.isAwaitingQueues());
    try testing.expectEqual(@as(u16, 1), protocol.queues);
    try testing.expectEqual(@as(u16, 256), try protocol.queueMaxSize(0));

    // O driver publicou a feature negociada nas duas palavras: a segunda tem
    // o bit 32 (VERSION_1), e a primeira ficou zerada.
    try testing.expectEqual(features.version_1, protocol.accepted);
    try testing.expectEqual(@as(u32, 0), FakeBar.driver_words[0]);
    try testing.expectEqual(@as(u32, 1), FakeBar.driver_words[1]);
}

test "virtio pci queue addresses are read from the selected queue" {
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 2);

    // Fila 0: enderecos completos de 64 bits, com a metade alta diferente de
    // zero — um truncamento para 32 bits apareceria aqui.
    FakeBar.poke32(@intCast(offset.queue_desc), 0x0000_1000);
    FakeBar.poke32(@intCast(offset.queue_desc + 4), 0x0000_0001);
    FakeBar.poke32(@intCast(offset.queue_driver), 0x0000_2000);
    FakeBar.poke32(@intCast(offset.queue_driver + 4), 0x0000_0002);
    FakeBar.poke32(@intCast(offset.queue_device), 0x0000_3000);
    FakeBar.poke32(@intCast(offset.queue_device + 4), 0x0000_0003);

    const first = try device.queueAddresses(0);
    try testing.expectEqual(@as(u64, 0x0000_0001_0000_1000), first.desc);
    try testing.expectEqual(@as(u64, 0x0000_0002_0000_2000), first.driver);
    try testing.expectEqual(@as(u64, 0x0000_0003_0000_3000), first.device);
    try testing.expectEqual(@as(u8, 0), FakeBar.peek8(@intCast(offset.queue_select)));

    // A fila 1 tem os proprios enderecos, e a selecao e escrita antes da
    // leitura.
    FakeBar.poke32(@intCast(offset.queue_desc), 0x0000_4000);
    FakeBar.poke32(@intCast(offset.queue_desc + 4), 0);
    const second = try device.queueAddresses(1);
    try testing.expectEqual(@as(u64, 0x0000_4000), second.desc);
    try testing.expectEqual(@as(u8, 1), FakeBar.peek8(@intCast(offset.queue_select)));

    // A leitura tambem e validada contra o fim da configuracao comum: uma
    // regiao que termine antes de 0x28 nao alcanca a area do driver.
    FakeBar.reset();
    var narrow = try Transport.attach(identification, collection(0x28), FakeBar.region());
    try testing.expectError(error.MissingCommonRegion, narrow.queueAddresses(0));
}

test "virtio pci programs a queue size and the three physical addresses" {
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 2);
    FakeBar.poke16(@intCast(offset.queue_size), 256);

    // Fila 0 com 128 descritores: 2048 bytes de tabela, 262 de anel
    // available e o used depois do alinhamento.
    const layout = virtqueue.Layout.compute(128) catch unreachable;
    const physical: u64 = 0x0000_0001_3000_0000;
    const addresses = layout.addresses(physical) catch unreachable;

    try device.configureQueue(0, 128, .{
        .desc = addresses.desc,
        .driver = addresses.driver,
        .device = addresses.device,
    });

    try testing.expectEqual(@as(u8, 0), FakeBar.peek8(@intCast(offset.queue_select)));
    try testing.expectEqual(@as(u16, 128), FakeBar.peek16(@intCast(offset.queue_size)));

    // Os tres enderecos sao gravados como dois DWORDs cada: o truncamento
    // para 32 bits apareceria na metade alta.
    try testing.expectEqual(@as(u32, 0x3000_0000), FakeBar.peek32(@intCast(offset.queue_desc)));
    try testing.expectEqual(@as(u32, 0x0000_0001), FakeBar.peek32(@intCast(offset.queue_desc + 4)));
    try testing.expectEqual(
        @as(u32, @truncate(addresses.driver)),
        FakeBar.peek32(@intCast(offset.queue_driver)),
    );
    try testing.expectEqual(
        @as(u32, @truncate(addresses.device)),
        FakeBar.peek32(@intCast(offset.queue_device)),
    );

    // A segunda fila recebe os proprios enderecos, e a selecao muda antes.
    try device.configureQueue(1, 64, .{
        .desc = 0x4000_0000,
        .driver = 0x4000_0800,
        .device = 0x4000_0900,
    });
    try testing.expectEqual(@as(u8, 1), FakeBar.peek8(@intCast(offset.queue_select)));
    try testing.expectEqual(@as(u16, 64), FakeBar.peek16(@intCast(offset.queue_size)));
    try testing.expectEqual(@as(u32, 0x4000_0000), FakeBar.peek32(@intCast(offset.queue_desc)));
    try testing.expectEqual(@as(u32, 0x4000_0900), FakeBar.peek32(@intCast(offset.queue_device)));
}

test "virtio pci refuses queue sizes and addresses the specification forbids" {
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 1);
    FakeBar.poke16(@intCast(offset.queue_size), 256);

    // Fila inexistente.
    try testing.expectError(
        error.InvalidQueue,
        device.configureQueue(1, 64, .{ .desc = 0x1000, .driver = 0x2000, .device = 0x3000 }),
    );
    // Tamanho zero.
    try testing.expectError(
        error.InvalidQueue,
        device.configureQueue(0, 0, .{ .desc = 0x1000, .driver = 0x2000, .device = 0x3000 }),
    );
    // Acima do maximo que o dispositivo informa.
    try testing.expectError(
        error.QueueSizeTooLarge,
        device.configureQueue(0, 512, .{ .desc = 0x1000, .driver = 0x2000, .device = 0x3000 }),
    );
    // Desalinhamentos: 16 para descritores, 2 para available, 4 para used.
    try testing.expectError(
        error.Misaligned,
        device.configureQueue(0, 64, .{ .desc = 0x1008, .driver = 0x2000, .device = 0x3000 }),
    );
    try testing.expectError(
        error.Misaligned,
        device.configureQueue(0, 64, .{ .desc = 0x1000, .driver = 0x2001, .device = 0x3000 }),
    );
    try testing.expectError(
        error.Misaligned,
        device.configureQueue(0, 64, .{ .desc = 0x1000, .driver = 0x2000, .device = 0x3002 }),
    );

    // Nada foi escrito na fila depois das recusas: o tamanho continua o que o
    // dispositivo informou.
    try testing.expectEqual(@as(u16, 256), FakeBar.peek16(@intCast(offset.queue_size)));
    try testing.expectEqual(@as(u32, 0), FakeBar.peek32(@intCast(offset.queue_desc)));
}

test "virtio pci enables a queue and confirms the reading" {
    // O BAR simulado tem uma copia unica de cada registrador de fila acima da
    // selecao, e nao uma por fila: o teste usa uma fila so para que o valor
    // lido seja o que o driver escreveu para ela.
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 1);

    try testing.expect(!try device.queueEnabled(0));
    try device.enableQueue(0);
    try testing.expect(try device.queueEnabled(0));
    try testing.expectEqual(@as(u16, 1), FakeBar.peek16(@intCast(offset.queue_enable)));
    try testing.expectEqual(@as(u8, 0), FakeBar.peek8(@intCast(offset.queue_select)));

    // Um dispositivo que descarta a escrita nao pode ser dado como pronto.
    FakeBar.ignore_queue_enable = true;
    FakeBar.poke16(@intCast(offset.queue_enable), 0);
    try testing.expectError(error.QueueEnableNotConfirmed, device.enableQueue(0));
    try testing.expect(!try device.queueEnabled(0));
}

test "virtio pci queue programming is refused when the common region is short" {
    FakeBar.reset();
    // 0x1E bytes alcancam queue_enable (0x1C), mas nao a area do driver
    // (0x28).
    var narrow = try Transport.attach(identification, collection(0x1E), FakeBar.region());
    FakeBar.poke16(@intCast(offset.num_queues), 1);
    FakeBar.poke16(@intCast(offset.queue_size), 64);

    narrow.configureQueue(0, 64, .{
        .desc = 0x1000,
        .driver = 0x2000,
        .device = 0x3000,
    }) catch |err| {
        // O primeiro registrador que passa da faixa declarada e queue_desc.
        try testing.expectEqual(@as(anyerror, error.MissingCommonRegion), err);
        return;
    };
    return error.TestUnexpectedResult;
}

// ----------------------------------------------------------------------
// `queue_enable` lido antes de ser escrito, e o contrato de `queue_select`
// (correcao D-3).
// ----------------------------------------------------------------------

test "a queue that is already enabled is refused before the write" {
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 1);

    // O dispositivo se apresenta com um valor que nao e o que este driver
    // deixaria: a habilitacao e recusada antes de qualquer escrita.
    FakeBar.poke16(@intCast(offset.queue_enable), 2);
    try testing.expectError(error.QueueAlreadyEnabled, device.enableQueue(0));

    // A prova de que nada foi escrito: o valor continua 2, e nao virou 1.
    try testing.expectEqual(@as(u16, 2), FakeBar.peek16(@intCast(offset.queue_enable)));
}

test "enabling the same queue twice is refused instead of repeated" {
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 1);

    try device.enableQueue(0);
    try testing.expectEqual(@as(u16, 1), FakeBar.peek16(@intCast(offset.queue_enable)));

    // A segunda habilitacao encontra a fila ja habilitada pelo driver: repetir
    // esconderia uma reinicializacao do dispositivo por fora.
    try testing.expectError(error.QueueAlreadyEnabled, device.enableQueue(0));
    try testing.expect(try device.queueEnabled(0));
}

test "every queue operation selects the queue it acts on" {
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 2);
    FakeBar.poke16(@intCast(offset.queue_size), 64);

    // O dispositivo nao promete manter `queue_select`: cada operacao escolhe a
    // fila de novo, e a selecao observada e a da operacao, nao a anterior.
    try device.configureQueue(1, 64, .{ .desc = 0x1000, .driver = 0x2000, .device = 0x3000 });
    try testing.expectEqual(@as(u8, 1), FakeBar.peek8(@intCast(offset.queue_select)));

    try device.enableQueue(1);
    try testing.expectEqual(@as(u8, 1), FakeBar.peek8(@intCast(offset.queue_select)));

    _ = try device.queueEnabled(1);
    try testing.expectEqual(@as(u8, 1), FakeBar.peek8(@intCast(offset.queue_select)));

    // E a fila 0 e selecionada do zero, sem herdar a selecao da fila 1. O BAR
    // simulado guarda uma copia por campo, e nao uma por fila, entao o
    // `queue_enable` da fila 0 e zerado a mao antes da chamada.
    FakeBar.poke16(@intCast(offset.queue_enable), 0);
    try device.enableQueue(0);
    try testing.expectEqual(@as(u8, 0), FakeBar.peek8(@intCast(offset.queue_select)));
}

// ----------------------------------------------------------------------
// Regressoes da correcao A-1: uma fila habilitada nao e reprogramada, e o
// erro nao e lido como "o dispositivo esta desabilitado".
// ----------------------------------------------------------------------

test "an enabled queue is not reprogrammed and keeps its state" {
    var device = fakeTransport();
    FakeBar.poke16(@intCast(offset.num_queues), 1);
    FakeBar.poke16(@intCast(offset.queue_size), 64);

    // O dispositivo se apresenta com a fila habilitada e com uma fila ja
    // programada: e o estado que o driver nao criou e nao pode desfazer.
    FakeBar.poke16(@intCast(offset.queue_enable), 1);
    FakeBar.poke32(@intCast(offset.queue_desc), 0x1111_1000);
    FakeBar.poke32(@intCast(offset.queue_driver), 0x2222_2000);
    FakeBar.poke32(@intCast(offset.queue_device), 0x3333_3000);

    // Reprogramar trocaria a memoria embaixo do dispositivo: recusado, e nada
    // e escrito.
    try testing.expectError(
        error.QueueAlreadyEnabled,
        device.configureQueue(0, 64, .{ .desc = 0x9000_0000, .driver = 0x9000_1000, .device = 0x9000_2000 }),
    );
    try testing.expectEqual(@as(u32, 0x1111_1000), FakeBar.peek32(@intCast(offset.queue_desc)));
    try testing.expectEqual(@as(u32, 0x2222_2000), FakeBar.peek32(@intCast(offset.queue_driver)));
    try testing.expectEqual(@as(u32, 0x3333_3000), FakeBar.peek32(@intCast(offset.queue_device)));
    try testing.expectEqual(@as(u16, 64), FakeBar.peek16(@intCast(offset.queue_size)));

    // A habilitacao tambem e recusada, e a fila continua habilitada: o erro
    // nao e evidencia de que o dispositivo ficou desabilitado.
    try testing.expectError(error.QueueAlreadyEnabled, device.enableQueue(0));
    try testing.expect(try device.queueEnabled(0));
    try testing.expectEqual(@as(u16, 1), FakeBar.peek16(@intCast(offset.queue_enable)));
}

test "a partial configuration failure leaves the queue addressable by the device" {
    FakeBar.reset();
    // Regiao comum que alcanca `queue_desc` (0x20) mas para antes de
    // `queue_driver` (0x28): a escrita do segundo endereco falha depois de o
    // primeiro ter sido aceito.
    var narrow = try Transport.attach(identification, collection(0x24), FakeBar.region());
    FakeBar.poke16(@intCast(offset.num_queues), 1);
    FakeBar.poke16(@intCast(offset.queue_size), 64);

    // `mapRegionError` reporta a faixa curta como `MissingCommonRegion`: e a
    // mesma recusa do teste da regiao curta, agora com o estado do dispositivo
    // a esquerda.
    try testing.expectError(error.MissingCommonRegion, narrow.configureQueue(0, 64, .{
        .desc = 0x5000_0000,
        .driver = 0x5000_1000,
        .device = 0x5000_2000,
    }));

    // A configuracao ficou pela metade: `queue_desc` aponta para a memoria da
    // fila e nao pode ser desfeito. E este o estado em que o chamador precisa
    // tratar o dispositivo como capaz de acessar os buffers.
    try testing.expectEqual(@as(u32, 0x5000_0000), FakeBar.peek32(@intCast(offset.queue_desc)));
    try testing.expect(!try narrow.queueEnabled(0));
}
