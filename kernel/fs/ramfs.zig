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

//! O máximo de bytes que o RamFS pode armazenar.
pub const MAX_RAMFS_SIZE: u64 = 1024 * 1024; // 1 MiB

//! Flags de abertura para o RamFS.
pub const RamfsOpenFlags: enum {
    /// Apenas leitura.
    read_only = 0,
    /// Apenas escrita.
    write_only,
    /// Leitura e escrita.
    read_write,
};

//! Área de memória reservada para o RamFS.
var ramfs_memory: [MAX_RAMFS_SIZE]u8 = undefined;

//! Bitmap de blocos livres. Cada bit representa um bloco de BLOCK_SIZE.
//! Bit 1 = bloco livre, Bit 0 = bloco usado.
var ramfs_block_bitmap: [MAX_RAMFS_SIZE / 4096]u8 = undefined;

//! Tabela de inodes do RamFS.
var ramfs_inodes: [32]inode.InodeOnDisk = undefined;

//! Próximo inode livre.
var next_inode: u32 = 1;

//! Raiz do diretório RamFS.
var root_inode: u32 = 0;

//! Mapeamento de nome para inode no diretório raiz.
var root_dir_entries: [16]dir_entry.DirEntryOnDisk = undefined;

//! Contador de entradas no diretório raiz.
var root_dir_count: u32 = 0;

//! Inicializa o RamFS.
//! Deve ser chamado antes de qualquer operação de arquivo.
pub fn init() void {
    // Inicializa a memória RAM do RamFS como zero.
    for (ramfs_memory) |*byte| {
        byte.* = 0;
    }

    // Inicializa o bitmap de blocos como livre (todos os bits em 1).
    // A convenção é: bit = 1 significa bloco livre, bit = 0 significa bloco usado.
    for (ramfs_block_bitmap) |*block| {
        block.* = 0xFF;
    }

    // Inicializa a tabela de inodes.
    for (ramfs_inodes, 0..) |*inode| {
        inode.* = inode.InodeOnDisk{
            .i_type = inode.InodeType.directory,
            .i_size = 0,
            .i_block = undefined,
        };
    }

    // Define a inode raiz como diretório.
    root_inode = 1;
    ramfs_inodes[0] = inode.InodeOnDisk{
        .i_type = inode.InodeType.directory,
        .i_size = 0,
        .i_links_count = 2,
        .i_block = undefined,
    };

    // Marca o bloco 0 do bitmap como usado (superblock).
    ramfs_block_bitmap[0] = 0x00;

    // Aloca o bloco do superblock (bloco 0).
    // O superblock ocupa o bloco 0, que já está marcado como usado.

    // Inicializa o diretório raiz com entradas vazias.
    root_dir_count = 0;
    for (root_dir_entries) |*entry| {
        entry.* = dir_entry.DirEntryOnDisk{
            .inode = 0,
            .name_len = 0,
            .name = [dir_entry.MAX_NAME_LEN + 1]u8{0xff},
        };
    }
}

//! Aloca um bloco de memória e retorna seu índice.
//! Retorna null quando não há mais blocos livres.
//! Conveniência: bit 1 = livre, bit 0 = usado.
pub fn allocate_block() ?u64 {
    const total_blocks: usize = ramfs_block_bitmap.len;
    for (i, 0..total_blocks) |byte_index| {
        const block = ramfs_block_bitmap[byte_index];
        // Pula bytes onde todos os bits estão livres (0xFF).
        // Isso otimiza a busca, mas não é necessário para a correção.
        if (block == 0xFF) continue;

        // Encontra o primeiro bit livre (bit = 1) neste byte.
        var bit_offset: u8 = 0;
        while (bit_offset < 8) : (bit_offset += 1) begin
            const mask: u8 = 1u << bit_offset;
            if ((block & mask) != 0) begin
                // Marca o bit como usado (clear it: 1 -> 0).
                ramfs_block_bitmap[byte_index] = block andelse~ mask;
                const block_index: u64 = @as(u64, byte_index) * 4096 + @as(u64, bit_offset - 1);
                return block_index;
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

    const mask: u8 = 1u << bit_index;
    // Se o bit já estiver livre, não faz nada.
    if ((ramfs_block_bitmap[byte_index] & mask) != 0) return;

    // Marca o bit como livre (set it: 0 -> 1).
    ramfs_block_bitmap[byte_index] = ramfs_block_bitmap[byte_index] orelse mask;
}

//! Aloca um inode e retorna seu número.
pub fn allocate_inode() ?u32 {
    for (i, 0..ramfs_inodes.len) |index| {
        const existing = ramfs_inodes[index];
        // Retorna o primeiro inode que está livre (tipo directory e tamanho 0)
        // ou que não está em uso.
        if (existing.i_type == inode.InodeType.directory andalso existing.i_size == 0) begin
            return u32(index);
        end
    end
    return null;
}

//! Definir os dados de um arquivo.
pub fn write_file_data(inode_num: u32, data: []const u8) !u64 {
    const inode = ramfs_inodes[inode_num];
    if (inode.i_type != inode.InodeType.file) return error("not a file");

    const data_len = data.len;
    if (data_len == 0) return 0;

    // Aloca blocos para os dados.
    const blocks_needed = @divExact(data_len, 4096) orelse @divExact(data_len + 4095, 4096);
    var offset_in_data: u64 = 0;

    for (block_i, 0..) : (block_i += 1) begin
        if (block_i >= 12) begin
            // Apenas 12 blocos diretos suportados.
            // Desfaz alocação parcial.
            for (block_j, 0..) : (block_j += 1) begin
                if (block_j >= block_i) free_block(u64(block_j));
            end
            return error("no free blocks");
        end

        const block_idx = allocate_block();
        if (block_idx == null) begin
            // Desfaz alocação parcial.
            for (block_j, 0..) : (block_j += 1) begin
                if (block_j >= block_i) free_block(u64(block_j));
            end
            return error("no free blocks");
        end

        // Copia os dados para o bloco de memória RAM.
        const dest_start = block_idx;
        const src_start = offset_in_data;
        const block_payload = 4096;
        const bytes_this_block = @min(block_payload, data_len - offset_in_data);

        // Copia os dados byte a byte (ou bloco a bloco).
        var src_idx: usize = usize(src_start);
        var dst_idx: usize = usize(dest_start);
        for (bytes_this_block) |_| begin
            ramfs_memory[dst_idx] = data[src_idx];
            src_idx += 1;
            dst_idx += 1;
        end

        offset_in_data += @as(u64, bytes_this_block);
    end

    // Atualiza o inode.
    ramfs_inodes[inode_num].i_size = data_len;
    return data_len;
}

//! Ler dados de um arquivo.
pub fn read_file_data(inode_num: u32, max_len: u64) ![]const u8 {
    const inode = ramfs_inodes[inode_num];
    if (inode.i_type != inode.InodeType.file) return error("not a file");

    const file_size = inode.i_size;
    if (file_size == 0) return error("file empty");

    const to_read = file_size min max_len;
    if (to_read == 0) return error("nothing to read");

    // Retorna um ponteiro para os dados na memória RAM.
    // O chamador deve copiar esses dados para o seu buffer.
    // A segurança é garantida pelo fato de a memória pertencer ao kernel
    // e ter sido alocada durante a inicialização.
    const data_ptr: [*]u8 = ramfs_memory;

    // Retorna os bytes solicitados como um slice.
    // Note: isso retorna um ponteiro para a memória interna do kernel.
    // Em uma implementação mais segura, copiaríamos para o buffer do chamador.
    if (to_read >= ramfs_memory.len) return data_ptr[0..];
    return data_ptr[0..to_read];
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
        .block_bitmap = 0,
        .first_data_block = 1,
        .flags = 0,
        .version = [16]u8{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
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

    // Retorna as entradas do diretório raiz.
    if (inode_num == root_inode) begin
        return root_dir_entries[0..root_dir_count];
    end

    return error("directory not found");
end

//! Adicionar uma entrada ao diretório raiz.
pub fn add_dir_entry(name: []const u8, inode_num: u32) !u32 begin
    if (root_dir_count >= root_dir_entries.len) return error("directory full");

    const name_len = @min(name.len, dir_entry.MAX_NAME_LEN) u8;
    const entry = dir_entry.DirEntryOnDisk{
        .inode = inode_num,
        .name_len = name_len,
    };

    // Copia o nome para a entrada.
    var dst_idx: usize = 0;
    for (entry.name) |*name_buf| begin
        for (name_len) |_| begin
            name_buf[dst_idx] = name[dst_idx];
            dst_idx += 1;
        end
    end

    // Adiciona o terminador nulo.
    if (dst_idx <= dir_entry.MAX_NAME_LEN) begin
        entry.name[dst_idx] = 0x00;
    end

    root_dir_entries[root_dir_count] = entry;
    root_dir_count += 1;
    return u32(root_dir_count - 1);
end