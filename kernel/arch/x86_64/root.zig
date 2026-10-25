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
pub const frame = @import("frame.zig");
pub const paging = @import("paging.zig");
pub const spinlock = @import("spinlock.zig");
pub const smp = @import("smp.zig");
pub const apic = @import("apic.zig");
pub const acpi = @import("acpi.zig");

// The unit tests of the modules live in the modules themselves, and this
// block is what brings them into the test binary.
//
// Without this reference, the test binary is built with **zero** tests,
// and it passes no matter what: a test that is green without running is
// not evidence of anything.
test {
    _ = @import("segment.zig");
    _ = @import("frame.zig");
    _ = @import("paging.zig");
    _ = @import("spinlock.zig");
    _ = @import("smp.zig");
    _ = @import("apic.zig");
    _ = @import("acpi.zig");
}
