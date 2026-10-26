//************************************************************************//
//  inode.zig                                                              //
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

//! An inode represents a file or directory in the file system.
//!
//! The inode stores metadata about the file, including its size, ownership,
//! permissions, and the blocks that store its data.

const std = @import("std");

/// The type of the inode (file, directory, etc.)
pub const InodeType = enum {
    /// Regular file
    file,
    /// Directory
    directory,
    /// Symbolic link (not fully implemented)
    symlink,
};

/// The permissions of the inode.
pub const InodePermissions = u16;

/// The number of links to this inode.
pub const InodeLinks: u32 = 1;

/// The size of the file in bytes.
pub const InodeSize: u64 = 0;

/// The time the file was last accessed.
pub const InodeAtime: u64 = 0;

/// The time the file was last modified.
pub const InodeMtime: u64 = 0;

/// The time the file status was last changed.
pub const InodeCtime: u64 = 0;

/// Disk inode layout.
pub const InodeOnDisk = struct {
    /// Inode type (file, directory, etc.)
    i_type: InodeType = .file,
    /// Inode permissions
    i_permissions: InodePermissions = 0o755,
    /// Number of hard links to this inode
    i_links_count: u32 = 1,
    /// File size in bytes
    i_size: u64 = 0,
    /// Time of last access
    i_atime: u64 = 0,
    /// Time of last modification
    i_mtime: u64 = 0,
    /// Time of last change
    i_ctime: u64 = 0,
    /// Direct block pointers (direct blocks)
    i_block: [12]u64 = undefined,
    /// Single indirect block pointer
    i_indirect: u64 = 0,
    /// Double indirect block pointer
    i_double_indirect: u64 = 0,
};
