//************************************************************************//
//  transport.zig                                                         //
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

//! Protocolo de inicializacao do transporte VirtIO, independente do barramento.
//!
//! O transporte moderno se apresenta de duas formas: pelo PCI (capabilities
//! vendor-specific com as regioes do transporte) e, no futuro, por MMIO
//! direto. O que os dois tem em comum e a *sequencia* de inicializacao da
//! secao 3.1.1 da especificacao:
//!
//! ```text
//!   reset -> ACKNOWLEDGE -> DRIVER -> features -> FEATURES_OK
//! ```
//!
//! Este modulo implementa essa sequencia contra o contrato `Registers`, que
//! informa como os registradores da configuracao comum sao alcancados. Quem o
//! implementa e `pci_transport.zig`, sobre MMIO; os testes implementam o
//! mesmo contrato sobre um arquivo de registradores em memoria.
//!
//! Duas regras dao forma ao modulo:
//!
//!   * **o estado vem do dispositivo.** O campo `status` e sempre o valor
//!     lido de volta depois de cada escrita; nao existe um estado interno que
//!     possa divergir do hardware. Se o dispositivo nao confirmar o valor
//!     escrito, a inicializacao falha em vez de seguir;
//!   * **nao existe caminho para DRIVER_OK.** A interface termina em
//!     `FEATURES_OK`, que e o estado correto antes das virtqueues. Escrever
//!     DRIVER_OK sem filas programadas anunciaria um dispositivo funcional que
//!     nao funciona, e por isso nao ha funcao publica que o faca — a API sera
//!     acrescentada pelo incremento das virtqueues, junto com a programacao
//!     que a justifica.
//!
//! A especificacao 2.4 e explicita: *"The driver MUST NOT clear a device
//! status bit"*. A validacao da escrita passa por `status.transition`, que ja
//! recusa a limpeza de um bit e a escrita do bit do dispositivo.

const std = @import("std");

const features = @import("features.zig");
const status = @import("status.zig");

pub const Error = error{
    /// A escrita de status apagaria um bit ja ligado.
    StatusBitCleared,
    /// O driver tentou escrever um bit que pertence ao dispositivo.
    DeviceBitWrittenByDriver,
    /// A escrita de status nao forma um estado da sequencia.
    InvalidStatusCombination,
    /// A transicao de status pula um passo.
    IllegalStatusTransition,
    /// O bit de suspensao foi escrito, e ele nao e negociado.
    StatusSuspendUnsupported,
    /// Um bit nao definido pela especificacao esta ligado no status.
    StatusReservedBitSet,
    /// O dispositivo nao zerou o status depois do reset.
    DeviceDidNotReset,
    /// O status lido nao e o que foi escrito: o dispositivo nao confirmou.
    StatusNotConfirmed,
    /// O dispositivo recusou a negociacao e nao ligou FEATURES_OK.
    FeaturesRejected,
    /// O dispositivo nao devolveu as features que o driver publicou.
    FeatureWriteNotConfirmed,
    /// O dispositivo nao oferece VIRTIO_F_VERSION_1.
    Version1NotOffered,
    /// O driver nao aceitou VIRTIO_F_VERSION_1.
    Version1NotNegotiated,
    /// O driver pediu uma feature que o dispositivo nao oferece.
    FeatureNotOffered,
    /// A feature existe, mas este subsistema ainda nao a implementa.
    FeatureNotImplemented,
    /// VIRTIO_F_ACCESS_PLATFORM exige um IOMMU, que nao existe aqui.
    AccessPlatformUnsupported,
    /// VIRTIO_F_RING_PACKED exige o layout empacotado.
    PackedRingUnsupported,
    /// O indice de fila pedido nao existe no dispositivo.
    InvalidQueue,
    /// O contrato de registradores falhou (leitura fora da regiao, por
    /// exemplo).
    RegisterAccess,
};

/// Contrato de acesso aos registradores da configuracao comum.
///
/// As larguras e os significados vem da especificacao 4.1.4.3; os offsets
/// ficam em quem implementa o contrato, e nao aqui, porque so o transporte
/// conhece o mapeamento que ele proprio usa.
pub const Registers = struct {
    ctx: *anyopaque,
    /// Le `device_feature` com o indice de selecao dado (0 ou 1).
    read_device_feature: *const fn (ctx: *anyopaque, index: u1) Error!u32,
    /// Escreve `driver_feature` com o indice de selecao dado.
    write_driver_feature: *const fn (ctx: *anyopaque, index: u1, value: u32) Error!void,
    /// Le `driver_feature` com o indice de selecao dado.
    read_driver_feature: *const fn (ctx: *anyopaque, index: u1) Error!u32,
    /// Le `device_status`.
    read_status: *const fn (ctx: *anyopaque) Error!u8,
    /// Escreve `device_status`.
    write_status: *const fn (ctx: *anyopaque, value: u8) Error!void,
    /// Le `num_queues`.
    num_queues: *const fn (ctx: *anyopaque) Error!u16,
    /// Le `queue_size` da fila escolhida.
    queue_size: *const fn (ctx: *anyopaque, index: u16) Error!u16,
    /// Le `queue_notify_off` da fila escolhida.
    queue_notify_offset: *const fn (ctx: *anyopaque, index: u16) Error!u16,
};

/// Etapas da sequencia, na ordem em que acontecem.
pub const Stage = enum {
    reset,
    acknowledge,
    driver,
    read_features,
    write_features,
    features_ok,
    queue_scan,

    /// Nome estavel da etapa, para o diagnostico.
    pub fn label(self: Stage) []const u8 {
        return @tagName(self);
    }
};

/// Resultado da inicializacao.
///
/// O erro tipado vem acompanhado da etapa: quem imprime o diagnostico nao
/// precisa adivinhar onde a sequencia parou, e a mensagem nao pode divergir do
/// que aconteceu.
pub const Outcome = union(enum) {
    initialized: void,
    failed: Failure,

    pub const Failure = struct {
        stage: Stage,
        reason: Error,
    };

    pub fn isInitialized(self: Outcome) bool {
        return switch (self) {
            .initialized => true,
            .failed => false,
        };
    }
};

/// Dispositivo cuja inicializacao parou antes de DRIVER_OK.
pub const Device = struct {
    registers: Registers,

    /// Ultimo valor lido de `device_status`.
    ///
    /// Nao e um estado paralelo: toda escrita e seguida de uma leitura, e e o
    /// valor lido que fica aqui. `phase` o interpreta.
    status: u8 = 0,

    /// Features que o dispositivo ofereceu no ultimo `readOfferedFeatures`.
    offered: u64 = 0,

    /// Features efetivamente publicadas em `driver_feature`.
    accepted: u64 = 0,

    /// Quantidade de filas informada pelo dispositivo.
    queues: u16 = 0,

    /// Executa a sequencia completa ate FEATURES_OK.
    ///
    /// `supported` e o conjunto que o VorynOS sabe conduzir. A funcao:
    ///
    ///   1. escreve zero e confirma que o dispositivo zerou o status;
    ///   2. liga ACKNOWLEDGE e confirma;
    ///   3. liga DRIVER e confirma;
    ///   4. le as duas palavras de `device_feature`;
    ///   5. negocia, publica `driver_feature` e confirma a leitura;
    ///   6. liga FEATURES_OK e confirma que o dispositivo o manteve.
    ///
    /// O passo 6 e o ultimo. DRIVER_OK nao e escrito aqui em nenhuma
    /// condicao.
    pub fn initialize(self: *Device, supported: u64) Outcome {
        self.resetDevice() catch |err| return failure(.reset, err);

        self.setStatusSync(status.bitsOf(.acknowledge), .acknowledge) catch |err|
            return failure(.acknowledge, err);
        self.setStatusSync(status.bitsOf(.driver), .driver) catch |err|
            return failure(.driver, err);

        const offered = self.readOfferedFeatures() catch |err|
            return failure(.read_features, err);
        self.offered = offered;

        const negotiated = features.negotiate(offered, supported) catch |err|
            return failure(.read_features, mapFeatureError(err));

        self.writeAcceptedFeatures(negotiated) catch |err|
            return failure(.write_features, err);
        self.accepted = negotiated;

        self.setStatusSync(status.bitsOf(.features_ok), .features_ok) catch |err|
            return failure(.features_ok, err);

        self.queues = self.registers.num_queues(self.registers.ctx) catch |err|
            return failure(.queue_scan, err);

        return .{ .initialized = {} };
    }

    fn failure(stage: Stage, reason: Error) Outcome {
        return .{ .failed = .{ .stage = stage, .reason = reason } };
    }

    /// Escreve zero e confirma que o dispositivo zerou o status.
    pub fn resetDevice(self: *Device) Error!void {
        try self.registers.write_status(self.registers.ctx, 0);

        const observed = try self.registers.read_status(self.registers.ctx);
        if (observed != 0) return error.DeviceDidNotReset;

        self.status = 0;
        self.offered = 0;
        self.accepted = 0;
        self.queues = 0;
    }

    /// Le o conjunto de 64 bits que o dispositivo oferece.
    pub fn readOfferedFeatures(self: *Device) Error!u64 {
        const low = try self.registers.read_device_feature(self.registers.ctx, 0);
        const high = try self.registers.read_device_feature(self.registers.ctx, 1);
        return features.fromWords(low, high);
    }

    /// Publica o conjunto negociado e confirma a leitura de volta.
    ///
    /// A confirmacao importa: um dispositivo que ignora `driver_feature`
    /// aceitaria FEATURES_OK sem que o driver tenha dito o que quer. A
    /// leitura de volta e o que separa uma negociacao real de uma suposta.
    pub fn writeAcceptedFeatures(self: *Device, accepted: u64) Error!void {
        try self.registers.write_driver_feature(
            self.registers.ctx,
            0,
            features.word(accepted, 0),
        );
        try self.registers.write_driver_feature(
            self.registers.ctx,
            1,
            features.word(accepted, 1),
        );

        const low = try self.registers.read_driver_feature(self.registers.ctx, 0);
        const high = try self.registers.read_driver_feature(self.registers.ctx, 1);
        if (features.fromWords(low, high) != accepted) return error.FeatureWriteNotConfirmed;
    }

    /// Escreve o status, le de volta e confirma a fase esperada.
    ///
    /// A escrita e validada por `status.transition` contra o valor que esta no
    /// dispositivo naquele momento, e nao contra uma copia local: se o
    /// dispositivo mudou o status sozinho (DEVICE_NEEDS_RESET, por exemplo), a
    /// transicao e recusada aqui.
    fn setStatusSync(self: *Device, value: u8, expected: status.Phase) Error!void {
        const current = try self.registers.read_status(self.registers.ctx);
        _ = status.transition(current, value) catch |err| return switch (err) {
            error.StatusBitCleared => error.StatusBitCleared,
            error.DeviceBitWrittenByDriver => error.DeviceBitWrittenByDriver,
            error.InvalidCombination => error.InvalidStatusCombination,
            error.IllegalTransition => error.IllegalStatusTransition,
            error.ReservedBitSet => error.StatusReservedBitSet,
            error.SuspendUnsupported => error.StatusSuspendUnsupported,
        };

        try self.registers.write_status(self.registers.ctx, value);

        const observed = try self.registers.read_status(self.registers.ctx);
        self.status = observed;

        const observed_phase = status.phase(observed) catch |err| return switch (err) {
            error.ReservedBitSet => error.StatusReservedBitSet,
            error.SuspendUnsupported => error.StatusSuspendUnsupported,
            else => error.InvalidStatusCombination,
        };
        if (observed_phase != expected) return error.StatusNotConfirmed;
    }

    /// Interpreta o valor atual do status.
    pub fn phase(self: Device) Error!status.Phase {
        return status.phase(self.status) catch |err| return switch (err) {
            error.ReservedBitSet => error.StatusReservedBitSet,
            error.SuspendUnsupported => error.StatusSuspendUnsupported,
            else => error.InvalidStatusCombination,
        };
    }

    /// Le o status atual do dispositivo, sem escrever nada.
    pub fn readStatus(self: *Device) Error!u8 {
        const observed = try self.registers.read_status(self.registers.ctx);
        self.status = observed;
        return observed;
    }

    /// Tamanho maximo da fila `index`, como o dispositivo informa.
    ///
    /// Nenhuma fila e programada aqui: a funcao existe para que o incremento
    /// das virtqueues consulte o dispositivo sem tocar no transporte.
    pub fn queueMaxSize(self: *Device, index: u16) Error!u16 {
        if (index >= self.queues) return error.InvalidQueue;
        return self.registers.queue_size(self.registers.ctx, index);
    }

    /// Deslocamento de notificacao da fila `index`.
    pub fn queueNotifyOffset(self: *Device, index: u16) Error!u16 {
        if (index >= self.queues) return error.InvalidQueue;
        return self.registers.queue_notify_offset(self.registers.ctx, index);
    }

    /// True quando a inicializacao chegou ao ponto anterior as virtqueues.
    pub fn isAwaitingQueues(self: Device) bool {
        const current = self.phase() catch return false;
        return current == .features_ok;
    }
};

fn mapFeatureError(err: anyerror) Error {
    return switch (err) {
        error.Version1NotOffered => error.Version1NotOffered,
        error.Version1NotNegotiated => error.Version1NotNegotiated,
        error.FeatureNotOffered => error.FeatureNotOffered,
        error.FeatureNotImplemented => error.FeatureNotImplemented,
        error.AccessPlatformUnsupported => error.AccessPlatformUnsupported,
        error.PackedRingUnsupported => error.PackedRingUnsupported,
        else => error.RegisterAccess,
    };
}

const testing = std.testing;

// ----------------------------------------------------------------------
// Arquivo de registradores simulado.
//
// O dispositivo falso guarda os registradores da configuracao comum e um
// historico de tudo que o driver escreveu. E o historico que permite provar
// que DRIVER_OK nunca foi escrito: nao basta a API nao ter a funcao, porque
// uma escrita poderia vir de qualquer outro caminho.
// ----------------------------------------------------------------------

const Fake = struct {
    var device_feature_low: u32 = 0;
    var device_feature_high: u32 = 0;
    var driver_feature_low: u32 = 0;
    var driver_feature_high: u32 = 0;
    var device_status: u8 = 0;
    var num_queues: u16 = 1;
    var queue_size: u16 = 256;
    var queue_notify_off: u16 = 0;

    /// Toda escrita de status, na ordem.
    var status_writes: [8]u8 = @splat(0);
    var status_write_count: usize = 0;

    /// True quando o dispositivo ignora FEATURES_OK, como faz um aparelho que
    /// nao aceita o conjunto negociado.
    var reject_features_ok: bool = false;

    /// True quando o dispositivo nao zera o status no reset.
    var ignore_reset: bool = false;

    /// True quando o dispositivo aceita a escrita de features mas nao guarda
    /// o valor.
    var ignore_driver_features: bool = false;

    fn reset() void {
        device_feature_low = 0;
        device_feature_high = 0;
        driver_feature_low = 0;
        driver_feature_high = 0;
        device_status = 0;
        num_queues = 1;
        queue_size = 256;
        queue_notify_off = 0;
        status_writes = @splat(0);
        status_write_count = 0;
        reject_features_ok = false;
        ignore_reset = false;
        ignore_driver_features = false;
    }

    fn ctx() *anyopaque {
        return @ptrCast(&device_status);
    }

    fn readDeviceFeature(_: *anyopaque, index: u1) Error!u32 {
        return if (index == 0) device_feature_low else device_feature_high;
    }

    fn writeDriverFeature(_: *anyopaque, index: u1, value: u32) Error!void {
        if (ignore_driver_features) return;
        if (index == 0) {
            driver_feature_low = value;
        } else {
            driver_feature_high = value;
        }
    }

    fn readDriverFeature(_: *anyopaque, index: u1) Error!u32 {
        return if (index == 0) driver_feature_low else driver_feature_high;
    }

    fn readStatus(_: *anyopaque) Error!u8 {
        return device_status;
    }

    fn writeStatus(_: *anyopaque, value: u8) Error!void {
        if (status_write_count == status_writes.len) return error.RegisterAccess;
        status_writes[status_write_count] = value;
        status_write_count += 1;

        if (value == 0) {
            if (!ignore_reset) device_status = 0;
            return;
        }
        if ((value & status.features_ok) != 0 and reject_features_ok) {
            device_status = value & ~status.features_ok;
            return;
        }
        device_status = value;
    }

    fn numQueues(_: *anyopaque) Error!u16 {
        return num_queues;
    }

    fn queueSize(_: *anyopaque, index: u16) Error!u16 {
        if (index >= num_queues) return error.RegisterAccess;
        return queue_size;
    }

    fn queueNotifyOffset(_: *anyopaque, index: u16) Error!u16 {
        if (index >= num_queues) return error.RegisterAccess;
        return queue_notify_off;
    }

    fn registers() Registers {
        return .{
            .ctx = ctx(),
            .read_device_feature = readDeviceFeature,
            .write_driver_feature = writeDriverFeature,
            .read_driver_feature = readDriverFeature,
            .read_status = readStatus,
            .write_status = writeStatus,
            .num_queues = numQueues,
            .queue_size = queueSize,
            .queue_notify_offset = queueNotifyOffset,
        };
    }

    /// True quando o valor `value` aparece no historico de escritas.
    fn wroteStatus(value: u8) bool {
        for (status_writes[0..status_write_count]) |entry| {
            if (entry == value) return true;
        }
        return false;
    }

    /// True quando alguma escrita tocou o bit de DRIVER_OK.
    fn wroteDriverOk() bool {
        for (status_writes[0..status_write_count]) |entry| {
            if (entry & status.driver_ok != 0) return true;
        }
        return false;
    }
};

/// Dispositivo falso sobre o estado que o teste ja configurou.
///
/// Nao zera o `Fake`: cada teste zera no inicio e configura o que precisa
/// antes de construir o dispositivo.
fn fakeDevice() Device {
    return .{ .registers = Fake.registers() };
}

test "virtio transport initialization stops at FEATURES_OK" {
    Fake.reset();
    // O que um virtio-blk moderno oferece: VERSION_1 na segunda palavra e
    // features de bloco na primeira.
    Fake.device_feature_low = 0x0000_0004;
    Fake.device_feature_high = 0x0000_0001;

    var device = fakeDevice();
    const outcome = device.initialize(features.version_1);
    try testing.expect(outcome.isInitialized());

    // O estado final e o que o dispositivo confirmou.
    try testing.expectEqual(@as(u8, 0x0B), device.status);
    try testing.expectEqual(status.Phase.features_ok, try device.phase());
    try testing.expect(device.isAwaitingQueues());
    try testing.expectEqual(features.version_1, device.accepted);
    try testing.expectEqual(@as(u64, 0x0000_0001_0000_0004), device.offered);
    try testing.expectEqual(@as(u16, 1), device.queues);

    // O driver publicou a feature negociada, e exatamente ela.
    try testing.expectEqual(@as(u32, 0), Fake.driver_feature_low);
    try testing.expectEqual(@as(u32, 1), Fake.driver_feature_high);

    // A sequencia de escritas: reset, ACKNOWLEDGE, DRIVER, FEATURES_OK.
    try testing.expectEqual(@as(usize, 4), Fake.status_write_count);
    try testing.expectEqual(@as(u8, 0), Fake.status_writes[0]);
    try testing.expectEqual(status.acknowledge, Fake.status_writes[1]);
    try testing.expectEqual(status.acknowledge | status.driver, Fake.status_writes[2]);
    try testing.expectEqual(
        status.acknowledge | status.driver | status.features_ok,
        Fake.status_writes[3],
    );

    // E a prova que importa: DRIVER_OK nunca foi escrito, sozinho ou junto.
    try testing.expect(!Fake.wroteDriverOk());
    try testing.expect(!Fake.wroteStatus(status.bitsOf(.driver_ok)));
}

test "virtio transport requires VERSION_1 and refuses to negotiate without it" {
    // Um dispositivo que nao oferece o bit 32 nao tem transporte moderno.
    Fake.reset();
    Fake.device_feature_low = 0x0000_0004;
    var device = fakeDevice();
    const failure = device.initialize(features.version_1).failed;
    try testing.expectEqual(Stage.read_features, failure.stage);
    try testing.expectEqual(@as(Error, error.Version1NotOffered), failure.reason);

    // O driver que nao aceita o bit 32 tambem nao negocia.
    Fake.reset();
    Fake.device_feature_high = 1;
    var second = fakeDevice();
    const refused = second.initialize(0).failed;
    try testing.expectEqual(@as(Error, error.Version1NotNegotiated), refused.reason);

    // Nenhum dos dois chegou a FEATURES_OK.
    try testing.expect(!Fake.wroteStatus(status.bitsOf(.features_ok)));
    try testing.expect(!Fake.wroteDriverOk());
}

test "virtio transport refuses features it does not implement" {
    // O dispositivo oferece INDIRECT_DESC, que o VorynOS ainda nao conduz.
    Fake.reset();
    Fake.device_feature_low = 0x1000_0000;
    Fake.device_feature_high = 0x0000_0001;

    var device = fakeDevice();
    const failure = device.initialize(features.version_1 | features.indirect_desc).failed;
    try testing.expectEqual(Stage.read_features, failure.stage);
    try testing.expectEqual(@as(Error, error.FeatureNotImplemented), failure.reason);
    try testing.expect(!Fake.wroteStatus(status.bitsOf(.features_ok)));
    try testing.expect(!Fake.wroteDriverOk());
}

test "virtio transport refuses a feature the device did not offer" {
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;

    var device = fakeDevice();
    const failure = device.initialize(features.version_1 | features.event_idx).failed;
    try testing.expectEqual(@as(Error, error.FeatureNotOffered), failure.reason);
    try testing.expectEqual(@as(u32, 0), Fake.driver_feature_low);
}

test "virtio transport reports a rejected FEATURES_OK" {
    // O dispositivo aceita a escrita mas nao mantem o bit: e a recusa que a
    // especificacao descreve para um conjunto de features invalido.
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;
    Fake.reject_features_ok = true;

    var device = fakeDevice();
    const failure = device.initialize(features.version_1).failed;
    try testing.expectEqual(Stage.features_ok, failure.stage);
    try testing.expectEqual(@as(Error, error.StatusNotConfirmed), failure.reason);
    try testing.expect(!device.isAwaitingQueues());
    try testing.expect(!Fake.wroteDriverOk());
}

test "virtio transport reports features the device did not keep" {
    // O dispositivo finge guardar driver_feature. Sem a leitura de volta, o
    // driver acreditaria ter negociado o que o dispositivo descartou.
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;
    Fake.ignore_driver_features = true;

    var device = fakeDevice();
    const failure = device.initialize(features.version_1).failed;
    try testing.expectEqual(Stage.write_features, failure.stage);
    try testing.expectEqual(@as(Error, error.FeatureWriteNotConfirmed), failure.reason);
    try testing.expect(!Fake.wroteStatus(status.bitsOf(.features_ok)));
}

test "virtio transport fails when the device does not reset" {
    Fake.reset();
    Fake.device_status = 0x0F;
    Fake.ignore_reset = true;

    var device = fakeDevice();
    const failure = device.initialize(features.version_1).failed;
    try testing.expectEqual(Stage.reset, failure.stage);
    try testing.expectEqual(@as(Error, error.DeviceDidNotReset), failure.reason);

    // O reset foi tentado antes de qualquer outra escrita.
    try testing.expectEqual(@as(usize, 1), Fake.status_write_count);
    try testing.expectEqual(@as(u8, 0), Fake.status_writes[0]);
}

test "virtio transport fails when the status lags behind the write" {
    // Um dispositivo que ignora a escrita de ACKNOWLEDGE nao pode ser
    // conduzido: sem confirmacao, o driver nao sabe em que estado esta.
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;

    var device = fakeDevice();
    device.registers.write_status = swallowAcknowledge;

    const failure = device.initialize(features.version_1).failed;
    try testing.expectEqual(Stage.acknowledge, failure.stage);
    try testing.expectEqual(@as(Error, error.StatusNotConfirmed), failure.reason);
    try testing.expectEqual(@as(u8, 0), device.status);
}

/// Escrita de status que descarta ACKNOWLEDGE, para o teste acima.
fn swallowAcknowledge(_: *anyopaque, value: u8) Error!void {
    if (value == status.acknowledge) return;
    Fake.device_status = value;
}

test "virtio transport keeps the device status as the source of truth" {
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;

    var device = fakeDevice();
    try testing.expect(device.initialize(features.version_1).isInitialized());

    // O dispositivo sinaliza que precisa de reset sem que o driver escreva
    // nada: a leitura passa a ser o unico estado valido.
    Fake.device_status = status.bitsOf(.driver_ok) | status.device_needs_reset;
    const observed = try device.readStatus();
    try testing.expectEqual(Fake.device_status, observed);
    try testing.expectEqual(status.Phase.device_needs_reset, try device.phase());
    try testing.expect(!device.isAwaitingQueues());
}

test "virtio transport refuses to clear a status bit" {
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;

    var device = fakeDevice();
    try testing.expect(device.initialize(features.version_1).isInitialized());

    // Voltar para ACKNOWLEDGE apagaria DRIVER e FEATURES_OK.
    const current = Fake.device_status;
    try testing.expectError(
        error.StatusBitCleared,
        device.setStatusSync(status.acknowledge, .acknowledge),
    );
    // Nada foi escrito: o historico nao cresceu.
    try testing.expectEqual(@as(usize, 4), Fake.status_write_count);
    try testing.expectEqual(current, Fake.device_status);
}

test "virtio transport inspects queues without programming them" {
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;
    Fake.num_queues = 2;
    Fake.queue_size = 128;
    Fake.queue_notify_off = 3;

    var device = fakeDevice();
    try testing.expect(device.initialize(features.version_1).isInitialized());

    try testing.expectEqual(@as(u16, 2), device.queues);
    try testing.expectEqual(@as(u16, 128), try device.queueMaxSize(0));
    try testing.expectEqual(@as(u16, 3), try device.queueNotifyOffset(1));

    // Um indice fora da faixa informada pelo dispositivo e recusado antes de
    // chegar ao registrador.
    try testing.expectError(error.InvalidQueue, device.queueMaxSize(2));
    try testing.expectError(error.InvalidQueue, device.queueNotifyOffset(2));
}

test "virtio transport surfaces a register failure with its stage" {
    Fake.reset();
    Fake.device_feature_high = 0x0000_0001;

    var device = fakeDevice();
    device.registers.read_device_feature = failRead;

    const failure = device.initialize(features.version_1).failed;
    try testing.expectEqual(Stage.read_features, failure.stage);
    try testing.expectEqual(@as(Error, error.RegisterAccess), failure.reason);

    // O dispositivo ficou em ACKNOWLEDGE|DRIVER, e nao em FEATURES_OK.
    try testing.expectEqual(status.acknowledge | status.driver, Fake.device_status);
    try testing.expect(!Fake.wroteStatus(status.bitsOf(.features_ok)));
}

fn failRead(_: *anyopaque, _: u1) Error!u32 {
    return error.RegisterAccess;
}

test "virtio transport outcome names the stage it failed at" {
    Fake.reset();
    var device = fakeDevice();
    const outcome = device.initialize(features.version_1);
    try testing.expect(!outcome.isInitialized());

    switch (outcome) {
        .initialized => return error.TestUnexpectedResult,
        .failed => |failure| {
            try testing.expectEqual(Stage.read_features, failure.stage);
            try testing.expectEqualStrings("read_features", failure.stage.label());
        },
    }
}
