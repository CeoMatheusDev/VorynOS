//************************************************************************//
//  root.zig                                                              //
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

//! Aggregated entry point of the kernel modules that the host can test.
//!
//! The modules are grouped so that the ones that do not depend on the
//! hardware can be compiled for the host, where their unit tests run. The
//! root lives at the top of the kernel tree because the modules of the IPC
//! use the context of the tasks, which lives in another directory, and the
//! root of a module has to be above every file that it imports.

pub const channel = @import("ipc/channel.zig");

// The unit tests of the modules live in the modules themselves, and this
// block is what brings them into the test binary.
//
// Without this reference, the test binary is built with **zero** tests,
// and it passes no matter what: a test that is green without running is
// not evidence of anything.
test {
    _ = @import("ipc/channel.zig");
}
