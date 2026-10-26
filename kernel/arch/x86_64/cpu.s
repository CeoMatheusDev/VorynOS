//************************************************************************//
//  cpu.s                                                                 //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.
// Copyright (C) 2026 VorynOS - All Rights Reserved.
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

/*
 * The instructions of the processor that need an explicit memory operand
 * are written here. The inline assembler of Zig refuses `invlpg` with a
 * register operand in a debug build, and the instruction is the one that
 * removes the stale translation of a page after the kernel changes its
 * permissions.
 */

.text

/*
 * Invalidates the translation of the page that contains the address.
 *
 * The System V ABI passes the first argument in RDI, and the instruction
 * reads the address from a register as an effective address. The function
 * does not return a value.
 */
.global voryn_invlpg
.type voryn_invlpg, @function
voryn_invlpg:
    invlpg (%rdi)
    ret
.size voryn_invlpg, . - voryn_invlpg
