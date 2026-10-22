//************************************************************************//
//  root.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Aggregated entry point of the memory modules of the kernel.
//!
//! The modules are grouped so that they can be compiled for the host, where
//! their unit tests run.

pub const physical = @import("physical.zig");
pub const heap = @import("heap.zig");
