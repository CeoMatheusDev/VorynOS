/*
 * SPDX-License-Identifier: GPL-3.0-only
 * Copyright (C) 2026 VorynOS contributors
 *
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
 * A task that is suspended inside an interrupt handler cannot be resumed
 * with a return: the context of a task therefore holds the whole frame of
 * the processor, and the switch returns to the entering task with an
 * interrupt return.
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

    movq 64(%rsp), %rax          /* rbx */
    movq %rax, 0(%rdi)
    movq 72(%rsp), %rax          /* rbp */
    movq %rax, 8(%rdi)
    movq 24(%rsp), %rax          /* r12 */
    movq %rax, 16(%rdi)
    movq 16(%rsp), %rax          /* r13 */
    movq %rax, 24(%rdi)
    movq 8(%rsp), %rax           /* r14 */
    movq %rax, 32(%rdi)
    movq (%rsp), %rax            /* r15 */
    movq %rax, 40(%rdi)
    movq 160(%rsp), %rax         /* the stack pointer of the interrupted code */
    movq %rax, 48(%rdi)
    movq 152(%rsp), %rax         /* the flags */
    movq %rax, 56(%rdi)
    movq 136(%rsp), %rax         /* the instruction pointer */
    movq %rax, 64(%rdi)
    movq 144(%rsp), %rax         /* the code segment */
    movq %rax, 72(%rdi)
    movq 168(%rsp), %rax         /* the stack segment */
    movq %rax, 80(%rdi)

    /* The context of the task that is entering. */
    movq voryn_next_context(%rip), %rsi
    movq 0(%rsi), %rbx
    movq 8(%rsi), %rbp
    movq 16(%rsi), %r12
    movq 24(%rsi), %r13
    movq 32(%rsi), %r14
    movq 40(%rsi), %r15

    /* The frame of the processor is built on the stack of the entering task,
     * below its stack pointer, and the task returns to it. */
    movq 48(%rsi), %rsp
    subq $40, %rsp
    movq 64(%rsi), %rax          /* the instruction pointer */
    movq %rax, (%rsp)
    movq 72(%rsi), %rax          /* the code segment */
    movq %rax, 8(%rsp)
    movq 56(%rsi), %rax          /* the flags */
    movq %rax, 16(%rsp)
    movq 48(%rsi), %rax          /* the stack pointer */
    movq %rax, 24(%rsp)
    movq 80(%rsi), %rax          /* the stack segment */
    movq %rax, 32(%rsp)

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
 * ABI:
 *   RDI - address of the context that receives the state
 */
.global voryn_capture_context
.type voryn_capture_context, @function
voryn_capture_context:
    movq %rbx, 0(%rdi)
    movq %rbp, 8(%rdi)
    movq %r12, 16(%rdi)
    movq %r13, 24(%rdi)
    movq %r14, 32(%rdi)
    movq %r15, 40(%rdi)
    leaq 8(%rsp), %rax          /* the stack pointer of the caller */
    movq %rax, 48(%rdi)
    pushfq
    popq %rax
    movq %rax, 56(%rdi)          /* the flags */
    movq (%rsp), %rax           /* the return address of the call */
    movq %rax, 64(%rdi)          /* the instruction to continue at */
    movw %cs, %ax
    movq %rax, 72(%rdi)          /* the code segment */
    movw %ss, %ax
    movq %rax, 80(%rdi)          /* the stack segment */
    ret
.size voryn_capture_context, . - voryn_capture_context

/*
 * A program that runs in the third level of privilege.
 *
 * The program writes a known value into the page of data that the kernel
 * prepared for it, calls the four calls of the kernel, writes the results
 * in the same page and ends the task.
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
 * The page of data of the user:
 *
 *   0x401000  the marker
 *   0x401008  the result of the probe
 *   0x401010  the result of the write
 *   0x401018  the result of the copy
 *   0x401020  the code copied from the page of code
 *   0x401028  the message that the program writes in the console
 */
.global voryn_user_program
.type voryn_user_program, @function
voryn_user_program:
    /* The program lives at a fixed virtual address, so the page of data is
     * reached with an absolute address. */
    movabsq $0x5A5A1234, %rax
    movabsq $0x401000, %rdi
    movq %rax, (%rdi)

    /* The message that the program writes in the console. */
    movabsq $0x401028, %rdi
    movabsq $0x0A534F6E79726F56, %rax   /* "VorynOS" and a new line */
    movq %rax, (%rdi)

    /* The call of the probe: the number of the call is in the first
     * register, and the first argument is in the second. */
    movq $1, %rax             /* the number of the system call */
    movq $0xF00D, %rdi        /* the argument of the system call */
    syscall

    /* The result of the call comes back in the first register, and it is
     * written in the second word of the page of data. */
    movabsq $0x401008, %rdi
    movq %rax, (%rdi)

    /* The call that writes in the console: the buffer is in the first
     * register, the length in the second, and the file in the third. */
    movabsq $0x401028, %rdi   /* the buffer */
    movq $8, %rsi             /* the length */
    movq $1, %rdx             /* the console */
    movq $2, %rax             /* the number of the system call */
    syscall
    movabsq $0x401010, %rdi
    movq %rax, (%rdi)

    /* The call that copies a block: the destination in the first
     * register, the origin in the second, and the length in the third.
     * The origin is the page of code, and the destination is the page of
     * data. */
    movabsq $0x401020, %rdi   /* the destination */
    movabsq $0x400000, %rsi   /* the origin */
    movq $8, %rdx             /* the length */
    movq $3, %rax             /* the number of the system call */
    syscall
    movabsq $0x401018, %rdi
    movq %rax, (%rdi)

    /* A call with an address that is not of the user: the kernel has to
     * refuse the call, and the answer is the negative value of the
     * error. */
    movabsq $0x1000, %rdi    /* an address of the kernel */
    movq $8, %rsi             /* the length */
    movq $1, %rdx             /* the console */
    movq $2, %rax             /* the number of the system call */
    syscall
    movabsq $0x401030, %rdi
    movq %rax, (%rdi)

    /* The call that ends the task. The kernel marks the task as
     * terminated, and the processor only leaves it in the next
     * interruption. */
    movq $0, %rdi             /* the code of exit */
    movq $4, %rax             /* the number of the system call */
    syscall

    /* The task should not come back. The instruction that halts the
     * processor and the pause instruction are privileged, the loop only
     * branches to itself. */
1:  jmp 1b
.size voryn_user_program, . - voryn_user_program
.global voryn_user_program_end
voryn_user_program_end:

/*
 * The programs of the two demo processes.
 *
 * Each program writes a known signature into the page of data that sits at
 * the same virtual address in both processes — 0x401000, one page above the
 * entry point — and then calls the system call that ends the task. The two
 * programs are deliberately almost identical: what separates them is not
 * the code but the address space, because each process reaches 0x401000
 * through its own private chain of page tables, which names a different
 * physical frame. If the spaces shared a mapping, only one of the two
 * signatures would ever be seen by the kernel; seeing both, in the frames
 * of their own spaces, is the proof of the isolation.
 *
 * After the call of exit the processor keeps running the task until the
 * next interruption; the loop that branches to itself covers the case where
 * the task is scheduled again before it is taken out of the list.
 *
 * The kernel copies exactly these bytes into the page of code of each
 * process, so the length of each program is part of the contract with the
 * kernel (see demo_program_length in main.zig). With the assembler used by
 * the project the encoding is:
 *
 *   movabsq $signature, %rax    10 bytes
 *   movabsq $0x401000, %rdi     10 bytes
 *   movq %rax, (%rdi)            3 bytes
 *   movq $4, %rax                5 bytes
 *   movq $0, %rdi                5 bytes
 *   syscall                      2 bytes
 *   jmp .                        2 bytes
 *   padding to 49 bytes         12 bytes (nop)
 */

.section .rodata
.align 16

.global voryn_demo_program_a
.type voryn_demo_program_a, @function
voryn_demo_program_a:
    movabsq $0xA1A1A1A1, %rax
    movabsq $0x401000, %rdi
    movq %rax, (%rdi)
    movq $4, %rax             /* the number of the system call of exit */
    movq $0, %rdi             /* the code of exit */
    syscall
    jmp .                     /* the task should not come back */
    .fill 49 - (. - voryn_demo_program_a), 1, 0x90
.size voryn_demo_program_a, . - voryn_demo_program_a
.global voryn_demo_program_a_end
voryn_demo_program_a_end:

.global voryn_demo_program_b
.type voryn_demo_program_b, @function
voryn_demo_program_b:
    movabsq $0xB2B2B2B2, %rax
    movabsq $0x401000, %rdi
    movq %rax, (%rdi)
    movq $4, %rax             /* the number of the system call of exit */
    movq $0, %rdi             /* the code of exit */
    syscall
    jmp .                     /* the task should not come back */
    .fill 49 - (. - voryn_demo_program_b), 1, 0x90
.size voryn_demo_program_b, . - voryn_demo_program_b
.global voryn_demo_program_b_end
voryn_demo_program_b_end:

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
