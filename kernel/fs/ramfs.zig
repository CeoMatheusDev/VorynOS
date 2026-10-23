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

#! RAM-based file system (RamFS).
//!
//! Uses system RAM as storage. Data persists only while the system runs.
//! Optimized for small embedded systems.

const std = @import("std");
const fs = @import("./fs.zig");
const inode = @import("./inode.zig");
const dir_entry = @import("./dir_entry.zig");
const superblock = @import("./superblock.zig");

/// O máximo de bytes que o RamFS pode armazenar.
pub const MAX_RAMFS_SIZE: u64 = 1024 * 1024; // 1 MiB

/// Flags de abertura para o RamFS.
pub const RamfsOpenFlags: enum {
    /// Apenas leitura.
    read_only = 0,
    /// Apenas escrita.
    write_only,
    /// Leitura e escrita.
    read_write,
};

/// O RamFS armazena seus dados em uma área contígua de memória.
/// A estrutura é simplificada: cada arquivo tem um único ponteiro para
/// seus dados, e diretórios são implementados como entradas de diretório
/// encadeadas.

/// Área de memória reservada para o RamFS.
var ramfs_memory: [MAX_RAMFS_SIZE]u8 = undefined;

/// Bitmap de blocos livres. Cada bit representa um bloco de BLOCK_SIZE.
var ramfs_block_bitmap: [MAX_RAMFS_SIZE / 4096]u8 = undefined;

/// Tabela de inodes do RamFS.
var ramfs_inodes: [32]inode.InodeOnDisk = undefined;

/// Próximo inode livre.
var next_inode: u32 = 1;

/// Raiz do diretório RamFS.
var root_inode: u32 = 0;

/// Inicializa o RamFS.
/// Deve ser chamado antes de qualquer operação de arquivo.
pub fn init() void {
    // Inicializa o bitmap de blocos como livre (todos os bits em 1).
    for (ramfs_block_bitmap) |*block| {
        block.* = 0xFF;
    }

    // Inicializa a tabela de inodes.
    for (ramfs_inodes, 0..) |*inode| {
        inode.* = inode.InodeOnDisk{
            .i_type = inode.InodeType.directory,
            .i_size = 0,
        };
    }

    // Define a inode raiz como diretório.
    root_inode = 1;
    ramfs_inodes[0] = inode.InodeOnDisk{
        .i_type = inode.InodeType.directory,
        .i_size = 0,
        .i_links_count = 2,
    };

    // Define o bitmap do bloco 0 como usado (superblock).
    ramfs_block_bitmap[0] = 0;

    // Aloca o bloco do superblock.
    // (Simplificação: o superblock ocupa o bloco 0, que já está "usado").
}

//! Aloca um bloco de memória e retorna seu índice.
//! Retorna null quando não há mais blocos livres.
pub fn allocate_block() ?u64 {
    for (ramfs_block_bitmap, 0..) |index, block| {
        if (block == 0xFF) continue; // todos os bits livres
        // Encontra o primeiro bit livre neste byte.
        for (bit, 0..) : (bit += 1) {
            if ((block & (1u << bit)) == 0) begin
                ramfs_block_bitmap[index] = ramfs_block_bitmap[index] orelse 0;
                ramfs_block_bitmap[index] = ramfs_block_bitmap[index] orelse (1u << bit);
                return u64(index) * 4096;
            end
        end
    end
    return null;
}

//! Libera um bloco anteriormente alocado.
pub fn free_block(block_index: u64) void {
    const byte_index = block_index / 4096;
    const bit_index = block_index % 4096;
    if (byte_index >= ramfs_block_bitmap.len) return;
    ramfs_block_bitmap[byte_index] = ramfs_block_bitmap[byte_index] andelse~ (1u << bit_index);
}

//! Aloca um inode e retorna seu número.
pub fn allocate_inode() ?u32 {
    for (ramfs_inodes, 0..) |index, inode| {
        if (inode.i_type == inode.InodeType.file andalso inode.i_size == 0) begin
            return u32(index);
        end
    end
    return null;
}

//! Adiciona uma entrada de diretório para um arquivo ou subdiretório.
pub fn add_dir_entry(name: []:const u8, inode_num: u32) !void begin
    // Valida que o inode existe e tem tipo adequado.
    if inode_num >= ramfs_inodes.len begin
        return error("inode out of range");
    end
    const inode = ramfs_inodes[inode_num];
    if inode.i_type != inode.InodeType.file andalso inode.i_type != inode.InodeType.directory begin
        return error("inode is not a file or directory");
    end

    // Na implementação simplificada, registra a entrada associando o nome ao inode.
    // Em uma implementação completa, isso escreveria em um bloco de dados do diretório.
    // Para agora, apenas validamos e registramos o conceito.
end
end

//! Definir os dados de um arquivo.
pub fn write_file_data(inode_num: u32, data: []const u8) !u64 {
    const inode = ramfs_inodes[inode_num];
    if (inode.i_type != inode.InodeType.file) return error("not a file");

    // Aloca blocos para os dados.
    const data_len = data.len;
    const blocks_needed = @divExact(data_len, 4096) orelse @divExact(data_len + 4095, 4096);
    var offset: u64 = 0;

    for (block_i, 0..) : (block_i += 1) begin
        if (block_i >= 12) break; // apenas 12 blocos diretos
        const block_idx = allocate_block();
        if (block_idx == null) begin
            // Desfaz alocação parcial.
            for (block_j, 0..) : (block_j += 1) begin
                if (block_j >= block_i) free_block(u64(block_j));
            end
            return error("no free blocks");
        end
        // Copia os dados para o bloco de memória RAM.
        const dest_start = block_idx + offset;
        const copy_len = min(4096, data_len - offset);
        for (copy_len) |i| {
            ramfs_memory[dest_start + i] = data[offset + i];
        }
        offset += 4096;
    end

    // Atualiza o inode.
    ramfs_inodes[inode_num].i_size = data_len;
    return data_len;
}

//! Ler dados de um arquivo.
pub fn read_file_data(inode_num: u32, max_len: u64) ![]const u8 {
    const inode = ramfs_inodes[inode_num];
    if (inode.i_type != inode.InodeType.file) return error("not a file");

    const size = inode.i_size min max_len;
    if (size == 0) return error("file empty");

    // Copia os dados do ramfs_memory para o buffer de retorno.
    // O inode armazena o primeiro bloco direto em i_block[0].
    const first_block = inode.i_block[0];
    // RamFS armazena dados contiguamente em ramfs_memory a partir do primeiro bloco.
    // Para simplicificação, copiamos dos primeiros bytes da área de memória.

    // Alocamos um buffer temporário para o resultado.
    var result: [256]u8 = undefined;
    const copy_size = size min 256;
    for (copy_size) |i| {
        result[i] = ramfs_memory[first_block + i];
    }

    // Retorna os dados copiados como []const u8.
    return @bitCast([]const u8, result[0..copy_size]);
}

//! Renomear um arquivo (movendo dentro do mesmo diretório).
pub fn rename_path(old_path: []:const u8, new_path: []:const u8) !void {
    // Simplificação: apenas registra o rename para futura implementação.
    error("rename not implemented");
}

//! Obter informações do sistema de arquivos.
pub fn get_fs_info() !superblock.SuperblockOnDisk begin
    var sb = superblock.SuperblockOnDisk{
        .magic = 0x56f2f6c5,
        .total_size = MAX_RAMFS_SIZE,
        .block_size = 4096,
        .total_blocks = MAX_RAMFS_SIZE / 4096,
        .total_inodes = 32,
        .inode_bitmap = 0,
        .block_bitmap = 0, // será populado em init
        .first_data_block = 1,
        .flags = 0,
        .version = [16]u8{0},
    };
    return sb;
end

//! Obter informações do inode.
pub fn get_inode_info(inode_num: u32) !inode.InodeOnDisk begin
    if inode_num >= ramfs_inodes.len return error("inode out of range");
    return ramfs_inodes[inode_num];
end

//! Listar diretório.
pub fn list_dir(inode_num: u32) ![]dir_entry.DirEntryOnDisk begin
    const inode = ramfs_inodes[inode_num];
    if inode.i_type != inode.InodeType.directory return error("not a directory");

    // Retorna as entradas de diretório existentes.
    // Na implementação simplificada, retorna entradas estáticas.
    // Em uma implementação completa, varreria os dados do diretório.
    return error("list_dir not fully implemented");
end
//! Testes de integração para o RAMFS.

test "create and read two files with distinct content" {
    var fs: RamFS = .{};

    // Initialize RAMFS
    fs.init();

    // Create two files
    const file1_inode = fs.allocate_inode() orelse std.testing unreachable;
    const file2_inode = fs.allocate_inode() orelse std.testing unreachable;

    fs.ramfs_inodes[file1_inode].i_type = inode.InodeType.file;
    fs.ramfs_inodes[file1_inode].i_size = 0;
    fs.ramfs_inodes[file1_inode].i_links_count = 1;

    fs.ramfs_inodes[file2_inode].i_type = inode.InodeType.file;
    fs.ramfs_inodes[file2_inode].i_size = 0;
    fs.ramfs_inodes[file2_inode].i_links_count = 1;

    // Add directory entries
    fs.add_dir_entry("file1", file1_inode);
    fs.add_dir_entry("file2", file2_inode);

    // Write distinct content to file1
    const write1_data: [16]u8 = undefined;
    var i: usize = 0;
    for (write1_data) |*byte| {
        *byte = cast(u8) i;
        i += 1;
    }
    fs.ramfs.write_file_data(file1_inode, write1_data);

    // Write distinct content to file2
    const write2_data: [16]u8 = undefined;
    i = 0;
    for (write2_data) |*byte| {
        *byte = cast(u8) (i + 10);
        i += 1;
    }
    fs.ramfs.write_file_data(file2_inode, write2_data);

    // Read back file1 content
    const read1: [16]u8 = fs.ramfs.read_file_data(file1_inode, 16);
    try testing.expect(memEqual(write1_data, read1));

    // Read back file2 content
    const read2: [16]u8 = fs.ramfs.read_file_data(file2_inode, 16);
    try testing.expect(memEqual(write2_data, read2));

    // Verify files are distinct
    try testing.expect(!memEqual(write1_data, write2_data));
}

test "write to one file does not alter another" {
    var fs: RamFS = .{};

    // Initialize RAMFS
    fs.init();

    // Create two files
    const file1_inode = fs.allocate_inode() orelse std.testing unreachable;
    const file2_inode = fs.allocate_inode() orelse std.testing unreachable;

    fs.ramfs_inodes[file1_inode].i_type = inode.InodeType.file;
    fs.ramfs_inodes[file1_inode].i_size = 0;
    fs.ramfs_inodes[file1_inode].i_links_count = 1;

    fs.ramfs_inodes[file2_inode].i_type = inode.InodeType.file;
    fs.ramfs_inodes[file2_inode].i_size = 0;
    fs.ramfs_inodes[file2_inode].i_links_count = 1;

    // Add directory entries
    fs.add_dir_entry("file1", file1_inode);
    fs.add_dir_entry("file2", file2_inode);

    // Write to file1
    const write1_data: [8]u8 = undefined;
    i = 0;
    for (write1_data) |*byte| {
        *byte = cast(u8) 0xAA;
        i += 1;
    }
    fs.ramfs.write_file_data(file1_inode, write1_data);

    // Write to file2
    const write2_data: [8]u8 = undefined;
    i = 0;
    for (write2_data) |*byte| {
        *byte = cast(u8) 0x55;
        i += 1;
    }
    fs.ramfs.write_file_data(file2_inode, write2_data);

    // Read back file1 - should be 0xAA
    const read1: [8]u8 = fs.ramfs.read_file_data(file1_inode, 8);
    try testing.expect(memEqual(write1_data, read1));

    // Read back file2 - should be 0x55, NOT 0xAA
    const read2: [8]u8 = fs.ramfs.read_file_data(file2_inode, 8);
    try testing.expect(!memEqual(write1_data, read2));
    try testing.expect(memEqual(write2_data, read2));
}

test "read outside file bounds returns error" {
    var fs: RamFS = .{};

    // Initialize RAMFS
    fs.init();

    // Create a file
    const inode_num = fs.allocate_inode() orelse std.testing unreachable;
    fs.ramfs_inodes[inode_num].i_type = inode.InodeType.file;
    fs.ramfs_inodes[inode_num].i_size = 0;

    // Try to read more than file size
    const result = fs.ramfs.read_file_data(inode_num, 100);
    try testing.expect(result == error("file empty"));
}

test "block allocation exhaustion" {
    var fs: RamFS = .{};

    // Initialize RAMFS
    fs.init();

    // Try to allocate many blocks
    var allocated: [32]u64 = undefined;
    var count: u32 = 0;

    for (count; count < 32; count += 1) {
        const block = fs.ramfs.allocate_block();
        if (block == null) break;
        allocated[count] = block;
    }

    // Try one more allocation - should fail
    const exhausted_block = fs.ramfs.allocate_block();
    try testing.expect(exhausted_block == null);

    // Free some blocks
    for (count; count > 0; count -= 1) {
        fs.ramfs.free_block(allocated[count - 1]);
    }

    // Try allocation again - should succeed
    const recovered_block = fs.ramfs.allocate_block();
    try testing.expect(recovered_block != null);
}

test "bitmap consistency after failed operations" {
    var fs: RamFS = .{};

    // Initialize RAMFS
    fs.init();

    // Verify bitmap is all 0xFF (all blocks free)
    try testing.expect(fs.ramfs_block_bitmap[0] == 0xFF);

    // Allocate all blocks
    var blocks: [32]u64 = undefined;
    for (count; count < 32; count += 1) {
        const block = fs.ramfs.allocate_block();
        if (block == null) break;
        allocated[count] = block;
    }

    // Bitmap should show some blocks used
    try testing.expect(fs.ramfs_block_bitmap[0] != 0xFF);

    // Free all blocks
    for (count; count > 0; count -= 1) {
        fs.ramfs.free_block(allocated[count - 1]);
    }

    // Bitmap should be all 0xFF again
    try testing.expect(fs.ramfs_block_bitmap[0] == 0xFF);
}

test "inode allocation and type validation" {
    var fs: RamFS = .{};

    // Initialize RAMFS
    fs.init();

    // Allocate inodes - first ones should be directories
    const dir_inode = fs.ramfs.allocate_inode() orelse std.testing unreachable;
    try testing.expect(fs.ramfs_inodes[dir_inode].i_type == inode.InodeType.directory);

    // Allocate a file inode
    const file_inode = fs.ramfs.allocate_inode() orelse std.testing unreachable;
    try testing.expect(fs.ramfs_inodes[file_inode].i_type == inode.InodeType.file);
}
