/**************************************************************************/
/*  syscall.s                                                             */
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
 * The entry point of the system call.
 *
 * The instruction `syscall` does not go through the interrupt table: it
 * loads the code and the stack segments of the kernel from the register
 * IA32_STAR, the address of the entry point from IA32_LSTAR and the mask
 * of the flags from IA32_SFMASK. The instruction also leaves the stack
 * pointer of the caller untouched, and the address of return and the flags
 * of the caller are left in the registers RCX and R11.
 *
 * The instruction is the door of the user mode, and the kernel does not use
 * it: the instruction replaces the code and the stack segments of the
 * caller by the ones of the kernel, therefore the entry point cannot tell
 * the privilege level of the caller by the selector of the code segment.
 * The kernel calls the handler of the call directly, and the entry point
 * always returns to the user mode.
 *
 * The entry point saves the state of the caller on the stack of the kernel
 * of the task, which is the stack that the scheduler points the segment of
 * task state at. The handler of the call therefore never runs on the stack
 * of the user, and the user cannot rewrite the frame of the handler.
 *
 * The way back is an interrupt return, because the privilege level changes:
 * the frame of the return carries the code and the stack segments of the
 * user mode, and the processor restores the stack pointer of the user.
 *
 * The selectors of the user mode are the ones of the segment module: the
 * code segment at the offset 0x18 and the stack segment at the offset 0x20.
 *
 * ABI:
 *   The address of the frame with the state of the caller arrives in RDI,
 *   and the privilege level of the caller arrives in RSI.
 * Registers: the registers of the caller are restored before the return.
 * Side effects: the processor returns to the caller.
 */

.section .text

/* The stack pointer of the caller, saved by the entry point while the
 * frame of the return is built. The value is read in the same sequence of
 * instructions, and the interrupts are disabled during it. */
.global voryn_user_stack_pointer
.type voryn_user_stack_pointer, @object
voryn_user_stack_pointer:
    .quad 0

/* The stack of the kernel of the task that is running. The scheduler
 * updates it with the stack of the task that enters. */
.global voryn_kernel_stack_pointer
.type voryn_kernel_stack_pointer, @object
voryn_kernel_stack_pointer:
    .quad 0

/* The flag that tells the entry that the task blocked. The scheduler sets
 * it when a task waits for a message, and the entry clears it before it
 * hands the control to the switch. */
.global voryn_syscall_blocked
.type voryn_syscall_blocked, @object
voryn_syscall_blocked:
    .quad 0

.global voryn_syscall_instruction_entry
.type voryn_syscall_instruction_entry, @function
voryn_syscall_instruction_entry:
    /* The stack pointer of the caller is still valid here: the instruction
     * does not change the stack. It is saved before the change, because
     * the frame of the return needs it. */
    movq %rsp, voryn_user_stack_pointer(%rip)

    /* The stack of the kernel of the task, where the handler runs. The
     * user cannot reach it, because the pages of the kernel do not have
     * the bit that allows the access from the user mode. */
    movq voryn_kernel_stack_pointer(%rip), %rsp

    /* The frame of the interrupt return. The processor pops the address of
     * return, the code segment, the flags, the stack pointer and the stack
     * segment, in this order, and the values are pushed in the reverse
     * order. */
    pushq $0x23                             /* the stack segment of the user */
    pushq voryn_user_stack_pointer(%rip)    /* the stack pointer of the user */
    pushq %r11                              /* the flags of the user */
    pushq $0x1b                             /* the code segment of the user */
    pushq %rcx                              /* the address of return of the user */

    /* The word of the error code and the vector, as the stub of the
     * interruption does, so that the frame has the same shape in the two
     * cases: the switch of the interruption reads the frame with the same
     * offsets, and the frame of the call is read the same way. The values are
     * not used by the call, and they exist for the shape of the frame. */
    pushq $0                                /* the word of the error code */
    pushq $0                                /* the vector */

    /* The state of the user. The order of the pushes is the reverse of the
     * order of the fields of the frame. */
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

    movq %rsp, %rdi                 /* the frame with the state of the user */
    movq $3, %rsi                   /* the privilege level of the caller */
    call voryn_syscall_handler

    /* The task may have blocked, waiting for a message. The frame is
     * still whole, and the switch of the interruption reads it with the
     * same offsets, so the control goes to the scheduler in the same way
     * as when the timer decides to change the task. */
    movq voryn_syscall_blocked(%rip), %rax
    testq %rax, %rax
    jz 1f
    movq $0, voryn_syscall_blocked(%rip)
    jmp voryn_task_switch
1:

    /* The result of the call is in the frame: the handler changed the
     * value of RAX there. */
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

    /* The word of the vector and the word of the error code sit between
     * the registers and the frame of the return, and the stub of the
     * interruption skips them in the same way. */
    addq $16, %rsp

    /* The frame of the interrupt return is at the top of the stack. */
    iretq
.size voryn_syscall_instruction_entry, . - voryn_syscall_instruction_entry

/* The kernel does not use an executable stack. */
.section .note.GNU-stack,"",@progbits
