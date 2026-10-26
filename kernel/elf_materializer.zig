//************************************************************************//
//  elf_materializer.zig                                                  //
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

//! Materialização de um plano de carga ELF64.
//!
//! O planejador de `elf_loader.zig` é puro: ele valida a imagem e calcula
//! páginas, permissões e entrada. Este módulo é a outra metade: ele aloca
//! páginas físicas, mapeia o espaço do processo, copia o conteúdo do
//! arquivo, zera o BSS, aplica as realocações relativas e deixa as páginas
//! com as permissões finais.
//!
//! O módulo depende do paginador e do alocador físico, por isso não é
//! compilado para o host. A verificação dele é o boot real no QEMU: a
//! imagem nativa escreve no console e termina, e o kernel confere o
//! marcador que ela deixou na página de dados.
//!
//! W^X no hardware:
//!
//!   * o segmento de código é copiado com a página gravável e **sem** o bit
//!     de execução, e depois recebe `R+X`;
//!   * o segmento de dados e a pilha recebem `R+W` com o bit de
//!     no-execute;
//!   * nenhuma página fica gravável e executável ao mesmo tempo.

const std = @import("std");

const cpu = @import("arch/x86_64/cpu.zig");
const paging = @import("arch/x86_64/paging.zig");
const physical = @import("memory/physical.zig");
const loader = @import("elf_loader.zig");

/// Número máximo de páginas que uma materialização pode alocar.
///
/// A janela atual tem quatro páginas: código, dados e duas de pilha. O
/// limite é maior do que o necessário para que um incremento que aumente a
/// janela não transforme o limite em um defeito silencioso.
const max_mapped_pages: usize = 32;

/// Erros da materialização.
pub const Error = paging.Error || error{
    /// O alocador físico não tem mais páginas.
    OutOfMemory,
    /// A materialização pediu mais páginas do que o limite do módulo.
    TooManyPages,
    /// O conteúdo do segmento aponta para fora do arquivo.
    ImageOutOfBounds,
    /// Uma soma de endereços ou de tamanhos não cabe em 64 bits.
    Overflow,
    /// Um segmento caiu fora da janela do processo.
    SegmentOutsideWindow,
    /// A pilha caiu fora da janela ou não está alinhada.
    StackOutsideWindow,
    /// A pilha ocupa uma página que pertence a um segmento.
    StackOverlapsImage,
};

/// Materializa o plano em `space`.
///
/// A janela e a pilha são validadas antes de qualquer alocação. O espaço do
/// processo é ativado durante a cópia, porque as páginas do usuário não
/// existem no espaço do kernel, e o espaço anterior é restaurado mesmo
/// quando a materialização falha.
///
/// Em caso de erro, os mapeamentos parciais são removidos e as páginas
/// físicas voltam para o alocador. A tarefa ainda não existe, portanto não
/// há contexto para desfazer.
pub fn materialize(
    space: *paging.AddressSpace,
    plan: *const loader.LoadPlan,
    image: []const u8,
    window_base: u64,
    window_size: u64,
    stack_base: u64,
    stack_pages: u64,
) Error!void {
    if (window_size == 0) return error.SegmentOutsideWindow;
    const window_end = std.math.add(u64, window_base, window_size) catch
        return error.Overflow;

    if (stack_pages == 0) return error.StackOutsideWindow;
    if (stack_base % paging.page_size != 0) return error.StackOutsideWindow;
    const stack_length = std.math.mul(u64, stack_pages, paging.page_size) catch
        return error.Overflow;
    const stack_end = std.math.add(u64, stack_base, stack_length) catch
        return error.Overflow;
    if (stack_base < window_base or stack_end > window_end) {
        return error.StackOutsideWindow;
    }

    for (plan.segmentList()) |segment| {
        if (segment.page_start >= segment.page_end) return error.SegmentOutsideWindow;
        if (segment.page_start < window_base or segment.page_end > window_end) {
            return error.SegmentOutsideWindow;
        }
        if (segment.file_size > segment.memory_size) return error.ImageOutOfBounds;

        const file_end = std.math.add(u64, segment.file_offset, segment.file_size) catch
            return error.Overflow;
        if (file_end > @as(u64, @intCast(image.len))) return error.ImageOutOfBounds;

        if (segment.page_start < stack_end and stack_base < segment.page_end) {
            return error.StackOverlapsImage;
        }
    }

    var allocated: [max_mapped_pages]u64 = undefined;
    var mapped_virtual: [max_mapped_pages]u64 = undefined;
    var mapped_count: usize = 0;

    const saved_cr3 = cpu.readCr3();
    const saved_space = paging.activeSpace();
    paging.activateSpace(space);
    defer {
        cpu.writeCr3(saved_cr3);
        paging.setActiveSpace(saved_space);
    }
    errdefer {
        // The cleanup runs before the defer above, with the space of the
        // process still active: the entries are removed before the pages
        // return to the allocator.
        for (mapped_virtual[0..mapped_count], allocated[0..mapped_count]) |virtual, page| {
            paging.unmapUserPageIn(space, virtual) catch {};
            physical.manager.free(page);
        }
    }

    for (plan.segmentList()) |segment| {
        // A cópia precisa de uma página gravável. O código começa com a
        // página gravável e sem execução, e só recebe `R+X` depois que o
        // conteúdo está completo. O dado nunca precisa ser executável.
        var page = segment.page_start;
        while (page < segment.page_end) : (page += paging.page_size) {
            try mapZeroedPage(space, page, .{
                .writable = true,
                .executable = false,
            }, &allocated, &mapped_virtual, &mapped_count);
        }

        try copySegment(image, segment);

        page = segment.page_start;
        while (page < segment.page_end) : (page += paging.page_size) {
            try paging.protectUserPageIn(space, page, .{
                .writable = segment.isWritable(),
                .executable = segment.isExecutable(),
            });
        }
    }

    // As realocações relativas valem `load_bias + addend` e escrevem em um
    // segmento gravável. O plano já recusou um alvo fora dele; a soma é
    // feita com a aritmética que envolve, porque o addend é assinado.
    for (plan.relocationList()) |relocation| {
        const target = std.math.add(u64, plan.load_bias, relocation.offset) catch
            return error.Overflow;
        const value = plan.load_bias +% @as(u64, @bitCast(relocation.addend));

        const pointer: *volatile u64 = @ptrFromInt(target);
        pointer.* = value;
    }

    // A pilha é páginas novas, zeradas e sem execução. O processo começa
    // com o ponteiro no topo, que o escalonador calcula a partir do
    // endereço e do comprimento.
    var page = stack_base;
    while (page < stack_end) : (page += paging.page_size) {
        try mapZeroedPage(space, page, .{
            .writable = true,
            .executable = false,
        }, &allocated, &mapped_virtual, &mapped_count);
    }
}

/// Aloca, mapeia e zera uma página do usuário.
fn mapZeroedPage(
    space: *paging.AddressSpace,
    virtual: u64,
    flags: paging.UserPageFlags,
    allocated: *[max_mapped_pages]u64,
    mapped_virtual: *[max_mapped_pages]u64,
    mapped_count: *usize,
) Error!void {
    if (mapped_count.* >= allocated.len) return error.TooManyPages;

    const page = physical.manager.allocate() orelse return error.OutOfMemory;

    // A página só entra na lista depois que o mapeamento deu certo: uma
    // falha aqui devolve a página na hora, e o erro não tem um mapeamento
    // para desfazer.
    paging.mapUserPageInFlags(space, virtual, page, flags) catch |err| {
        physical.manager.free(page);
        return err;
    };

    allocated[mapped_count.*] = page;
    mapped_virtual[mapped_count.*] = virtual;
    mapped_count.* += 1;

    // O espaço está ativo e a página é gravável neste momento; a escrita
    // do supervisor passa pela permissão de escrita da entrada.
    const destination: [*]u8 = @ptrFromInt(virtual);
    @memset(destination[0..@intCast(paging.page_size)], 0);
}

/// Copia o conteúdo do arquivo para a página já mapeada.
///
/// A cópia atravessa a fronteira das páginas em pedaços, porque o arquivo
/// não é contínuo na memória virtual. O que sobra entre `file_size` e
/// `memory_size` é o BSS, que já está zerado.
fn copySegment(image: []const u8, segment: loader.PlannedSegment) Error!void {
    var offset: u64 = 0;
    while (offset < segment.file_size) {
        const virtual = std.math.add(u64, segment.virtual_address, offset) catch
            return error.Overflow;
        const page_offset = virtual & (paging.page_size - 1);
        const remaining = segment.file_size - offset;
        const length = @min(paging.page_size - page_offset, remaining);

        const source_offset = std.math.add(u64, segment.file_offset, offset) catch
            return error.Overflow;

        const destination: [*]u8 = @ptrFromInt(virtual);
        @memcpy(
            destination[0..@intCast(length)],
            image[@intCast(source_offset)..][0..@intCast(length)],
        );

        offset += length;
    }
}
