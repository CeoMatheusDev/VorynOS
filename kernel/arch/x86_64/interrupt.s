/**************************************************************************/
/*  interrupt.s                                                           */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               VorynOS                                  */
/*              https://github.com/CeoMatheusDev/VorynOS                  */
/**************************************************************************/
/* Copyright (C) 2026 VorynOS contributors.                               */
/* Copyright (C) 2020 - 2026 Matheus.A.Santos contributors. */
/* Copyright (C) 2026 VorynOS - All Rights Reserved. */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

/*
 * Entry points of the interrupt and exception handlers.
 *
 * The stubs normalise the stack frame so that the handler in Zig always
 * receives the same layout:
 *
 *   - a word with the error code, zero when the exception does not push one;
 *   - the vector number;
 *   - the general purpose registers.
 *
 * The registers are saved in the order that leaves them in the frame with
 * the most recently saved register at the lowest address, which is the
 * natural order of a structure in memory.
 *
 * ABI of the handler:
 *   RDI - the vector number
 *   RSI - the address of the register frame
 *
 * Registers: the stubs restore every register they change. The stack is
 * balanced when the handler returns.
 * Side effects: the handler is called with interrupts disabled by the
 * processor, it is the responsibility of the handler to re-enable them.
 */

.section .text

/* Saves the general purpose registers that the processor does not save. */
.macro PUSH_REGISTERS
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %rbx
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
.endm

/*
 * Aligns the stack for the call of the handler.
 *
 * The convention of the system V of AMD64 asks for a stack pointer that is
 * a multiple of sixteen before the call, and the handler of Zig assumes
 * that it is the case.
 *
 * The processor does not leave the stack aligned when the interruption
 * comes from the kernel itself: the processor pushes the frame of the
 * return only when the privilege level changes, and the pushes of the stub
 * change the parity of the stack pointer. The interruption that comes from
 * the user mode leaves the stack aligned, and the padding is not pushed
 * for it.
 *
 * The macro has to be paired with UNALIGN_STACK, and the register of the
 * padding is the one that the convention of the call makes the callee
 * save.
 */
.macro ALIGN_STACK
    movq %rsp, %rax
    testq $8, %rax
    jz 901f
    pushq $0                  /* the padding */
    movq $1, %rbx
    jmp 902f
901:
    movq $0, %rbx
902:
.endm

/* Removes the padding that ALIGN_STACK pushed, if there was one. */
.macro UNALIGN_STACK
    testq %rbx, %rbx
    jz 903f
    addq $8, %rsp
903:
.endm

/* Restores the registers saved by PUSH_REGISTERS. */
.macro POP_REGISTERS
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbx
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rax
.endm

/*
 * Entry point of an exception that does not push an error code.
 *
 * The word that the processor pushed for the exceptions that do push one is
 * removed before the return, so the frame is always the same.
 */
.macro EXCEPTION_ENTRY number
    .global voryn_exception_\number
    .type voryn_exception_\number, @function
voryn_exception_\number:
    pushq $0
    pushq $\number
    PUSH_REGISTERS
    /* An exception without an error code leaves no code behind, and the
     * global is cleared so that a previous exception does not show up in
     * the report of this one. */
    movq $0, voryn_exception_error_code(%rip)
    movq $\number, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call voryn_exception_handler
    UNALIGN_STACK
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

/*
 * Entry point of an exception that pushes an error code.
 *
 * The error code of the processor is kept above the word that the stub
 * pushes, the handler reads it from the frame.
 */
.macro EXCEPTION_ENTRY_WITH_ERROR number
    .global voryn_exception_\number
    .type voryn_exception_\number, @function
voryn_exception_\number:
    pushq $0
    pushq $\number
    PUSH_REGISTERS
    /* The processor pushes the error code between the word of the vector
     * and the frame of the return, and the frame of an exception **with**
     * an error code has a shape that is different from the shape of the
     * frame of an interruption.
     *
     * The frame is normalized here: the error code is saved in a global,
     * and the five words of the return of the processor are moved down by
     * eight bytes. The handler, the switch of the context and the return of
     * the processor read the same offsets in the two cases, and the shape of
     * the frame stops being a concern of each call. */
    movq 136(%rsp), %rax
    movq %rax, voryn_exception_error_code(%rip)
    movq 144(%rsp), %rax
    movq %rax, 136(%rsp)
    movq 152(%rsp), %rax
    movq %rax, 144(%rsp)
    movq 160(%rsp), %rax
    movq %rax, 152(%rsp)
    movq 168(%rsp), %rax
    movq %rax, 160(%rsp)
    movq 176(%rsp), %rax
    movq %rax, 168(%rsp)
    movq $\number, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call voryn_exception_handler
    UNALIGN_STACK
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

/*
 * Entry point of a hardware interrupt.
 *
 * The frame has the same layout as the frame of an exception, the handler
 * returns to the interrupted code.
 */
.macro INTERRUPT_ENTRY number
    .global voryn_interrupt_\number
    .type voryn_interrupt_\number, @function
voryn_interrupt_\number:
    pushq $0
    pushq $\number
    PUSH_REGISTERS
    /* The state of the floating point unit and of the vector registers
     * belongs to the task that is interrupted, and the processor does not
     * save it in the long mode. The area is the one of the context of the
     * task, and the context is the one that the scheduler points at.
     *
     * The save happens here, at the entry of the interruption, and not in
     * the switch: the handler is written in Zig, and the code that it
     * runs uses the vector registers, and therefore it would save the state
     * that the interrupted task had left behind.
     *
     * The save comes after PUSH_REGISTERS because the instruction needs a
     * register to hold the address of the context, and every register of
     * the task is already saved in the frame at this point. */
    movq voryn_current_context(%rip), %rax
    testq %rax, %rax
    jz .Lskip_fp_save_\number
    fxsave64 192(%rax)
.Lskip_fp_save_\number:
    movq $\number, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call voryn_interrupt_handler
    UNALIGN_STACK
    /* The handler returns zero to resume the interrupted code, and a value
     * different from zero to switch to another task. The switch reads the
     * frame that is still on the stack, so it is entered with a jump and not
     * with a call: a call would move the frame. */
    testq %rax, %rax
    jz 1f
    jmp voryn_task_switch
1:
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

/*
 * Entry point of the vectors that the kernel does not handle.
 */
.macro EXCEPTION_ENTRY_UNEXPECTED
    .global voryn_exception_unexpected
    .type voryn_exception_unexpected, @function
voryn_exception_unexpected:
    pushq $0
    pushq $255
    PUSH_REGISTERS
    movq $255, %rdi
    movq %rsp, %rsi
    ALIGN_STACK
    call voryn_exception_handler
    UNALIGN_STACK
    POP_REGISTERS
    addq $16, %rsp
    iretq
.endm

EXCEPTION_ENTRY 0
EXCEPTION_ENTRY 1
EXCEPTION_ENTRY 2
EXCEPTION_ENTRY 3
EXCEPTION_ENTRY 4
EXCEPTION_ENTRY 5
EXCEPTION_ENTRY 6
EXCEPTION_ENTRY 7
EXCEPTION_ENTRY_WITH_ERROR 8
EXCEPTION_ENTRY 9
EXCEPTION_ENTRY_WITH_ERROR 10
EXCEPTION_ENTRY_WITH_ERROR 11
EXCEPTION_ENTRY_WITH_ERROR 12
EXCEPTION_ENTRY_WITH_ERROR 13
EXCEPTION_ENTRY_WITH_ERROR 14
EXCEPTION_ENTRY 15
EXCEPTION_ENTRY 16
EXCEPTION_ENTRY_WITH_ERROR 17
EXCEPTION_ENTRY 18
EXCEPTION_ENTRY 19
EXCEPTION_ENTRY 20
EXCEPTION_ENTRY_WITH_ERROR 21
EXCEPTION_ENTRY 22
EXCEPTION_ENTRY 23
EXCEPTION_ENTRY 24
EXCEPTION_ENTRY 25
EXCEPTION_ENTRY 26
EXCEPTION_ENTRY 27
EXCEPTION_ENTRY 28
EXCEPTION_ENTRY 29
EXCEPTION_ENTRY 30
EXCEPTION_ENTRY 31

INTERRUPT_ENTRY 32
INTERRUPT_ENTRY 33
INTERRUPT_ENTRY 34
INTERRUPT_ENTRY 35
INTERRUPT_ENTRY 36
INTERRUPT_ENTRY 37
INTERRUPT_ENTRY 38
INTERRUPT_ENTRY 39
INTERRUPT_ENTRY 40
INTERRUPT_ENTRY 41
INTERRUPT_ENTRY 42
INTERRUPT_ENTRY 43
INTERRUPT_ENTRY 44
INTERRUPT_ENTRY 45
INTERRUPT_ENTRY 46
INTERRUPT_ENTRY 47

INTERRUPT_ENTRY 64

EXCEPTION_ENTRY_UNEXPECTED

/*
 * Loads the interrupt descriptor table.
 *
 * ABI:
 *   RDI - address of the IDTR structure (16 bit limit followed by the
 *         64 bit base address).
 */
.global voryn_load_idt
.type voryn_load_idt, @function
voryn_load_idt:
    lidt (%rdi)
    ret
.size voryn_load_idt, . - voryn_load_idt

/*
 * Stores the interrupt descriptor table.
 *
 * ABI:
 *   RDI - address of the IDTR structure that receives the values.
 */
.global voryn_store_idt
.type voryn_store_idt, @function
voryn_store_idt:
    sidt (%rdi)
    ret
.size voryn_store_idt, . - voryn_store_idt

/* The error code of the last exception that pushed one.
 *
 * The stub of an exception with an error code saves the code here before it
 * normalizes the frame, and the handler reads the code from here. */
.section .bss
.align 8
.global voryn_exception_error_code
.type voryn_exception_error_code, @object
voryn_exception_error_code:
    .quad 0

/* The kernel does not use an executable stack. */
.section .note.GNU-stack,"",@progbits
