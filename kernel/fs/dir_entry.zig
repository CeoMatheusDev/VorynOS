//************************************************************************//
//  dir_entry.zig                                                         //
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

//! A directory entry representing a file or subdirectory in a directory.
//!
//! Directory entries are stored compactly in the file system.

const std = @import("std");

/// The maximum length of a file name in the file system.
pub const MAX_NAME_LEN: usize = 255;

/// A directory entry.
pub const DirEntryOnDisk = struct {
    /// Inode number of the file/directory
    inode: u32,
    /// Length of the name (not counting null terminator)
    name_len: u8,
    /// File name (null-terminated, padded to MAX_NAME_LEN)
    name: [MAX_NAME_LEN + 1]u8 = @splat(0xff),
};
