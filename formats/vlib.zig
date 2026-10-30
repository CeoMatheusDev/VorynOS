//************************************************************************//
//  vlib.zig                                                              //
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

//! VLIB — Voryn Library (`.vlb`), the container of a native library.
//!
//! O formato é o irmão do VEX (executável) e do VPK (pacote): um arquivo
//! único, explicitamente little-endian, que carrega uma **imagem de
//! biblioteca** — um ELF64 relocável — com o nome da biblioteca, os símbolos
//! que ela exporta, a ABI de sistema de chamadas para a qual foi construída e
//! as capabilities que ela exige.
//!
//! ```text
//! +------------------+  offset 0
//! | cabeçalho (64 B) |  magic, versão, geometria, ABI, capabilities e CRCs
//! +------------------+  offset 64 (symbol_table_offset)
//! | registros (N*24) |  nome, binding, tipo e valor de cada símbolo
//! | nomes            |  nomes dos símbolos, consecutivos
//! | nome da lib      |  os últimos `name_len` bytes da região da tabela
//! +------------------+  offset image_offset = 64 + símbolos + nomes + nome
//! | imagem           |  o ELF64 relocável, byte a byte
//! +------------------+
//! ```
//!
//! Duas somas de verificação, porque as duas falhas são diferentes:
//!
//!   * `image_crc32` cobre os **bytes de código** da biblioteca. É a parte
//!     perigosa: um único byte trocado muda o que a biblioteca faz;
//!   * `symbol_table_crc32` cobre os registros de símbolos, os nomes dos
//!     símbolos e o nome da biblioteca. Sem ela, um deslocamento de nome
//!     corrompido poderia apontar para uma região válida e o export errado
//!     passaria na validação de limites.
//!
//! O codec é **puro**: não faz syscalls, não aloca e não faz I/O. O
//! armazenamento do arquivo fica com o RamFS/VFSX, e a política de carregar
//! ou não a biblioteca fica com o kernel — este módulo só diz o que o arquivo
//! contém e se ele está íntegro.

const std = @import("std");

/// `"VLB1"` em little endian.
pub const magic: u32 = 0x564C_4231;
pub const version: u16 = 1;
pub const header_size: usize = 64;
pub const symbol_record_size: usize = 24;
pub const max_symbols: usize = 4096;
pub const max_name_len: usize = 255;
pub const max_library_name_len: usize = 64;

/// Bandeiras do cabeçalho.
pub const Flags = struct {
    /// A imagem é posição-independente e pode ser carregada em qualquer
    /// janela alinhada. Sem esta bandeira, o carregador não deve realocar a
    /// imagem.
    pub const relocatable: u32 = 1 << 0;
};

/// Visibilidade de um símbolo.
pub const Binding = enum(u8) {
    /// O símbolo faz parte da interface da biblioteca.
    exported = 0,
    /// O símbolo é interno; não é oferecido a quem liga contra a biblioteca.
    hidden = 1,
};

/// Natureza do símbolo.
pub const Kind = enum(u8) {
    function = 0,
    object = 1,
};

pub const Error = error{
    /// O buffer de saída não cabe o arquivo.
    BufferTooSmall,
    /// O arquivo é menor que o cabeçalho ou não termina onde a geometria diz.
    InvalidSize,
    /// O magic não é "VLB1".
    InvalidMagic,
    /// A versão do formato não é suportada.
    UnsupportedVersion,
    /// `header_size`, o alinhamento ou a geometria da tabela são inválidos.
    InvalidHeader,
    /// O nome da biblioteca ou de um símbolo é vazio, longo ou inválido.
    InvalidName,
    /// Dois símbolos exportados com o mesmo nome.
    DuplicateName,
    /// O binding ou o tipo de um símbolo é desconhecido.
    InvalidKind,
    /// Um campo aponta para fora do arquivo.
    OutOfBounds,
    /// O CRC da imagem ou da tabela não confere.
    ChecksumMismatch,
    /// O símbolo pedido não existe entre os exportados.
    SymbolNotFound,
    /// Uma soma de tamanhos estourou.
    Overflow,
};

/// Símbolo de entrada da operação de empacotamento.
pub const SymbolSource = struct {
    name: []const u8,
    binding: Binding = .exported,
    kind: Kind = .function,
    /// Deslocamento do símbolo dentro da imagem.
    value: u64,
};

/// Opções do empacotamento.
pub const Options = struct {
    /// Nome da biblioteca, sem diretório nem extensão (`libvoryn`).
    name: []const u8,
    /// Versão da ABI de sistema de chamadas para a qual a imagem foi
    /// construída. Um kernel que não a suporte deve recusar a biblioteca.
    abi_version: u32,
    /// Máscara das capabilities exigidas, com o bit `k` para o kind `k`.
    required_capabilities: u64 = 0,
    /// Bandeiras de `Flags`.
    flags: u32 = Flags.relocatable,
    symbols: []const SymbolSource,
    /// Bytes do ELF64 relocável.
    image: []const u8,
};

/// Visão validada do arquivo. Os slices apontam para o buffer recebido.
pub const Info = struct {
    /// Nome da biblioteca, sem `NUL`.
    name: []const u8,
    abi_version: u32,
    required_capabilities: u64,
    flags: u32,
    symbol_count: usize,
    /// Bytes do ELF64 embutido.
    image: []const u8,
    /// O arquivo inteiro, do cabeçalho ao último byte da imagem.
    total_size: usize,
};

/// Visão de um símbolo do arquivo.
pub const Symbol = struct {
    name: []const u8,
    binding: Binding,
    kind: Kind,
    value: u64,
};

fn put16(out: []u8, offset: usize, value: u16) void {
    out[offset] = @truncate(value);
    out[offset + 1] = @truncate(value >> 8);
}

fn put32(out: []u8, offset: usize, value: u32) void {
    put16(out, offset, @truncate(value));
    put16(out, offset + 2, @truncate(value >> 16));
}

fn put64(out: []u8, offset: usize, value: u64) void {
    put32(out, offset, @truncate(value));
    put32(out, offset + 4, @truncate(value >> 32));
}

fn get16(input: []const u8, offset: usize) u16 {
    return @as(u16, input[offset]) | (@as(u16, input[offset + 1]) << 8);
}

fn get32(input: []const u8, offset: usize) u32 {
    return @as(u32, get16(input, offset)) | (@as(u32, get16(input, offset + 2)) << 16);
}

fn get64(input: []const u8, offset: usize) u64 {
    return @as(u64, get32(input, offset)) | (@as(u64, get32(input, offset + 4)) << 32);
}

/// Um nome de símbolo é um identificador técnico: sem `NUL`, sem `/`, sem
/// espaço e sem caractere de controle. A regra existe para que o nome possa
/// ser usado como chave e como caminho sem nova validação.
fn validSymbolName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |character| {
        if (character < 0x21 or character > 0x7E) return false;
        if (character == '/') return false;
    }
    return true;
}

/// O nome da biblioteca aceita o mesmo alfabeto do nome de símbolo, com o
/// limite próprio.
fn validLibraryName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_library_name_len) return false;
    return validSymbolName(name);
}

/// A conversão é explícita em vez de derivada do enum: a lista de valores
/// aceitos faz parte do formato, e um valor novo no enum não deve passar a
/// ser aceito sem uma decisão sobre o formato.
fn bindingFromByte(value: u8) Error!Binding {
    return switch (value) {
        0 => .exported,
        1 => .hidden,
        else => error.InvalidKind,
    };
}

fn kindFromByte(value: u8) Error!Kind {
    return switch (value) {
        0 => .function,
        1 => .object,
        else => error.InvalidKind,
    };
}

fn namesTotal(symbols: []const SymbolSource) usize {
    var total: usize = 0;
    for (symbols) |symbol| total += symbol.name.len;
    return total;
}

/// Tamanho exato do arquivo que `pack` produz.
pub fn packedSize(options: Options) Error!usize {
    if (!validLibraryName(options.name)) return error.InvalidName;
    if (options.symbols.len > max_symbols) return error.Overflow;
    if (options.image.len == 0) return error.InvalidSize;

    const table: u64 = @as(u64, options.symbols.len) * symbol_record_size +
        namesTotal(options.symbols) + options.name.len;
    const total = std.math.add(u64, header_size, table) catch return error.Overflow;
    const full = std.math.add(u64, total, options.image.len) catch return error.Overflow;
    if (full > std.math.maxInt(usize)) return error.Overflow;
    return @intCast(full);
}

/// Empacota a biblioteca e devolve o número de bytes escritos.
pub fn pack(options: Options, out: []u8) Error!usize {
    const total = try packedSize(options);
    if (out.len < total) return error.BufferTooSmall;

    // A tabela é validada antes de escrever qualquer byte: um erro no meio do
    // empacotamento deixaria um arquivo parcial no buffer do chamador.
    var seen: [max_symbols][]const u8 = undefined;
    for (options.symbols, 0..) |symbol, index| {
        if (!validSymbolName(symbol.name)) return error.InvalidName;
        if (symbol.binding == .exported) {
            for (seen[0..index]) |previous| {
                if (std.mem.eql(u8, previous, symbol.name)) return error.DuplicateName;
            }
            seen[index] = symbol.name;
        } else {
            seen[index] = "";
        }
    }

    @memset(out[0..total], 0);

    const table_offset: usize = header_size;
    const names_offset: usize = table_offset + options.symbols.len * symbol_record_size;
    const name_offset: usize = names_offset + namesTotal(options.symbols);
    const image_offset: usize = name_offset + options.name.len;

    put32(out, 0, magic);
    put16(out, 4, version);
    put16(out, 6, @intCast(header_size));
    put16(out, 8, @intCast(options.symbols.len));
    put16(out, 10, @intCast(options.name.len));
    put32(out, 12, options.abi_version);
    put32(out, 16, options.flags);
    put32(out, 20, 0);
    put64(out, 24, options.required_capabilities);
    put64(out, 32, @intCast(table_offset));
    put64(out, 40, @intCast(image_offset));
    put64(out, 48, @intCast(options.image.len));

    var name_cursor: usize = names_offset;
    for (options.symbols, 0..) |symbol, index| {
        const record = table_offset + index * symbol_record_size;
        put64(out, record, @intCast(name_cursor - names_offset));
        put16(out, record + 8, @intCast(symbol.name.len));
        out[record + 10] = @backingInt(symbol.binding);
        out[record + 11] = @backingInt(symbol.kind);
        put64(out, record + 16, symbol.value);
        @memcpy(out[name_cursor .. name_cursor + symbol.name.len], symbol.name);
        name_cursor += symbol.name.len;
    }
    @memcpy(out[name_offset .. name_offset + options.name.len], options.name);
    @memcpy(out[image_offset..total], options.image);

    put32(out, 56, std.hash.Crc32.hash(out[image_offset..total]));
    put32(out, 20, std.hash.Crc32.hash(out[table_offset..image_offset]));

    return total;
}

/// Valida o arquivo e devolve a visão das suas partes.
pub fn validate(bytes: []const u8) Error!Info {
    if (bytes.len < header_size) return error.InvalidSize;
    if (get32(bytes, 0) != magic) return error.InvalidMagic;
    if (get16(bytes, 4) != version) return error.UnsupportedVersion;
    if (get16(bytes, 6) != header_size) return error.InvalidHeader;

    const symbol_count = get16(bytes, 8);
    const name_len = get16(bytes, 10);
    const abi_version = get32(bytes, 12);
    const flags = get32(bytes, 16);
    const table_crc = get32(bytes, 20);
    const required_capabilities = get64(bytes, 24);
    const table_offset = get64(bytes, 32);
    const image_offset = get64(bytes, 40);
    const image_size = get64(bytes, 48);
    const image_crc = get32(bytes, 56);

    if (symbol_count > max_symbols) return error.InvalidHeader;
    if (name_len == 0 or name_len > max_library_name_len) return error.InvalidName;
    if (table_offset != header_size) return error.InvalidHeader;

    // A imagem termina exatamente no fim do arquivo: bytes sobrando são
    // recusados, porque um anexo depois da imagem passaria sem ser lido.
    const expected = std.math.add(u64, image_offset, image_size) catch return error.Overflow;
    if (expected != bytes.len) return error.InvalidSize;
    if (image_size == 0) return error.InvalidSize;

    const names_start = std.math.add(u64, table_offset, @as(u64, symbol_count) * symbol_record_size) catch
        return error.Overflow;
    if (names_start > image_offset) return error.OutOfBounds;
    // O nome da biblioteca ocupa o fim da região da tabela.
    if (image_offset - @as(u64, name_len) < names_start) return error.OutOfBounds;
    const library_name_end: usize = @intCast(image_offset);
    const library_name_start = library_name_end - name_len;

    const table_slice = bytes[@intCast(table_offset)..@intCast(image_offset)];
    if (std.hash.Crc32.hash(table_slice) != table_crc) return error.ChecksumMismatch;

    const name = bytes[library_name_start..library_name_end];
    if (!validLibraryName(name)) return error.InvalidName;

    const image_start: usize = @intCast(image_offset);
    const image = bytes[image_start..];
    if (std.hash.Crc32.hash(image) != image_crc) return error.ChecksumMismatch;

    // Os registros são validados depois dos CRCs: um registro corrompido que
    // ainda caiba nos limites seria aceito se a checagem viesse antes.
    var index: usize = 0;
    while (index < symbol_count) : (index += 1) {
        const record = @as(usize, @intCast(table_offset)) + index * symbol_record_size;
        const name_offset = get64(bytes, record);
        const symbol_name_len = get16(bytes, record + 8);
        _ = try bindingFromByte(bytes[record + 10]);
        _ = try kindFromByte(bytes[record + 11]);

        if (symbol_name_len == 0 or symbol_name_len > max_name_len) return error.InvalidName;
        const absolute = std.math.add(u64, names_start, name_offset) catch return error.Overflow;
        const end = std.math.add(u64, absolute, symbol_name_len) catch return error.Overflow;
        if (end > library_name_start) return error.OutOfBounds;
        if (!validSymbolName(bytes[@intCast(absolute)..@intCast(end)])) return error.InvalidName;
    }

    return .{
        .name = name,
        .abi_version = abi_version,
        .required_capabilities = required_capabilities,
        .flags = flags,
        .symbol_count = symbol_count,
        .image = image,
        .total_size = bytes.len,
    };
}

/// Lê o símbolo `index` do arquivo já validado.
pub fn symbolAt(bytes: []const u8, info: Info, index: usize) Error!Symbol {
    if (index >= info.symbol_count) return error.SymbolNotFound;

    const table_offset: usize = @intCast(get64(bytes, 32));
    const names_start = table_offset + info.symbol_count * symbol_record_size;
    const record = table_offset + index * symbol_record_size;
    const name_offset = get64(bytes, record);
    const symbol_name_len = get16(bytes, record + 8);
    const start: usize = @intCast(@as(u64, names_start) + name_offset);

    return .{
        .name = bytes[start .. start + symbol_name_len],
        .binding = try bindingFromByte(bytes[record + 10]),
        .kind = try kindFromByte(bytes[record + 11]),
        .value = get64(bytes, record + 16),
    };
}

/// Procura um símbolo **exportado** pelo nome. Um símbolo interno não é
/// encontrado: a procura é a operação de quem liga contra a biblioteca.
pub fn findExport(bytes: []const u8, name: []const u8) Error!Symbol {
    const info = try validate(bytes);
    var index: usize = 0;
    while (index < info.symbol_count) : (index += 1) {
        const symbol = try symbolAt(bytes, info, index);
        if (symbol.binding != .exported) continue;
        if (std.mem.eql(u8, symbol.name, name)) return symbol;
    }
    return error.SymbolNotFound;
}

test "pack and validate round trip the library" {
    const image = "not-an-elf-but-opaque";
    const symbols = [_]SymbolSource{
        .{ .name = "voryn_main", .value = 0x1000 },
        .{ .name = "voryn_init", .value = 0x0000 },
        .{ .name = "internal", .binding = .hidden, .value = 0x1100 },
    };
    const options = Options{
        .name = "libvoryn",
        .abi_version = 13,
        .required_capabilities = 1 << 2,
        .symbols = &symbols,
        .image = image,
    };

    var buffer: [512]u8 = @splat(0);
    const written = try pack(options, &buffer);
    try std.testing.expectEqual(try packedSize(options), written);

    const info = try validate(buffer[0..written]);
    try std.testing.expectEqualStrings("libvoryn", info.name);
    try std.testing.expectEqual(@as(u32, 13), info.abi_version);
    try std.testing.expectEqual(@as(u64, 1 << 2), info.required_capabilities);
    try std.testing.expectEqual(@as(usize, 3), info.symbol_count);
    try std.testing.expectEqualStrings(image, info.image);
    try std.testing.expectEqual(written, info.total_size);
    try std.testing.expect(info.flags & Flags.relocatable != 0);

    const main = try findExport(buffer[0..written], "voryn_main");
    try std.testing.expectEqual(@as(u64, 0x1000), main.value);
    try std.testing.expectEqual(Kind.function, main.kind);
    try std.testing.expectEqual(Binding.exported, main.binding);

    // O símbolo interno existe na tabela e não é encontrado pela procura.
    const hidden = try symbolAt(buffer[0..written], info, 2);
    try std.testing.expectEqual(Binding.hidden, hidden.binding);
    try std.testing.expectError(error.SymbolNotFound, findExport(buffer[0..written], "internal"));
    try std.testing.expectError(error.SymbolNotFound, findExport(buffer[0..written], "absent"));
}

test "the packing is deterministic" {
    const symbols = [_]SymbolSource{.{ .name = "sym", .value = 7 }};
    const options = Options{ .name = "lib", .abi_version = 13, .symbols = &symbols, .image = "0123456789" };

    var first: [128]u8 = @splat(0);
    var second: [128]u8 = @splat(0);
    const a = try pack(options, &first);
    const b = try pack(options, &second);

    try std.testing.expectEqual(a, b);
    try std.testing.expectEqualSlices(u8, first[0..a], second[0..b]);
}

test "a corrupted image is refused" {
    const symbols = [_]SymbolSource{.{ .name = "sym", .value = 0 }};
    const options = Options{ .name = "lib", .abi_version = 13, .symbols = &symbols, .image = "code-bytes" };

    var buffer: [128]u8 = @splat(0);
    const written = try pack(options, &buffer);

    var corrupted: [128]u8 = undefined;
    @memcpy(corrupted[0..written], buffer[0..written]);
    corrupted[written - 1] ^= 0xff;

    try std.testing.expectError(error.ChecksumMismatch, validate(corrupted[0..written]));
}

test "a corrupted symbol table is refused" {
    const symbols = [_]SymbolSource{.{ .name = "sym", .value = 0 }};
    const options = Options{ .name = "lib", .abi_version = 13, .symbols = &symbols, .image = "code" };

    var buffer: [128]u8 = @splat(0);
    const written = try pack(options, &buffer);

    // Troca um byte do nome do símbolo sem tocar no CRC da tabela.
    var corrupted: [128]u8 = undefined;
    @memcpy(corrupted[0..written], buffer[0..written]);
    corrupted[header_size + symbol_record_size] = 'x';

    try std.testing.expectError(error.ChecksumMismatch, validate(corrupted[0..written]));
}

test "the magic, the version and the size are validated" {
    const symbols = [_]SymbolSource{.{ .name = "sym", .value = 0 }};
    const options = Options{ .name = "lib", .abi_version = 13, .symbols = &symbols, .image = "code" };

    var buffer: [128]u8 = @splat(0);
    const written = try pack(options, &buffer);

    var wrong_magic: [128]u8 = undefined;
    @memcpy(wrong_magic[0..written], buffer[0..written]);
    wrong_magic[0] = 0;
    try std.testing.expectError(error.InvalidMagic, validate(wrong_magic[0..written]));

    var wrong_version: [128]u8 = undefined;
    @memcpy(wrong_version[0..written], buffer[0..written]);
    wrong_version[4] = 9;
    try std.testing.expectError(error.UnsupportedVersion, validate(wrong_version[0..written]));

    try std.testing.expectError(error.InvalidSize, validate(buffer[0 .. header_size - 1]));

    // Um byte a mais depois da imagem passa a ser recusado.
    var longer: [128]u8 = @splat(0);
    @memcpy(longer[0..written], buffer[0..written]);
    try std.testing.expectError(error.InvalidSize, validate(longer[0 .. written + 1]));
}

test "a duplicate exported name is refused and a hidden one is not" {
    const duplicated = [_]SymbolSource{
        .{ .name = "same", .value = 1 },
        .{ .name = "same", .value = 2 },
    };
    var buffer: [256]u8 = @splat(0);
    try std.testing.expectError(
        error.DuplicateName,
        pack(.{ .name = "lib", .abi_version = 13, .symbols = &duplicated, .image = "code" }, &buffer),
    );

    // Dois internos com o mesmo nome não são um conflito de interface.
    const hidden = [_]SymbolSource{
        .{ .name = "same", .binding = .hidden, .value = 1 },
        .{ .name = "same", .binding = .hidden, .value = 2 },
    };
    const written = try pack(.{ .name = "lib", .abi_version = 13, .symbols = &hidden, .image = "code" }, &buffer);
    try std.testing.expect(written > header_size);
}

test "invalid names are refused at packing" {
    var buffer: [256]u8 = @splat(0);
    const symbols = [_]SymbolSource{.{ .name = "ok", .value = 0 }};

    try std.testing.expectError(
        error.InvalidName,
        pack(.{ .name = "", .abi_version = 13, .symbols = &symbols, .image = "code" }, &buffer),
    );
    try std.testing.expectError(
        error.InvalidName,
        pack(.{ .name = "lib/name", .abi_version = 13, .symbols = &symbols, .image = "code" }, &buffer),
    );

    const bad_symbol = [_]SymbolSource{.{ .name = "with space", .value = 0 }};
    try std.testing.expectError(
        error.InvalidName,
        pack(.{ .name = "lib", .abi_version = 13, .symbols = &bad_symbol, .image = "code" }, &buffer),
    );
}

test "a small buffer and an empty image are refused" {
    const symbols = [_]SymbolSource{.{ .name = "sym", .value = 0 }};
    var small: [8]u8 = @splat(0);

    try std.testing.expectError(
        error.BufferTooSmall,
        pack(.{ .name = "lib", .abi_version = 13, .symbols = &symbols, .image = "code" }, &small),
    );
    try std.testing.expectError(
        error.InvalidSize,
        pack(.{ .name = "lib", .abi_version = 13, .symbols = &symbols, .image = "" }, &small),
    );
}

test "a library without symbols is valid" {
    var buffer: [128]u8 = @splat(0);
    const written = try pack(.{
        .name = "libempty",
        .abi_version = 13,
        .symbols = &.{},
        .image = "code",
    }, &buffer);

    const info = try validate(buffer[0..written]);
    try std.testing.expectEqual(@as(usize, 0), info.symbol_count);
    try std.testing.expectEqualStrings("libempty", info.name);
    try std.testing.expectEqualStrings("code", info.image);
}
