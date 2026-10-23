//************************************************************************//
//  dir_entry.zig                                                         //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
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
