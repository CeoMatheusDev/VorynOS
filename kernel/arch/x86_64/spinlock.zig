//************************************************************************//
//  spinlock.zig                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Spinlocks para protecao de estruturas compartilhadas em SMP.
//!
//! O spinlock usa test-and-set com pause no laco de espera. A variante
//! irq-safe desabilita interrupcoes locais na aquisicao e as restaura na
//! liberacao, evitando deadlock quando o holder e preemptado por uma
//! interrupcao que tenta adquirir o mesmo lock.
//!
//! Toda operacao usa barriers de memoria para que writes feitos antes da
//! liberacao sejam visiveis ao proximo holder.

const std = @import("std");
const cpu = @import("cpu.zig");

/// Spinlock simples: compare-and-swap com espera ativa.
///
/// `tryLock` publica a aquisicao com `@cmpxchgStrong`: a troca de 0 por 1
/// so acontece se o valor ainda for 0, e duas CPUs nao podem vencer a mesma
/// disputa. O caminho de espera usa `@atomicLoad` para reduzir o trafego de
/// cache, e `unlock` publica a liberacao com release.
///
/// O lock nao e reentrante: o holder que tentar adquiri-lo novamente
/// travará para sempre. O lock nao tem prioridade nem justica: qualquer
/// CPU na fila de espera pode ganhar na próxima iteracao.
pub const Spinlock = struct {
    /// 0 = livre, 1 = trancado.
    locked: u8 = 0,

    pub fn lock(self: *Spinlock) void {
        // Testa primeiro para reduzir trafego no barramento de cache.
        while (true) {
            if (self.tryLock()) return;
            // Espera enquanto o lock estiver trancado.
            while (@atomicLoad(u8, &self.locked, .acquire) != 0) {
                cpu.pause();
            }
        }
    }

    /// Tenta adquirir o lock sem bloquear. Retorna true se obteve o lock.
    ///
    /// A operacao e um compare-and-swap: o valor esperado e 0, o novo valor
    /// e 1. Se outra CPU tiver adquirido o lock entre a leitura e a troca,
    /// a troca falha e esta CPU nao entra na regiao critica. Um load
    /// seguido de store nao oferece essa garantia.
    pub fn tryLock(self: *Spinlock) bool {
        return @cmpxchgStrong(u8, &self.locked, 0, 1, .acquire, .monotonic) == null;
    }

    /// Libera o lock. O caller deve ser o holder atual.
    pub fn unlock(self: *Spinlock) void {
        // Barreira de escrita antes de liberar: writes feitos antes desta
        // chamada sao visiveis ao proximo holder.
        @atomicStore(u8, &self.locked, 0, .release);
    }

    /// Retorna true se o lock esta atualmente trancado.
    pub fn isLocked(self: *const Spinlock) bool {
        return @atomicLoad(u8, &self.locked, .acquire) != 0;
    }
};

/// Spinlock irq-safe: desabilita interrupcoes locais na aquisicao e
/// restaura o estado anterior na liberacao.
///
/// Usado para proteger estruturas que podem ser acessadas tanto em
/// contexto de interrupcao quanto em contexto de thread. Evita deadlock
/// quando o holder e preemptado por uma interrupcao que tenta adquirir
/// o mesmo lock.
///
/// `lockIrqSave` devolve o RFLAGS anterior. `unlockIrqRestore` recebe esse
/// valor e restaura o estado exato: se as interrupcoes ja estavam
/// desabilitadas antes da aquisicao, continuam desabilitadas depois. Um
/// `sti` incondicional na liberacao quebraria esse contrato e poderia
/// habilitar interrupcoes no meio de outra regiao critica.
pub const IrqSpinlock = struct {
    lock: Spinlock = .{},

    /// Adquire o lock, salva o RFLAGS e desabilita interrupcoes locais.
    pub fn lockIrqSave(self: *IrqSpinlock) u64 {
        const flags = cpu.saveAndDisableInterrupts();
        self.lock.lock();
        return flags;
    }

    /// Libera o lock e restaura o RFLAGS salvo por `lockIrqSave`.
    pub fn unlockIrqRestore(self: *IrqSpinlock, flags: u64) void {
        self.lock.unlock();
        cpu.restoreInterrupts(flags);
    }

    /// Adquire o lock assumindo que interrupcoes ja estao desabilitadas.
    pub fn lockIrqsDisabled(self: *IrqSpinlock) void {
        self.lock.lock();
    }

    /// Libera o lock assumindo que interrupcoes permanecem desabilitadas.
    pub fn unlockIrqsDisabled(self: *IrqSpinlock) void {
        self.lock.unlock();
    }

    pub fn isLocked(self: *const IrqSpinlock) bool {
        return self.lock.isLocked();
    }
};

test "spinlock try lock and unlock" {
    var lock: Spinlock = .{};
    try std.testing.expect(!lock.isLocked());
    try std.testing.expect(lock.tryLock());
    try std.testing.expect(lock.isLocked());
    lock.unlock();
    try std.testing.expect(!lock.isLocked());
}

test "spinlock lock and unlock serializes access" {
    var lock: Spinlock = .{};
    var counter: u32 = 0;
    const iterations = 1000;

    // Testa no contexto single-thread: o lock protege o contador.
    lock.lock();
    counter += iterations;
    lock.unlock();
    try std.testing.expectEqual(counter, iterations);
}

test "spinlock excludes concurrent holders" {
    var lock: Spinlock = .{};
    var holders = std.atomic.Value(u32).init(0);
    var violations = std.atomic.Value(u32).init(0);

    const Worker = struct {
        fn run(
            lock_ptr: *Spinlock,
            holders_ptr: *std.atomic.Value(u32),
            violations_ptr: *std.atomic.Value(u32),
        ) void {
            var iteration: u32 = 0;
            while (iteration < 200_000) : (iteration += 1) {
                if (!lock_ptr.tryLock()) continue;

                const previous = holders_ptr.fetchAdd(1, .monotonic);
                if (previous != 0) {
                    _ = violations_ptr.fetchAdd(1, .monotonic);
                }
                _ = holders_ptr.fetchSub(1, .monotonic);
                lock_ptr.unlock();
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{ &lock, &holders, &violations });
    }
    for (threads) |thread| thread.join();

    // A ausencia de violacoes e o criterio: o teste nao prova justica nem
    // progresso, apenas que duas CPUs nunca entram juntas na regiao critica.
    try std.testing.expectEqual(@as(u32, 0), violations.load(.monotonic));
}
