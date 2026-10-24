//************************************************************************//
//  fs.zig                                                                 //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Fachada de arquivos do VorynOS.
//!
//! A fachada transforma os caminhos e os descritores do contrato das
//! chamadas de sistema em operações do RamFS. Ela mantém uma tabela fixa
//! de arquivos abertos por processo, com deslocamento por descritor, e não
//! depende de hardware: o kernel e os testes de host usam exatamente o
//! mesmo código.
//!
//! Cada processo tem a sua própria tabela de descritores. Dois processos
//! que abrem o mesmo caminho recebem descritores independentes, com
//! deslocamentos independentes, e fechar um descritor em um processo não
//! afeta o outro.

const std = @import("std");
const ramfs = @import("./ramfs.zig");
const vfsx = @import("./vfsx.zig");

/// Namespace único de montagem para a fachada atual.
var namespace: vfsx.Namespace = .{};

/// Encaminha caminhos absolutos ao VFSX; preserva caminhos relativos legados.
fn backendPath(path: []const u8) Error![]const u8 {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] != '/') return path;
    const route = try namespace.route(path);
    return switch (route.backend) {
        .ramfs => route.relative_path,
    };
}

const inode = @import("./inode.zig");

/// Flags de abertura.
pub const O_RDONLY: u16 = 0o0;
pub const O_WRONLY: u16 = 0o1;
pub const O_RDWR: u16 = 0o2;
pub const O_ACCMODE: u16 = 0o3;
pub const O_CREAT: u16 = 0o100;
pub const O_TRUNC: u16 = 0o1000;
pub const O_APPEND: u16 = 0o2000;

/// Número máximo de processos que a fachada conhece.
///
/// O valor é independente do limite de espaços de endereço do paginador:
/// a fachada não depende de hardware e pode ser testada no host com
/// vários processos. O kernel usa os identificadores dos espaços de
/// endereço, que hoje vão de 0 a 3.
pub const max_processes: usize = 8;

/// Número máximo de arquivos abertos ao mesmo tempo em um processo.
pub const max_open_files: usize = 16;

/// Comprimento máximo de um caminho aceito pela fachada.
pub const max_path_len: usize = 255;

/// Descritor de arquivo aberto.
pub const Fd = u32;

/// Erros da fachada.
pub const Error = ramfs.Error || vfsx.Error || error{
    /// A tabela de arquivos abertos está cheia.
    TooManyOpenFiles,
    /// O descritor não existe ou já foi fechado.
    BadDescriptor,
    /// A operação exige um descritor de escrita.
    NotWritable,
    /// A operação exige um descritor de leitura.
    NotReadable,
    /// O inode é um diretório e não pode ser lido como arquivo.
    IsADirectory,
    /// As flags de acesso do descritor são inválidas.
    InvalidFlags,
    /// O identificador de processo não pertence a nenhuma tabela conhecida.
    UnknownProcess,
    /// A operação não pode atravessar montagens distintas.
    CrossMount,
};

/// Entrada da tabela de arquivos abertos.
const OpenFile = struct {
    used: bool = false,
    inode: u32 = 0,
    offset: usize = 0,
    flags: u16 = 0,
};

/// Tabelas de arquivos abertos, uma por processo.
var open_files: [max_processes][max_open_files]OpenFile =
    @splat(@splat(OpenFile{}));

/// Inodes removidos do namespace, aguardando o último close.
var unlinked: [ramfs.inode_count]bool = @splat(false);

fn reclaimIfUnused(inode_num: u32) void {
    if (!unlinked[inode_num]) return;
    for (open_files) |table| {
        for (table) |entry| {
            if (entry.used and entry.inode == inode_num) return;
        }
    }
    unlinked[inode_num] = false;
    ramfs.releaseUnlinked(inode_num);
}

/// Inicializa o RamFS e fecha todos os descritores de todos os processos.
pub fn init() void {
    ramfs.init();
    namespace.init();
    @memset(unlinked[0..], false);
    for (&open_files) |*table| {
        for (table) |*entry| entry.* = .{};
    }
}

/// Verdadeiro quando o descritor permite leitura.
fn readable(flags: u16) bool {
    const access = flags & O_ACCMODE;
    return access == O_RDONLY or access == O_RDWR;
}

/// Verdadeiro quando o descritor permite escrita.
fn writable(flags: u16) bool {
    const access = flags & O_ACCMODE;
    return access == O_WRONLY or access == O_RDWR;
}

/// Devolve a tabela de descritores do processo, ou `null`.
fn tableFor(process_id: u64) ?*[max_open_files]OpenFile {
    if (process_id >= max_processes) return null;
    return &open_files[@as(usize, @intCast(process_id))];
}

/// Devolve a entrada da tabela de descritores, ou `null`.
fn descriptor(process_id: u64, fd: Fd) ?*OpenFile {
    const table = tableFor(process_id) orelse return null;
    if (fd >= max_open_files) return null;
    const entry = &table[fd];
    if (!entry.used) return null;
    return entry;
}

/// Registra um inode na tabela do processo e devolve o descritor.
fn installDescriptor(process_id: u64, inode_num: u32, flags: u16) Error!Fd {
    const table = tableFor(process_id) orelse return error.UnknownProcess;
    if (ramfs.inodeKind(inode_num) != .file) return error.IsADirectory;

    const access = flags & O_ACCMODE;
    if (access != O_RDONLY and access != O_WRONLY and access != O_RDWR) {
        return error.InvalidFlags;
    }

    var free_slot: ?usize = null;
    for (table, 0..) |*entry, index| {
        if (!entry.used) {
            free_slot = index;
            break;
        }
    }
    const index = free_slot orelse return error.TooManyOpenFiles;

    if (flags & O_TRUNC != 0) {
        if (!writable(flags)) return error.NotWritable;
        try ramfs.truncate(inode_num, 0);
    }

    var offset: usize = 0;
    if (flags & O_APPEND != 0) {
        offset = @intCast(ramfs.sizeOf(inode_num) orelse 0);
    }

    table[index] = .{
        .used = true,
        .inode = inode_num,
        .offset = offset,
        .flags = flags,
    };
    return @as(Fd, @intCast(index));
}

/// Partes de um caminho: o diretório pai e o último componente.
const PathParts = struct {
    parent: u32,
    name: []const u8,
};

/// Separa o diretório pai do nome do último componente.
fn splitPath(path: []const u8) Error!PathParts {
    if (path.len == 0 or path.len > max_path_len) return error.InvalidPath;

    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];

    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse {
        return .{ .parent = ramfs.root_inode, .name = trimmed };
    };

    const name = trimmed[slash + 1 ..];
    if (name.len == 0) return error.InvalidPath;

    const parent_path = if (slash == 0) "/" else trimmed[0..slash];
    const parent = try ramfs.resolvePath(parent_path);
    return .{ .parent = parent, .name = name };
}

/// Cria o inode de um arquivo e adiciona a entrada de diretório.
fn createInode(path: []const u8) Error!u32 {
    const parts = try splitPath(try backendPath(path));
    return ramfs.createFile(parts.parent, parts.name);
}

/// Cria um arquivo e devolve um descritor aberto para leitura e escrita.
pub fn create(process_id: u64, path: []const u8, mode: u16) Error!Fd {
    _ = mode;
    const inode_num = try createInode(path);
    return installDescriptor(process_id, inode_num, O_RDWR);
}

/// Cria um diretório e devolve o inode dele.
pub fn mkdir(path: []const u8) Error!u32 {
    const parts = try splitPath(try backendPath(path));
    return ramfs.createDirectory(parts.parent, parts.name);
}

/// Abre um arquivo. As flags `O_CREAT` criam o arquivo quando ele não
/// existe; as demais exigem que o caminho já exista.
pub fn open(process_id: u64, path: []const u8, flags: u16) Error!Fd {
    const target = ramfs.resolvePath(try backendPath(path)) catch |err| {
        if (err == error.EntryNotFound and flags & O_CREAT != 0) {
            const inode_num = try createInode(path);
            return installDescriptor(process_id, inode_num, flags);
        }
        return err;
    };
    return installDescriptor(process_id, target, flags);
}

/// Fecha um descritor.
pub fn close(process_id: u64, fd: Fd) Error!void {
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    const inode_num = entry.inode;
    entry.* = .{};
    reclaimIfUnused(inode_num);
}

/// Fecha todos os descritores de um processo e recupera inodes desvinculados
/// apenas quando nenhuma outra tabela de processo os referencia.
pub fn closeAll(process_id: u64) Error!void {
    const table = tableFor(process_id) orelse return error.UnknownProcess;
    // Primeiro, remove todas as referências do processo; depois recupera.
    // Assim, inodes compartilhados por vários descritores não são liberados cedo.
    var candidates: [max_open_files]u32 = undefined;
    var count: usize = 0;
    for (table) |*entry| {
        if (!entry.used) continue;
        candidates[count] = entry.inode;
        count += 1;
        entry.* = .{};
    }
    for (candidates[0..count]) |inode_num| reclaimIfUnused(inode_num);
}

/// Lê do descritor e avança o deslocamento.
pub fn read(process_id: u64, fd: Fd, buffer: []u8) Error!usize {
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    if (!readable(entry.flags)) return error.NotReadable;

    const count = try ramfs.readFileAt(entry.inode, entry.offset, buffer);
    entry.offset += count;
    return count;
}

/// Escreve no descritor e avança o deslocamento.
pub fn write(process_id: u64, fd: Fd, data: []const u8) Error!usize {
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    if (!writable(entry.flags)) return error.NotWritable;

    const count = try ramfs.writeFileAt(entry.inode, entry.offset, data);
    entry.offset += count;
    return count;
}

/// Move o deslocamento do descritor.
pub fn seek(process_id: u64, fd: Fd, offset: usize) Error!void {
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    entry.offset = offset;
}

/// Deslocamento atual do descritor.
pub fn tell(process_id: u64, fd: Fd) Error!usize {
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    return entry.offset;
}

/// Lê um arquivo inteiro pelo caminho, sem abrir descritor.
pub fn readFile(path: []const u8, buffer: []u8) Error!usize {
    const target = try ramfs.resolvePath(try backendPath(path));
    return ramfs.readFile(target, buffer);
}

/// Substitui o conteúdo de um arquivo pelo caminho, sem abrir descritor.
pub fn writeFile(path: []const u8, data: []const u8) Error!void {
    const target = try ramfs.resolvePath(try backendPath(path));
    return ramfs.writeFile(target, data);
}

/// Tamanho de um arquivo pelo caminho.
pub fn sizeOf(path: []const u8) Error!u64 {
    const target = try ramfs.resolvePath(try backendPath(path));
    if (ramfs.inodeKind(target) != .file) return error.NotAFile;
    return ramfs.sizeOf(target) orelse error.NotAFile;
}

/// Move ou renomeia um arquivo regular dentro da mesma montagem.
pub fn rename(source: []const u8, target: []const u8) Error!void {
    if (source.len == 0 or target.len == 0) return error.InvalidPath;
    if (source[0] != '/' or target[0] != '/') return error.InvalidPath;
    const from_route = try namespace.route(source);
    const to_route = try namespace.route(target);
    if (from_route.slot != to_route.slot) return error.CrossMount;
    const from = try splitPath(from_route.relative_path);
    const to = try splitPath(to_route.relative_path);
    switch (from_route.backend) {
        .ramfs => try ramfs.renameFile(from.parent, from.name, to.parent, to.name),
    }
}

/// Remove um nome de arquivo; descritores já abertos permanecem válidos.
pub fn unlink(path: []const u8) Error!void {
    if (path.len == 0 or path[0] != '/') return error.InvalidPath;
    const route = try namespace.route(path);
    const parts = try splitPath(route.relative_path);
    const target = switch (route.backend) {
        .ramfs => try ramfs.unlinkFile(parts.parent, parts.name),
    };
    unlinked[target] = true;
    reclaimIfUnused(target);
}

/// Metadados básicos de um caminho, sem alterar a ABI das syscalls.
pub const FileStat = struct {
    inode: u32,
    kind: inode.InodeType,
    size: u64,
    permissions: u16,
    links: u32,
};

/// Consulta metadados pelo VFSX, sem alocação dinâmica.
pub fn stat(path: []const u8) Error!FileStat {
    const target = try ramfs.resolvePath(try backendPath(path));
    const info = try ramfs.getInodeInfo(target);
    return .{
        .inode = target,
        .kind = info.i_type,
        .size = info.i_size,
        .permissions = info.i_permissions,
        .links = info.i_links_count,
    };
}

/// Número de blocos livres do RamFS.
pub fn freeBlockCount() usize {
    return ramfs.freeBlockCount();
}

/// Tipo do inode de um caminho, ou `null` quando ele não existe.
pub fn kindOf(path: []const u8) ?inode.InodeType {
    const target = ramfs.resolvePath(backendPath(path) catch return null) catch return null;
    return ramfs.inodeKind(target);
}

// ---------------------------------------------------------------------------
// Testes
// ---------------------------------------------------------------------------

const testing = std.testing;

test "create, write, seek and read through a descriptor" {
    init();

    const fd = try create(0, "/hello.txt", 0o644);
    try testing.expectEqual(@as(usize, 5), try write(0, fd, "hello"));
    try testing.expectEqual(@as(usize, 6), try write(0, fd, " world"));
    try testing.expectEqual(@as(usize, 11), try tell(0, fd));

    try seek(0, fd, 0);

    var buffer: [16]u8 = undefined;
    const count = try read(0, fd, &buffer);
    try testing.expectEqual(@as(usize, 11), count);
    try testing.expectEqualSlices(u8, "hello world", buffer[0..count]);

    // Uma leitura depois do fim não inventa dados.
    try testing.expectEqual(@as(usize, 0), try read(0, fd, &buffer));

    try close(0, fd);
    try testing.expectError(error.BadDescriptor, close(0, fd));
    try testing.expectError(error.BadDescriptor, read(0, fd, &buffer));
}

test "open with O_CREAT, O_TRUNC and O_APPEND" {
    init();

    try testing.expectError(error.EntryNotFound, open(0, "/missing.txt", O_RDONLY));

    const created = try open(0, "/log.txt", O_CREAT | O_RDWR);
    _ = try write(0, created, "first");
    try close(0, created);

    // O_CREAT respeita o modo de acesso pedido: um descritor criado para
    // escrita não serve para leitura.
    var probe: [4]u8 = undefined;
    const write_only = try open(0, "/created.txt", O_CREAT | O_WRONLY);
    try testing.expectError(error.NotReadable, read(0, write_only, &probe));
    try close(0, write_only);

    const appended = try open(0, "/log.txt", O_WRONLY | O_APPEND);
    _ = try write(0, appended, "+second");
    try close(0, appended);

    var buffer: [32]u8 = undefined;
    var count = try readFile("/log.txt", &buffer);
    try testing.expectEqualSlices(u8, "first+second", buffer[0..count]);

    const truncated = try open(0, "/log.txt", O_RDWR | O_TRUNC);
    try testing.expectEqual(@as(u64, 0), try sizeOf("/log.txt"));
    try close(0, truncated);

    count = try readFile("/log.txt", &buffer);
    try testing.expectEqual(@as(usize, 0), count);
}

test "nested paths require the parent directory" {
    init();

    try testing.expectError(error.EntryNotFound, create(0, "/apps/demo.elf", 0o755));

    const apps = try mkdir("/apps");
    try testing.expectEqual(inode.InodeType.directory, kindOf("/apps").?);

    const fd = try create(0, "/apps/demo.elf", 0o755);
    _ = try write(0, fd, "ELF");
    try close(0, fd);

    try testing.expectEqual(apps, try ramfs.resolvePath("/apps"));
    try testing.expectEqual(@as(u64, 3), try sizeOf("/apps/demo.elf"));

    try testing.expectError(error.NameExists, mkdir("/apps"));
    try testing.expectError(error.NotADirectory, create(0, "/apps/demo.elf/child", 0o644));
}

test "access flags are enforced" {
    init();

    const fd = try create(0, "/flags.txt", 0o644);
    try close(0, fd);

    var buffer: [8]u8 = undefined;

    const read_only = try open(0, "/flags.txt", O_RDONLY);
    try testing.expectError(error.NotWritable, write(0, read_only, "x"));
    try close(0, read_only);

    const write_only = try open(0, "/flags.txt", O_WRONLY);
    try testing.expectError(error.NotReadable, read(0, write_only, &buffer));
    try close(0, write_only);

    try testing.expectError(error.InvalidFlags, open(0, "/flags.txt", 0o3));
    try testing.expectError(error.NotWritable, open(0, "/flags.txt", O_RDONLY | O_TRUNC));
}

test "descriptors are independent per process" {
    init();
    const seed = try create(0, "/shared.txt", 0o644);
    _ = try write(0, seed, "abc");
    try close(0, seed);

    const first = try open(0, "/shared.txt", O_RDONLY);
    const second = try open(1, "/shared.txt", O_RDONLY);

    var buffer_a: [8]u8 = undefined;
    var buffer_b: [8]u8 = undefined;
    const count_a = try read(0, first, &buffer_a);
    const count_b = try read(1, second, &buffer_b);
    try testing.expectEqual(@as(usize, 3), count_a);
    try testing.expectEqual(@as(usize, 3), count_b);
    try testing.expectEqualStrings("abc", buffer_a[0..count_a]);
    try testing.expectEqualStrings("abc", buffer_b[0..count_b]);

    // The two offsets are independent: rewinding one does not rewind the
    // other.
    try seek(0, first, 0);
    try testing.expectEqual(@as(usize, 0), try read(1, second, &buffer_b));

    try close(0, first);
    try close(1, second);

    try testing.expectError(error.UnknownProcess, create(8, "/x.txt", 0o644));
}

test "descriptor table is bounded and reusable" {
    init();

    const fd = try create(0, "/shared.txt", 0o644);
    try close(0, fd);

    var descriptors: [max_open_files]Fd = undefined;
    for (&descriptors) |*slot| {
        slot.* = try open(0, "/shared.txt", O_RDONLY);
    }
    try testing.expectError(error.TooManyOpenFiles, open(0, "/shared.txt", O_RDONLY));

    try close(0, descriptors[0]);
    descriptors[0] = try open(0, "/shared.txt", O_RDONLY);

    for (descriptors) |descriptor_fd| {
        try close(0, descriptor_fd);
    }

    // A tabela volta a aceitar todos os descritores depois de fechados.
    for (&descriptors) |*slot| {
        slot.* = try open(0, "/shared.txt", O_RDONLY);
    }
    for (descriptors) |descriptor_fd| {
        try close(0, descriptor_fd);
    }
}

// M0.3.1: facade dispatch regression coverage.
test "VFSX routes absolute facade paths and rejects traversal" {
    init();
    const fd = try create(0, "/route.txt", 0o644);
    _ = try write(0, fd, "vfsx");
    try close(0, fd);
    var data: [8]u8 = undefined;
    const count = try readFile("/route.txt", &data);
    try testing.expectEqualStrings("vfsx", data[0..count]);
    try testing.expectError(error.InvalidPath, open(0, "/../route.txt", O_RDONLY));
    try testing.expectError(error.InvalidPath, mkdir("/a/../b"));
}

test "VFSX stat reports file and directory metadata" {
    init();
    const directory = try mkdir("/meta");
    const fd = try create(0, "/meta/data", 0o644);
    _ = try write(0, fd, "abc");
    try close(0, fd);

    const dir_stat = try stat("/meta");
    try testing.expectEqual(directory, dir_stat.inode);
    try testing.expectEqual(inode.InodeType.directory, dir_stat.kind);
    try testing.expectEqual(@as(u64, 0), dir_stat.size);

    const file_stat = try stat("/meta/data");
    try testing.expectEqual(inode.InodeType.file, file_stat.kind);
    try testing.expectEqual(@as(u64, 3), file_stat.size);
    try testing.expectEqual(@as(u32, 1), file_stat.links);
    try testing.expectError(error.EntryNotFound, stat("/meta/missing"));
    try testing.expectError(error.InvalidPath, stat("/meta/../data"));
}

test "VFSX rename preserves open descriptors and rejects directory moves" {
    init();
    _ = try mkdir("/source");
    _ = try mkdir("/destination");
    const fd = try create(0, "/source/item", 0o644);
    _ = try write(0, fd, "persistent");
    try rename("/source/item", "/destination/new");
    try testing.expectError(error.EntryNotFound, stat("/source/item"));
    try testing.expectEqual(@as(u64, 10), (try stat("/destination/new")).size);
    try seek(0, fd, 0);
    var buffer: [16]u8 = undefined;
    const count = try read(0, fd, &buffer);
    try testing.expectEqualStrings("persistent", buffer[0..count]);
    try close(0, fd);
    try testing.expectError(error.NotAFile, rename("/source", "/destination/moved"));
    try testing.expectError(error.InvalidPath, rename("/destination/new", "/destination/../bad"));
}

test "VFSX unlink retains open descriptors until last close" {
    init();
    const fd = try create(0, "/removed", 0o644);
    _ = try write(0, fd, "keep");
    const other = try open(1, "/removed", O_RDONLY);
    const old_inode = (try stat("/removed")).inode;
    const blocks_before = freeBlockCount();
    try unlink("/removed");
    try testing.expectError(error.EntryNotFound, stat("/removed"));
    try testing.expectError(error.EntryNotFound, open(2, "/removed", O_RDONLY));
    try seek(0, fd, 0);
    var buf: [8]u8 = undefined;
    const count = try read(0, fd, &buf);
    try testing.expectEqualStrings("keep", buf[0..count]);
    try close(0, fd);
    try testing.expectEqual(blocks_before, freeBlockCount());
    try testing.expectEqual(@as(usize, 4), try read(1, other, &buf));
    try close(1, other);
    try testing.expectEqual(blocks_before + 1, freeBlockCount());
    try testing.expect(ramfs.inodeKind(old_inode) == null);
    try testing.expectError(error.EntryNotFound, unlink("/removed"));
    _ = try mkdir("/directory");
    try testing.expectError(error.NotAFile, unlink("/directory"));
    try testing.expectError(error.InvalidPath, unlink("/../invalid"));
}

test "closeAll releases unlinked inode only after last process exits" {
    init();
    const first = try create(0, "/ephemeral", 0o644);
    _ = try write(0, first, "payload");
    const second = try open(0, "/ephemeral", O_RDONLY);
    const third = try open(1, "/ephemeral", O_RDONLY);
    const inode_num = (try stat("/ephemeral")).inode;
    const blocks_before = freeBlockCount();
    try unlink("/ephemeral");
    try closeAll(0);
    try testing.expectEqual(blocks_before, freeBlockCount());
    try testing.expect(ramfs.inodeKind(inode_num) != null);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 7), try read(1, third, &buf));
    try testing.expectEqualStrings("payload", buf[0..7]);
    try testing.expectError(error.BadDescriptor, close(0, first));
    try testing.expectError(error.BadDescriptor, close(0, second));
    try closeAll(1);
    try testing.expectEqual(blocks_before + 1, freeBlockCount());
    try testing.expect(ramfs.inodeKind(inode_num) == null);
    try closeAll(1); // idempotente
    try testing.expectError(error.UnknownProcess, closeAll(max_processes));
}

test "closeAll keeps linked files and allows descriptor reuse" {
    init();
    const fd = try create(2, "/persistent", 0o644);
    _ = try write(2, fd, "ok");
    const inode_num = (try stat("/persistent")).inode;
    try closeAll(2);
    try testing.expect(ramfs.inodeKind(inode_num) != null);
    const reopened = try open(2, "/persistent", O_RDONLY);
    try testing.expectEqual(fd, reopened);
    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try read(2, reopened, &buf));
    try closeAll(2);
}
