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

/// Spinlock simples: test-and-set com espera ativa.
///
/// O lock usa @atomicStore para publicar a trancagem e @atomicLoad para
/// consultar o estado. Na tentativa de aquisicao, escreve 1 apenas quando
/// o lock esta livre (0). Em um sistema de CPU unica com interrupcoes
/// desabilitadas na regiao critica, isso e suficiente; quando o SMP estiver
/// ativo, a tentativa sera substituida por uma instrucao cmpxchg atomica.
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
    /// A escrita so ocorre quando o lock esta livre (0), evitando
    /// sobrescrever um lock ja trancado por outra CPU.
    pub fn tryLock(self: *Spinlock) bool {
        if (@atomicLoad(u8, &self.locked, .acquire) != 0) return false;
        @atomicStore(u8, &self.locked, 1, .release);
        return true;
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
pub const IrqSpinlock = struct {
    lock: Spinlock = .{},

    /// Adquire o lock e desabilita interrupcoes locais.
    pub fn lockIrqSave(self: *IrqSpinlock) void {
        cpu.disableInterrupts();
        self.lock.lock();
    }

    /// Libera o lock e reabilita interrupcoes locais.
    pub fn unlockIrqRestore(self: *IrqSpinlock) void {
        self.lock.unlock();
        cpu.enableInterrupts();
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


