//************************************************************************//
//  mmio.zig                                                              //
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

//! Acesso a memoria mapeada de dispositivo (MMIO).
//!
//! Um registrador de dispositivo nao e RAM. Os valores chegam do hardware, e
//! nao da memoria: o processador nao pode servir uma leitura da cache, nao
//! pode adiar uma escrita e nao pode juntar duas escritas proximas. As regras
//! aplicadas aqui sao as tres que a diferenca exige:
//!
//!   * toda leitura e toda escrita atravessam um ponteiro `volatile`, para
//!     que o compilador nao elimine, repita nem reordene o acesso dentro da
//!     funcao;
//!   * a pagina e mapeada sem cache (`paging.mapDevicePage`), porque nenhum
//!     nivel de cache pode guardar um valor que o dispositivo ainda pode
//!     mudar;
//!   * cada acesso e cercado por uma barreira de ordenacao: uma escrita que
//!     publica um comando precisa estar visivel no dispositivo antes da
//!     leitura que espera a resposta.
//!
//! O modulo separa tres coisas que costumam ser misturadas:
//!
//!   * `Window`  - a janela virtual reservada onde os BARs sao mapeados;
//!   * `Region`  - uma faixa ja mapeada, com comprimento, permissoes e estado;
//!   * `Bus`     - o contrato de acesso cru, que o kernel liga ao `volatile` e
//!                 os testes ligam a uma memoria simulada.
//!
//! A validacao (limites, alinhamento, transbordo, estado do mapeamento) vive
//! em `Region` e nao no `Bus`: assim a mesma validacao que roda no kernel e
//! exercitada no host, sem hardware e sem porta de I/O.
//!
//! O que este modulo NAO faz: nao cria tabelas de pagina. O mapeamento e
//! injetado por `Mapper`, e o kernel o liga a `paging.zig`, de modo que nao
//! existe um segundo gerenciador de paginacao.

const std = @import("std");

/// Tamanho da pagina usado pela janela e pelo mapeamento.
pub const page_size: u64 = 4096;

pub const Error = error{
    /// A regiao ja nao esta mapeada: um acesso depois de `unmap`.
    NotMapped,
    /// A regiao tem comprimento zero.
    EmptyRegion,
    /// O acesso passa do fim da regiao.
    OutOfRange,
    /// O deslocamento nao respeita o alinhamento da largura acessada.
    Misaligned,
    /// A soma do deslocamento com a largura nao cabe em 64 bits.
    Overflow,
    /// A regiao foi mapeada somente para leitura.
    NotWritable,
    /// A janela nao tem paginas livres contiguas para a faixa pedida.
    WindowExhausted,
    /// O mapeador de plataforma recusou a pagina.
    MapFailed,
    /// A base ou o comprimento da janela nao descrevem paginas inteiras.
    InvalidWindow,
};

/// Largura de um acesso, em bytes.
///
/// O valor do enum e o proprio tamanho. Um acesso usa a largura que o
/// registrador define na especificacao do dispositivo: ler um registrador de
/// 32 bits com duas leituras de 16 bits produziria dois valores de momentos
/// diferentes.
pub const Width = enum(u8) {
    byte = 1,
    word = 2,
    dword = 4,
    qword = 8,

    /// Tamanho da largura em bytes.
    pub fn size(self: Width) u64 {
        return @backingInt(self);
    }
};

/// Contrato do acesso cru a uma faixa de memoria de dispositivo.
///
/// O `ctx` pertence ao chamador. A funcao `read_fn` devolve o valor da largura
/// pedida; `write_fn` grava o valor. Nenhuma das duas valida nada: a validacao
/// e de `Region`, que e quem garante que o endereco existe.
pub const Bus = struct {
    ctx: ?*const anyopaque,
    read_fn: *const fn (ctx: ?*const anyopaque, address: u64, width: Width) u64,
    write_fn: *const fn (ctx: ?*const anyopaque, address: u64, width: Width, value: u64) void,

    pub fn read(self: Bus, address: u64, width: Width) u64 {
        return self.read_fn(self.ctx, address, width);
    }

    pub fn write(self: Bus, address: u64, width: Width, value: u64) void {
        self.write_fn(self.ctx, address, width, value);
    }
};

/// Leitura volatil de um registrador real.
///
/// O ponteiro e `volatile` porque o valor pode mudar sem que este programa
/// escreva nele. A barreira de aquisicao antes do acesso impede que a leitura
/// seja movida para antes de uma escrita que a antecede na ordem do codigo.
fn volatileRead(_: ?*const anyopaque, address: u64, width: Width) u64 {
    fence();
    return switch (width) {
        .byte => @as(*const volatile u8, @ptrFromInt(address)).*,
        .word => @as(*const volatile u16, @ptrFromInt(address)).*,
        .dword => @as(*const volatile u32, @ptrFromInt(address)).*,
        .qword => @as(*const volatile u64, @ptrFromInt(address)).*,
    };
}

/// Escrita volatil em um registrador real.
///
/// A barreira de liberacao depois do acesso garante que a escrita chegou ao
/// dispositivo antes de qualquer acesso posterior.
fn volatileWrite(_: ?*const anyopaque, address: u64, width: Width, value: u64) void {
    switch (width) {
        .byte => @as(*volatile u8, @ptrFromInt(address)).* = @truncate(value),
        .word => @as(*volatile u16, @ptrFromInt(address)).* = @truncate(value),
        .dword => @as(*volatile u32, @ptrFromInt(address)).* = @truncate(value),
        .qword => @as(*volatile u64, @ptrFromInt(address)).* = value,
    }
    fence();
}

/// Barreira completa de ordenacao de memoria.
///
/// `mfence` e a instrucao que ordena *store* seguido de *load*, que e
/// exatamente a sequencia do driver com um dispositivo: escrever um comando e
/// ler a resposta. As barreiras mais baratas (`sfence`/`lfence`) ordenam
/// apenas um dos sentidos de cada lado, e por isso nao substituem esta.
///
/// O `memory` no clobber avisa o compilador de que a instrucao pode ler e
/// escrever qualquer memoria, e e o que impede que ele mova um acesso para o
/// outro lado da barreira.
fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// O barramento de um dispositivo real: acesso volatil direto ao endereco.
pub const volatile_bus: Bus = .{
    .ctx = null,
    .read_fn = volatileRead,
    .write_fn = volatileWrite,
};

/// Permissoes de uma regiao mapeada.
pub const Permissions = struct {
    /// True quando a regiao pode ser escrita.
    writable: bool,

    /// Regiao somente de leitura: o caso da configuracao de um dispositivo e
    /// dos registradores que ele informa.
    pub const read_only: Permissions = .{ .writable = false };

    /// Regiao que o driver escreve e le.
    pub const read_write: Permissions = .{ .writable = true };
};

/// Contrato de mapeamento, injetado pela plataforma.
///
/// O kernel liga as duas funcoes a `paging.mapDevicePage` e
/// `paging.unmapKernelPage`; os testes ligam a uma tabela em memoria. O tipo e
/// o mesmo usado por `kernel/memory/dma.zig`, e nao uma segunda abstracao.
pub const Mapper = struct {
    /// Mapeia uma pagina; devolve false quando a plataforma recusa.
    map: *const fn (virtual: u64, physical: u64) bool,
    /// Desfaz o mapeamento de uma pagina.
    unmap: *const fn (virtual: u64) void,
};

/// Uma faixa de memoria de dispositivo ja validada.
///
/// `virtual` e `physical` apontam para o inicio da faixa, `length` e o
/// comprimento *declarado* (nao o arredondado para paginas) e por isso e ele
/// que limita os acessos. `mapped` e o estado: depois de `Window.unmap` a
/// faixa continua existindo como valor, mas todo acesso falha com
/// `error.NotMapped` em vez de tocar em memoria que nao pertence mais ao
/// driver.
pub const Region = struct {
    bus: Bus,
    virtual: u64,
    physical: u64,
    length: u64,
    permissions: Permissions,
    mapped: bool,

    /// Quantas paginas a janela reservou para esta faixa; zero quando a
    /// faixa nao veio de `Window.mapRange`.
    pages: usize = 0,

    /// Valida um acesso e devolve o endereco virtual dele.
    ///
    /// A ordem das verificacoes e escolhida para que o erro devolvido seja o
    /// que descreve a falha, e nao um efeito colateral dela:
    ///
    ///   1. o estado do mapeamento, porque uma faixa desmapeada nao deve nem
    ///      comparar limites contra memoria que ja nao lhe pertence;
    ///   2. o comprimento zero, que e uma faixa invalida e nao um acesso fora
    ///      dela;
    ///   3. um deslocamento que ja comeca fora da faixa, antes de qualquer
    ///      aritmetica — e o caso comum de um registrador inexistente, e
    ///      reporta-lo como `Overflow` esconderia o erro real;
    ///   4. o transbordo de `offset + largura`;
    ///   5. o fim que passa do comprimento declarado;
    ///   6. o alinhamento da largura;
    ///   7. o transbordo de `virtual + offset`.
    pub fn address(self: Region, offset: u64, width: Width) Error!u64 {
        if (!self.mapped) return error.NotMapped;
        if (self.length == 0) return error.EmptyRegion;
        if (offset >= self.length) return error.OutOfRange;

        const end = std.math.add(u64, offset, width.size()) catch return error.Overflow;
        if (end > self.length) return error.OutOfRange;
        if (offset % width.size() != 0) return error.Misaligned;

        return std.math.add(u64, self.virtual, offset) catch return error.Overflow;
    }

    /// True quando o acesso seria aceito.
    pub fn contains(self: Region, offset: u64, width: Width) bool {
        _ = self.address(offset, width) catch return false;
        return true;
    }

    /// Le a largura pedida.
    pub fn read(self: Region, offset: u64, width: Width) Error!u64 {
        const target = try self.address(offset, width);
        return self.bus.read(target, width);
    }

    /// Escreve a largura pedida.
    pub fn write(self: Region, offset: u64, width: Width, value: u64) Error!void {
        if (!self.permissions.writable) {
            // O estado do mapeamento e validado antes da permissao, para que
            // uma faixa desmapeada continue respondendo `NotMapped`.
            if (!self.mapped) return error.NotMapped;
            return error.NotWritable;
        }
        const target = try self.address(offset, width);
        self.bus.write(target, width, value);
    }

    pub fn read8(self: Region, offset: u64) Error!u8 {
        return @truncate(try self.read(offset, .byte));
    }

    pub fn read16(self: Region, offset: u64) Error!u16 {
        return @truncate(try self.read(offset, .word));
    }

    pub fn read32(self: Region, offset: u64) Error!u32 {
        return @truncate(try self.read(offset, .dword));
    }

    pub fn read64(self: Region, offset: u64) Error!u64 {
        return self.read(offset, .qword);
    }

    pub fn write8(self: Region, offset: u64, value: u8) Error!void {
        return self.write(offset, .byte, value);
    }

    pub fn write16(self: Region, offset: u64, value: u16) Error!void {
        return self.write(offset, .word, value);
    }

    pub fn write32(self: Region, offset: u64, value: u32) Error!void {
        return self.write(offset, .dword, value);
    }

    pub fn write64(self: Region, offset: u64, value: u64) Error!void {
        return self.write(offset, .qword, value);
    }

    /// Deriva uma faixa menor, com o mesmo barramento e as mesmas permissoes.
    ///
    /// A sub-faixa e validada contra a faixa de origem, e nao contra si mesma:
    /// `offset + length` precisa caber no que ja estava mapeado. E assim que
    /// cada capability do VirtIO recebe uma visao propria dentro do mesmo BAR.
    pub fn view(self: Region, offset: u64, length: u64) Error!Region {
        if (!self.mapped) return error.NotMapped;
        if (length == 0) return error.EmptyRegion;

        const end = std.math.add(u64, offset, length) catch return error.Overflow;
        if (end > self.length) return error.OutOfRange;

        return .{
            .bus = self.bus,
            .virtual = std.math.add(u64, self.virtual, offset) catch return error.Overflow,
            .physical = std.math.add(u64, self.physical, offset) catch return error.Overflow,
            .length = length,
            .permissions = self.permissions,
            .mapped = true,
            .pages = 0,
        };
    }
};

/// Maior janela que o kernel reserva para MMIO, em paginas.
///
/// O valor e o da janela virtual de `kernel/main.zig` (16 MiB). O mapa de
/// bits e estatico de proposito: o mapeamento de um BAR acontece uma vez, no
/// boot, e uma alocacao dinamica aqui so acrescentaria um caminho de falha.
pub const window_pages: usize = 4096;

/// Janela virtual onde os BARs sao mapeados.
///
/// A janela nao mapeia nada ao ser criada: ela guarda quais paginas estao em
/// uso. `mapRange` encontra uma sequencia livre, mapeia pagina a pagina pelo
/// `Mapper` injetado e devolve a faixa. Se o mapeador recusar uma pagina, as
/// anteriores sao desfeitas antes do erro, para que uma falha no meio nao
/// deixe paginas reservadas sem dono.
pub const Window = struct {
    base: u64,
    pages: usize,
    used: [window_pages / 8]u8 = @splat(0),
    mapper: Mapper,

    /// Prepara a janela sobre uma faixa virtual reservada.
    pub fn init(base: u64, length: u64, mapper: Mapper) Error!Window {
        if (base % page_size != 0) return error.InvalidWindow;
        if (length == 0 or length % page_size != 0) return error.InvalidWindow;

        const pages = length / page_size;
        if (pages > window_pages) return error.InvalidWindow;
        return .{ .base = base, .pages = @intCast(pages), .mapper = mapper };
    }

    fn isFree(self: *const Window, index: usize) bool {
        return self.used[index / 8] & (@as(u8, 1) << @intCast(index % 8)) == 0;
    }

    fn setUsed(self: *Window, index: usize, value: bool) void {
        const mask = @as(u8, 1) << @intCast(index % 8);
        if (value) {
            self.used[index / 8] |= mask;
        } else {
            self.used[index / 8] &= ~mask;
        }
    }

    /// Procura a primeira sequencia livre com o tamanho pedido.
    ///
    /// A busca comeca na pagina zero para que o mesmo pedido receba sempre o
    /// mesmo endereco virtual: o console do boot fica reproduzivel.
    fn findRun(self: *const Window, count: usize) ?usize {
        if (count == 0 or count > self.pages) return null;

        var start: usize = 0;
        while (start + count <= self.pages) : (start += 1) {
            var offset: usize = 0;
            while (offset < count) : (offset += 1) {
                if (!self.isFree(start + offset)) break;
            }
            if (offset == count) return start;
        }
        return null;
    }

    /// Mapeia uma faixa fisica na janela e devolve a regiao correspondente.
    ///
    /// `length` e o comprimento pedido, e nao o arredondado: a regiao devolvida
    /// aceita acessos ate `length`, e o resto da ultima pagina fica mapeado mas
    /// fora do alcance de `Region.address`.
    pub fn mapRange(
        self: *Window,
        physical: u64,
        length: u64,
        permissions: Permissions,
    ) Error!Region {
        if (length == 0) return error.EmptyRegion;
        if (physical % page_size != 0) return error.MapFailed;

        const rounded = std.math.add(u64, length, page_size - 1) catch return error.Overflow;
        const count: usize = @intCast(rounded / page_size);
        if (count == 0 or count > self.pages) return error.WindowExhausted;

        const start = self.findRun(count) orelse return error.WindowExhausted;
        const virtual = self.base + @as(u64, @intCast(start)) * page_size;

        var mapped: usize = 0;
        while (mapped < count) : (mapped += 1) {
            const page_virtual = virtual + @as(u64, @intCast(mapped)) * page_size;
            const page_physical = std.math.add(
                u64,
                physical,
                @as(u64, @intCast(mapped)) * page_size,
            ) catch {
                self.rollback(start, mapped);
                return error.Overflow;
            };
            if (!self.mapper.map(page_virtual, page_physical)) {
                self.rollback(start, mapped);
                return error.MapFailed;
            }
        }

        var index: usize = 0;
        while (index < count) : (index += 1) self.setUsed(start + index, true);

        return .{
            .bus = volatile_bus,
            .virtual = virtual,
            .physical = physical,
            .length = length,
            .permissions = permissions,
            .mapped = true,
            .pages = count,
        };
    }

    fn rollback(self: *Window, start: usize, mapped: usize) void {
        var index: usize = 0;
        while (index < mapped) : (index += 1) {
            const page_virtual = self.base + @as(u64, @intCast(start + index)) * page_size;
            self.mapper.unmap(page_virtual);
        }
    }

    /// Desfaz o mapeamento de uma faixa devolvida por `mapRange`.
    ///
    /// A faixa fica marcada como nao mapeada: um acesso posterior falha com
    /// `error.NotMapped` em vez de tocar em memoria que a janela ja devolveu.
    pub fn unmap(self: *Window, region: *Region) void {
        if (!region.mapped or region.pages == 0) return;

        const offset = region.virtual - self.base;
        const start: usize = @intCast(offset / page_size);

        var index: usize = 0;
        while (index < region.pages) : (index += 1) {
            const page_virtual = region.virtual + @as(u64, @intCast(index)) * page_size;
            self.mapper.unmap(page_virtual);
            self.setUsed(start + index, false);
        }

        region.mapped = false;
        region.pages = 0;
    }

    /// Quantas paginas estao em uso.
    pub fn usedPages(self: *const Window) usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < self.pages) : (index += 1) {
            if (!self.isFree(index)) count += 1;
        }
        return count;
    }
};

const testing = std.testing;

// ----------------------------------------------------------------------
// Plataforma simulada.
//
// A janela dos testes e um bloco de memoria estatica deste processo,
// alinhado a pagina: assim o `volatile_bus` — o mesmo do kernel, e nao uma
// copia — acessa memoria de verdade, e as regioes que saem de
// `Window.mapRange` sao exercitadas pelo caminho real de leitura e escrita.
//
// O mapeador nao mapeia nada: ele registra cada pagina para que o teste possa
// conferir o que foi mapeado e o que foi desfeito.
// ----------------------------------------------------------------------

const test_window_length: u64 = 64 * 1024;

const Platform = struct {
    var memory: [test_window_length]u8 align(page_size) = @splat(0);
    var map_calls: u32 = 0;
    var unmap_calls: u32 = 0;
    var last_virtual: u64 = 0;
    var last_physical: u64 = 0;
    var refuse_at: ?u64 = null;

    fn reset() void {
        memory = @splat(0);
        map_calls = 0;
        unmap_calls = 0;
        last_virtual = 0;
        last_physical = 0;
        refuse_at = null;
    }

    fn map(virtual: u64, physical: u64) bool {
        if (refuse_at) |refused| {
            if (virtual == refused) return false;
        }
        map_calls += 1;
        last_virtual = virtual;
        last_physical = physical;
        return true;
    }

    fn unmap(virtual: u64) void {
        _ = virtual;
        unmap_calls += 1;
    }

    fn mapper() Mapper {
        return .{ .map = map, .unmap = unmap };
    }

    /// Base virtual da janela: o proprio bloco estatico.
    fn base() u64 {
        return @intFromPtr(&memory);
    }

    fn read(_: ?*const anyopaque, address: u64, width: Width) u64 {
        const offset = address - base();
        var value: u64 = 0;
        var index: u64 = 0;
        while (index < width.size()) : (index += 1) {
            value |= @as(u64, memory[@intCast(offset + index)]) << @intCast(index * 8);
        }
        return value;
    }

    fn write(_: ?*const anyopaque, address: u64, width: Width, value: u64) void {
        const offset = address - base();
        var index: u64 = 0;
        while (index < width.size()) : (index += 1) {
            memory[@intCast(offset + index)] = @truncate(value >> @intCast(index * 8));
        }
    }

    fn bus() Bus {
        return .{ .ctx = null, .read_fn = read, .write_fn = write };
    }
};

fn testWindow() Window {
    return Window.init(Platform.base(), test_window_length, Platform.mapper()) catch unreachable;
}

/// Regiao de teste com barramento simulado, sem passar pela janela.
fn testRegion(virtual: u64, length: u64) Region {
    return .{
        .bus = Platform.bus(),
        .virtual = virtual,
        .physical = 0,
        .length = length,
        .permissions = Permissions.read_write,
        .mapped = true,
    };
}

test "mmio width reports the access size" {
    try testing.expectEqual(@as(u64, 1), Width.byte.size());
    try testing.expectEqual(@as(u64, 2), Width.word.size());
    try testing.expectEqual(@as(u64, 4), Width.dword.size());
    try testing.expectEqual(@as(u64, 8), Width.qword.size());
}

test "mmio window maps a range and reserves its pages" {
    Platform.reset();
    var window = testWindow();

    var region = try window.mapRange(0xFE00_0000, 0x2000, Permissions.read_write);
    try testing.expectEqual(Platform.base(), region.virtual);
    try testing.expectEqual(@as(u64, 0xFE00_0000), region.physical);
    try testing.expectEqual(@as(u64, 0x2000), region.length);
    try testing.expectEqual(@as(usize, 2), region.pages);
    try testing.expectEqual(@as(u32, 2), Platform.map_calls);
    try testing.expectEqual(@as(u64, 0xFE00_1000), Platform.last_physical);
    try testing.expectEqual(@as(usize, 2), window.usedPages());

    // A segunda faixa comeca depois da primeira, e nao em cima dela.
    var second = try window.mapRange(0xFE01_0000, page_size, Permissions.read_only);
    try testing.expectEqual(Platform.base() + 0x2000, second.virtual);
    try testing.expectEqual(@as(usize, 3), window.usedPages());

    window.unmap(&second);
    try testing.expectEqual(@as(usize, 2), window.usedPages());
    try testing.expect(!second.mapped);
    try testing.expectEqual(@as(u32, 1), Platform.unmap_calls);

    window.unmap(&region);
    try testing.expectEqual(@as(usize, 0), window.usedPages());
    // A faixa ocupava duas paginas, e as duas foram desfeitas.
    try testing.expectEqual(@as(u32, 3), Platform.unmap_calls);
}

test "mmio window rounds the length up to whole pages" {
    Platform.reset();
    var window = testWindow();

    // 0x100 bytes cabem em uma pagina, e o comprimento devolvido continua
    // sendo o pedido: o que passa dele e recusado por `Region.address`.
    const region = try window.mapRange(0xFE00_0000, 0x100, Permissions.read_write);
    try testing.expectEqual(@as(usize, 1), region.pages);
    try testing.expectEqual(@as(u64, 0x100), region.length);
    try testing.expectEqual(@as(usize, 1), window.usedPages());
    try testing.expectError(error.OutOfRange, region.read32(0x100));
}

test "mmio window rejects empty, unaligned and oversized ranges" {
    Platform.reset();
    var window = testWindow();

    try testing.expectError(
        error.EmptyRegion,
        window.mapRange(0xFE00_0000, 0, Permissions.read_write),
    );
    try testing.expectError(
        error.MapFailed,
        window.mapRange(0xFE00_0100, page_size, Permissions.read_write),
    );
    try testing.expectError(
        error.WindowExhausted,
        window.mapRange(0xFE00_0000, test_window_length + page_size, Permissions.read_write),
    );

    // Uma janela que nao descreve paginas inteiras nao e aceita.
    try testing.expectError(error.InvalidWindow, Window.init(Platform.base() + 1, page_size, Platform.mapper()));
    try testing.expectError(error.InvalidWindow, Window.init(Platform.base(), 0, Platform.mapper()));
    try testing.expectError(error.InvalidWindow, Window.init(Platform.base(), 3, Platform.mapper()));
}

test "mmio window rolls back when the platform refuses a page" {
    Platform.reset();
    var window = testWindow();

    // A segunda pagina e recusada: a primeira precisa ser desfeita.
    Platform.refuse_at = Platform.base() + page_size;
    try testing.expectError(
        error.MapFailed,
        window.mapRange(0xFE00_0000, 0x2000, Permissions.read_write),
    );
    try testing.expectEqual(@as(u32, 1), Platform.unmap_calls);
    try testing.expectEqual(@as(usize, 0), window.usedPages());
    Platform.refuse_at = null;
}

test "mmio window exhausts the static map" {
    Platform.reset();
    var window = testWindow();

    // 16 paginas: a janela de teste tem 16.
    var index: usize = 0;
    while (index < 16) : (index += 1) {
        _ = try window.mapRange(0xFE00_0000 + index * page_size, page_size, Permissions.read_write);
    }
    try testing.expectEqual(@as(usize, 16), window.usedPages());
    try testing.expectError(
        error.WindowExhausted,
        window.mapRange(0xFE10_0000, page_size, Permissions.read_write),
    );
}

test "mmio region validates offsets, alignment and bounds" {
    Platform.reset();
    const region = testRegion(Platform.base(), 0x100);

    // Offset valido, em todas as larguras.
    try testing.expect(region.contains(0x00, .byte));
    try testing.expect(region.contains(0x02, .word));
    try testing.expect(region.contains(0x04, .dword));
    try testing.expect(region.contains(0x08, .qword));
    try testing.expect(region.contains(0xFC, .dword));

    // Fim exato da regiao: 0xFC + 4 = 0x100.
    try testing.expect(!region.contains(0xFD, .dword));
    try testing.expectError(error.OutOfRange, region.read32(0xFD));

    // Fora dos limites.
    try testing.expectError(error.OutOfRange, region.read32(0x100));
    try testing.expectError(error.OutOfRange, region.read32(0x1000));
    try testing.expectError(error.OutOfRange, region.read8(0x100));

    // Alinhamento natural da largura.
    try testing.expectError(error.Misaligned, region.read32(0x02));
    try testing.expectError(error.Misaligned, region.read16(0x01));
    try testing.expectError(error.Misaligned, region.read64(0x04));
    try testing.expect(region.contains(0x01, .byte));
}

test "mmio region rejects overflow and empty regions" {
    Platform.reset();
    const region = testRegion(Platform.base(), 0x100);

    // Um deslocamento que ja comeca fora da faixa e reportado como tal: o
    // transbordo de `offset + largura` nao e o erro que descreve o acesso.
    try testing.expectError(error.OutOfRange, region.address(std.math.maxInt(u64), .dword));
    try testing.expectError(error.OutOfRange, region.address(std.math.maxInt(u64) - 1, .qword));

    // Transbordo de `offset + largura`: a faixa comeca no maximo e tem
    // comprimento maximo, entao o fim do acesso nao cabe em 64 bits.
    const wide = testRegion(Platform.base(), std.math.maxInt(u64));
    try testing.expectError(error.Overflow, wide.address(std.math.maxInt(u64) - 1, .qword));
    try testing.expectError(error.Overflow, wide.address(std.math.maxInt(u64) - 3, .dword));

    // Transbordo de `virtual + offset`: a faixa comeca perto do topo do
    // espaco de enderecos.
    const top = testRegion(std.math.maxInt(u64) - 8, 0x100);
    try testing.expectError(error.Overflow, top.address(0x10, .dword));

    // Regiao de comprimento zero.
    const empty = testRegion(Platform.base(), 0);
    try testing.expectError(error.EmptyRegion, empty.read8(0));
    try testing.expectError(error.EmptyRegion, empty.address(0, .byte));
    try testing.expect(!empty.contains(0, .byte));
}

test "mmio region reads and writes every width" {
    Platform.reset();
    const region = testRegion(Platform.base(), 0x100);

    try region.write8(0x00, 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), try region.read8(0x00));

    try region.write16(0x02, 0xBEEF);
    try testing.expectEqual(@as(u16, 0xBEEF), try region.read16(0x02));
    // Little endian: o byte baixo vem primeiro.
    try testing.expectEqual(@as(u8, 0xEF), try region.read8(0x02));
    try testing.expectEqual(@as(u8, 0xBE), try region.read8(0x03));

    try region.write32(0x04, 0xDEAD_BEEF);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), try region.read32(0x04));

    try region.write64(0x08, 0x0123_4567_89AB_CDEF);
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), try region.read64(0x08));
    try testing.expectEqual(@as(u32, 0x89AB_CDEF), try region.read32(0x08));

    // Uma escrita de 32 bits nao alcanca o vizinho.
    try region.write32(0x0C, 0x1111_1111);
    try testing.expectEqual(@as(u32, 0x1111_1111), try region.read32(0x0C));
}

test "mmio region refuses writes to a read only range" {
    Platform.reset();
    var region = testRegion(Platform.base(), 0x100);
    region.permissions = Permissions.read_only;

    // Escrever e recusado: e o caso dos registradores que so o dispositivo
    // altera.
    try testing.expectError(error.NotWritable, region.write8(0x00, 0x7F));
    try testing.expectError(error.NotWritable, region.write32(0x04, 0x1));

    // Ler continua permitido.
    try testing.expectEqual(@as(u8, 0), try region.read8(0x00));

    // Depois de desmapeada, a faixa responde `NotMapped` e nao `NotWritable`:
    // o estado do mapeamento vem antes da permissao.
    var window = testWindow();
    var mapping = try window.mapRange(0xFE00_0000, page_size, Permissions.read_only);
    window.unmap(&mapping);
    try testing.expectError(error.NotMapped, mapping.write8(0x00, 0x1));
}

test "mmio region refuses every access after unmap" {
    Platform.reset();
    var window = testWindow();

    var region = try window.mapRange(0xFE00_0000, 0x1000, Permissions.read_write);
    try region.write32(0x00, 0x1234);

    window.unmap(&region);

    // A faixa continua sendo um valor valido, mas nao aponta mais para
    // memoria do driver.
    try testing.expect(!region.mapped);
    try testing.expectError(error.NotMapped, region.read32(0x00));
    try testing.expectError(error.NotMapped, region.write32(0x00, 0x1));
    try testing.expectError(error.NotMapped, region.address(0, .dword));
    try testing.expectError(error.NotMapped, region.view(0, 4));
    try testing.expect(!region.contains(0, .byte));

    // Desmapear duas vezes nao devolve paginas duas vezes.
    window.unmap(&region);
    try testing.expectEqual(@as(u32, 1), Platform.unmap_calls);
}

test "mmio region view is validated against the mapped range" {
    Platform.reset();
    var window = testWindow();
    const bar = try window.mapRange(0xFE00_0000, 0x2000, Permissions.read_write);

    // Visoes do mesmo BAR, como as capabilities do VirtIO moderno.
    const first = try bar.view(0x0000, 0x1000);
    try testing.expectEqual(Platform.base(), first.virtual);
    try testing.expectEqual(@as(u64, 0x1000), first.length);

    const second = try bar.view(0x1000, 0x40);
    try testing.expectEqual(Platform.base() + 0x1000, second.virtual);
    try testing.expectEqual(@as(u64, 0x40), second.length);
    try testing.expectEqual(@as(usize, 0), second.pages);

    // A visao nao passa do que foi mapeado.
    try testing.expectError(error.OutOfRange, bar.view(0x1000, 0x1001));
    try testing.expectError(error.OutOfRange, bar.view(0x2000, 0x1));
    try testing.expectError(error.Overflow, bar.view(std.math.maxInt(u64), 0x10));
    try testing.expectError(error.EmptyRegion, bar.view(0, 0));

    // Uma visao escreve no mesmo lugar que a faixa de origem.
    try second.write32(0x00, 0xCAFE_F00D);
    try testing.expectEqual(@as(u32, 0xCAFE_F00D), try bar.read32(0x1000));
}
