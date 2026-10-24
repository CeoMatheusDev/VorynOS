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
//!   * 32 default_state.inodes, numerados de 0 a 31; o inode 0 é o diretório raiz;
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

/// Estado de uma instância RamFS, separado das operações.
/// A implementação legada continua usando a instância default_state;
/// operações parametrizadas por *State serão introduzidas gradualmente.
pub const State = struct {
    memory: [total_size]u8 = undefined,
    block_bitmap: [block_count / 8]u8 = undefined,
    inodes: [inode_count]inode.InodeOnDisk = undefined,
    dir_entries: [dir_entry_count]DirEntry = undefined,
};

var default_state: State = .{};

/// Inicializa o RamFS e apaga todo o conteúdo anterior.
pub fn init() void {
    initState(&default_state);
}

/// Initializes an explicitly supplied RamFS state without touching other instances.
pub fn initState(state: *State) void {
    @memset(state.memory[0..], 0);
    @memset(state.block_bitmap[0..], 0);

    for (&state.inodes) |*entry| {
        entry.* = .{
            .i_type = .file,
            .i_permissions = 0o755,
            .i_links_count = 0,
            .i_size = 0,
            .i_block = @splat(0),
        };
    }

    for (&state.dir_entries) |*entry| {
        entry.* = .{};
    }

    // O bloco 0 é o superbloco: ele nunca é entregue a um arquivo.
    state.block_bitmap[0] |= 1;

    // O inode 0 é o diretório raiz. O contador de links funciona como
    // marcador de inode ocupado: zero significa livre.
    state.inodes[root_inode] = .{
        .i_type = .directory,
        .i_permissions = 0o755,
        .i_links_count = 1,
        .i_size = 0,
        .i_block = @splat(0),
    };
}

/// Verdadeiro quando o bloco está marcado como usado.
fn blockUsedFor(state: *const State, block: usize) bool {
    const mask = @as(u8, 1) << @intCast(block % 8);
    return state.block_bitmap[block / 8] & mask != 0;
}

fn blockUsed(block: usize) bool {
    return blockUsedFor(&default_state, block);
}

/// Updates a bitmap bit for one volume.
fn setBlockUsedFor(state: *State, block: usize, used: bool) void {
    const mask = @as(u8, 1) << @intCast(block % 8);
    if (used) {
        state.block_bitmap[block / 8] |= mask;
    } else {
        state.block_bitmap[block / 8] &= ~mask;
    }
}

fn setBlockUsed(block: usize, used: bool) void {
    setBlockUsedFor(&default_state, block, used);
}

/// Allocates and zeroes one data block in a specific initialized volume.
pub fn allocateBlockFor(state: *State) ?u32 {
    var index: usize = 1;
    while (index < block_count) : (index += 1) {
        if (blockUsedFor(state, index)) continue;
        setBlockUsedFor(state, index, true);
        @memset(state.memory[index * block_size ..][0..block_size], 0);
        return @intCast(index);
    }
    return null;
}

/// Legacy allocator bound to the default RamFS.
pub fn allocateBlock() ?u32 {
    return allocateBlockFor(&default_state);
}

/// Releases and zeroes an allocated block of a specific volume.
pub fn freeBlockFor(state: *State, block: u32) bool {
    const index: usize = block;
    if (index == 0 or index >= block_count) return false;
    if (!blockUsedFor(state, index)) return false;
    setBlockUsedFor(state, index, false);
    @memset(state.memory[index * block_size ..][0..block_size], 0);
    return true;
}

pub fn freeBlock(block: u32) bool {
    return freeBlockFor(&default_state, block);
}

pub fn freeBlockCountFor(state: *const State) usize {
    var count: usize = 0;
    for (0..block_count) |index| {
        if (!blockUsedFor(state, index)) count += 1;
    }
    return count;
}

pub fn freeBlockCount() usize {
    return freeBlockCountFor(&default_state);
}

/// Número de inodes livres.
pub fn freeInodeCount() usize {
    var count: usize = 0;
    for (default_state.inodes) |entry| {
        if (entry.i_links_count == 0) count += 1;
    }
    return count;
}

/// Fixed-size snapshot of allocator and namespace occupancy.
/// Counters are observational; callers must ensure mutations are quiescent.
pub const StorageStats = struct {
    total_blocks: usize,
    used_blocks: usize,
    free_blocks: usize,
    total_inodes: usize,
    used_inodes: usize,
    free_inodes: usize,
    total_dir_entries: usize,
    used_dir_entries: usize,
    free_dir_entries: usize,
    total_bytes: usize,
    allocated_data_bytes: usize,
};

pub fn storageStats() StorageStats {
    return storageStatsFor(&default_state);
}

/// Reports occupancy of a specific initialized volume.
pub fn storageStatsFor(state: *const State) StorageStats {
    var free_blocks: usize = 0;
    for (0..block_count) |index| {
        const mask = @as(u8, 1) << @intCast(index % 8);
        if (state.block_bitmap[index / 8] & mask == 0) free_blocks += 1;
    }
    var free_inodes: usize = 0;
    for (state.inodes) |entry| {
        if (entry.i_links_count == 0) free_inodes += 1;
    }
    var used_entries: usize = 0;
    for (state.dir_entries) |entry| {
        if (entry.used) used_entries += 1;
    }
    return .{
        .total_blocks = block_count,
        .used_blocks = block_count - free_blocks,
        .free_blocks = free_blocks,
        .total_inodes = inode_count,
        .used_inodes = inode_count - free_inodes,
        .free_inodes = free_inodes,
        .total_dir_entries = dir_entry_count,
        .used_dir_entries = used_entries,
        .free_dir_entries = dir_entry_count - used_entries,
        .total_bytes = total_size,
        .allocated_data_bytes = (block_count - free_blocks - 1) * block_size,
    };
}

/// Read-only consistency audit for the in-memory block allocator and directory.
/// Orphan inodes are permitted because unlink defers reclamation until close.
pub const AuditError = error{
    MissingRoot,
    InvalidDirectoryEntry,
    InvalidBlockReference,
    DuplicateBlockReference,
    BlockBitmapMismatch,
    InvalidFileLayout,
    DuplicateDirectoryName,
    InvalidDirectoryName,
    DirectoryCycle,
    DirectoryMultipleParents,
};

pub fn audit() AuditError!void {
    if (default_state.inodes[root_inode].i_links_count == 0 or default_state.inodes[root_inode].i_type != .directory)
        return error.MissingRoot;

    var referenced: [block_count]bool = @splat(false);
    referenced[0] = true;
    for (default_state.inodes) |entry| {
        if (entry.i_links_count == 0) continue;
        if (entry.i_type == .file) {
            if (entry.i_size > max_file_size) return error.InvalidFileLayout;
            const expected: usize = if (entry.i_size == 0) 0 else
                (@as(usize, @intCast(entry.i_size)) - 1) / block_size + 1;
            for (entry.i_block, 0..) |block, index| {
                if ((index < expected and block == 0) or
                    (index >= expected and block != 0))
                    return error.InvalidFileLayout;
            }
        }
        for (entry.i_block) |block| {
            if (block == 0) continue;
            const index: usize = @intCast(block);
            if (index >= block_count) return error.InvalidBlockReference;
            if (referenced[index]) return error.DuplicateBlockReference;
            referenced[index] = true;
        }
    }
    for (referenced, 0..) |used, index| {
        if (blockUsed(index) != used) return error.BlockBitmapMismatch;
    }
    for (default_state.dir_entries) |entry| {
        if (!entry.used) continue;
        if (entry.parent >= inode_count or entry.inode >= inode_count)
            return error.InvalidDirectoryEntry;
        if (default_state.inodes[entry.parent].i_links_count == 0 or default_state.inodes[entry.parent].i_type != .directory)
            return error.InvalidDirectoryEntry;
        if (default_state.inodes[entry.inode].i_links_count == 0 or entry.name_len == 0 or entry.name_len > max_name_len)
            return error.InvalidDirectoryEntry;
        const name = entry.name[0..entry.name_len];
        if (!validName(name)) return error.InvalidDirectoryName;
    }
    // Each directory except the root must have at most one parent.
    // Follow parent chains with a bounded walk to detect cycles without
    // recursion or allocation. Unreachable directories are allowed for now.
    for (default_state.dir_entries) |entry| {
        if (!entry.used or default_state.inodes[entry.inode].i_type != .directory) continue;
        if (entry.inode == root_inode) return error.DirectoryCycle;
        var parent_links: usize = 0;
        for (default_state.dir_entries) |other| {
            if (other.used and other.inode == entry.inode) parent_links += 1;
        }
        if (parent_links > 1) return error.DirectoryMultipleParents;

        var cursor = entry.parent;
        var depth: usize = 0;
        while (cursor != root_inode) : (depth += 1) {
            if (depth >= inode_count or cursor == entry.inode)
                return error.DirectoryCycle;
            var next: ?u32 = null;
            for (default_state.dir_entries) |candidate| {
                if (candidate.used and candidate.inode == cursor) {
                    next = candidate.parent;
                    break;
                }
            }
            cursor = next orelse break;
        }
    }
    for (default_state.dir_entries, 0..) |entry, index| {
        if (!entry.used) continue;
        for (default_state.dir_entries[index + 1 ..]) |other| {
            if (!other.used or other.parent != entry.parent) continue;
            if (std.mem.eql(u8, entry.name[0..entry.name_len], other.name[0..other.name_len]))
                return error.DuplicateDirectoryName;
        }
    }
}

/// Devolve o tipo do inode, ou `null` quando o inode está livre.
pub fn inodeKind(inode_num: u32) ?inode.InodeType {
    if (inode_num >= inode_count) return null;
    const entry = default_state.inodes[inode_num];
    if (entry.i_links_count == 0) return null;
    return entry.i_type;
}

/// Aloca um inode do tipo pedido.
fn allocateInode(kind: inode.InodeType) Error!u32 {
    for (&default_state.inodes, 0..) |*entry, index| {
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
    const entry = &default_state.inodes[inode_num];
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
    for (default_state.dir_entries) |entry| {
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

    for (&default_state.dir_entries) |*entry| {
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

/// Renomeia ou move um arquivo regular sem invalidar seu inode e descritores.
pub fn renameFile(source_parent: u32, source_name: []const u8, target_parent: u32, target_name: []const u8) Error!void {
    if (inodeKind(source_parent) != .directory or inodeKind(target_parent) != .directory)
        return error.NotADirectory;
    if (!validName(source_name) or !validName(target_name)) return error.InvalidName;

    const source_inode = lookup(source_parent, source_name) orelse return error.EntryNotFound;
    if (inodeKind(source_inode) != .file) return error.NotAFile;
    if (source_parent == target_parent and std.mem.eql(u8, source_name, target_name)) return;
    if (lookup(target_parent, target_name) != null) return error.NameExists;

    for (&default_state.dir_entries) |*entry| {
        if (!entry.used or entry.parent != source_parent or entry.inode != source_inode) continue;
        if (!std.mem.eql(u8, entry.name[0..entry.name_len], source_name)) continue;
        entry.parent = target_parent;
        entry.name_len = @intCast(target_name.len);
        @memset(entry.name[0..], 0);
        @memcpy(entry.name[0..target_name.len], target_name);
        return;
    }
    return error.EntryNotFound;
}

/// Desvincula um arquivo regular do diretório sem liberar seu inode.
/// O chamador deve liberar o inode quando não houver descritores abertos.
pub fn unlinkFile(parent: u32, name: []const u8) Error!u32 {
    if (inodeKind(parent) != .directory) return error.NotADirectory;
    if (!validName(name)) return error.InvalidName;
    const target = lookup(parent, name) orelse return error.EntryNotFound;
    if (inodeKind(target) != .file) return error.NotAFile;
    for (&default_state.dir_entries) |*entry| {
        if (!entry.used or entry.parent != parent or entry.inode != target) continue;
        if (!std.mem.eql(u8, entry.name[0..entry.name_len], name)) continue;
        entry.* = .{};
        return target;
    }
    return error.EntryNotFound;
}

/// Libera inode desvinculado; nunca deve ser chamado com descritores vivos.
pub fn releaseUnlinked(inode_num: u32) void {
    if (inode_num == root_inode or inodeKind(inode_num) != .file) return;
    for (default_state.dir_entries) |entry| {
        if (entry.used and entry.inode == inode_num) return;
    }
    releaseInode(inode_num);
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

    // Preserve existing blocks if allocation fails partway through extension.
    var new_indices: [direct_blocks]usize = undefined;
    var new_count: usize = 0;
    errdefer {
        for (new_indices[0..new_count]) |index| {
            const block = default_state.inodes[inode_num].i_block[index];
            _ = freeBlock(@as(u32, @intCast(block)));
            default_state.inodes[inode_num].i_block[index] = 0;
        }
    }

    var count: usize = 0;
    while (count < required) : (count += 1) {
        if (default_state.inodes[inode_num].i_block[count] != 0) continue;
        const block = allocateBlock() orelse return error.NoSpace;
        default_state.inodes[inode_num].i_block[count] = block;
        new_indices[new_count] = count;
        new_count += 1;
    }
}

/// Libera todos os blocos de um inode e zera os ponteiros.
fn releaseBlocks(inode_num: u32) void {
    for (&default_state.inodes[inode_num].i_block) |*block| {
        if (block.* != 0) {
            _ = freeBlock(@as(u32, @intCast(block.*)));
            block.* = 0;
        }
    }
}

/// Substitui o conteúdo de um arquivo.
pub fn writeFile(inode_num: u32, data: []const u8) Error!void {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (default_state.inodes[inode_num].i_type != .file) return error.NotAFile;

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
        @memcpy(default_state.memory[start..][0..count], data[offset..][0..count]);
        offset += count;
    }

    releaseBlocks(inode_num);
    for (&default_state.inodes[inode_num].i_block, 0..) |*slot, index| {
        slot.* = if (index < required) new_blocks[index] else 0;
    }
    default_state.inodes[inode_num].i_size = data.len;
}

/// Escreve `data` em `offset`, sem apagar o restante do arquivo.
///
/// A escrita pode estender o arquivo; o espaço entre o fim antigo e o
/// início da escrita é preenchido com zero, porque os blocos novos já são
/// alocados zerados.
pub fn writeFileAt(inode_num: u32, offset: usize, data: []const u8) Error!usize {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (default_state.inodes[inode_num].i_type != .file) return error.NotAFile;
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
        const block = @as(usize, @intCast(default_state.inodes[inode_num].i_block[block_index]));
        @memcpy(
            default_state.memory[block * block_size + inside ..][0..count],
            data[source..][0..count],
        );
        source += count;
        position += count;
    }

    if (default_state.inodes[inode_num].i_size < end) default_state.inodes[inode_num].i_size = end;
    return data.len;
}

/// Encolhe um arquivo para `new_size` bytes.
pub fn truncate(inode_num: u32, new_size: usize) Error!void {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (default_state.inodes[inode_num].i_type != .file) return error.NotAFile;
    if (new_size > default_state.inodes[inode_num].i_size) return error.InvalidOffset;
    if (new_size > max_file_size) return error.FileTooLarge;

    const required = try blocksFor(new_size);
    var index = required;
    while (index < direct_blocks) : (index += 1) {
        const block = default_state.inodes[inode_num].i_block[index];
        if (block != 0) {
            _ = freeBlock(@as(u32, @intCast(block)));
            default_state.inodes[inode_num].i_block[index] = 0;
        }
    }

    // O restante do último bloco fica inacessível pelo tamanho, mas é
    // zerado para que uma futura extensão não exponha dados antigos.
    if (new_size % block_size != 0 and required > 0) {
        const block = @as(usize, @intCast(default_state.inodes[inode_num].i_block[required - 1]));
        const start = block * block_size + (new_size % block_size);
        @memset(default_state.memory[start..][0 .. block_size - (new_size % block_size)], 0);
    }

    default_state.inodes[inode_num].i_size = new_size;
}

/// Lê o arquivo a partir de `offset` para o buffer do chamador e devolve o
/// número de bytes lidos. O fim do arquivo devolve zero, como uma leitura
/// de sistema de arquivos.
pub fn readFileAt(inode_num: u32, offset: usize, buffer: []u8) Error!usize {
    if (inodeKind(inode_num) == null) return error.InvalidInode;
    if (default_state.inodes[inode_num].i_type != .file) return error.NotAFile;

    const size = @as(usize, @intCast(default_state.inodes[inode_num].i_size));
    if (offset >= size or buffer.len == 0) return 0;

    const count = @min(buffer.len, size - offset);
    var destination: usize = 0;
    var position: usize = offset;
    while (destination < count) {
        const block_index = position / block_size;
        const inside = position % block_size;
        const chunk = @min(block_size - inside, count - destination);
        const block = @as(usize, @intCast(default_state.inodes[inode_num].i_block[block_index]));
        @memcpy(
            buffer[destination..][0..chunk],
            default_state.memory[block * block_size + inside ..][0..chunk],
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
    for (&default_state.dir_entries) |*entry| {
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
    if (default_state.inodes[inode_num].i_type != .file) return null;
    return default_state.inodes[inode_num].i_size;
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
    return default_state.inodes[inode_num];
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

test "rename regular files preserves inode and rejects collisions and directories" {
    init();
    const from = try createDirectory(root_inode, "from");
    const to = try createDirectory(root_inode, "to");
    const original = try createFile(from, "item");
    try writeFile(original, "data");
    try renameFile(from, "item", to, "renamed");
    try testing.expectEqual(original, try resolvePath("/to/renamed"));
    try testing.expectError(error.EntryNotFound, resolvePath("/from/item"));
    try testing.expectEqual(@as(u64, 4), sizeOf(original).?);
    try renameFile(to, "renamed", to, "renamed");
    _ = try createFile(to, "exists");
    try testing.expectError(error.NameExists, renameFile(to, "renamed", to, "exists"));
    try testing.expectError(error.NotAFile, renameFile(root_inode, "from", to, "moved"));
    try testing.expectError(error.InvalidName, renameFile(to, "renamed", to, ".."));
}

test "unlink detaches file and explicit release reclaims inode and blocks" {
    init();
    const file = try createFile(root_inode, "temporary");
    try writeFile(file, "payload");
    const free_before = freeBlockCount();
    try testing.expectEqual(file, try unlinkFile(root_inode, "temporary"));
    try testing.expectError(error.EntryNotFound, resolvePath("/temporary"));
    var data: [8]u8 = undefined;
    const count = try readFile(file, &data);
    try testing.expectEqualStrings("payload", data[0..count]);
    releaseUnlinked(file);
    try testing.expectEqual(free_before + 1, freeBlockCount());
    try testing.expect(inodeKind(file) == null);
    try testing.expectError(error.EntryNotFound, unlinkFile(root_inode, "temporary"));
    const directory = try createDirectory(root_inode, "dir");
    _ = directory;
    try testing.expectError(error.NotAFile, unlinkFile(root_inode, "dir"));
}

test "full directory rolls back newly allocated file inode" {
    init();
    const shared = try createFile(root_inode, "shared");
    var index: usize = 1;
    while (index < dir_entry_count) : (index += 1) {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "alias-{d}", .{index});
        try addDirEntry(root_inode, name, shared);
    }
    const before_inodes = freeInodeCount();
    const before_blocks = freeBlockCount();
    try testing.expectError(error.DirectoryFull, createFile(root_inode, "overflow-file"));
    try testing.expect(lookup(root_inode, "overflow-file") == null);
    try testing.expectEqual(before_inodes, freeInodeCount());
    try testing.expectEqual(before_blocks, freeBlockCount());
}

test "full directory rolls back newly allocated directory inode" {
    init();
    const shared = try createFile(root_inode, "shared");
    var index: usize = 1;
    while (index < dir_entry_count) : (index += 1) {
        var buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "alias-{d}", .{index});
        try addDirEntry(root_inode, name, shared);
    }
    const before_inodes = freeInodeCount();
    const before_blocks = freeBlockCount();
    try testing.expectError(error.DirectoryFull, createDirectory(root_inode, "overflow-dir"));
    try testing.expect(lookup(root_inode, "overflow-dir") == null);
    try testing.expectEqual(before_inodes, freeInodeCount());
    try testing.expectEqual(before_blocks, freeBlockCount());
}

test "writeFileAt NoSpace rolls back partial block allocation" {
    init();
    const target = try createFile(root_inode, "target");
    _ = try writeFileAt(target, 0, "preserved");
    const original_size = sizeOf(target).?;
    const original_block = default_state.inodes[target].i_block[0];

    // Leave exactly one free block: extending to three blocks must fail
    // after allocating the first new block.
    var held: [block_count - 1]u32 = undefined;
    var held_count: usize = 0;
    while (freeBlockCount() > 1) {
        held[held_count] = allocateBlock() orelse return error.TestUnexpectedResult;
        held_count += 1;
    }
    const before_free = freeBlockCount();
    const payload: [block_size * 2 + 1]u8 = @splat(0x5a);
    try testing.expectError(error.NoSpace, writeFileAt(target, 0, &payload));
    try testing.expectEqual(original_size, sizeOf(target).?);
    try testing.expectEqual(original_block, default_state.inodes[target].i_block[0]);
    try testing.expectEqual(@as(u32, 0), default_state.inodes[target].i_block[1]);
    try testing.expectEqual(@as(u32, 0), default_state.inodes[target].i_block[2]);
    try testing.expectEqual(before_free, freeBlockCount());
    var result: [9]u8 = undefined;
    const read_count = try readFileAt(target, 0, &result);
    try testing.expectEqual(@as(usize, 9), read_count);
    try testing.expectEqualStrings("preserved", &result);
    for (held[0..held_count]) |block| try testing.expect(freeBlock(block));
}

test "truncate frees trailing blocks and zeroes retained block tail" {
    init();
    const target = try createFile(root_inode, "truncate-target");
    const payload: [block_size * 3]u8 = @splat(0x7b);
    try writeFile(target, &payload);
    const before = freeBlockCount();
    try truncate(target, block_size + 3);
    try testing.expectEqual(@as(u64, block_size + 3), sizeOf(target).?);
    try testing.expectEqual(before + 1, freeBlockCount());
    try testing.expectEqual(@as(u32, 0), default_state.inodes[target].i_block[2]);
    const extension: [block_size - 3]u8 = @splat(0x2a);
    _ = try writeFileAt(target, block_size * 2, &extension);
    var gap: [block_size - 3]u8 = undefined;
    const read_count = try readFileAt(target, block_size + 3, &gap);
    try testing.expectEqual(gap.len, read_count);
    for (gap) |byte| try testing.expectEqual(@as(u8, 0), byte);
    try testing.expectEqual(@as(u64, block_size * 3 - 3), sizeOf(target).?);
}

test "writeFileAt rejects out of range offsets without modifying file" {
    init();
    const target = try createFile(root_inode, "offset-target");
    try writeFile(target, "original");
    const before = freeBlockCount();
    try testing.expectError(error.FileTooLarge, writeFileAt(target, max_file_size, "x"));
    try testing.expectError(error.FileTooLarge, writeFileAt(target, std.math.maxInt(usize), "x"));
    try testing.expectEqual(before, freeBlockCount());
    try testing.expectEqual(@as(u64, 8), sizeOf(target).?);
    var result: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), try readFileAt(target, 0, &result));
    try testing.expectEqualStrings("original", &result);
}

test "writeFile replacement NoSpace preserves original contents" {
    init();
    const target = try createFile(root_inode, "replace-target");
    try writeFile(target, "original");
    var held: [block_count - 1]u32 = undefined;
    var held_count: usize = 0;
    while (freeBlockCount() > 1) {
        held[held_count] = allocateBlock() orelse return error.TestUnexpectedResult;
        held_count += 1;
    }
    const before = freeBlockCount();
    const replacement: [block_size + 1]u8 = @splat(0x55);
    try testing.expectError(error.NoSpace, writeFile(target, &replacement));
    try testing.expectEqual(before, freeBlockCount());
    try testing.expectEqual(@as(u64, 8), sizeOf(target).?);
    var result: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), try readFileAt(target, 0, &result));
    try testing.expectEqualStrings("original", &result);
    for (held[0..held_count]) |block| try testing.expect(freeBlock(block));
}

test "writeFileAt crossing block boundary preserves neighboring bytes" {
    init();
    const file = try createFile(root_inode, "boundary");
    const original: [block_size * 2]u8 = @splat(0x41);
    try writeFile(file, &original);
    const free_before = freeBlockCount();
    try testing.expectEqual(@as(usize, 4), try writeFileAt(file, block_size - 2, "WXYZ"));
    try testing.expectEqual(free_before, freeBlockCount());
    try testing.expectEqual(@as(u64, block_size * 2), sizeOf(file).?);
    var window: [6]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), try readFileAt(file, block_size - 3, &window));
    try testing.expectEqualStrings("AWXYZA", &window);
}

test "truncate to zero releases blocks and subsequent writes start clean" {
    init();
    const file = try createFile(root_inode, "zero");
    const original: [block_size * 2]u8 = @splat(0x9a);
    try writeFile(file, &original);
    const before = freeBlockCount();
    try truncate(file, 0);
    try testing.expectEqual(@as(u64, 0), sizeOf(file).?);
    try testing.expectEqual(before + 2, freeBlockCount());
    for (default_state.inodes[file].i_block) |block| try testing.expectEqual(@as(u32, 0), block);
    try testing.expectEqual(@as(usize, 1), try writeFileAt(file, block_size + 2, "Z"));
    var gap: [block_size + 2]u8 = undefined;
    try testing.expectEqual(gap.len, try readFileAt(file, 0, &gap));
    for (gap) |byte| try testing.expectEqual(@as(u8, 0), byte);
    var last: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try readFileAt(file, block_size + 2, &last));
    try testing.expectEqual(@as(u8, 'Z'), last[0]);
}

test "empty writes leave inode and block allocation unchanged" {
    init();
    const file = try createFile(root_inode, "empty");
    try writeFile(file, "data");
    const before = freeBlockCount();
    const first_block = default_state.inodes[file].i_block[0];
    try testing.expectEqual(@as(usize, 0), try writeFileAt(file, max_file_size + 1, ""));
    try testing.expectEqual(before, freeBlockCount());
    try testing.expectEqual(first_block, default_state.inodes[file].i_block[0]);
    try testing.expectEqual(@as(u64, 4), sizeOf(file).?);
    var result: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try readFileAt(file, 0, &result));
    try testing.expectEqualStrings("data", &result);
}

test "writeFileAt maximum direct block capacity and overflow rejection" {
    init();
    const file = try createFile(root_inode, "maximum");
    const payload: [max_file_size]u8 = @splat(0x63);
    try testing.expectEqual(max_file_size, try writeFileAt(file, 0, &payload));
    const before = freeBlockCount();
    try testing.expectEqual(@as(u64, max_file_size), sizeOf(file).?);
    try testing.expectError(error.FileTooLarge, writeFileAt(file, max_file_size, "x"));
    try testing.expectEqual(before, freeBlockCount());
    var last: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), try readFileAt(file, max_file_size - 1, &last));
    try testing.expectEqual(@as(u8, 0x63), last[0]);
}

test "failed extension can be retried after blocks become available" {
    init();
    const file = try createFile(root_inode, "retry");
    try writeFile(file, "stable");
    var held: [block_count - 1]u32 = undefined;
    var held_count: usize = 0;
    while (freeBlockCount() > 1) {
        held[held_count] = allocateBlock() orelse return error.TestUnexpectedResult;
        held_count += 1;
    }
    try testing.expectError(error.NoSpace, writeFileAt(file, block_size * 2, "done"));
    try testing.expectEqual(@as(u64, 6), sizeOf(file).?);
    for (held[0..held_count]) |block| try testing.expect(freeBlock(block));
    try testing.expectEqual(@as(usize, 4), try writeFileAt(file, block_size * 2, "done"));
    var result: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try readFileAt(file, block_size * 2, &result));
    try testing.expectEqualStrings("done", &result);
    var old: [6]u8 = undefined;
    try testing.expectEqual(@as(usize, 6), try readFileAt(file, 0, &old));
    try testing.expectEqualStrings("stable", &old);
}


// M0.3.20: namespace saturation and transactional inode allocation.
test "inode exhaustion does not create a directory entry and released inode is reusable" {
    init();
    var ids: [inode_count - 1]u32 = undefined;
    for (&ids, 0..) |*slot, index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "inode-{d}", .{index});
        slot.* = try createFile(root_inode, path);
    }
    try testing.expectEqual(@as(usize, 0), freeInodeCount());
    const blocks_before = freeBlockCount();
    try testing.expectError(error.NoFreeInode, createFile(root_inode, "overflow"));
    try testing.expectError(error.NoFreeInode, createDirectory(root_inode, "overflow-dir"));
    try testing.expect(lookup(root_inode, "overflow") == null);
    try testing.expect(lookup(root_inode, "overflow-dir") == null);
    try testing.expectEqual(blocks_before, freeBlockCount());

    const removed = try unlinkFile(root_inode, "inode-0");
    try testing.expectEqual(ids[0], removed);
    releaseUnlinked(removed);
    try testing.expectEqual(@as(usize, 1), freeInodeCount());
    const reused = try createFile(root_inode, "reused");
    try testing.expectEqual(removed, reused);
    try testing.expectEqual(@as(usize, 0), freeInodeCount());
}

test "full directory table rejects new entry without leaking allocated inode" {
    init();
    const anchor = try createFile(root_inode, "anchor");
    // addDirEntry permits an existing inode in multiple entries. This
    // directly saturates the fixed directory table without 64 default_state.inodes.
    for (0..dir_entry_count - 1) |index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "alias-{d}", .{index});
        try addDirEntry(root_inode, path, anchor);
    }
    const inodes_before = freeInodeCount();
    const blocks_before = freeBlockCount();
    try testing.expectError(error.DirectoryFull, createFile(root_inode, "extra"));
    try testing.expectError(error.DirectoryFull, createDirectory(root_inode, "extra-dir"));
    try testing.expect(lookup(root_inode, "extra") == null);
    try testing.expect(lookup(root_inode, "extra-dir") == null);
    try testing.expectEqual(inodes_before, freeInodeCount());
    try testing.expectEqual(blocks_before, freeBlockCount());
    var entries: [dir_entry_count]DirEntryInfo = undefined;
    try testing.expectEqual(@as(usize, dir_entry_count), try listDir(root_inode, &entries));
}

test "duplicate and invalid names do not consume namespace resources" {
    init();
    const original = try createFile(root_inode, "stable");
    const inodes_before = freeInodeCount();
    const blocks_before = freeBlockCount();
    try testing.expectError(error.NameExists, createFile(root_inode, "stable"));
    try testing.expectError(error.NameExists, createDirectory(root_inode, "stable"));
    try testing.expectError(error.InvalidName, createFile(root_inode, ".."));
    try testing.expectError(error.InvalidName, createDirectory(root_inode, "bad/name"));
    try testing.expectEqual(original, lookup(root_inode, "stable").?);
    try testing.expectEqual(inodes_before, freeInodeCount());
    try testing.expectEqual(blocks_before, freeBlockCount());
}

test "audit validates initialized and populated RamFS" {
    init();
    try audit();
    const file = try createFile(root_inode, "audit-file");
    try writeFile(file, "integrity");
    try audit();
    try testing.expectEqual(@as(usize, block_count - 2), freeBlockCount());
}

test "audit detects allocator bitmap mismatch without modifying data" {
    init();
    const file = try createFile(root_inode, "file");
    try writeFile(file, "payload");
    try audit();
    const block: usize = @intCast(default_state.inodes[file].i_block[0]);
    setBlockUsed(block, false);
    try testing.expectError(error.BlockBitmapMismatch, audit());
    setBlockUsed(block, true);
    try audit();
}

test "audit detects invalid directory reference" {
    init();
    _ = try createFile(root_inode, "file");
    try audit();
    var slot: usize = 0;
    while (slot < dir_entry_count and !default_state.dir_entries[slot].used) : (slot += 1) {}
    try testing.expect(slot < dir_entry_count);
    const original = default_state.dir_entries[slot].inode;
    default_state.dir_entries[slot].inode = @intCast(inode_count);
    try testing.expectError(error.InvalidDirectoryEntry, audit());
    default_state.dir_entries[slot].inode = original;
    try audit();
}

test "audit rejects missing required file block" {
    init();
    const file = try createFile(root_inode, "required");
    try writeFile(file, "data");
    const saved = default_state.inodes[file].i_block[0];
    default_state.inodes[file].i_block[0] = 0;
    try testing.expectError(error.InvalidFileLayout, audit());
    default_state.inodes[file].i_block[0] = saved;
    try audit();
}

test "audit rejects blocks beyond logical file size" {
    init();
    const file = try createFile(root_inode, "trailing");
    try writeFile(file, "data");
    const extra = allocateBlock() orelse return error.NoSpace;
    default_state.inodes[file].i_block[1] = extra;
    try testing.expectError(error.InvalidFileLayout, audit());
    default_state.inodes[file].i_block[1] = 0;
    _ = freeBlock(extra);
    try audit();
}

test "audit rejects file size exceeding direct block capacity" {
    init();
    const file = try createFile(root_inode, "oversize");
    const original = default_state.inodes[file].i_size;
    default_state.inodes[file].i_size = max_file_size + 1;
    try testing.expectError(error.InvalidFileLayout, audit());
    default_state.inodes[file].i_size = original;
    try audit();
}

test "storage statistics reflect initialization and file allocation" {
    init();
    const initial = storageStats();
    try testing.expectEqual(@as(usize, 1), initial.used_blocks);
    try testing.expectEqual(@as(usize, 1), initial.used_inodes);
    try testing.expectEqual(@as(usize, 0), initial.used_dir_entries);
    try testing.expectEqual(@as(usize, 0), initial.allocated_data_bytes);
    const file = try createFile(root_inode, "stats");
    try writeFile(file, "data");
    const after = storageStats();
    try testing.expectEqual(initial.used_blocks + 1, after.used_blocks);
    try testing.expectEqual(initial.used_inodes + 1, after.used_inodes);
    try testing.expectEqual(@as(usize, 1), after.used_dir_entries);
    try testing.expectEqual(@as(usize, block_size), after.allocated_data_bytes);
    try audit();
}

test "storage statistics track truncate and released file" {
    init();
    const file = try createFile(root_inode, "stats-truncate");
    var payload: [block_size + 1]u8 = @splat(7);
    try writeFile(file, &payload);
    try testing.expectEqual(@as(usize, 2 * block_size), storageStats().allocated_data_bytes);
    try truncate(file, 1);
    try testing.expectEqual(@as(usize, block_size), storageStats().allocated_data_bytes);
    _ = try unlinkFile(root_inode, "stats-truncate");
    releaseUnlinked(file);
    const after = storageStats();
    try testing.expectEqual(@as(usize, 0), after.allocated_data_bytes);
    try testing.expectEqual(@as(usize, 0), after.used_dir_entries);
    try audit();
}

test "audit detects duplicate names within the same directory" {
    init();
    const first = try createFile(root_inode, "first");
    const second = try createFile(root_inode, "second");
    try audit();
    var second_slot: ?usize = null;
    for (default_state.dir_entries, 0..) |entry, index| {
        if (entry.used and entry.inode == second) second_slot = index;
    }
    const slot = second_slot orelse unreachable;
    const saved = default_state.dir_entries[slot];
    default_state.dir_entries[slot].name = @splat(0);
    @memcpy(default_state.dir_entries[slot].name[0..5], "first");
    default_state.dir_entries[slot].name_len = 5;
    try testing.expectError(error.DuplicateDirectoryName, audit());
    default_state.dir_entries[slot] = saved;
    try testing.expectEqual(first, lookup(root_inode, "first").?);
    try audit();
}

test "audit detects malformed directory entry names" {
    init();
    const file = try createFile(root_inode, "valid");
    var slot: ?usize = null;
    for (default_state.dir_entries, 0..) |entry, index| {
        if (entry.used and entry.inode == file) slot = index;
    }
    const index = slot orelse unreachable;
    const saved = default_state.dir_entries[index];
    default_state.dir_entries[index].name[0] = '/';
    try testing.expectError(error.InvalidDirectoryName, audit());
    default_state.dir_entries[index] = saved;
    try audit();
}

test "audit detects directory self-cycle" {
    init();
    const folder = try createDirectory(root_inode, "loop");
    var slot: ?usize = null;
    for (default_state.dir_entries, 0..) |entry, index| {
        if (entry.used and entry.inode == folder) slot = index;
    }
    const index = slot orelse unreachable;
    const saved = default_state.dir_entries[index].parent;
    default_state.dir_entries[index].parent = folder;
    try testing.expectError(error.DirectoryCycle, audit());
    default_state.dir_entries[index].parent = saved;
    try audit();
}

test "audit detects directory cycle across two nodes" {
    init();
    const a = try createDirectory(root_inode, "a");
    const b = try createDirectory(a, "b");
    var a_slot: ?usize = null;
    for (default_state.dir_entries, 0..) |entry, index| {
        if (entry.used and entry.inode == a) a_slot = index;
    }
    const index = a_slot orelse unreachable;
    const saved = default_state.dir_entries[index].parent;
    default_state.dir_entries[index].parent = b;
    try testing.expectError(error.DirectoryCycle, audit());
    default_state.dir_entries[index].parent = saved;
    try audit();
}

test "audit rejects directory with multiple parent links" {
    init();
    const a = try createDirectory(root_inode, "a");
    const b = try createDirectory(root_inode, "b");
    const child = try createDirectory(a, "child");
    try addDirEntry(b, "alias", child);
    try testing.expectError(error.DirectoryMultipleParents, audit());
}

test "default RamFS state retains legacy API behavior" {
    init();
    try audit();
    const file = try createFile(root_inode, "state");
    try writeFile(file, "separated");
    try testing.expectEqual(@as(usize, 9), @as(usize, @intCast(default_state.inodes[file].i_size)));
    try testing.expectEqual(@as(usize, 1), storageStats().used_dir_entries);
    try audit();
    init();
    try testing.expectEqual(@as(usize, 0), storageStats().used_dir_entries);
    try audit();
}

test "independent RamFS state initialization and statistics" {
    init();
    const original = storageStats();
    const file = try createFile(root_inode, "legacy");
    try writeFile(file, "data");
    const populated = storageStats();

    var other: State = .{};
    initState(&other);
    const empty = storageStatsFor(&other);
    try testing.expectEqual(@as(usize, 1), empty.used_blocks);
    try testing.expectEqual(@as(usize, 1), empty.used_inodes);
    try testing.expectEqual(@as(usize, 0), empty.used_dir_entries);
    try testing.expectEqual(@as(usize, 0), empty.allocated_data_bytes);
    try testing.expectEqual(original.used_blocks, empty.used_blocks);
    try testing.expectEqual(populated.used_blocks, storageStats().used_blocks);
    try testing.expectEqual(populated.used_dir_entries, storageStats().used_dir_entries);

    other.block_bitmap[0] |= 0b10;
    try testing.expectEqual(@as(usize, 2), storageStatsFor(&other).used_blocks);
    try testing.expectEqual(populated.used_blocks, storageStats().used_blocks);
    initState(&other);
    try testing.expectEqual(@as(usize, 1), storageStatsFor(&other).used_blocks);
    try audit();
}

test "independent block allocators do not share bitmaps or data" {
    init();
    var other: State = .{};
    initState(&other);
    const first = allocateBlock() orelse unreachable;
    const second = allocateBlockFor(&other) orelse unreachable;
    try testing.expectEqual(@as(u32, 1), first);
    try testing.expectEqual(@as(u32, 1), second);
    default_state.memory[block_size] = 0xAB;
    other.memory[block_size] = 0xCD;
    try testing.expectEqual(@as(u8, 0xAB), default_state.memory[block_size]);
    try testing.expectEqual(@as(u8, 0xCD), other.memory[block_size]);
    try testing.expect(freeBlockFor(&other, second));
    try testing.expectEqual(@as(usize, block_count - 1), freeBlockCountFor(&other));
    try testing.expectEqual(@as(usize, block_count - 2), freeBlockCount());
    try testing.expectEqual(@as(u8, 0xAB), default_state.memory[block_size]);
    try testing.expect(!freeBlockFor(&other, 0));
    try testing.expect(!freeBlockFor(&other, second));
    try testing.expect(freeBlock(first));
    try audit();
}
