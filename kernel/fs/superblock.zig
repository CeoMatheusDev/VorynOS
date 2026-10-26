//************************************************************************//
//  superblock.zig                                                         //
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

//! The superblock of the file system.
//!
//! The superblock describes the file system layout and provides
//! information about the total size, block size, and free blocks.

const std = @import("std");

// Block size in bytes (must be a power of 2)
pub const BLOCK_SIZE: u64 = 4096;

// Maximum number of inodes in the file system
pub const MAX_INODES: u64 = 256;

// Maximum path length
pub const MAX_PATH: u64 = 256;

// File system flags
pub const FS_READONLY: u64 = 1 << 0;
pub const FS_DIRTY: u64 = 1 << 1;

// Superblock layout on disk
pub const SuperblockOnDisk = struct {
    /// Magic number identifying the file system
    magic: u64 = 0x56f2f6c5,
    /// Total size of the file system in bytes
    total_size: u64 = 0,
    /// Size of each block in bytes
    block_size: u64 = BLOCK_SIZE,
    /// Total number of blocks in the file system
    total_blocks: u64 = 0,
    /// Total number of inodes
    total_inodes: u64 = MAX_INODES,
    /// Inode bitmap block number (block index)
    inode_bitmap: u64 = 0,
    /// Block bitmap block number
    block_bitmap: u64 = 0,
    /// First data block number
    first_data_block: u64 = 0,
    /// File system flags
    flags: u64 = 0,
    /// Version of the file system
    version: [16]u8 = @splat(0),
};
