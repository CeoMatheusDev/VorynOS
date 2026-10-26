//************************************************************************//
//  virtio_blk.zig                                                        //
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

const std = @import("std");




// ---------- Convenientes (stub) ----------
pub fn blk_read() !void {
    // Stub: logs and returns; device not yet programmed.
    // Note: 'serial' is not imported here; caller should provide logging.
    // sector and buf are unused in this stub.
    
    
}

pub fn blk_write() !void {
    // Stub: logs and returns; device not yet programmed.
    // sector and buf are unused in this stub.
    
    
}