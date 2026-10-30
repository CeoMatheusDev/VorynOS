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

//! Aggregated entry point of the AI module (F9).
//!
//!   * `tensor`   - the dense product and the ReLU activation;
//!   * `model`    - the binary model format, the validation and the inference;
//!   * `security` - the checked arithmetic of the limits;
//!   * `embedded` - the model image that the kernel embeds, built at compile
//!                  time with a CRC verified by `model.validate`.
//!
//! The module is **pure**: it does not touch hardware, it does not allocate
//! and it does not depend on the scheduler. The kernel imports it to run the
//! boot self-test and the system call 24; the host tests import the same
//! code, and the tests are collected here so that no file of the module
//! stays out of the test binary.

const std = @import("std");

pub const tensor = @import("tensor.zig");
pub const model = @import("model.zig");
pub const security = @import("security.zig");
pub const embedded = @import("embedded.zig");

test {
    _ = @import("tensor.zig");
    _ = @import("model.zig");
    _ = @import("security.zig");
    _ = @import("embedded.zig");
}

test "the aggregated module exposes the image and the format" {
    try std.testing.expect(embedded.image_len >= model.MIN_BUF_SIZE);
    try std.testing.expectEqual(model.MAGIC, std.mem.readInt(u32, embedded.image[0..4], .little));
}
