//************************************************************************//
//  virtio_blk.zig                                                        //
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

//! Interfaces provisórias do driver virtio-blk.
//!
//! **Este módulo não é um driver funcional.** Não existe detecção de
//! dispositivo, handshake de status, negociação de features, virtqueue
//! programada, barra mapeada nem pedido enviado: nada aqui toca um
//! dispositivo. As duas funções abaixo são apenas os pontos de entrada onde
//! o driver real será ligado à camada de blocos
//! (`kernel/storage/block.zig`).
//!
//! O contrato deste incremento é que **nenhuma operação de bloco reporta
//! sucesso**. Em Zig, uma função `!void` cujo corpo termina sem `return`
//! devolve o payload, isto é, sucesso; um stub vazio portanto publicaria
//! uma leitura ou uma escrita concluída sem acessar dispositivo algum. Por
//! isso `blk_read` e `blk_write` devolvem `error.NotImplemented` de forma
//! incondicional, o conjunto de erros faz parte da assinatura e os testes
//! deste arquivo falham se alguém restaurar um corpo vazio.
//!
//! As assinaturas ainda não recebem LBA, buffer nem contagem de setores, e
//! por isso **não** constituem uma interface de I/O de blocos. O redesenho
//! da API, a integração com `block.Device` e a persistência física em disco
//! ficam para um incremento posterior
//! (`docs/adr/ADR-F04-block-driver-proposta.md`).

const std = @import("std");

/// Erros do módulo virtio-blk.
///
/// O conjunto é declarado de forma explícita, no mesmo padrão de
/// `virtio.QueueError` e `block.Error`, para que o contrato de erro faça
/// parte da assinatura pública em vez de ser inferido do corpo.
pub const BlkError = error{
    /// Não existe driver virtio-blk: nenhum dispositivo foi detectado,
    /// nenhuma virtqueue foi programada e nenhum pedido foi enviado. Toda
    /// operação de bloco devolve este erro enquanto não houver
    /// implementação real de I/O.
    NotImplemented,
};

/// Ponto de entrada da leitura de blocos.
///
/// Não lê nada: a assinatura não recebe LBA nem buffer, e o corpo não
/// consulta o barramento PCI nem programa fila alguma. Devolve
/// `error.NotImplemented` sempre, com ou sem hardware presente, para que
/// nenhum chamador trate a operação como concluída.
pub fn blk_read() BlkError!void {
    return error.NotImplemented;
}

/// Ponto de entrada da escrita de blocos.
///
/// Não escreve nada, pelos mesmos motivos de `blk_read`: sem LBA, sem
/// buffer e sem dispositivo programado. Devolve `error.NotImplemented`
/// sempre, em vez de publicar uma escrita concluída que não aconteceu.
pub fn blk_write() BlkError!void {
    return error.NotImplemented;
}

// ----------------------------------------------------------------------
// Regressão do falso sucesso.
//
// Estes testes entram em `zig build test` pelo binário `arch-tests`, que
// importa este módulo através de `kernel/arch/x86_64/root.zig`. Nenhum
// deles depende de hardware: o módulo não abre portas de I/O nem mapeia
// barras, e o resultado é o mesmo em qualquer máquina, porque não existe
// caminho de sucesso para ser alcançado.
// ----------------------------------------------------------------------

const testing = std.testing;

/// Conjunto de erros declarado por `f`.
fn errorSetOf(comptime f: anytype) type {
    const returned = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    return @typeInfo(returned).error_union.error_set;
}

test "virtio-blk read returns an explicit error instead of success" {
    // Um `!void` com corpo vazio devolve sucesso: é exatamente o
    // comportamento que este teste recusa.
    try testing.expectError(error.NotImplemented, blk_read());
}

test "virtio-blk write returns an explicit error instead of success" {
    try testing.expectError(error.NotImplemented, blk_write());
}

test "the block operations never succeed and ignore the presence of hardware" {
    // Chamadas repetidas: as operações não guardam estado que possa virar
    // sucesso em uma tentativa seguinte, e o erro devolvido é sempre o
    // documentado, porque nenhum ramo do módulo consulta um dispositivo.
    for (0..4) |_| {
        const read_error: BlkError = if (blk_read()) |_| return error.TestUnexpectedResult else |err| err;
        const write_error: BlkError = if (blk_write()) |_| return error.TestUnexpectedResult else |err| err;
        try testing.expectEqualStrings("NotImplemented", @errorName(read_error));
        try testing.expectEqualStrings("NotImplemented", @errorName(write_error));
    }
}

test "the declared error set is the whole contract of the operations" {
    // O conjunto declarado tem um único erro e é o conjunto das duas
    // funções. Se alguém trocar o erro devolvido, os testes acima falham;
    // se alguém ampliar o conjunto, este teste falha e a mudança precisa
    // ser documentada em vez de silenciosa.
    try testing.expectEqual(BlkError, errorSetOf(blk_read));
    try testing.expectEqual(BlkError, errorSetOf(blk_write));

    const names = @typeInfo(BlkError).error_set.error_names.?;
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("NotImplemented", names[0]);
}
