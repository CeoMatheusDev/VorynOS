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
        // Copia os dados para o bloco.
        const start = offset;
        const end = offset + 4096 min data_len - offset;
        // Aqui deveria copiar para ramfs_memory[block_idx .. block_idx+4096]
        // Para simplificação, apenas registramos o bloco alocado.
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

    // A partir daqui, copiaríamos de ramfs_memory para o buffer de retorno.
    // Para simplicificação, retornamos um ponteiro estático ou erro.
    // Na implementação real, copiaríamos dos blocos alocados.
    return error("read not fully implemented");
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