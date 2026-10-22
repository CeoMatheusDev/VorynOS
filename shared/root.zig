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

//! Aggregated entry point of the VorynOS shared module.
//!
//! The shared module contains the contracts and the architecture support
//! that the bootloader (VNB) and the kernel (VNK) both depend on:
//!
//!   * `handoff`  - the boot handoff contract;
//!   * `memmap`  - helpers for the memory map;
//!   * `elf64`   - the ELF64 reader used to load the kernel image;
//!   * `usermode`- the layout of the window of the user mode;
//!   * `port`    - x86_64 port I/O primitives;
//!   * `serial`  - the 16550 serial driver used by both sides of the handoff.
//!
//! The module deliberately contains no operating system dependency so that it
//! can be compiled for the UEFI environment, for the freestanding kernel and
//! for the host based unit tests.

pub const handoff = @import("handoff.zig");
pub const memmap = @import("memmap.zig");
pub const elf64 = @import("elf64.zig");
pub const usermode = @import("usermode.zig");
pub const port = @import("arch/x86_64/port.zig");
pub const serial = @import("arch/x86_64/serial.zig");

// The unit tests of the modules live in the modules themselves, and this
// block is what os traz para o binário de testes.
//
// Without this reference, the test binary is built with **zero** tests,
// and it passes no matter what: um teste que verde sem correr não é
// evidência de nada.
test {
    _ = @import("handoff.zig");
    _ = @import("memmap.zig");
    _ = @import("elf64.zig");
    _ = @import("usermode.zig");
}
