//************************************************************************//
//  containment.zig                                                       //
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

//! Contencao de falhas PCI/DMA de um dispositivo que o driver ja entregou a
//! memoria da fila.
//!
//! A pergunta que este modulo responde nao e "como recuperar": e "o que fica
//! registrado, e o que pode ser devolvido ao alocador, depois de uma falha que
//! o driver nao consegue mais explicar".
//!
//! Tres fatos governam o desenho:
//!
//!   * **revogar o *bus master* nao e quiescencia.** O bit `Command[2]` do PCI
//!     autoriza a funcao a iniciar transacoes de barramento. Desliga-lo impede
//!     transacoes *novas*; nao existe operacao PCI/PCIe que confirme que as
//!     transacoes ja despachadas chegaram ao destino. Por isso a revogacao
//!     nunca libera memoria neste modulo;
//!   * **reset confirmado tambem nao e prova portavel de quiescencia.** A
//!     leitura de volta zerada do `device_status` do VirtIO diz que o
//!     dispositivo aceitou o reset; ela nao diz, sozinha, que escritas DMA ja
//!     emitidas terminaram em todo hardware. O modulo trata o reset confirmado
//!     como a condicao *disponivel* para devolver memoria, e nao como uma
//!     garantia universal — o que ele permite e o que o driver ja fazia, com a
//!     condicao agora nomeada em um unico lugar;
//!   * **a contencao e do dispositivo, e nao do pedido.** O driver de bloco ja
//!     envenena a propria instancia quando um pedido falha. Este modulo guarda
//!     o estado do dispositivo: se ele ainda pode emitir DMA, se a revogacao
//!     foi confirmada, se um reset foi tentado e qual foi o motivo.
//!
//! O modulo nao importa `pci.zig` nem toca em registradores. O alvo da
//! revogacao chega como um ponteiro de funcao com contexto, do mesmo modo que
//! `mmio.Mapper` recebe o mapeador: quem conhece o barramento e o chamador.
//! Isso mantem a VVDI compilavel e testavel sozinha, como manda o ADR-0021.

const std = @import("std");

/// Motivo pelo qual o dispositivo entrou em contencao.
///
/// E um conjunto fechado de condicoes que o driver distingue: ele serve ao
/// diagnostico e ao registro em serie, nao a uma politica automatica — nao
/// existe recuperacao neste incremento.
pub const Reason = enum {
    /// A espera limitada pela conclusao de um pedido terminou.
    timeout,
    /// O dispositivo devolveu uma conclusao que nao descreve o pedido.
    invalid_completion,
    /// O pedido foi publicado, mas o registrador de notificacao recusou.
    notify_failure,
    /// A fila nao pode ser programada ou habilitada.
    queue_failure,
    /// `DRIVER_OK` nao foi confirmado ou a ativacao falhou.
    activation_failure,
    /// O dispositivo nao confirmou o reset.
    reset_unconfirmed,
    /// Depois de `DRIVER_OK`, a configuracao do driver de bloco falhou.
    configuration_failure,

    /// Rotulo estavel para o registro em serie e para os testes.
    pub fn label(self: Reason) []const u8 {
        return switch (self) {
            .timeout => "timeout",
            .invalid_completion => "invalid-completion",
            .notify_failure => "notify-failure",
            .queue_failure => "queue-failure",
            .activation_failure => "activation-failure",
            .reset_unconfirmed => "reset-unconfirmed",
            .configuration_failure => "configuration-failure",
        };
    }
};

/// Resultado da tentativa de revogar o *bus master*.
pub const Revocation = enum {
    /// Nenhum alvo foi registrado: o driver nao tem como revogar.
    unavailable,
    /// A leitura de volta confirmou o bit desligado.
    revoked,
    /// A leitura de volta divergiu, ou a funcao nao respondeu.
    failed,

    pub fn label(self: Revocation) []const u8 {
        return switch (self) {
            .unavailable => "unavailable",
            .revoked => "revoked",
            .failed => "failed",
        };
    }
};

/// Alvo da revogacao, fornecido pelo chamador.
///
/// `ctx` e o estado que a funcao precisa para achar o dispositivo. Ele precisa
/// sobreviver a este objeto — na orquestracao de boot e um valor estatico —
/// porque a contencao pode ser consultada depois de a funcao que a criou
/// retornar.
pub const BusMaster = struct {
    ctx: *anyopaque,
    /// True somente quando a leitura de volta do registrador confirmou a
    /// revogacao. "Escrevi" nao e resposta suficiente para este contrato.
    revoke: *const fn (ctx: *anyopaque) bool,
};

/// Estado do dispositivo perante o driver.
pub const State = enum {
    /// Nenhuma memoria foi entregue ao dispositivo: nao ha o que conter.
    disarmed,
    /// A fila foi entregue e nenhuma falha foi detectada.
    armed,
    /// Falha detectada; o *bus master* foi revogado com confirmacao.
    contained,
    /// Falha detectada; a revogacao nao foi confirmada.
    contained_unrevoked,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .disarmed => "disarmed",
            .armed => "armed",
            .contained => "contained",
            .contained_unrevoked => "contained-unrevoked",
        };
    }
};

/// Fatos que o chamador precisa comprovar antes de abrir um novo ciclo de vida.
///
/// A contencao nao alcanca o alocador de DMA, o transporte nem o registro de
/// dispositivos. Por isso ela nao tenta descobrir sozinha se o ciclo anterior
/// terminou: recebe os tres fatos ja apurados por quem tem acesso a eles, e
/// **recusa** reiniciar quando algum deles nao pode ser comprovado.
pub const RestartFacts = struct {
    /// O transporte afirma que a fila deixou de pertencer ao dispositivo
    /// (`QueueMemory.canReturnToAllocator`).
    queue_returned: bool,
    /// Nao existe mais alocacao nem mapeamento de DMA desta instancia.
    memory_released: bool,
    /// Nenhum driver ativo conserva ponteiro para esta instancia.
    driver_detached: bool,
};

/// Motivo pelo qual um novo ciclo de vida foi recusado.
///
/// Recusar preserva o estado anterior: a instancia continua como estava, e a
/// contencao continua valendo. Nenhuma das recusas e silenciosa.
pub const RestartError = error{
    /// A fila ainda pertence ao dispositivo.
    QueueStillOwnedByDevice,
    /// Ainda existe memoria de DMA que depende desta contencao.
    MemoryStillDependent,
    /// Um driver ativo ainda aponta para esta instancia.
    DriverStillAttached,
    /// O ciclo anterior foi entregue e nenhum reset o fechou.
    ResetNotConfirmed,
    /// O dispositivo esta contido. Sem recuperacao online, ele nao reinicia.
    DeviceQuarantined,
};

/// Estado de contencao de um dispositivo.
///
/// Todas as operacoes sao idempotentes e nenhuma delas espera: a estrutura e
/// consultada em caminhos de erro, e um caminho de erro nao pode bloquear o
/// kernel. Nao ha relogio, nao ha laco e nao ha alocacao.
pub const Containment = struct {
    bus_master: ?BusMaster = null,
    state: State = .disarmed,
    reason: ?Reason = null,
    /// Resultado da unica tentativa de revogacao feita nesta instancia.
    revocation: ?Revocation = null,
    /// Um reset foi pedido ao dispositivo.
    reset_attempted: bool = false,
    /// O reset foi confirmado pela leitura de volta.
    reset_confirmed: bool = false,
    /// Quantas vezes `contain` foi chamada. Util para provar idempotencia.
    contain_calls: u32 = 0,

    /// Registra que a memoria da fila sera entregue ao dispositivo.
    ///
    /// Chamada exatamente onde a posse e transferida (`QueueMemory.handOver`).
    /// Depois dela, `permitsMemoryRelease` passa a exigir um reset confirmado.
    /// Repetir a chamada nao muda nada e nao apaga uma contencao anterior.
    pub fn arm(self: *Containment, bus_master: ?BusMaster) void {
        if (self.state != .disarmed) {
            // Ja armado ou ja contido: o alvo mais antigo continua valendo.
            // Trocar o alvo agora apontaria a contencao para outro dispositivo.
            return;
        }
        self.bus_master = bus_master;
        self.state = .armed;
    }

    /// Fecha o ciclo de vida anterior e prepara a instancia para outro.
    ///
    /// Antes de apagar qualquer coisa, comprova as tres condicoes externas e o
    /// estado interno. Se qualquer uma falhar, o estado e **preservado** e a
    /// recusa e devolvida: uma contencao nao pode ser apagada por engano, e um
    /// dispositivo que ainda pode acessar memoria nao pode ser esquecido.
    ///
    /// O que a funcao garante quando aceita: a instancia volta a `.disarmed`,
    /// sem alvo, sem motivo, sem resultado de revogacao e com
    /// `reset_confirmed` falso. Isto e o que impede o defeito F-1 — o estado de
    /// uma rodada nao sobrevive para autorizar liberacao nem para responder
    /// por uma revogacao na rodada seguinte.
    ///
    /// A reinicializacao **nao** rearma: o alvo da rodada nova e registrado
    /// por `arm`, no ponto em que a memoria e entregue. Entre a aceitacao e o
    /// `arm` a instancia esta `.disarmed`, e `permitsMemoryRelease` devolve
    /// verdadeiro, que e a resposta correta para uma rodada que ainda nao
    /// entregou nada.
    pub fn beginNewLifecycle(self: *Containment, facts: RestartFacts) RestartError!void {
        if (!facts.queue_returned) return error.QueueStillOwnedByDevice;
        if (!facts.memory_released) return error.MemoryStillDependent;
        if (!facts.driver_detached) return error.DriverStillAttached;

        if (self.state != .disarmed) {
            // Ordem deliberada: um dispositivo contido e o caso mais grave e
            // nao pode ser reiniciado nem com reset confirmado, porque nao
            // existe recuperacao online. Depois dele, o ciclo entregue exige
            // que o reset tenha sido confirmado.
            if (self.isQuarantined()) return error.DeviceQuarantined;
            if (!self.reset_confirmed) return error.ResetNotConfirmed;
        }

        self.* = .{};
    }

    /// Contem o dispositivo e devolve o resultado da revogacao.
    ///
    /// A revogacao acontece no maximo uma vez por instancia. Uma segunda
    /// chamada nao tenta de novo — nao ha espera nem repeticao neste modulo —
    /// e devolve o mesmo resultado da primeira, com o motivo original
    /// preservado. Uma falha de revogacao nao e mascarada: o estado fica
    /// `contained_unrevoked` e o chamador consegue distinguir os dois casos.
    pub fn contain(self: *Containment, why: Reason) Revocation {
        self.contain_calls +|= 1;

        if (self.revocation) |previous| {
            // Idempotente: nao reescreve o motivo nem tenta revogar de novo.
            return previous;
        }

        self.reason = why;
        const target = self.bus_master orelse {
            self.revocation = .unavailable;
            self.state = .contained_unrevoked;
            return .unavailable;
        };

        const confirmed = target.revoke(target.ctx);
        const outcome: Revocation = if (confirmed) .revoked else .failed;
        self.revocation = outcome;
        self.state = if (confirmed) .contained else .contained_unrevoked;
        return outcome;
    }

    /// Registra o resultado de uma tentativa de reset.
    ///
    /// Um reset confirmado nunca e esquecido; um reset que falhou nao apaga a
    /// confirmacao de um anterior. Um reset confirmado tambem nao rearma o
    /// dispositivo: recuperacao nao faz parte deste incremento, e voltar a
    /// `armed` faria um pedido novo alcancar uma fila que ninguem reconstruiu.
    pub fn noteReset(self: *Containment, confirmed: bool) void {
        self.reset_attempted = true;
        if (confirmed) self.reset_confirmed = true;
    }

    /// True quando a memoria entregue ao dispositivo pode voltar ao alocador.
    ///
    /// A regra e uma so, e vale para todas as saidas de erro: **so um reset
    /// confirmado devolve a memoria**. A revogacao do *bus master* nao entra
    /// nesta conta, porque ela impede transacoes novas e nao prova o destino
    /// das antigas.
    pub fn permitsMemoryRelease(self: *const Containment) bool {
        return switch (self.state) {
            // Nada foi entregue: a memoria continua sendo do driver.
            .disarmed => true,
            // Entregue, sem reset confirmado.
            .armed, .contained, .contained_unrevoked => self.reset_confirmed,
        };
    }

    /// True quando o dispositivo esta contido: nenhuma operacao nova e aceita.
    pub fn isQuarantined(self: *const Containment) bool {
        return self.state == .contained or self.state == .contained_unrevoked;
    }

    /// True quando a revogacao foi confirmada pela leitura de volta.
    pub fn revocationConfirmed(self: *const Containment) bool {
        return self.revocation == .revoked;
    }

    /// Descricao de uma linha para o registro em serie, sem alocacao.
    pub fn describe(self: *const Containment, buffer: []u8) []const u8 {
        const reason = if (self.reason) |value| value.label() else "none";
        const revocation = if (self.revocation) |value| value.label() else "none";
        return std.fmt.bufPrint(
            buffer,
            "state={s} reason={s} bus_master={s} reset_attempted={d} reset_confirmed={d}",
            .{
                self.state.label(),
                reason,
                revocation,
                @intFromBool(self.reset_attempted),
                @intFromBool(self.reset_confirmed),
            },
        ) catch buffer[0..0];
    }
};

// ----------------------------------------------------------------------
// Testes.
//
// O alvo de revogacao e um contador em memoria: nenhum teste abre portas de
// I/O, e todos descrevem uma falha que o driver precisa distinguir.
// ----------------------------------------------------------------------

const testing = std.testing;

/// Alvo de revogacao que responde o que o teste mandar.
const FakeBusMaster = struct {
    confirm: bool = true,
    attempts: u32 = 0,

    fn revoke(ctx: *anyopaque) bool {
        const self: *FakeBusMaster = @ptrCast(@alignCast(ctx));
        self.attempts += 1;
        return self.confirm;
    }

    fn handle(self: *FakeBusMaster) BusMaster {
        return .{ .ctx = @ptrCast(self), .revoke = revoke };
    }
};

test "a disarmed containment lets the driver keep its own memory" {
    const containment: Containment = .{};
    try testing.expectEqual(State.disarmed, containment.state);
    try testing.expect(containment.permitsMemoryRelease());
    try testing.expect(!containment.isQuarantined());
    try testing.expect(containment.reason == null);
}

test "arming requires a confirmed reset before the memory can return" {
    var target: FakeBusMaster = .{};
    var containment: Containment = .{};
    containment.arm(target.handle());

    try testing.expectEqual(State.armed, containment.state);
    // A fila ja foi entregue: sem reset confirmado, nada volta ao alocador.
    try testing.expect(!containment.permitsMemoryRelease());
    try testing.expect(!containment.isQuarantined());

    containment.noteReset(false);
    try testing.expect(containment.reset_attempted);
    try testing.expect(!containment.reset_confirmed);
    try testing.expect(!containment.permitsMemoryRelease());

    containment.noteReset(true);
    try testing.expect(containment.reset_confirmed);
    try testing.expect(containment.permitsMemoryRelease());
}

test "arming twice keeps the first bus master target" {
    var first: FakeBusMaster = .{ .confirm = true };
    var second: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};
    containment.arm(first.handle());
    containment.arm(second.handle());

    const outcome = containment.contain(.timeout);
    try testing.expectEqual(Revocation.revoked, outcome);
    try testing.expectEqual(@as(u32, 1), first.attempts);
    // O segundo alvo nunca foi usado: a contencao continua apontando para o
    // dispositivo que recebeu a fila.
    try testing.expectEqual(@as(u32, 0), second.attempts);
}

test "a confirmed revocation contains the device but never releases memory" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};
    containment.arm(target.handle());

    const outcome = containment.contain(.timeout);
    try testing.expectEqual(Revocation.revoked, outcome);
    try testing.expectEqual(State.contained, containment.state);
    try testing.expect(containment.isQuarantined());
    try testing.expect(containment.revocationConfirmed());
    try testing.expectEqual(Reason.timeout, containment.reason.?);

    // O ponto central: revogar bus master nao e quiescencia. A memoria
    // continua retida mesmo com a revogacao confirmada.
    try testing.expect(!containment.permitsMemoryRelease());

    // So o reset confirmado a devolve.
    containment.noteReset(true);
    try testing.expect(containment.permitsMemoryRelease());
}

test "a failed revocation is recorded distinctly and still holds the memory" {
    var target: FakeBusMaster = .{ .confirm = false };
    var containment: Containment = .{};
    containment.arm(target.handle());

    const outcome = containment.contain(.invalid_completion);
    try testing.expectEqual(Revocation.failed, outcome);
    try testing.expectEqual(State.contained_unrevoked, containment.state);
    try testing.expect(containment.isQuarantined());
    try testing.expect(!containment.revocationConfirmed());
    try testing.expect(!containment.permitsMemoryRelease());
}

test "containment without a bus master target is reported as unavailable" {
    var containment: Containment = .{};
    containment.arm(null);

    const outcome = containment.contain(.queue_failure);
    try testing.expectEqual(Revocation.unavailable, outcome);
    // Sem caminho de revogacao o estado nao pode ser apresentado como contido
    // com sucesso.
    try testing.expectEqual(State.contained_unrevoked, containment.state);
    try testing.expect(!containment.revocationConfirmed());
    try testing.expect(!containment.permitsMemoryRelease());
}

test "containment is idempotent and keeps the first reason" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};
    containment.arm(target.handle());

    _ = containment.contain(.timeout);
    const second = containment.contain(.reset_unconfirmed);
    const third = containment.contain(.configuration_failure);

    try testing.expectEqual(Revocation.revoked, second);
    try testing.expectEqual(Revocation.revoked, third);
    // Uma unica tentativa de revogacao, e o motivo original preservado: o
    // segundo evento e consequencia do primeiro, nao uma causa nova.
    try testing.expectEqual(@as(u32, 1), target.attempts);
    try testing.expectEqual(Reason.timeout, containment.reason.?);
    try testing.expectEqual(@as(u32, 3), containment.contain_calls);
}

test "a failed revocation is not retried by a later containment call" {
    var target: FakeBusMaster = .{ .confirm = false };
    var containment: Containment = .{};
    containment.arm(target.handle());

    _ = containment.contain(.notify_failure);
    const second = containment.contain(.timeout);
    try testing.expectEqual(Revocation.failed, second);
    // Sem laco e sem repeticao: o driver nao insiste em um dispositivo que
    // nao respondeu.
    try testing.expectEqual(@as(u32, 1), target.attempts);
    try testing.expectEqual(Reason.notify_failure, containment.reason.?);
}

test "a later successful revocation cannot upgrade an earlier failure" {
    var target: FakeBusMaster = .{ .confirm = false };
    var containment: Containment = .{};
    containment.arm(target.handle());
    _ = containment.contain(.timeout);

    // Mesmo que o dispositivo passe a responder, a instancia nao reescreve o
    // resultado: uma contencao nao confirmada permanece nao confirmada.
    target.confirm = true;
    const again = containment.contain(.timeout);
    try testing.expectEqual(Revocation.failed, again);
    try testing.expectEqual(State.contained_unrevoked, containment.state);
}

test "a confirmed reset does not rearm a contained device" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};
    containment.arm(target.handle());
    _ = containment.contain(.timeout);
    containment.noteReset(true);

    // Recuperacao nao faz parte deste incremento: armar de novo nao pode
    // devolver o dispositivo ao estado operacional.
    containment.arm(target.handle());
    try testing.expectEqual(State.contained, containment.state);
    try testing.expect(containment.isQuarantined());
}

test "a failed reset after containment keeps the memory retained" {
    // O cenario da divida A-3, na ordem em que acontece no boot: a fila ja foi
    // entregue, a configuracao falha, o driver tenta resetar, o dispositivo
    // nao confirma, e entao o *bus master* e revogado.
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};
    containment.arm(target.handle());

    containment.noteReset(false); // reset nao confirmado
    const outcome = containment.contain(.reset_unconfirmed);

    try testing.expectEqual(Revocation.revoked, outcome);
    try testing.expectEqual(State.contained, containment.state);
    try testing.expect(containment.isQuarantined());
    // As duas coisas ao mesmo tempo: a revogacao funcionou e a memoria
    // continua retida, porque revogar nao e quiescencia e o reset falhou.
    try testing.expect(containment.revocationConfirmed());
    try testing.expect(!containment.permitsMemoryRelease());
}

test "container reports a reset that failed and was never retried as such" {
    var containment: Containment = .{};
    containment.arm(null);
    containment.noteReset(false);
    try testing.expect(containment.reset_attempted);
    try testing.expect(!containment.reset_confirmed);
    try testing.expect(!containment.permitsMemoryRelease());
}

test "reset confirmation is never downgraded by a later failed attempt" {
    var containment: Containment = .{};
    containment.arm(null);
    containment.noteReset(true);
    containment.noteReset(false);
    try testing.expect(containment.reset_confirmed);
    try testing.expect(containment.permitsMemoryRelease());
}

test "the diagnostic line names state, reason and revocation" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};
    containment.arm(target.handle());
    _ = containment.contain(.activation_failure);
    containment.noteReset(false);

    var buffer: [128]u8 = undefined;
    const text = containment.describe(&buffer);
    try testing.expectEqualStrings(
        "state=contained reason=activation-failure bus_master=revoked reset_attempted=1 reset_confirmed=0",
        text,
    );

    // O buffer pequeno nao produz texto truncado apresentado como completo.
    var small: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), containment.describe(&small).len);
}

test "every reason has a distinct stable label" {
    const reasons = [_]Reason{
        .timeout,
        .invalid_completion,
        .notify_failure,
        .queue_failure,
        .activation_failure,
        .reset_unconfirmed,
        .configuration_failure,
    };
    for (reasons, 0..) |reason, index| {
        try testing.expect(reason.label().len > 0);
        for (reasons[index + 1 ..]) |other| {
            try testing.expect(!std.mem.eql(u8, reason.label(), other.label()));
        }
    }
}

// ----------------------------------------------------------------------
// F-1: isolamento entre ciclos de vida.
//
// O defeito demonstrado: `arm` era no-op sobre uma instancia ja usada e
// `reset_confirmed` era pegajoso. Numa segunda rodada, `permitsMemoryRelease`
// autorizava liberar memoria sem nenhum reset daquela rodada, e `contain`
// devolvia o resultado da revogacao anterior sem revogar de novo. Os testes
// abaixo reproduzem o defeito no estado antigo e fixam o comportamento novo.
// ----------------------------------------------------------------------

/// Todos os fatos favoraveis: ciclo anterior fechado.
const closed_cycle: RestartFacts = .{
    .queue_returned = true,
    .memory_released = true,
    .driver_detached = true,
};

test "F-1: a second round does not inherit the reset confirmation" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};

    // RODADA 1: arma, entrega, reset confirmado, memoria liberada.
    containment.arm(target.handle());
    containment.noteReset(true);
    try testing.expect(containment.permitsMemoryRelease());

    // Fim da rodada 1: o chamador comprova as tres condicoes e abre a rodada 2.
    try containment.beginNewLifecycle(closed_cycle);

    // O estado da rodada 1 nao sobrevive. Este e o defeito F-1: antes da
    // correcao, `reset_confirmed` continuava verdadeiro aqui.
    try testing.expectEqual(State.disarmed, containment.state);
    try testing.expect(!containment.reset_confirmed);
    try testing.expect(!containment.reset_attempted);
    try testing.expect(containment.reason == null);
    try testing.expect(containment.revocation == null);
    try testing.expect(containment.bus_master == null);

    // RODADA 2: arma de novo, e agora a liberacao exige o reset DESTA rodada.
    containment.arm(target.handle());
    try testing.expectEqual(State.armed, containment.state);
    try testing.expect(!containment.permitsMemoryRelease());
}

test "F-1: a second round performs its own revocation" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};

    // RODADA 1 sem falha: arma, entrega, e o reset fecha o ciclo. Uma rodada
    // que contivesse o dispositivo nao chegaria aqui — `DeviceQuarantined`
    // recusa a reinicializacao, e e isso que impede o resultado de uma
    // revogacao de atravessar para a rodada seguinte.
    containment.arm(target.handle());
    containment.noteReset(true);
    try testing.expect(containment.revocation == null);
    try testing.expectEqual(@as(u32, 0), target.attempts);

    try containment.beginNewLifecycle(closed_cycle);

    // RODADA 2: a primeira falha desta rodada revoga de verdade.
    containment.arm(target.handle());
    const outcome = containment.contain(.configuration_failure);
    try testing.expectEqual(Revocation.revoked, outcome);
    try testing.expectEqual(@as(u32, 1), target.attempts);
    try testing.expectEqual(Reason.configuration_failure, containment.reason.?);

    // E uma segunda chamada continua idempotente dentro da rodada 2.
    const again = containment.contain(.timeout);
    try testing.expectEqual(Revocation.revoked, again);
    try testing.expectEqual(@as(u32, 1), target.attempts);
    try testing.expectEqual(Reason.configuration_failure, containment.reason.?);
}

test "F-1: a failed reset blocks reuse instead of being forgotten" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};

    containment.arm(target.handle());
    containment.noteReset(false);

    try testing.expectError(error.ResetNotConfirmed, containment.beginNewLifecycle(closed_cycle));
    // O estado anterior e preservado: nada foi apagado.
    try testing.expectEqual(State.armed, containment.state);
    try testing.expect(containment.reset_attempted);
    try testing.expect(!containment.reset_confirmed);
    try testing.expect(!containment.permitsMemoryRelease());
}

test "F-1: a contained device is never restarted by a new lifecycle" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};
    containment.arm(target.handle());
    _ = containment.contain(.timeout);

    // Mesmo com reset confirmado, um dispositivo contido nao reinicia:
    // recuperacao online esta fora de escopo.
    containment.noteReset(true);
    try testing.expectError(error.DeviceQuarantined, containment.beginNewLifecycle(closed_cycle));
    try testing.expectEqual(State.contained, containment.state);
    try testing.expect(containment.isQuarantined());
}

test "F-1: restart is refused while the device still owns the queue" {
    var containment: Containment = .{};
    containment.arm(null);
    containment.noteReset(false);

    var facts = closed_cycle;
    facts.queue_returned = false;
    try testing.expectError(error.QueueStillOwnedByDevice, containment.beginNewLifecycle(facts));
    try testing.expectEqual(State.armed, containment.state);
}

test "F-1: restart is refused while DMA memory is still dependent" {
    var containment: Containment = .{};
    containment.arm(null);
    containment.noteReset(false);

    var facts = closed_cycle;
    facts.memory_released = false;
    try testing.expectError(error.MemoryStillDependent, containment.beginNewLifecycle(facts));
    try testing.expectEqual(State.armed, containment.state);
}

test "F-1: restart is refused while a driver still points at the instance" {
    var containment: Containment = .{};
    containment.arm(null);
    containment.noteReset(false);

    var facts = closed_cycle;
    facts.driver_detached = false;
    try testing.expectError(error.DriverStillAttached, containment.beginNewLifecycle(facts));
    try testing.expectEqual(State.armed, containment.state);
}

test "F-1: the single initial lifecycle is unchanged" {
    var target: FakeBusMaster = .{ .confirm = true };
    var containment: Containment = .{};

    // Primeira rodada de um boot normal: a instancia esta limpa, e o gate a
    // aceita sem exigir reset (nada foi entregue ainda).
    try testing.expectEqual(State.disarmed, containment.state);
    try containment.beginNewLifecycle(closed_cycle);
    try testing.expectEqual(State.disarmed, containment.state);

    containment.arm(target.handle());
    try testing.expectEqual(State.armed, containment.state);
    try testing.expect(!containment.permitsMemoryRelease());
    containment.noteReset(true);
    try testing.expect(containment.permitsMemoryRelease());
}

test "F-1: a refused restart never releases memory" {
    // Ausencia de liberacao prematura: em todas as recusas, a memoria
    // continua retida, porque o estado nao foi apagado.
    const refusals = [_]struct { facts: RestartFacts, expected: RestartError }{
        .{ .facts = .{ .queue_returned = false, .memory_released = true, .driver_detached = true }, .expected = error.QueueStillOwnedByDevice },
        .{ .facts = .{ .queue_returned = true, .memory_released = false, .driver_detached = true }, .expected = error.MemoryStillDependent },
        .{ .facts = .{ .queue_returned = true, .memory_released = true, .driver_detached = false }, .expected = error.DriverStillAttached },
        .{ .facts = .{ .queue_returned = false, .memory_released = false, .driver_detached = false }, .expected = error.QueueStillOwnedByDevice },
    };

    for (refusals) |case| {
        var containment: Containment = .{};
        containment.arm(null);
        // Sem reset confirmado, a recusa e inevitavel em qualquer combinacao.
        try testing.expectError(case.expected, containment.beginNewLifecycle(case.facts));
        try testing.expect(!containment.permitsMemoryRelease());
        try testing.expectEqual(State.armed, containment.state);
    }
}
