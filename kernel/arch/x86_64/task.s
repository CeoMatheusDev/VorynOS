/**************************************************************************/
/*  task.s                                                                */
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
 * Switch of the execution context between two tasks.
 *
 * The routine is called from the entry point of an interrupt, with the frame
 * of the interrupt still on the stack of the task that is leaving. The
 * layout of the frame, from the lowest address, is:
 *
 *   0    r15        64   rbx       120  vector      144  CS
 *   8    r14        72   rbp       128  reserved   152  RFLAGS
 *   16   r13        80   rdi       136  RIP        160  RSP
 *   24   r12        88   rsi                       168  SS
 *   32   r11        96   rdx
 *   40   r10       104   rcx
 *   48   r9        112   rax
 *   56   r8
 *
 * The frame of the processor is below the registers of the stub. The
 * processor pushes the stack segment, the stack pointer, the flags, the code
 * segment and the instruction pointer, so the order of the addresses is the
 * reverse of the order of the pushes.
 *
 * The context of a task holds EVERY register of the processor, and not only
 * the ones that the architecture saves between calls. A task that is
 * suspended in the middle of a system call has to come back with the same
 * value in every register, otherwise the result of the call is lost and the
 * task computes with values that belong to another task.
 *
 * The frame that the switch builds for the entering task is built on the
 * stack of the kernel of the task, and not on the stack of the interrupted
 * code: the stack of the user mode belongs to the user, and a frame that
 * the user can rewrite is a frame that the user controls. The frame has the
 * same shape as the frame of the stub, therefore a task that is suspended
 * again finds the same layout under its feet.
 *
 * ABI: none, the routine never returns to its caller.
 * Registers: the registers of the entering task are restored.
 * Side effects: the global counters of the switch are updated.
 */

.section .text

.global voryn_task_switch
.type voryn_task_switch, @function
voryn_task_switch:
    /* The moment of the switch, used to measure its cost. */
    rdtsc
    shlq $32, %rdx
    orq %rdx, %rax
    movq %rax, voryn_switch_timestamp(%rip)

    /* The context of the task that is leaving. */
    movq voryn_current_context(%rip), %rdi

    movq 0(%rsp), %rax          /* r15 */
    movq %rax, 0(%rdi)
    movq 8(%rsp), %rax          /* r14 */
    movq %rax, 8(%rdi)
    movq 16(%rsp), %rax         /* r13 */
    movq %rax, 16(%rdi)
    movq 24(%rsp), %rax         /* r12 */
    movq %rax, 24(%rdi)
    movq 32(%rsp), %rax         /* r11 */
    movq %rax, 32(%rdi)
    movq 40(%rsp), %rax         /* r10 */
    movq %rax, 40(%rdi)
    movq 48(%rsp), %rax         /* r9 */
    movq %rax, 48(%rdi)
    movq 56(%rsp), %rax         /* r8 */
    movq %rax, 56(%rdi)
    movq 64(%rsp), %rax         /* rbx */
    movq %rax, 64(%rdi)
    movq 72(%rsp), %rax         /* rbp */
    movq %rax, 72(%rdi)
    movq 80(%rsp), %rax         /* rdi */
    movq %rax, 80(%rdi)
    movq 88(%rsp), %rax         /* rsi */
    movq %rax, 88(%rdi)
    movq 96(%rsp), %rax         /* rdx */
    movq %rax, 96(%rdi)
    movq 104(%rsp), %rax        /* rcx */
    movq %rax, 104(%rdi)
    movq 112(%rsp), %rax        /* rax */
    movq %rax, 112(%rdi)
    movq 120(%rsp), %rax        /* the vector */
    movq %rax, 120(%rdi)
    movq 160(%rsp), %rax        /* the stack pointer of the interrupted code */
    movq %rax, 128(%rdi)
    movq 152(%rsp), %rax        /* the flags */
    movq %rax, 136(%rdi)
    movq 136(%rsp), %rax        /* the instruction pointer */
    movq %rax, 144(%rdi)
    movq 144(%rsp), %rax        /* the code segment */
    movq %rax, 152(%rdi)
    movq 168(%rsp), %rax        /* the stack segment */
    movq %rax, 160(%rdi)

    /* The context of the task that is entering. */
    movq voryn_next_context(%rip), %rsi

    /* The frame of the entering task is built on the stack of the kernel of
     * the task. The scheduler points the segment of task state at it, and
     * the stack of the interrupted code belongs to the task that is
     * leaving. */
    movq voryn_kernel_stack_pointer(%rip), %rsp
    subq $176, %rsp

    /* The general purpose registers, in the order of the addresses. */
    movq 0(%rsi), %rax
    movq %rax, 0(%rsp)
    movq 8(%rsi), %rax
    movq %rax, 8(%rsp)
    movq 16(%rsi), %rax
    movq %rax, 16(%rsp)
    movq 24(%rsi), %rax
    movq %rax, 24(%rsp)
    movq 32(%rsi), %rax
    movq %rax, 32(%rsp)
    movq 40(%rsi), %rax
    movq %rax, 40(%rsp)
    movq 48(%rsi), %rax
    movq %rax, 48(%rsp)
    movq 56(%rsi), %rax
    movq %rax, 56(%rsp)
    movq 64(%rsi), %rax
    movq %rax, 64(%rsp)
    movq 72(%rsi), %rax
    movq %rax, 72(%rsp)
    movq 80(%rsi), %rax
    movq %rax, 80(%rsp)
    movq 88(%rsi), %rax
    movq %rax, 88(%rsp)
    movq 96(%rsi), %rax
    movq %rax, 96(%rsp)
    movq 104(%rsi), %rax
    movq %rax, 104(%rsp)
    movq 112(%rsi), %rax
    movq %rax, 112(%rsp)

    /* The vector and the word of the error code: the frame has the same
     * shape as the frame of the stub. */
    movq 120(%rsi), %rax
    movq %rax, 120(%rsp)
    movq $0, 128(%rsp)

    /* The frame of the return of the processor. */
    movq 144(%rsi), %rax        /* the instruction pointer */
    movq %rax, 136(%rsp)
    movq 152(%rsi), %rax        /* the code segment */
    movq %rax, 144(%rsp)
    movq 136(%rsi), %rax        /* the flags */
    movq %rax, 152(%rsp)
    movq 128(%rsi), %rax        /* the stack pointer of the interrupted code */
    movq %rax, 160(%rsp)
    movq 160(%rsi), %rax        /* the stack segment */
    movq %rax, 168(%rsp)

    /* The cost of the switch, in cycles of the time stamp counter. */
    rdtsc
    shlq $32, %rdx
    orq %rdx, %rax
    subq voryn_switch_timestamp(%rip), %rax
    movq %rax, voryn_switch_cycles(%rip)
    addq %rax, voryn_switch_total(%rip)
    incq voryn_switch_count(%rip)

    /* The smallest switch is the best estimate of the cost of a switch, the
     * first ones are slower because of the cold caches. */
    cmpq %rax, voryn_switch_minimum(%rip)
    jb 1f
    movq %rax, voryn_switch_minimum(%rip)
1:

    /* The address space of the entering task. A process runs in a space of
     * its own, and the switch of the space happens together with the switch
     * of the context. The value is zero when the space does not change.
     *
     * The change happens after the frame is built, because the frame lives
     * in the image of the kernel, and the image is mapped in every space. */
    movq voryn_next_cr3(%rip), %rax
    testq %rax, %rax
    jz 2f
    movq %rax, %cr3
    movq $0, voryn_next_cr3(%rip)
2:

    /* The registers of the entering task, in the order of the pops.
     *
     * The frame holds the registers from the lowest address to the highest
     * one, with the register that was saved last at the lowest address, and
     * the stack grows towards the low addresses: the first pop therefore
     * takes the register that was saved last. */
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

    /* The word of the vector and the word of the error code sit between the
     * registers and the frame of the return of the processor. The stub of
     * the interrupt skips them in the same way before it returns. */
    addq $16, %rsp

    /* Return to the point where the entering task was suspended. */
    iretq
.size voryn_task_switch, . - voryn_task_switch

/*
 * Captures the context of the task that is running.
 *
 * The context holds the instruction that the task continues at, which is the
 * instruction after the call of this routine, and the state of the processor
 * at that point.
 *
 * The routine saves every register before it uses any of them, because the
 * registers of the caller are the state that the task has to come back
 * with.
 *
 * ABI:
 *   RDI - address of the context that receives the state
 */
.global voryn_capture_context
.type voryn_capture_context, @function
voryn_capture_context:
    movq %rax, 112(%rdi)        /* rax */
    movq %rcx, 104(%rdi)        /* rcx */
    movq %rdx, 96(%rdi)         /* rdx */
    movq %rsi, 88(%rdi)         /* rsi */
    movq %r8, 56(%rdi)          /* r8 */
    movq %r9, 48(%rdi)          /* r9 */
    movq %r10, 40(%rdi)         /* r10 */
    movq %r11, 32(%rdi)         /* r11 */
    movq %rbx, 64(%rdi)         /* rbx */
    movq %rbp, 72(%rdi)         /* rbp */
    movq %r12, 24(%rdi)         /* r12 */
    movq %r13, 16(%rdi)         /* r13 */
    movq %r14, 8(%rdi)          /* r14 */
    movq %r15, 0(%rdi)          /* r15 */
    leaq 8(%rsp), %rax          /* the stack pointer of the caller */
    movq %rax, 128(%rdi)        /* rsp */
    pushfq
    popq %rax
    movq %rax, 136(%rdi)        /* the flags */
    movq (%rsp), %rax           /* the return address of the call */
    movq %rax, 144(%rdi)        /* the instruction to continue at */
    movw %cs, %ax
    movq %rax, 152(%rdi)        /* the code segment */
    movw %ss, %ax
    movq %rax, 160(%rdi)        /* the stack segment */
    movq $0, 120(%rdi)          /* the vector */
    ret
.size voryn_capture_context, . - voryn_capture_context

/*
 * A program that runs in the third level of privilege.
 *
 * The program writes a known value into the page of data that the kernel
 * prepared for it, calls the calls of the kernel, writes the results in the
 * same page and ends the task.
 *
 * The values prove four different things:
 *
 *   - the first one proves that the task runs in the third level of
 *     privilege with access to its own pages;
 *   - the result of the probe proves that the call reached the handler of
 *     the kernel and that the answer came back;
 *   - the result of the write proves that the kernel read a buffer of the
 *     user after checking the range in the page tables;
 *   - the result of the copy proves that the kernel copied a block of
 *     memory of the user.
 *
 * The window of the user mode has no fixed address: the kernel chooses an
 * address that does not collide with the image of the kernel and hands it to
 * the task in the register RBX when the task starts. The program therefore
 * reaches every address through that register.
 *
 * The same program serves the two processes of the kernel. The role of the
 * process arrives in the first register of the entry point: the process of
 * role zero starts the conversation on the channel, and the process of role
 * one answers it. The marker of the page of data carries the role, and two
 * processes that write different markers in the same virtual address prove
 * that their pages are not the same pages.
 *
 * The page of data of the user:
 *
 *   0x00  the marker
 *   0x08  the result of the probe
 *   0x10  the result of the write
 *   0x18  the result of the copy
 *   0x20  the code copied from the page of code
 *   0x28  the message that the program writes in the console
 *   0x30  the answer of the call that the kernel refused
 *   0x38  the value of the answer of the channel
 *   0x40  the block of the copy with the overlapping ranges
 *   0x44  the destination of the copy with the overlapping ranges
 *   0x50  the result of the copy with the overlapping ranges
 *   0x58  the result of the copy to the other process
 *   0x60  the block that the copy to the other process wrote
 */
.global voryn_user_program
.type voryn_user_program, @function
voryn_user_program:
    /* The role of the process. The register is callee saved, therefore the
     * role survives the calls of the system. */
    movq %rcx, %r12

    /* The marker of the page of data. The marker carries the role, and two
     * processes that write different markers in the same address prove
     * that the pages of the two processes are not the same pages. */
    movq %r12, %rax
    addq $0x5A5A1234, %rax
    leaq 0x1000(%rbx), %rdi
    movq %rax, (%rdi)

    /* The message that the program writes in the console. */
    movabsq $0x0A534F6E79726F56, %rax   /* "VorynOS" and a new line */
    leaq 0x1028(%rbx), %rdi
    movq %rax, (%rdi)

    /* The call of the probe: the number of the call is in the first
     * register, and the first argument is in the second. */
    movq $1, %rax             /* the number of the system call */
    movq $0xF00D, %rdi        /* the argument of the system call */
    syscall

    /* The result of the call comes back in the first register, and it is
     * written in the second word of the page of data. */
    leaq 0x1008(%rbx), %rdi
    movq %rax, (%rdi)

    /* The call that writes in the console: the buffer is in the first
     * register, the length in the second, and the file in the third. */
    leaq 0x1028(%rbx), %rdi   /* the buffer */
    movq $8, %rsi             /* the length */
    movq $1, %rdx             /* the console */
    movq $2, %rax             /* the number of the system call */
    syscall
    leaq 0x1010(%rbx), %rdi
    movq %rax, (%rdi)

    /* The call that copies a block: the destination in the first
     * register, the origin in the second, and the length in the third.
     * The origin is the page of code, and the destination is the page of
     * data. */
    leaq 0x1020(%rbx), %rdi   /* the destination */
    leaq 0x0000(%rbx), %rsi   /* the origin */
    movq $8, %rdx             /* the length */
    movq $3, %rax             /* the number of the system call */
    syscall
    leaq 0x1018(%rbx), %rdi
    movq %rax, (%rdi)

    /* A call with an address that is not of the user: the kernel has to
     * refuse the call, and the answer is the negative value of the
     * error. */
    movabsq $0x1000, %rdi    /* an address of the kernel */
    movq $8, %rsi             /* the length */
    movq $1, %rdx             /* the console */
    movq $2, %rax             /* the number of the system call */
    syscall
    leaq 0x1030(%rbx), %rdi
    movq %rax, (%rdi)

    /* A copy whose ranges overlap. The user chooses the two addresses, and
     * a copy that refused the overlap would deny a call that is
     * legitimate. The copy that requires the ranges not to overlap lifts
     * a panic in the kernel, and a task of the user mode would be able to
     * stop the machine with two arguments.
     *
     * The call takes the destination in the first register and the origin
     * in the second one, and the destination is four bytes above the
     * origin, so the two ranges share the four bytes in the middle. */
    leaq 0x1040(%rbx), %rdi
    movabsq $0x1122334455667788, %rax
    movq %rax, (%rdi)

    leaq 0x1044(%rbx), %rdi   /* the destination, four bytes above */
    leaq 0x1040(%rbx), %rsi   /* the origin */
    movq $8, %rdx             /* the length */
    movq $3, %rax             /* the number of the system call */
    syscall
    leaq 0x1050(%rbx), %rdi
    movq %rax, (%rdi)

    /* The role decides who starts the conversation. */
    testq %r12, %r12
    jz 5f

    /* The process that answers. The call **blocks**: the task stays
     * waiting, the scheduler chooses another task, and the message wakes
     * the task up when it arrives. The call returns as if it had answered
     * at once. */
6:  movq $0, %rdi             /* the channel */
    movq $1, %rsi             /* the side of the process that started */
    movq $8, %rax             /* the number of the system call */
    syscall

    /* The answer is the value of the message with the bytes inverted, and
     * it waits in the queue of the side of the process that started. */
    movq %rdx, %rax
    notq %rax
    movq $0, %rdi             /* the channel */
    movq $0, %rsi             /* the side of the process that answers */
    movq $2, %rdx             /* the type of the answer */
    movq %rax, %r8            /* the value of the answer */
    movq $5, %rax             /* the number of the system call */
    syscall

    /* The call that ends the task. The kernel marks the task as
     * terminated, and the processor only leaves it in the next
     * interruption. */
    movq $0, %rdi             /* the code of exit */
    movq $4, %rax             /* the number of the system call */
    syscall
7:  jmp 7b

    /* The process that starts the conversation. */
5:
    /* The message for the channel: the arguments are the channel, the side
     * of the process that answers, the type of the message and the value
     * of the message. */
    movq $0, %rdi             /* the channel */
    movq $1, %rsi             /* the side of the process that answers */
    movq $1, %rdx             /* the type of the message */
    movq $0x5A5A1234, %r8     /* the value of the message */
    movq $5, %rax             /* the number of the system call */
    syscall

    /* The answer of the other process may not have arrived yet, and the
     * call that takes a message **blocks** until it arrives: the task
     * stays waiting, and o escalonador escolhe outra tarefa. */
2:  movq $0, %rdi             /* the channel */
    movq $0, %rsi             /* the side of the process that answers */
    movq $8, %rax             /* the number of the system call */
    syscall

    /* The value of the answer is the second result of the call, and it
     * is written in the eighth word of the page of data. */
    leaq 0x1038(%rbx), %rdi
    movq %rdx, (%rdi)

    /* The copy to the other process. The arguments are the identifier of
     * the process of the destination, the address of the destination in
     * the space of that process, the address of the origin in the space of
     * the caller, and the length of the block. The two spaces do not name
     * the same pages, therefore the kernel copies the block through the
     * tables of the two spaces. */
    movq $1, %rdi             /* the process of the destination */
    leaq 0x1060(%rbx), %rsi   /* the destination */
    leaq 0x1000(%rbx), %rdx   /* the origin, the marker of the process */
    movq $8, %r8              /* the length */
    movq $7, %rax             /* the number of the system call */
    syscall
    leaq 0x1058(%rbx), %rdi
    movq %rax, (%rdi)

    /* The call that ends the task. */
    movq $0, %rdi             /* the code of exit */
    movq $4, %rax             /* the number of the system call */
    syscall
1:  jmp 1b
.size voryn_user_program, . - voryn_user_program
.global voryn_user_program_end
voryn_user_program_end:

/* The contexts of the tasks that are leaving and that are entering, and the
 * measurements of the switches. */
.section .bss
.align 8
.global voryn_current_context
voryn_current_context:
    .quad 0
.global voryn_next_context
voryn_next_context:
    .quad 0
.global voryn_next_cr3
voryn_next_cr3:
    .quad 0
.global voryn_switch_timestamp
voryn_switch_timestamp:
    .quad 0
.global voryn_switch_cycles
voryn_switch_cycles:
    .quad 0
.global voryn_switch_total
voryn_switch_total:
    .quad 0
.global voryn_switch_count
voryn_switch_count:
    .quad 0
.global voryn_switch_minimum
voryn_switch_minimum:
    .quad 0

/* The kernel does not use an executable stack. */
.section .note.GNU-stack,"",@progbits
