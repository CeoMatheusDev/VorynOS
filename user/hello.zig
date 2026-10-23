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
    // F4/F5: exercita syscalls de arquivo pelo SDK, sem acesso ao kernel.
    const fd = sdk.fsOpen("/apps/hello.txt", 1);
    if (sdk.syscall.isError(fd)) sdk.exit(3);
    var data: [7]u8 = undefined;
    const count = sdk.fsRead(fd, &data);
    if (sdk.syscall.isError(count) or count != data.len) sdk.exit(4);
    if (sdk.fsClose(fd) != 0) sdk.exit(5);
    const message = "toolchain ELF\n";
    const result = sdk.write(message);
    sdk.exit(if (sdk.syscall.isError(result)) 1 else 0);
}
