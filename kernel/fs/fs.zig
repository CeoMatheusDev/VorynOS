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
    if (route.volume_id != 0) return error.UnsupportedVolume;
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

/// Handle interno com geração; a ABI atual de syscalls continua usando Fd.
pub const CheckedFd = u64;

const max_fd_sequence: u32 = 0x00ff_ffff;

/// Erros da fachada.
pub const Error = ramfs.Error || vfsx.Error || error{
    /// A tabela de arquivos abertos está cheia.
    TooManyOpenFiles,
    /// Nenhuma posição livre possui geração disponível.
    DescriptorGenerationExhausted,
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
    generation: u32 = 0,
};

/// Tabelas de arquivos abertos, uma por processo.
var open_files: [max_processes][max_open_files]OpenFile =
    @splat(@splat(OpenFile{}));

/// Contadores persistentes por posição: não reiniciam ao fechar a tabela.
var fd_generations: [max_processes][max_open_files]u32 =
    @splat(@splat(0));

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

/// Valida flags e disponibilidade antes de qualquer mutação do namespace.
fn preflightDescriptor(process_id: u64, flags: u16) Error!void {
    const table = tableFor(process_id) orelse return error.UnknownProcess;
    const access = flags & O_ACCMODE;
    if (access != O_RDONLY and access != O_WRONLY and access != O_RDWR) return error.InvalidFlags;
    if (flags & O_TRUNC != 0 and !writable(flags)) return error.NotWritable;

    const process_index: usize = @intCast(process_id);
    var retired_free = false;
    for (table, 0..) |entry, index| {
        if (entry.used) continue;
        if ((fd_generations[process_index][index] & max_fd_sequence) != max_fd_sequence) return;
        retired_free = true;
    }
    if (retired_free) return error.DescriptorGenerationExhausted;
    return error.TooManyOpenFiles;
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
        if (!entry.used and (fd_generations[@as(usize, @intCast(process_id))][index] & max_fd_sequence) != max_fd_sequence) {
            free_slot = index;
            break;
        }
    }
    const index = free_slot orelse {
        for (table, 0..) |entry, slot| {
            if (!entry.used and (fd_generations[@as(usize, @intCast(process_id))][slot] & max_fd_sequence) == max_fd_sequence) {
                return error.DescriptorGenerationExhausted;
            }
        }
        return error.TooManyOpenFiles;
    };

    if (flags & O_TRUNC != 0) {
        if (!writable(flags)) return error.NotWritable;
        try ramfs.truncate(inode_num, 0);
    }

    var offset: usize = 0;
    if (flags & O_APPEND != 0) {
        offset = @intCast(ramfs.sizeOf(inode_num) orelse 0);
    }

    const process_index: usize = @intCast(process_id);
    // 24 bits para a geração e 8 bits para a identidade da tabela.
    // Nunca reutiliza a geração: posições esgotadas são aposentadas.
    const sequence = (fd_generations[process_index][index] & max_fd_sequence) + 1;
    fd_generations[process_index][index] = (@as(u32, @intCast(process_index)) << 24) | sequence;
    table[index] = .{
        .generation = fd_generations[process_index][index],
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
    try preflightDescriptor(process_id, O_RDWR);
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
    try preflightDescriptor(process_id, flags);
    const target = ramfs.resolvePath(try backendPath(path)) catch |err| {
        if (err == error.EntryNotFound and flags & O_CREAT != 0) {
            const inode_num = try createInode(path);
            return installDescriptor(process_id, inode_num, flags);
        }
        return err;
    };
    return installDescriptor(process_id, target, flags);
}

/// Emite um handle verificável para um descritor já aberto.
/// O identificador inclui geração e posição; o ID do processo é validado
/// separadamente, evitando acesso cruzado entre tabelas.
pub fn checkedFd(process_id: u64, fd: Fd) Error!CheckedFd {
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    return (@as(u64, entry.generation) << 32) | @as(u64, fd);
}

/// Valida geração e processo antes de devolver o índice da tabela.
pub fn validateCheckedFd(process_id: u64, handle: CheckedFd) Error!Fd {
    const fd: Fd = @truncate(handle);
    const generation: u32 = @truncate(handle >> 32);
    if (generation == 0) return error.BadDescriptor;
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    if (entry.generation != generation) return error.BadDescriptor;
    return fd;
}

/// Fecha apenas se o handle ainda identifica a mesma abertura.
pub fn closeChecked(process_id: u64, handle: CheckedFd) Error!void {
    return close(process_id, try validateCheckedFd(process_id, handle));
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
    // Uma escrita vazia não altera nem o arquivo nem o offset, inclusive em O_APPEND.
    if (data.len == 0) return 0;

    // O_APPEND é uma propriedade da operação de escrita, não apenas
    // do deslocamento inicial da abertura. Outros descritores podem
    // alterar o tamanho do arquivo entre duas escritas.
    const position: usize = if (entry.flags & O_APPEND != 0)
        @intCast(ramfs.sizeOf(entry.inode) orelse return error.InvalidInode)
    else
        entry.offset;
    const count = try ramfs.writeFileAt(entry.inode, position, data);
    entry.offset = position + count;
    return count;
}

/// Encolhe o arquivo aberto; não altera o deslocamento do descritor.
/// A validação de acesso acontece antes de modificar o inode.
pub fn truncateFd(process_id: u64, fd: Fd, new_size: usize) Error!void {
    const entry = descriptor(process_id, fd) orelse return error.BadDescriptor;
    if (!writable(entry.flags)) return error.NotWritable;
    try ramfs.truncate(entry.inode, new_size);
}

/// Encolhe um arquivo pelo caminho, sem consumir um descritor.
pub fn truncateFile(path: []const u8, new_size: usize) Error!void {
    const target = try ramfs.resolvePath(try backendPath(path));
    try ramfs.truncate(target, new_size);
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

/// Runs a read-only integrity audit of the current RamFS backend.
/// This diagnostic does not modify descriptors, offsets, or namespace state.
/// Call only while filesystem mutations are quiescent.
pub fn auditStorage() ramfs.AuditError!void {
    return ramfs.audit();
}

/// Snapshot of RamFS capacity and occupancy without dynamic allocation.
pub fn storageStats() ramfs.StorageStats {
    return ramfs.storageStats();
}

/// Inodes livres do RamFS, para diagnóstico e testes de recuperação.
pub fn freeInodeCount() usize {
    return ramfs.freeInodeCount();
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

test "process descriptor tables isolate equal fd numbers and offsets" {
    init();
    const owner_fd = try create(0, "/isolated", 0o600);
    _ = try write(0, owner_fd, "abcdef");
    const peer_fd = try open(1, "/isolated", O_RDONLY);
    try testing.expectEqual(owner_fd, peer_fd);
    var first: [2]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try read(1, peer_fd, &first));
    try testing.expectEqualStrings("ab", &first);
    try testing.expectEqual(@as(usize, 6), try tell(0, owner_fd));
    try testing.expectEqual(@as(usize, 2), try tell(1, peer_fd));
    try testing.expectEqual(@as(usize, 0), try read(0, owner_fd, &first));
    try closeAll(0);
    try testing.expectError(error.BadDescriptor, close(0, owner_fd));
    var second: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try read(1, peer_fd, &second));
    try testing.expectEqualStrings("cdef", &second);
    try closeAll(1);
}

test "reused process slot does not retain old descriptors or offsets" {
    init();
    const old_fd = try create(3, "/previous", 0o600);
    _ = try write(3, old_fd, "old");
    try closeAll(3);
    var scratch: [1]u8 = undefined;
    try testing.expectError(error.BadDescriptor, read(3, old_fd, &scratch));
    const new_fd = try open(3, "/previous", O_RDONLY);
    try testing.expectEqual(old_fd, new_fd);
    try testing.expectEqual(@as(usize, 0), try tell(3, new_fd));
    var bytes: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try read(3, new_fd, &bytes));
    try testing.expectEqualStrings("old", &bytes);
    try closeAll(3);
    try testing.expectError(error.BadDescriptor, close(3, new_fd));
}

test "unlink and process slot reuse cannot resurrect reclaimed inode" {
    init();
    const fd = try create(4, "/obsolete", 0o600);
    _ = try write(4, fd, "gone");
    const inode_num = (try stat("/obsolete")).inode;
    const blocks_before = freeBlockCount();
    try unlink("/obsolete");
    try closeAll(4);
    try testing.expectEqual(blocks_before + 1, freeBlockCount());
    try testing.expect(ramfs.inodeKind(inode_num) == null);
    try testing.expectError(error.EntryNotFound, open(4, "/obsolete", O_RDONLY));
    try testing.expectError(error.BadDescriptor, close(4, fd));
    const fresh = try create(4, "/fresh", 0o600);
    try testing.expectEqual(fd, fresh);
    try testing.expectEqual(@as(usize, 0), try tell(4, fresh));
    try closeAll(4);
}

test "checked handles reject stale generation after fd reuse" {
    init();
    const first = try create(0, "/checked-first", 0o600);
    const old_handle = try checkedFd(0, first);
    try closeChecked(0, old_handle);
    const second = try create(0, "/checked-second", 0o600);
    try testing.expectEqual(first, second);
    const new_handle = try checkedFd(0, second);
    try testing.expect(old_handle != new_handle);
    try testing.expectError(error.BadDescriptor, validateCheckedFd(0, old_handle));
    try testing.expectError(error.BadDescriptor, closeChecked(0, old_handle));
    try testing.expectEqual(second, try validateCheckedFd(0, new_handle));
    try closeChecked(0, new_handle);
}

test "checked handles reject cross-process use and termination reuse" {
    init();
    const first = try create(1, "/checked-owner", 0o600);
    const handle = try checkedFd(1, first);
    try testing.expectError(error.BadDescriptor, validateCheckedFd(2, handle));
    try closeAll(1);
    try testing.expectError(error.BadDescriptor, validateCheckedFd(1, handle));
    const reused = try open(1, "/checked-owner", O_RDONLY);
    try testing.expectEqual(first, reused);
    try testing.expectError(error.BadDescriptor, validateCheckedFd(1, handle));
    try closeAll(1);
}

test "exhausted generation retires slot without wrapping" {
    init();
    const process: usize = 6;
    const retired_slot: usize = 0;
    const previous = fd_generations[process][retired_slot];
    defer fd_generations[process][retired_slot] = previous;
    fd_generations[process][retired_slot] = (@as(u32, @intCast(process)) << 24) | max_fd_sequence;
    const fd = try create(process, "/retirement", 0o600);
    try testing.expectEqual(@as(Fd, 1), fd);
    try testing.expectEqual((@as(u32, @intCast(process)) << 24) | max_fd_sequence, fd_generations[process][retired_slot]);
    try closeAll(process);
}

test "all retired slots report generation exhaustion" {
    init();
    const process: usize = 7;
    const previous = fd_generations[process];
    defer fd_generations[process] = previous;
    for (&fd_generations[process]) |*generation| {
        generation.* = (@as(u32, @intCast(process)) << 24) | max_fd_sequence;
    }
    try testing.expectError(error.DescriptorGenerationExhausted, create(process, "/no-generation", 0o600));
    try testing.expectError(error.DescriptorGenerationExhausted, open(process, "/no-generation", O_RDONLY));
}

test "create rejects full descriptor table before modifying namespace" {
    init();
    const process: u64 = 0;
    var fds: [max_open_files]Fd = undefined;
    for (&fds, 0..) |*fd, index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "/filled-{d}", .{index});
        fd.* = try create(process, path, 0o600);
    }
    const before_inodes = freeInodeCount();
    const before_blocks = freeBlockCount();
    try testing.expectError(error.TooManyOpenFiles, create(process, "/must-not-exist", 0o600));
    try testing.expectError(error.TooManyOpenFiles, open(process, "/must-not-exist", O_CREAT | O_RDWR));
    try testing.expectError(error.EntryNotFound, ramfs.resolvePath("/must-not-exist"));
    try testing.expectEqual(before_inodes, freeInodeCount());
    try testing.expectEqual(before_blocks, freeBlockCount());
    try closeAll(process);
}

test "generation exhaustion rejects create without allocating inode" {
    init();
    const process: usize = 7;
    const previous = fd_generations[process];
    defer fd_generations[process] = previous;
    for (&fd_generations[process]) |*generation| {
        generation.* = (@as(u32, @intCast(process)) << 24) | max_fd_sequence;
    }
    const before_inodes = freeInodeCount();
    const before_blocks = freeBlockCount();
    try testing.expectError(error.DescriptorGenerationExhausted, create(process, "/retired-no-create", 0o600));
    try testing.expectError(error.DescriptorGenerationExhausted, open(process, "/retired-no-create", O_CREAT | O_RDWR));
    try testing.expectError(error.EntryNotFound, ramfs.resolvePath("/retired-no-create"));
    try testing.expectEqual(before_inodes, freeInodeCount());
    try testing.expectEqual(before_blocks, freeBlockCount());
}

test "O_APPEND writes use current EOF across independent descriptors" {
    init();
    const first = try open(0, "/append.txt", O_CREAT | O_RDWR | O_APPEND);
    const second = try open(1, "/append.txt", O_RDWR);
    try testing.expectEqual(@as(usize, 3), try write(0, first, "one"));
    try seek(0, first, 0);
    try testing.expectEqual(@as(usize, 3), try write(1, second, "two"));
    try testing.expectEqual(@as(usize, 1), try write(0, first, "!"));
    try testing.expectEqual(@as(usize, 4), try tell(0, first));
    var result: [8]u8 = undefined;
    const count = try readFile("/append.txt", &result);
    try testing.expectEqualStrings("two!", result[0..count]);
    try close(1, second);
    try close(0, first);
}

test "truncateFd enforces access and retains independent descriptor offsets" {
    init();
    const writer = try open(0, "/trunc.txt", O_CREAT | O_RDWR);
    try testing.expectEqual(@as(usize, 8), try write(0, writer, "abcdefgh"));
    const reader = try open(1, "/trunc.txt", O_RDONLY);
    try testing.expectError(error.NotWritable, truncateFd(1, reader, 2));
    try testing.expectEqual(@as(u64, 8), try sizeOf("/trunc.txt"));
    try truncateFd(0, writer, 3);
    try testing.expectEqual(@as(u64, 3), try sizeOf("/trunc.txt"));
    try testing.expectEqual(@as(usize, 8), try tell(0, writer));
    var result: [8]u8 = undefined;
    const count = try read(1, reader, &result);
    try testing.expectEqualStrings("abc", result[0..count]);
    try testing.expectError(error.InvalidOffset, truncateFd(0, writer, 4));
    try testing.expectError(error.BadDescriptor, truncateFd(0, @as(Fd, @intCast(max_open_files)), 0));
    try close(1, reader);
    try close(0, writer);
}

test "truncateFile handles paths and frees RamFS blocks" {
    init();
    const fd = try open(0, "/path-trunc", O_CREAT | O_RDWR);
    const payload: [ramfs.block_size * 2]u8 = @splat(0x61);
    _ = try write(0, fd, &payload);
    const before = freeBlockCount();
    try truncateFile("/path-trunc", 0);
    try testing.expectEqual(before + 2, freeBlockCount());
    try testing.expectEqual(@as(u64, 0), try sizeOf("/path-trunc"));
    try testing.expectError(error.EntryNotFound, truncateFile("/missing", 0));
    try close(0, fd);
}

// M0.3.17: append/truncate semantics and descriptor lifetime regressions.
test "zero-length append write preserves offset even when EOF changes" {
    init();
    const appender = try open(0, "/append-empty", O_CREAT | O_RDWR | O_APPEND);
    const writer = try open(1, "/append-empty", O_RDWR);
    try testing.expectEqual(@as(usize, 4), try write(1, writer, "data"));
    try seek(0, appender, 2);
    const blocks_before = freeBlockCount();
    try testing.expectEqual(@as(usize, 0), try write(0, appender, ""));
    try testing.expectEqual(@as(usize, 2), try tell(0, appender));
    try testing.expectEqual(blocks_before, freeBlockCount());
    try testing.expectEqual(@as(u64, 4), try sizeOf("/append-empty"));
    try testing.expectEqual(@as(usize, 1), try write(0, appender, "!"));
    try testing.expectEqual(@as(usize, 5), try tell(0, appender));
    var buffer: [8]u8 = undefined;
    const count = try readFile("/append-empty", &buffer);
    try testing.expectEqualStrings("data!", buffer[0..count]);
    try closeAll(0);
    try closeAll(1);
}

test "append follows truncate and retains inode after unlink until last close" {
    init();
    const appender = try open(0, "/append-lifetime", O_CREAT | O_RDWR | O_APPEND);
    const reader = try open(1, "/append-lifetime", O_RDONLY);
    try testing.expectEqual(@as(usize, 6), try write(0, appender, "abcdef"));
    try truncateFd(0, appender, 2);
    try testing.expectEqual(@as(usize, 1), try write(0, appender, "!"));
    try testing.expectEqual(@as(usize, 3), try tell(0, appender));
    const inode_num = (try stat("/append-lifetime")).inode;
    const blocks_before = freeBlockCount();
    try unlink("/append-lifetime");
    try closeAll(0);
    try testing.expectEqual(blocks_before, freeBlockCount());
    try testing.expect(ramfs.inodeKind(inode_num) != null);
    var buffer: [8]u8 = undefined;
    const count = try read(1, reader, &buffer);
    try testing.expectEqualStrings("ab!", buffer[0..count]);
    try closeAll(1);
    try testing.expectEqual(blocks_before + 1, freeBlockCount());
    try testing.expect(ramfs.inodeKind(inode_num) == null);
}

test "truncate does not validate stale checked handles as live descriptors" {
    init();
    const original = try open(2, "/truncate-handle", O_CREAT | O_RDWR);
    const stale = try checkedFd(2, original);
    try close(2, original);
    const reused = try open(2, "/truncate-handle", O_RDWR);
    try testing.expectEqual(original, reused);
    try testing.expectError(error.BadDescriptor, validateCheckedFd(2, stale));
    try testing.expectEqual(@as(usize, 4), try write(2, reused, "data"));
    try truncateFd(2, reused, 2);
    try testing.expectEqual(@as(u64, 2), try sizeOf("/truncate-handle"));
    try closeAll(2);
}


// M0.3.18: rollback de escrita e isolamento entre tabelas de descritores.
test "failed oversized write preserves offset content and block allocation" {
    init();
    const fd = try open(0, "/oversized-rollback", O_CREAT | O_RDWR);
    _ = try write(0, fd, "stable");
    const blocks_before = freeBlockCount();
    const offset_before = try tell(0, fd);
    try seek(0, fd, ramfs.max_file_size);
    try testing.expectError(error.FileTooLarge, write(0, fd, "!"));
    try testing.expectEqual(@as(usize, ramfs.max_file_size), try tell(0, fd));
    try testing.expectEqual(blocks_before, freeBlockCount());
    try testing.expectEqual(@as(u64, 6), try sizeOf("/oversized-rollback"));
    try seek(0, fd, 0);
    var buffer: [8]u8 = undefined;
    const count = try read(0, fd, &buffer);
    try testing.expectEqualStrings("stable", buffer[0..count]);
    try testing.expectEqual(@as(usize, 6), offset_before);
    try closeAll(0);
}

test "failed append write retains descriptor offset after external truncate" {
    init();
    const appender = try open(0, "/append-failure", O_CREAT | O_RDWR | O_APPEND);
    const writer = try open(1, "/append-failure", O_RDWR);
    _ = try write(1, writer, "abcdef");
    try seek(0, appender, 1);
    try truncateFd(1, writer, 2);
    const before = freeBlockCount();
    const huge: [ramfs.max_file_size]u8 = @splat(0x78);
    try testing.expectError(error.FileTooLarge, write(0, appender, &huge));
    try testing.expectEqual(@as(usize, 1), try tell(0, appender));
    try testing.expectEqual(@as(u64, 2), try sizeOf("/append-failure"));
    try testing.expectEqual(before, freeBlockCount());
    try testing.expectEqual(@as(usize, 1), try write(0, appender, "!"));
    var buffer: [8]u8 = undefined;
    const count = try readFile("/append-failure", &buffer);
    try testing.expectEqualStrings("ab!", buffer[0..count]);
    try closeAll(0);
    try closeAll(1);
}

test "truncate cannot cross process descriptor tables" {
    init();
    const owner = try open(0, "/truncate-isolation", O_CREAT | O_RDWR);
    _ = try write(0, owner, "private");
    try testing.expectError(error.BadDescriptor, truncateFd(1, owner, 0));
    try testing.expectEqual(@as(u64, 7), try sizeOf("/truncate-isolation"));
    const other = try open(1, "/truncate-isolation", O_RDONLY);
    try testing.expectError(error.NotWritable, truncateFd(1, other, 0));
    try testing.expectError(error.BadDescriptor, truncateFd(max_processes, owner, 0));
    try testing.expectEqual(@as(u64, 7), try sizeOf("/truncate-isolation"));
    try closeAll(0);
    try closeAll(1);
}


// M0.3.19: pressure de blocos, rollback e recuperação após unlink.
test "NoSpace during multi-block extension preserves inode and allows retry" {
    init();
    const payload: [ramfs.max_file_size]u8 = @splat(0x5a);
    // Twenty full files occupy 240 blocks. A further 11-block file
    // leaves fewer than five free blocks for the attempted extension.
    for (0..20) |index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "/pressure-{d}", .{index});
        const fd = try create(0, path, 0o600);
        _ = try write(0, fd, &payload);
        try close(0, fd);
    }
    const reserve = try create(0, "/reserve", 0o600);
    const eleven_blocks: [ramfs.block_size * 11]u8 = @splat(0x33);
    try testing.expectEqual(eleven_blocks.len, try write(0, reserve, &eleven_blocks));
    try close(0, reserve);

    const target = try open(0, "/target", O_CREAT | O_RDWR);
    try testing.expectEqual(@as(usize, 4), try write(0, target, "safe"));
    const before_blocks = freeBlockCount();
    const before_offset = try tell(0, target);
    const extension: [ramfs.block_size * 5]u8 = @splat(0x7e);
    try testing.expectError(error.NoSpace, write(0, target, &extension));
    try testing.expectEqual(before_blocks, freeBlockCount());
    try testing.expectEqual(before_offset, try tell(0, target));
    try testing.expectEqual(@as(u64, 4), try sizeOf("/target"));
    var result: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try readFile("/target", &result));
    try testing.expectEqualStrings("safe", result[0..4]);

    try truncateFile("/reserve", 0);
    try testing.expectEqual(@as(usize, extension.len), try write(0, target, &extension));
    try testing.expectEqual(@as(u64, 4 + extension.len), try sizeOf("/target"));
    try closeAll(0);
}

test "unlinked open file holds blocks until final process closes" {
    init();
    const initial_blocks = freeBlockCount();
    const initial_inodes = freeInodeCount();
    const owner = try open(0, "/reclaim-pressure", O_CREAT | O_RDWR);
    const payload: [ramfs.block_size * 3]u8 = @splat(0x71);
    _ = try write(0, owner, &payload);
    const observer = try open(1, "/reclaim-pressure", O_RDONLY);
    try unlink("/reclaim-pressure");
    try testing.expectError(error.EntryNotFound, open(2, "/reclaim-pressure", O_RDONLY));
    try closeAll(0);
    try testing.expectEqual(initial_blocks - 3, freeBlockCount());
    try testing.expectEqual(initial_inodes - 1, freeInodeCount());
    var buffer: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try read(1, observer, &buffer));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x71, 0x71, 0x71, 0x71 }, &buffer);
    try closeAll(1);
    try testing.expectEqual(initial_blocks, freeBlockCount());
    try testing.expectEqual(initial_inodes, freeInodeCount());
}

test "truncate and rewrite repeatedly reuse released blocks" {
    init();
    const before_blocks = freeBlockCount();
    const fd = try open(0, "/cycle", O_CREAT | O_RDWR);
    const payload: [ramfs.block_size * 4]u8 = @splat(0x4c);
    for (0..5) |_| {
        try seek(0, fd, 0);
        try testing.expectEqual(payload.len, try write(0, fd, &payload));
        try testing.expectEqual(before_blocks - 4, freeBlockCount());
        try truncateFd(0, fd, 0);
        try testing.expectEqual(before_blocks, freeBlockCount());
        try testing.expectEqual(@as(u64, 0), try sizeOf("/cycle"));
    }
    try closeAll(0);
    try unlink("/cycle");
    try testing.expectEqual(before_blocks, freeBlockCount());
}


// M0.3.20: descriptor preflight and namespace exhaustion.
test "inode exhaustion through facade preserves namespace and descriptor slots" {
    init();
    for (0..ramfs.inode_count - 1) |index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "/full-inode-{d}", .{index});
        const fd = try create(0, path, 0o600);
        try close(0, fd);
    }
    try testing.expectEqual(@as(usize, 0), freeInodeCount());
    const blocks_before = freeBlockCount();
    try testing.expectError(error.NoFreeInode, create(0, "/not-created", 0o600));
    try testing.expectError(error.NoFreeInode, open(0, "/not-created", O_CREAT | O_RDWR));
    try testing.expectError(error.NoFreeInode, mkdir("/not-created-dir"));
    try testing.expect(kindOf("/not-created") == null);
    try testing.expect(kindOf("/not-created-dir") == null);
    try testing.expectEqual(blocks_before, freeBlockCount());
    try unlink("/full-inode-0");
    const recovered = try create(0, "/reused-inode", 0o600);
    try testing.expectEqual(@as(usize, 0), freeInodeCount());
    try close(0, recovered);
}

test "failed O_CREAT does not invalidate an existing checked descriptor" {
    init();
    const existing = try create(0, "/existing", 0o600);
    const handle = try checkedFd(0, existing);
    const inode_before = freeInodeCount();
    try testing.expectError(error.NameExists, create(0, "/existing", 0o600));
    try testing.expectError(error.InvalidPath, create(0, "/..", 0o600));
    try testing.expectEqual(inode_before, freeInodeCount());
    try testing.expectEqual(existing, try validateCheckedFd(0, handle));
    try testing.expectEqual(@as(usize, 2), try write(0, existing, "ok"));
    try closeAll(0);
}


// M0.3.21: namespace rename semantics with live handles.
test "rename across directories preserves inode content and checked handles" {
    init();
    _ = try mkdir("/left");
    _ = try mkdir("/right");
    const fd = try open(0, "/left/source", O_CREAT | O_RDWR);
    _ = try write(0, fd, "persistent");
    const checked = try checkedFd(0, fd);
    const original = try stat("/left/source");
    const before_inodes = freeInodeCount();
    const before_blocks = freeBlockCount();

    try rename("/left/source", "/right/destination");
    try testing.expect(kindOf("/left/source") == null);
    const moved = try stat("/right/destination");
    try testing.expectEqual(original.inode, moved.inode);
    try testing.expectEqual(original.size, moved.size);
    try testing.expectEqual(before_inodes, freeInodeCount());
    try testing.expectEqual(before_blocks, freeBlockCount());
    try testing.expectEqual(fd, try validateCheckedFd(0, checked));
    try seek(0, fd, 0);
    var buffer: [16]u8 = undefined;
    const count = try read(0, fd, &buffer);
    try testing.expectEqualStrings("persistent", buffer[0..count]);
    try closeAll(0);
}

test "rename collision and missing source leave namespace unchanged" {
    init();
    _ = try mkdir("/src");
    _ = try mkdir("/dst");
    const source = try open(0, "/src/one", O_CREAT | O_RDWR);
    _ = try write(0, source, "source");
    const target = try open(0, "/dst/two", O_CREAT | O_RDWR);
    _ = try write(0, target, "target");
    const source_stat = try stat("/src/one");
    const target_stat = try stat("/dst/two");
    const before_inodes = freeInodeCount();
    const before_blocks = freeBlockCount();

    try testing.expectError(error.NameExists, rename("/src/one", "/dst/two"));
    try testing.expectError(error.EntryNotFound, rename("/src/missing", "/dst/new"));
    try rename("/src/one", "/src/one");
    try testing.expectEqual(source_stat.inode, (try stat("/src/one")).inode);
    try testing.expectEqual(target_stat.inode, (try stat("/dst/two")).inode);
    try testing.expectEqual(before_inodes, freeInodeCount());
    try testing.expectEqual(before_blocks, freeBlockCount());
    var buffer: [8]u8 = undefined;
    var count = try readFile("/src/one", &buffer);
    try testing.expectEqualStrings("source", buffer[0..count]);
    count = try readFile("/dst/two", &buffer);
    try testing.expectEqualStrings("target", buffer[0..count]);
    try closeAll(0);
}

test "rename then unlink retains inode across process handles until last close" {
    init();
    const initial_inodes = freeInodeCount();
    const initial_blocks = freeBlockCount();
    const writer = try open(0, "/old-name", O_CREAT | O_RDWR);
    _ = try write(0, writer, "data");
    const reader = try open(1, "/old-name", O_RDONLY);
    try rename("/old-name", "/new-name");
    try unlink("/new-name");
    try testing.expect(kindOf("/old-name") == null);
    try testing.expect(kindOf("/new-name") == null);
    try closeAll(0);
    try testing.expectEqual(initial_inodes - 1, freeInodeCount());
    try testing.expectEqual(initial_blocks - 1, freeBlockCount());
    var buffer: [8]u8 = undefined;
    const count = try read(1, reader, &buffer);
    try testing.expectEqualStrings("data", buffer[0..count]);
    try closeAll(1);
    try testing.expectEqual(initial_inodes, freeInodeCount());
    try testing.expectEqual(initial_blocks, freeBlockCount());
}

test "rename rejects noncanonical paths and directories without mutation" {
    init();
    _ = try mkdir("/directory");
    const fd = try open(0, "/file", O_CREAT | O_RDWR);
    const before_inodes = freeInodeCount();
    try testing.expectError(error.InvalidPath, rename("/file", "/../escape"));
    try testing.expectError(error.NotAFile, rename("/directory", "/moved-directory"));
    try testing.expectEqual(before_inodes, freeInodeCount());
    try testing.expect(kindOf("/file") != null);
    try testing.expect(kindOf("/directory") != null);
    try close(0, fd);
}

test "cross mount rename preserves files and resources" {
    init();
    try namespace.mount("/alias", .ramfs);
    const a = try open(0, "/a", O_CREAT | O_RDWR);
    _ = try write(0, a, "alpha");
    const b = try open(0, "/alias/b", O_CREAT | O_RDWR);
    _ = try write(0, b, "beta");
    const inode_a = (try stat("/a")).inode;
    const inode_b = (try stat("/alias/b")).inode;
    const blocks = freeBlockCount();
    const inodes = freeInodeCount();
    try testing.expectError(error.CrossMount, rename("/a", "/alias/b"));
    try testing.expectError(error.CrossMount, rename("/alias/b", "/a"));
    try testing.expectEqual(inode_a, (try stat("/a")).inode);
    try testing.expectEqual(inode_b, (try stat("/alias/b")).inode);
    try testing.expectEqual(blocks, freeBlockCount());
    try testing.expectEqual(inodes, freeInodeCount());
    try closeAll(0);
}

test "rename within mounted alias preserves checked descriptor" {
    init();
    try namespace.mount("/alias", .ramfs);
    const fd = try open(0, "/alias/before", O_CREAT | O_RDWR);
    _ = try write(0, fd, "value");
    const handle = try checkedFd(0, fd);
    const old_inode = (try stat("/alias/before")).inode;
    try rename("/alias/before", "/alias/after");
    try testing.expect(kindOf("/alias/before") == null);
    try testing.expectEqual(old_inode, (try stat("/alias/after")).inode);
    try testing.expectEqual(fd, try validateCheckedFd(0, handle));
    try seek(0, fd, 0);
    var buf: [8]u8 = undefined;
    const n = try read(0, fd, &buf);
    try testing.expectEqualStrings("value", buf[0..n]);
    try closeAll(0);
}

test "storage audit preserves live descriptors and offsets" {
    init();
    const fd = try open(0, "/audit-live", O_CREAT | O_RDWR);
    _ = try write(0, fd, "abcdef");
    const position = try tell(0, fd);
    const checked = try checkedFd(0, fd);
    const before_blocks = freeBlockCount();
    const before_inodes = freeInodeCount();
    try auditStorage();
    try testing.expectEqual(position, try tell(0, fd));
    try testing.expectEqual(fd, try validateCheckedFd(0, checked));
    try testing.expectEqual(before_blocks, freeBlockCount());
    try testing.expectEqual(before_inodes, freeInodeCount());
    try closeAll(0);
    try auditStorage();
}

test "storage audit accepts unlinked file retained by open descriptor" {
    init();
    const fd = try open(0, "/audit-unlinked", O_CREAT | O_RDWR);
    _ = try write(0, fd, "retained");
    try unlink("/audit-unlinked");
    try testing.expect(kindOf("/audit-unlinked") == null);
    try auditStorage();
    try seek(0, fd, 0);
    var buffer: [16]u8 = undefined;
    const n = try read(0, fd, &buffer);
    try testing.expectEqualStrings("retained", buffer[0..n]);
    try closeAll(0);
    try auditStorage();
}

test "FS storage statistics account for open and reclaimed unlinked file" {
    init();
    const baseline = storageStats();
    const fd = try open(0, "/stats-open", O_CREAT | O_RDWR);
    _ = try write(0, fd, "data");
    const allocated = storageStats();
    try testing.expectEqual(baseline.used_inodes + 1, allocated.used_inodes);
    try testing.expectEqual(baseline.used_blocks + 1, allocated.used_blocks);
    try testing.expectEqual(baseline.used_dir_entries + 1, allocated.used_dir_entries);
    try unlink("/stats-open");
    const unlinked_stats = storageStats();
    try testing.expectEqual(baseline.used_dir_entries, unlinked_stats.used_dir_entries);
    try testing.expectEqual(allocated.used_blocks, unlinked_stats.used_blocks);
    try closeAll(0);
    const reclaimed = storageStats();
    try testing.expectEqual(baseline.used_inodes, reclaimed.used_inodes);
    try testing.expectEqual(baseline.used_blocks, reclaimed.used_blocks);
    try auditStorage();
}
