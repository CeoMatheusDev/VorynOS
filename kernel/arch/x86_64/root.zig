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

//! Aggregated entry point of the architecture modules of the kernel.
//!
//! The modules are grouped so that the parts that do not depend on the
//! hardware can be compiled for the host, where their unit tests run.

pub const segment = @import("segment.zig");
