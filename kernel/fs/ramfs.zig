//************************************************************************//
//  ramfs.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Sistema de arquivos em memória (RamFS).
//!
//! O RamFS usa uma área contígua de RAM como armazenamento. Os dados
//! existem apenas enquanto o sistema está ligado, e o módulo é puro: ele
//! não depende de hardware, de alocador dinâmico nem de syscalls, e por
//! isso roda tanto no kernel quanto nos testes de host.
//!
//! Layout:
//!
//!   * 256 blocos de 4 KiB (1 MiB no total), numerados de 0 a 255;
//!   * o bloco 0 é reservado para o superbloco e nunca é entregue;
//!   * o bitmap tem um bit por bloco, com 1 significando **usado**;
//!   * 32 inodes, numerados de 0 a 31; o inode 0 é o diretório raiz;
//!   * cada inode aponta para até 12 blocos diretos (48 KiB por arquivo);
//!   * uma tabela fixa de entradas de diretório guarda nome, pai e inode.
//!
//! Limitações deliberadas desta etapa:
//!
//!   * não há blocos indiretos, portanto o tamanho máximo é 48 KiB;
//!   * não há caches de bloco, journaling ou persistência;
//!   * o diretório é uma tabela fixa de 64 entradas por sistema, e não um
//!     arquivo com blocos próprios;
//!   * não existem entradas `.` e `..`; o caminho `..` é recusado.

const std = @import("std");
const inode = @import("./inode.zig");
const superblock = @import("./superblock.zig");

/// Tamanho de um bloco do RamFS, em bytes.
pub const block_size: usize = 4096;

/// Número de blocos do RamFS.
pub const block_count: usize = 256;

/// Tamanho total do RamFS, em bytes.
pub const total_size: usize = block_count * block_size;

/// Número de inodes do RamFS.
pub const inode_count: usize = 32;

/// Número de entradas de diretório do RamFS.
pub const dir_entry_count: usize = 64;

/// Comprimento máximo de um componente de caminho.
pub const max_name_len: usize = 64;

/// Número de blocos diretos de um inode.
pub const direct_blocks: usize = 12;

/// Tamanho máximo de um arquivo, em bytes.
pub const max_file_size: usize = direct_blocks * block_size;

/// Inode do diretório raiz.
pub const root_inode: u32 = 0;

/// Erros do RamFS.
pub const Error = error{
    /// O número do inode não existe.
    InvalidInode,
    /// O inode existe, mas não é um arquivo.
    NotAFile,
    /// O inode existe, mas não é um diretório.
    NotADirectory,
    /// O nome é vazio, longo demais ou contém um separador.
    InvalidName,
    /// Já existe uma entrada com o mesmo nome no diretório.
    NameExists,
    /// A entrada de diretório não existe.
    EntryNotFound,
    /// O diretório não tem mais entradas livres.
    DirectoryFull,
    /// Não há blocos livres.
    NoSpace,
    /// Não há inodes livres.
    NoFreeInode,
    /// O arquivo passar do limite de blocos diretos.
    FileTooLarge,
    /// O deslocamento não pertence ao arquivo.
    InvalidOffset,
    /// O caminho é vazio, relativo de forma inválida ou usa `..`.
    InvalidPath,
    /// O buffer fornecido é pequeno demais para a lista.
    BufferTooSmall,
};

/// Entrada da tabela de diretórios.
const DirEntry = struct {
    used: bool = false,
    parent: u32 = 0,
    inode: u32 = 0,
    name: [max_name_len]u8 = @splat(0),
    name_len: u8 = 0,
};

/// Visão de uma entrada de diretório entregue por `listDir`.
pub const DirEntryInfo = struct {
    inode: u32,
    kind: inode.InodeType,
    name: []const u8,
};

/// Área de armazenamento do RamFS.
var memory: [total_size]u8 = undefined;

/// Bitmap de blocos, com 1 significando usado.
var block_bitmap: [block_count / 8]u8 = undefined;

/// Tabela de inodes.
var inodes: [inode_count]inode.InodeOnDisk = undefined;

/// Tabela de entradas de diretório.
var dir_entries: [dir_entry_count]DirEntry = undefined;

/// Inicializa o RamFS e apaga todo o conteúdo anterior.
pub fn init() void {
    @memset(memory[0..], 0);
    @memset(block_bitmap[0..], 0);

    for (&inodes) |*entry| {
        entry.* = .{
            .i_type = .file,
            .i_permissions = 0o755,
            .i_links_count = 0,
            .i_size = 0,
            .i_block = @splat(0),
        };
    }

    for (&dir_entries) |*entry| {
        entry.* = .{};
    }

    // O bloco 0 é o superbloco: ele nunca é entregue a um arquivo.
    setBlockUsed(0, true);

    // O inode 0 é o diretório raiz. O contador de links funciona como
    // marcador de inode ocupado: zero significa livre.
    inodes[root_inode] = .{
        .i_type = .directory,
        .i_permissions = 0o755,
        .i_links_count = 1,
        .i_size = 0,
        .i_block = @splat(0),
    };
}

/// Verdadeiro quando o bloco está marcado como usado.
fn blockUsed(block: usize) bool {
    const mask = @as(u8, 1) << @intCast(block % 8);
    return block_bitmap[block / 8] & mask != 0;
}

/// Marca ou desmarca um bloco.
fn setBlockUsed(block: usize, used: bool) void {
    const mask = @as(u8, 1) << @intCast(block % 8);
    if (used) {
        block_bitmap[block / 8] |= mask;
    } else {
        block_bitmap[block / 8] &= ~mask;
    }
}

/// Aloca um bloco e devolve o número dele, ou `null` quando não há bloco
/// livre. O conteúdo do bloco é zerado.
pub fn allocateBlock() ?u32 {
    var index: usize = 1; // o bloco 0 é o superbloco
    while (index < block_count) : (index += 1) {
        if (blockUsed(index)) continue;
        setBlockUsed(index, true);
        @memset(memory[index * block_size ..][0..block_size], 0);
        return @as(u32, @intCast(index));
    }
    return null;
}

/// Libera um bloco. Devolve `false` quando o número é inválido, quando o
/// bloco é reservado ou quando ele já estava livre.
pub fn freeBlock(block: u32) bool {
    const index: usize = block;
    if (index == 0 or index >= block_count) return false;
    if (!blockUsed(index)) return false;

    setBlockUsed(index, false);
    @memset(memory[index * block_size ..][0..block_size], 0);
    return true;
}

/// Número de blocos livres.
pub fn freeBlockCount() usize {
    var count: usize = 0;
    for (0..block_count) |index| {
        if (!blockUsed(index)) count += 1;
    }
    return count;
}

/// Número de inodes livres.
pub fn freeInodeCount() usize {
    var count: usize = 0;
    for (inodes) |entry| {
        if (entry.i_links_count == 0) count += 1;
    }
    return count;
}

/// Devolve o tipo do inode, ou `null` quando o inode está livre.
pub fn inodeKind(inode_num: u32) ?inode.InodeType {
    if (inode_num >= inode_count) return null;
    const entry = inodes[inode_num];
    if (entry.i_links_count == 0) return null;
    return entry.i_type;
}

/// Aloca um inode do tipo pedido.
fn allocateInode(kind: inode.InodeType) Error!u32 {
    for (&inodes, 0..) |*entry, index| {
        if (entry.i_links_count != 0) continue;
        entry.* = .{
            .i_type = kind,
            .i_permissions = 0o755,
            .i_links_count = 1,
            .i_size = 0,
            .i_block = @splat(0),
        };
        return @as(u32, @intCast(index));
    }
    return error.NoFreeInode;
}

/// Libera um inode e todos os blocos dele.
fn releaseInode(inode_num: u32) void {
    if (inode_num >= inode_count) return;
    const entry = &inodes[inode_num];
    for (entry.i_block) |block| {
        if (block != 0) _ = freeBlock(@as(u32, @intCast(block)));
    }
    entry.* = .{
        .i_type = .file,
        .i_permissions = 0o755,
        .i_links_count = 0,
        .i_size = 0,
        .i_block = @splat(0),
    };
}

/// Verdadeiro quando o nome pode ser usado como componente de caminho.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        if (byte == '/' or byte == 0) return false;
    }
    return true;
}

/// Procura uma entrada pelo nome dentro de um diretório.
pub fn lookup(parent: u32, name: []const u8) ?u32 {
    if (parent >= inode_count) return null;
    for (dir_entries) |entry| {
        if (!entry.used) continue;
        if (entry.parent != parent) continue;
        if (std.mem.eql(u8, entry.name[0..entry.name_len], name)) return entry.inode;
    }
    return null;
}

/// Adiciona uma entrada de diretório. O inode já tem de existir.
pub fn addDirEntry(parent: u32, name: []const u8, inode_num: u32) Error!void {
    if (inodeKind(parent) != .directory) return error.NotADirectory;
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (!validName(name)) return error.InvalidName;
    if (lookup(parent, name) != null) return error.NameExists;

    for (&dir_entries) |*entry| {
        if (entry.used) continue;
        entry.used = true;
        entry.parent = parent;
        entry.inode = inode_num;
        entry.name_len = @as(u8, @intCast(name.len));
        @memset(entry.name[0..], 0);
        @memcpy(entry.name[0..name.len], name);
        return;
    }

    return error.DirectoryFull;
}

/// Cria um arquivo vazio dentro de um diretório.
pub fn createFile(parent: u32, name: []const u8) Error!u32 {
    if (inodeKind(parent) != .directory) return error.NotADirectory;
    if (!validName(name)) return error.InvalidName;
    if (lookup(parent, name) != null) return error.NameExists;

    const inode_num = try allocateInode(.file);
    errdefer releaseInode(inode_num);

    try addDirEntry(parent, name, inode_num);
    return inode_num;
}

/// Cria um diretório vazio dentro de um diretório.
pub fn createDirectory(parent: u32, name: []const u8) Error!u32 {
    if (inodeKind(parent) != .directory) return error.NotADirectory;
    if (!validName(name)) return error.InvalidName;
    if (lookup(parent, name) != null) return error.NameExists;

    const inode_num = try allocateInode(.directory);
    errdefer releaseInode(inode_num);

    try addDirEntry(parent, name, inode_num);
    return inode_num;
}

/// Resolve um caminho absoluto (ou relativo à raiz) e devolve o inode.
///
/// Componentes vazios e `.` são ignorados. O componente `..` é recusado,
/// porque o RamFS ainda não mantém a cadeia de diretórios pais de forma
/// segura para navegação.
pub fn resolvePath(path: []const u8) Error!u32 {
    if (path.len == 0) return error.InvalidPath;

    var current = root_inode;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |component| {
        if (component.len == 0) continue;
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
        if (inodeKind(current) != .directory) return error.NotADirectory;

        current = lookup(current, component) orelse return error.EntryNotFound;
    }

    return current;
}

/// Calcula quantos blocos um arquivo de `length` bytes ocupa.
fn blocksFor(length: usize) Error!usize {
    if (length > max_file_size) return error.FileTooLarge;
    if (length == 0) return 0;
    return (length + block_size - 1) / block_size;
}

/// Garante que o inode tenha pelo menos `required` blocos alocados.
fn ensureBlocks(inode_num: u32, required: usize) Error!void {
    if (required > direct_blocks) return error.FileTooLarge;

    var count: usize = 0;
    while (count < required) : (count += 1) {
        if (inodes[inode_num].i_block[count] != 0) continue;
        const block = allocateBlock() orelse return error.NoSpace;
        inodes[inode_num].i_block[count] = block;
    }
}

/// Libera todos os blocos de um inode e zera os ponteiros.
fn releaseBlocks(inode_num: u32) void {
    for (&inodes[inode_num].i_block) |*block| {
        if (block.* != 0) {
            _ = freeBlock(@as(u32, @intCast(block.*)));
            block.* = 0;
        }
    }
}

/// Substitui o conteúdo de um arquivo.
pub fn writeFile(inode_num: u32, data: []const u8) Error!void {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (inodes[inode_num].i_type != .file) return error.NotAFile;

    const required = try blocksFor(data.len);

    // Os blocos novos são alocados antes de os antigos serem liberados,
    // para que uma falha no meio do caminho não destrua o conteúdo atual.
    var new_blocks: [direct_blocks]u32 = @splat(0);
    var allocated: usize = 0;
    errdefer {
        for (new_blocks[0..allocated]) |block| {
            _ = freeBlock(block);
        }
    }

    while (allocated < required) : (allocated += 1) {
        new_blocks[allocated] = allocateBlock() orelse return error.NoSpace;
    }

    var offset: usize = 0;
    for (new_blocks[0..required]) |block| {
        const count = @min(block_size, data.len - offset);
        const start = @as(usize, block) * block_size;
        @memcpy(memory[start..][0..count], data[offset..][0..count]);
        offset += count;
    }

    releaseBlocks(inode_num);
    for (&inodes[inode_num].i_block, 0..) |*slot, index| {
        slot.* = if (index < required) new_blocks[index] else 0;
    }
    inodes[inode_num].i_size = data.len;
}

/// Escreve `data` em `offset`, sem apagar o restante do arquivo.
///
/// A escrita pode estender o arquivo; o espaço entre o fim antigo e o
/// início da escrita é preenchido com zero, porque os blocos novos já são
/// alocados zerados.
pub fn writeFileAt(inode_num: u32, offset: usize, data: []const u8) Error!usize {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (inodes[inode_num].i_type != .file) return error.NotAFile;
    if (data.len == 0) return 0;

    const end = std.math.add(usize, offset, data.len) catch return error.FileTooLarge;
    const required = try blocksFor(end);
    try ensureBlocks(inode_num, required);

    var source: usize = 0;
    var position: usize = offset;
    while (source < data.len) {
        const block_index = position / block_size;
        const inside = position % block_size;
        const count = @min(block_size - inside, data.len - source);
        const block = @as(usize, @intCast(inodes[inode_num].i_block[block_index]));
        @memcpy(
            memory[block * block_size + inside ..][0..count],
            data[source..][0..count],
        );
        source += count;
        position += count;
    }

    if (inodes[inode_num].i_size < end) inodes[inode_num].i_size = end;
    return data.len;
}

/// Encolhe um arquivo para `new_size` bytes.
pub fn truncate(inode_num: u32, new_size: usize) Error!void {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (inodes[inode_num].i_type != .file) return error.NotAFile;
    if (new_size > inodes[inode_num].i_size) return error.InvalidOffset;
    if (new_size > max_file_size) return error.FileTooLarge;

    const required = try blocksFor(new_size);
    var index = required;
    while (index < direct_blocks) : (index += 1) {
        const block = inodes[inode_num].i_block[index];
        if (block != 0) {
            _ = freeBlock(@as(u32, @intCast(block)));
            inodes[inode_num].i_block[index] = 0;
        }
    }

    // O restante do último bloco fica inacessível pelo tamanho, mas é
    // zerado para que uma futura extensão não exponha dados antigos.
    if (new_size % block_size != 0 and required > 0) {
        const block = @as(usize, @intCast(inodes[inode_num].i_block[required - 1]));
        const start = block * block_size + (new_size % block_size);
        @memset(memory[start..][0 .. block_size - (new_size % block_size)], 0);
    }

    inodes[inode_num].i_size = new_size;
}

/// Lê o arquivo a partir de `offset` para o buffer do chamador e devolve o
/// número de bytes lidos. O fim do arquivo devolve zero, como uma leitura
/// de sistema de arquivos.
pub fn readFileAt(inode_num: u32, offset: usize, buffer: []u8) Error!usize {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (inodes[inode_num].i_type != .file) return error.NotAFile;

    const size = @as(usize, @intCast(inodes[inode_num].i_size));
    if (offset >= size or buffer.len == 0) return 0;

    const count = @min(buffer.len, size - offset);
    var destination: usize = 0;
    var position: usize = offset;
    while (destination < count) {
        const block_index = position / block_size;
        const inside = position % block_size;
        const chunk = @min(block_size - inside, count - destination);
        const block = @as(usize, @intCast(inodes[inode_num].i_block[block_index]));
        @memcpy(
            buffer[destination..][0..chunk],
            memory[block * block_size + inside ..][0..chunk],
        );
        destination += chunk;
        position += chunk;
    }

    return count;
}

/// Lê o arquivo desde o início.
pub fn readFile(inode_num: u32, buffer: []u8) Error!usize {
    return readFileAt(inode_num, 0, buffer);
}

/// Lista as entradas de um diretório, sem `.` e `..`.
pub fn listDir(directory: u32, out: []DirEntryInfo) Error!usize {
    if (inodeKind(directory) != .directory) return error.NotADirectory;

    var count: usize = 0;
    for (&dir_entries) |*entry| {
        if (!entry.used) continue;
        if (entry.parent != directory) continue;
        if (count >= out.len) return error.BufferTooSmall;

        const target = inodeKind(entry.inode) orelse continue;
        out[count] = .{
            .inode = entry.inode,
            .kind = target,
            .name = entry.name[0..entry.name_len],
        };
        count += 1;
    }
    return count;
}

/// Tamanho de um arquivo, ou `null` quando o inode não é um arquivo.
pub fn sizeOf(inode_num: u32) ?u64 {
    if (inodeKind(inode_num) == null) return null;
    if (inodes[inode_num].i_type != .file) return null;
    return inodes[inode_num].i_size;
}

/// Informações do superbloco do RamFS.
pub fn getFsInfo() superblock.SuperblockOnDisk {
    return .{
        .magic = 0x56f2f6c5,
        .total_size = total_size,
        .block_size = block_size,
        .total_blocks = block_count,
        .total_inodes = inode_count,
        .inode_bitmap = 0,
        .block_bitmap = 0,
        .first_data_block = 1,
        .flags = 0,
        .version = @splat(0),
    };
}

/// Informações de um inode.
pub fn getInodeInfo(inode_num: u32) Error!inode.InodeOnDisk {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    return inodes[inode_num];
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "init leaves the root directory and the data blocks free" {
    init();

    try testing.expectEqual(@as(u32, root_inode), 0);
    try testing.expectEqual(inode.InodeType.directory, inodeKind(root_inode).?);
    try testing.expectEqual(block_count - 1, freeBlockCount());
    try testing.expectEqual(inode_count - 1, freeInodeCount());

    const info = getFsInfo();
    try testing.expectEqual(@as(u64, total_size), info.total_size);
    try testing.expectEqual(@as(u64, block_count), info.total_blocks);
    try testing.expectEqual(@as(u64, inode_count), info.total_inodes);
}

test "block allocator round trip and exhaustion" {
    init();

    var allocated: [block_count - 1]u32 = undefined;
    var count: usize = 0;
    while (count < allocated.len) : (count += 1) {
        allocated[count] = allocateBlock() orelse return error.TestUnexpectedResult;
    }

    try testing.expectEqual(@as(usize, 0), freeBlockCount());
    try testing.expect(allocateBlock() == null);

    // O bloco 0 é reservado e não pode ser liberado.
    try testing.expect(!freeBlock(0));
    try testing.expect(freeBlock(allocated[0]));
    try testing.expect(!freeBlock(allocated[0]));
    try testing.expectEqual(@as(usize, 1), freeBlockCount());

    const recovered = allocateBlock() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(allocated[0], recovered);
    try testing.expectEqual(@as(usize, 0), freeBlockCount());

    for (allocated) |block| {
        try testing.expect(freeBlock(block));
    }
    try testing.expectEqual(block_count - 1, freeBlockCount());
}

test "files keep distinct contents and overwrite releases blocks" {
    init();

    const first = try createFile(root_inode, "first.bin");
    const second = try createFile(root_inode, "second.bin");

    var content: [5000]u8 = undefined;
    for (&content, 0..) |*byte, index| byte.* = @as(u8, @intCast(index % 251));

    try writeFile(first, &content);
    try testing.expectEqual(@as(u64, content.len), sizeOf(first).?);
    try testing.expectEqual(@as(usize, block_count - 1 - 2), freeBlockCount());

    try writeFile(second, "second");
    try testing.expectEqual(@as(usize, block_count - 1 - 3), freeBlockCount());

    var read_back: [5000]u8 = undefined;
    const read_count = try readFile(first, &read_back);
    try testing.expectEqual(content.len, read_count);
    try testing.expectEqualSlices(u8, &content, read_back[0..read_count]);

    // Uma sobrescrita menor libera o bloco que não é mais usado.
    try writeFile(first, "first");
    try testing.expectEqual(@as(usize, block_count - 1 - 2), freeBlockCount());

    var second_back: [8]u8 = undefined;
    const second_count = try readFile(second, &second_back);
    try testing.expectEqualSlices(u8, "second", second_back[0..second_count]);

    try testing.expectError(error.NotAFile, readFile(root_inode, &read_back));
}

test "read at an offset and at the end of the file" {
    init();

    const file = try createFile(root_inode, "offset.txt");
    try writeFile(file, "0123456789");

    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try readFileAt(file, 0, &buffer));
    try testing.expectEqualSlices(u8, "0123", &buffer);

    try testing.expectEqual(@as(usize, 4), try readFileAt(file, 3, &buffer));
    try testing.expectEqualSlices(u8, "3456", &buffer);

    try testing.expectEqual(@as(usize, 2), try readFileAt(file, 8, &buffer));
    try testing.expectEqualSlices(u8, "89", buffer[0..2]);

    try testing.expectEqual(@as(usize, 0), try readFileAt(file, 10, &buffer));
    try testing.expectEqual(@as(usize, 0), try readFileAt(file, 99, &buffer));
}

test "append extends the file and keeps the previous bytes" {
    init();

    const file = try createFile(root_inode, "append.txt");
    try writeFile(file, "hello");
    try testing.expectEqual(@as(usize, 6), try writeFileAt(file, 5, " world"));
    try testing.expectEqual(@as(u64, 11), sizeOf(file).?);

    var buffer: [16]u8 = undefined;
    const count = try readFile(file, &buffer);
    try testing.expectEqualSlices(u8, "hello world", buffer[0..count]);

    try testing.expectEqual(@as(usize, 1), try writeFileAt(file, 0, "H"));
    const updated = try readFile(file, &buffer);
    try testing.expectEqualSlices(u8, "Hello world", buffer[0..updated]);
}

test "directory lookup, nesting and listing" {
    init();

    const docs = try createDirectory(root_inode, "docs");
    const readme = try createFile(docs, "readme.txt");
    try writeFile(readme, "vorynos");

    try testing.expectEqual(docs, try resolvePath("/docs"));
    try testing.expectEqual(readme, try resolvePath("/docs/readme.txt"));
    try testing.expectEqual(readme, try resolvePath("docs/readme.txt"));
    try testing.expectEqual(readme, try resolvePath("/docs/./readme.txt"));
    try testing.expectEqual(root_inode, try resolvePath("/"));

    try testing.expectError(error.EntryNotFound, resolvePath("/docs/missing.txt"));
    try testing.expectError(error.InvalidPath, resolvePath("/docs/../readme.txt"));
    try testing.expectError(error.InvalidPath, resolvePath(""));

    var root_entries: [8]DirEntryInfo = undefined;
    const root_count = try listDir(root_inode, &root_entries);
    try testing.expectEqual(@as(usize, 1), root_count);
    try testing.expectEqualStrings("docs", root_entries[0].name);
    try testing.expectEqual(inode.InodeType.directory, root_entries[0].kind);

    var docs_entries: [8]DirEntryInfo = undefined;
    const docs_count = try listDir(docs, &docs_entries);
    try testing.expectEqual(@as(usize, 1), docs_count);
    try testing.expectEqualStrings("readme.txt", docs_entries[0].name);
    try testing.expectEqual(inode.InodeType.file, docs_entries[0].kind);

    try testing.expectError(error.NameExists, createFile(docs, "readme.txt"));
    try testing.expectError(error.NotADirectory, createFile(readme, "nested"));
    try testing.expectError(error.InvalidName, createFile(docs, ""));
    try testing.expectError(error.InvalidName, createFile(docs, "a/b"));
    try testing.expectError(error.InvalidName, createFile(docs, ".."));
}

test "a file larger than the direct blocks is refused without data loss" {
    init();

    const file = try createFile(root_inode, "large.bin");
    try writeFile(file, "original");

    var large: [max_file_size + 1]u8 = undefined;
    @memset(&large, 0xAA);

    try testing.expectError(error.FileTooLarge, writeFile(file, &large));

    var buffer: [16]u8 = undefined;
    const count = try readFile(file, &buffer);
    try testing.expectEqualSlices(u8, "original", buffer[0..count]);
}

test "inode exhaustion is reported" {
    init();

    var names: [inode_count - 1][8]u8 = undefined;
    var created: usize = 0;
    while (created < names.len) : (created += 1) {
        names[created] = [_]u8{ 'f', 0, 0, 0, 0, 0, 0, 0 };
        names[created][1] = @as(u8, @intCast('0' + (created % 10)));
        names[created][2] = @as(u8, @intCast('a' + (created / 10)));
        _ = try createFile(root_inode, names[created][0..3]);
    }

    try testing.expectEqual(@as(usize, 0), freeInodeCount());
    try testing.expectError(error.NoFreeInode, createFile(root_inode, "overflow"));
}
