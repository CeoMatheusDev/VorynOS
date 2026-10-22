/**************************************************************************/
/*  segment.s                                                             */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               VorynOS                                  */
/*              https://github.com/CeoMatheusDev/VorynOS                  */
/**************************************************************************/
/* Copyright (C) 2026 VorynOS contributors.                               */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

/*
 * Access to the structures of the segment subsystem: the global descriptor
 * table and the task state segment.
 *
 * The instructions that manipulate these structures have no form that the
 * inline assembly of Zig can express with the correct operand size, and
 * their semantics depend on the exact width of the operand. They are
 * therefore implemented here, where the size is explicit.
 *
 * ABI of `voryn_gdt_load_data`:
 *   DI - selector of the kernel data segment
 *
 * ABI of `voryn_gdt_load_code`:
 *   DI - selector of the kernel code segment
 *
 * ABI of `voryn_load_tss`:
 *   DI - selector of the task state segment
 *
 * ABI of `voryn_load_gdt` and `voryn_store_gdt`:
 *   RDI - address of the GDTR structure (16 bit limit followed by the 64 bit
 *         base address)
 *
 * Registers: the routines preserve every register they change, except for
 * the segment registers that they reload on purpose.
 * Side effects: `voryn_gdt_load_data` reloads `SS`, `DS`, `ES`, `FS` and
 * `GS`; `voryn_gdt_load_code` reloads `CS` with a far jump.
 */

.section .text

/*
 * Reloads the data segment registers.
 *
 * The data segments are reloaded before the code segment: the far jump that
 * follows needs a valid stack, which the current one already is.
 */
.global voryn_gdt_load_data
.type voryn_gdt_load_data, @function
voryn_gdt_load_data:
    movw %di, %ax
    movw %ax, %ss
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs
    ret
.size voryn_gdt_load_data, . - voryn_gdt_load_data

/*
 * Reloads the code segment.
 *
 * The code segment can only be changed with a far transfer. A far jump is
 * used instead of a far return because it does not touch the stack, which
 * removes one class of alignment problems.
 *
 * The far pointer holds the offset in the first quad word and the selector
 * in the second one. The selector is zero extended: the far pointer has a
 * full quad word for it and the upper bits have to be zero. The upper bits
 * of the argument register are undefined in the ABI.
 */
.global voryn_gdt_load_code
.type voryn_gdt_load_code, @function
voryn_gdt_load_code:
    leaq 1f(%rip), %rax
    movq %rax, voryn_far_pointer(%rip)
    movzwq %di, %rax
    movq %rax, voryn_far_pointer+8(%rip)
    ljmpq *voryn_far_pointer(%rip)
1:
    ret
.size voryn_gdt_load_code, . - voryn_gdt_load_code

/*
 * Loads the task state segment into the `TR` register.
 *
 * The instruction takes a sixteen bit selector. The assembler promotes a
 * register operand to the thirty two bit form, which is not the encoding
 * the instruction is defined with, therefore the selector is placed in
 * memory and the sixteen bit form of the instruction is used.
 */
.global voryn_load_tss
.type voryn_load_tss, @function
voryn_load_tss:
    movw %di, voryn_tss_selector(%rip)
    ltrw voryn_tss_selector(%rip)
    ret
.size voryn_load_tss, . - voryn_load_tss

/*
 * Loads the global descriptor table.
 */
.global voryn_load_gdt
.type voryn_load_gdt, @function
voryn_load_gdt:
    lgdt (%rdi)
    ret
.size voryn_load_gdt, . - voryn_load_gdt

/*
 * Stores the global descriptor table.
 */
.global voryn_store_gdt
.type voryn_store_gdt, @function
voryn_store_gdt:
    sgdt (%rdi)
    ret
.size voryn_store_gdt, . - voryn_store_gdt

/* The far pointer used by the reload of the code segment and the selector
 * used by the load of the task state segment. */
.section .bss
.align 8
.global voryn_far_pointer
voryn_far_pointer:
    .quad 0
    .quad 0
.global voryn_tss_selector
voryn_tss_selector:
    .word 0

/* The kernel does not use an executable stack. */
.section .note.GNU-stack,"",@progbits
