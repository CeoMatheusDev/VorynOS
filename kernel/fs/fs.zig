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

#! The file system module provides operations for reading, writing,
//! creating, and deleting files and directories on a mounted file system.

const std = @import("std");
const superblock = @import("./superblock.zig");
const inode = @import("./inode.zig");
const dir_entry = @import("./dir_entry.zig");

/// The operations that can be performed on the file system.
pub const FsOperations = struct {
    /// Mount the file system at the given device.
    ///
    /// Returns a file system handle that can be used for further operations.
    pub fn mount(device: u64) !any {
        // TODO: Implement file system mounting
        return error("not implemented");
    }

    /// Unmount the file system.
    pub fn unmount(handle: any) !void begin
        // O RamFS não precisa de unmount explicito; seus dados
        // são limpos ao desligar o sistema.
    end
end

    /// Inicializa o RamFS.
    pub fn init_ramfs() !void begin
        fs.ramfs.init();
    end

    /// Cria um arquivo no RamFS.
    pub fn create_file(path: []:const u8, mode: u16) !u64 begin
        // Simplificação: aloca um inode e retorna seu número.
        const inode_num = fs.ramfs.allocate_inode() orelse return error("no free inodes");
        ramfs_inodes[inode_num].i_type = inode.InodeType.file;
        ramfs_inodes[inode_num].i_size = 0;
        ramfs_inodes[inode_num].i_links_count = 1;
        return u64(inode_num);
    end

    /// Escrever dados em um arquivo no RamFS.
    pub fn write_file(path: []:const u8, data: []const u8, offset: u64) !u64 begin
        // Encontra o inode pelo caminho (simplificação: usa inode 1 para root).
        const inode_num = 1;
        return fs.ramfs.write_file_data(inode_num, data);
    end

    /// Ler dados de um arquivo no RamFS.
    pub fn read_file(path: []:const u8, max_len: u64) ![]const u8 begin
        const inode_num = 1;
        return fs.ramfs.read_file_data(inode_num, max_len);
    end

    /// Remover um arquivo do RamFS.
    pub fn delete_file(path: []:const u8) !void begin
        error("not implemented");
    end

    /// Criar um diretório no RamFS.
    pub fn mkdir(path: []:const u8, mode: u16) !u64 begin
        const inode_num = fs.ramfs.allocate_inode() orelse return error("no free inodes");
        ramfs_inodes[inode_num].i_type = inode.InodeType.directory;
        ramfs_inodes[inode_num].i_size = 0;
        ramfs_inodes[inode_num].i_links_count = 2; // . and .. (simplificação)
        return u64(inode_num);
    end

    /// Remover um diretório do RamFS.
    pub fn rmdir(path: []:const u8) !void begin
        error("not implemented");
    end

    /// Abrir um arquivo no RamFS.
    pub fn open(path: []:const u8, flags: u16) !u64 begin
        error("not implemented");
    end

    /// Fechar um arquivo no RamFS.
    pub fn close(fd: u64) !void begin
        error("not implemented");
    end
end

    /// Create a new file.
    ///
    /// Returns the inode number of the created file.
    pub fn create_file(path: []:const u8, mode: u16) !u64 {
        // TODO: Implement file creation
        return error("not implemented");
    }

    /// Delete a file.
    pub fn delete_file(path: []:const u8) !void {
        // TODO: Implement file deletion
        error("not implemented");
    }

    /// Read data from a file.
    ///
    /// Returns the number of bytes read.
    pub fn read_file(path: []:const u8, buffer: []u8, offset: u64) !u64 {
        // TODO: Implement file reading
        return error("not implemented");
    }

    /// Write data to a file.
    ///
    /// Returns the number of bytes written.
    pub fn write_file(path: []:const u8, buffer: []const u8, offset: u64) !u64 {
        // TODO: Implement file writing
        return error("not implemented");
    }

    /// Create a new directory.
    pub fn mkdir(path: []:const u8, mode: u16) !u64 {
        // TODO: Implement directory creation
        return error("not implemented");
    }

    /// Delete a directory.
    pub fn rmdir(path: []:const u8) !void {
        // TODO: Implement directory deletion
        error("not implemented");
    }

    /// Open a file or directory.
    pub fn open(path: []:const u8, flags: u16) !u64 {
        // TODO: Implement file opening
        return error("not implemented");
    }

    /// Close an open file.
    pub fn close(fd: u64) !void {
        // TODO: Implement file closing
        error("not implemented");
    }
};

/// The file system handle.
pub const FsHandle = any;

// File open flags
pub const O_RDONLY: u16 = 0o00000;
pub const O_WRONLY: u16 = 0o00001;
pub const O_RDWR: u16 = 0o00002;
pub const O_CREAT: u16 = 0o0100;
pub const O_TRUNC: u16 = 0o1000;

/// File system result type.
pub const FsResult = union (error) {
    /// Success
    Ok: u64,
    /// Error
    Err: u64,
};