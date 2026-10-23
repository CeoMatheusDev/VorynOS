//************************************************************************//
//  hello.zig                                                             //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! Aplicação ELF64 nativa usando a interface pública do SDK VorynOS.
const sdk = @import("voryn_sdk");

export fn _start() noreturn {
    // Smoke test da ABI antes de usar o console.
    if (sdk.ping() != 0x42) sdk.exit(2);
    const message = "toolchain ELF\n";
    const result = sdk.write(message);
    sdk.exit(if (sdk.syscall.isError(result)) 1 else 0);
}
