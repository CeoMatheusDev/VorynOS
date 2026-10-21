/* SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 VorynOS contributors
 */

/*
 * VorynOS x86_64 kernel entry point.
 *
 * The Voryn Native Boot loader leaves the firmware and jumps directly to
 * `voryn_kernel_entry` with:
 *
 *   RDI  - physical address of the boot handoff structure
 *   RSI  - reserved for future use
 *
 * ABI notes:
 *   - The System V AMD64 ABI passes the first integer argument in RDI, which
 *     is where the kernel expects the handoff pointer.
 *   - RDI is caller saved, so the value is consumed immediately.
 *   - The kernel establishes its own stack before touching any memory, so
 *     the stack of the loader is never used.
 *   - The stack is 16 byte aligned at the point of the call, as required by
 *     the ABI.
 *   - Interrupts are disabled on entry; the kernel enables them when it
 *     installs its own interrupt handling.
 */

.section .text
.global voryn_kernel_entry
.type voryn_kernel_entry, @function
voryn_kernel_entry:
    /* Establish the kernel stack: top of the .bss stack region. */
    lea voryn_boot_stack_end(%rip), %rsp
    and $-16, %rsp

    /* voryn_kmain(boot_handoff) never returns. */
    call voryn_kmain

    /* Defensive: the kernel must never come back from here. */
1:
    cli
    hlt
    jmp 1b
.size voryn_kernel_entry, . - voryn_kernel_entry

/* Address of the entry point, used by the kernel to verify that the loader
 * transferred control to the expected address. */
.section .data
.global voryn_kernel_entry_address
.type voryn_kernel_entry_address, @object
voryn_kernel_entry_address:
    .quad voryn_kernel_entry
.size voryn_kernel_entry_address, . - voryn_kernel_entry_address

/* Boot stack of the kernel. It lives in the image itself so that the kernel
 * owns its stack from the very first instruction, independently of any
 * firmware allocation. */
.section .bss
.align 16
.global voryn_boot_stack
.type voryn_boot_stack, @object
voryn_boot_stack:
    .skip 65536
.global voryn_boot_stack_end
.type voryn_boot_stack_end, @object
voryn_boot_stack_end:

/* The kernel does not use an executable stack. */
.section .note.GNU-stack,"",@progbits
