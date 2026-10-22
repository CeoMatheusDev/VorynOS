# ADR-0005 — Task model, context switch, and user mode

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED — the scheduler and user mode are implemented and verified |
| **Date** | 2026-10-21 |
| **Decided by** | VorynOS Engineering |
| **Context** | Milestone F3, execution |

## 1. Context

Milestone F2 delivered the processor structures. Milestone F3 needs tasks
that switch between each other, and the first verifiable objective is
**user mode**: a task that runs at the third privilege level, with its own
pages, and that returns to the kernel through a system call.

## 2. Decisions

### 2.1 The context holds the complete processor frame

A task suspended **inside** an interrupt handler has no return address to
return to: the interrupt frame belongs to the handler, and not to the
interrupted code. A context that only held the registers the architecture
does not save, and that was resumed with a `ret`, would read an arbitrary
value from the stack.

VorynOS's context holds, besides the registers the architecture does not
save, the instruction pointer, the flags, and the segment selectors. The
switch builds the processor frame on the stack of the incoming task and
ends with an `iretq`.

**Consequence:** the switch costs a few cycles more than a `ret`, and the
measurement confirms the order of magnitude: **358 cycles** in the best
case, with an average of 8 thousand cycles in the first execution, in which
the caches are still cold.

### 2.2 The switch happens at the interrupt entry point

The context switch is performed by the interrupt entry point, and not by
the Zig handler. The interrupt frame is still on the stack when the
suspended task is resumed, and therefore the context can be reconstructed
from it.

**Consequence:** the handler returns a value that indicates whether the
switch is necessary, and the entry point decides.

### 2.3 The policy is round-robin, and not "the first ready task"

The first version of the policy always returned the first ready task of the
list. With three tasks, the second was never chosen: the processor switched
between the first and the second and the third starved.

The policy visits the tasks **starting from the current task**, and returns
to the beginning when it reaches the end. It is the simplest policy that
does not produce starvation, and it is the basis on which the gamer
profile's latency policies will be built, with data.

### 2.4 The task segment points to the task's stack

The processor loads the task segment's stack pointer whenever the privilege
level changes, **in both directions**. A user task that receives its stack
pointer from somewhere else would run on the kernel stack, whose pages are
not accessible from user mode.

The scheduler points the task segment to the stack of the task that is
going to run. For a user task, it is the user stack; for a kernel task, it
is the task's own stack.

**Consequence:** the handler of an exception coming from user mode runs on
the user stack. The user stack has to be larger than the kernel stack would
use, and this coupling needs to be documented.

### 2.5 The user bit exists at all levels of the hierarchy

The processor checks the user bit at **all** levels of the table hierarchy.
The upper-level entries always receive the bit, and it is the page entries
that decide: the kernel pages do not have it, and therefore remain
inaccessible from user mode.

### 2.6 The kernel prepares the coprocessor

The firmware leaves the coprocessor disabled, and a floating-point
instruction raises a coprocessor error. The compiler's memory copy routine
uses vector instructions, and the kernel enables the unit, enables the state
saved by the processor, and masks the unit's exceptions.

**Consequence:** every kernel needs this routine, and its absence shows up
as a coprocessor error inside a library routine, which misleads the
diagnosis.

## 3. User mode: what already exists and what is missing

**User mode is implemented and verified.** The user task's program runs at
the third privilege level, writes to its own data page, calls the kernel
through the `syscall` instruction, and receives the response back in the
same register.

The following exists and has been verified:

- the page tables with the user bit and the kernel pages without it;
- the user task, with its own program, its data page, and its stack;
- each task's kernel stack, where the interrupt and call handlers run;
- the task segment, with the 64-bit mode layout, pointing to the kernel
  stack of the running task;
- the system call through the `syscall` instruction, with the handler in
  Zig.

The delivery of the exception coming from user mode **has been fixed**: the
cause was the task segment layout, described in section 3.3.

The interrupt gate diagnosis remains registered, because it delimits the
problem, but **its conclusion was wrong**: the fault was not a privilege
check, and rather a stack fault, with vector 12. The record below is what
the investigation found at the time:

1. The user task **runs** at the third privilege level: the processor
   records `cpl=3`, with the code selector `0x1b` and the data selector
   `0x23`, and the program reaches the system call instruction, with the
   number register filled in.
2. The system call gate is **correct**, byte by byte. The descriptor
   measured in memory is `81 07 08 00 00 ee 29 00 00 00 00 00 00 00 00`:
   the offset in two parts, the `0x08` selector of the kernel code, the zero
   interrupt stack index, and the `0xee` type, present and of the third
   privilege level.
3. The segments are correct: the user code has the long mode bit and the
   third privilege level, and the data segment is writable and of the third
   privilege level.
4. The page tables are correct: the three user pages are present, writable,
   and with the user bit, and the upper levels of the hierarchy have it as
   well.
5. The system call **is delivered** by the emulator: the interrupt log
   shows the `0x80` vector with the software interrupt marker.
6. During the delivery, the emulator raises an **exception with error code
   zero**, before the handler receives control: the exception trace shows
   the same exception and, then, a double fault, because the delivery of
   the fault itself also fails.
7. The reading of the trace identified the exception as the **general
   protection fault**, with the zero error code, and the conclusion was
   that it was a privilege check.

**The correction of item 7 is what resolved the defect:** the exception is
the **stack fault**, vector 12, and it does not come from the gate: it
comes from the task segment, whose layout was wrong. The interrupt gate
delivered the call correctly, and what was failing was the stack the
processor used to deliver the exception coming from user mode.

### 3.1 Consequence: the system call instruction

The interrupt gate path is abandoned. The kernel starts to use the
`syscall` instruction, with the mechanism the architecture provides for it
in 64-bit mode, and the decision has three reasons:

1. **The gate path is the only one that fails.** The `syscall` instruction
   does not go through the interrupt table, and therefore does not depend on
   the check that fails.
2. **The handler's stack becomes the kernel's.** With the interrupt gate,
   the handler runs on the user stack, and the user could overwrite the
   handler's frame. With `syscall`, the processor delivers the call on the
   stack that the task segment points to, and the user stack is only
   restored on the way back.
3. **The interrupt gate is a legacy path.** The architecture's
   recommendation for system calls in 64-bit mode is the `syscall`
   instruction, with the model registers `IA32_STAR`, `IA32_LSTAR`, and
   `IA32_SFMASK`.

The user task **is not scheduled** until the system call works through the
new path, because a task that fails halts the machine. The alternative
would be to mask the fault in user mode, which would destroy precisely the
isolation that user mode must offer.

### 3.3 The cause of the defect: the task segment

The migration to the `syscall` instruction did **not** resolve the defect
by itself: the first execution of the new path reproduced the same failure,
and the exception trace pointed to the real defect.

The symptom, in the emulator's trace, is the vector **12** — the **stack
fault** exception, with zero error code — and not the general protection
fault that the previous diagnosis assumed. The stack fault is raised at the
delivery of an interrupt coming from the third privilege level, and it is
followed by a double fault, because the delivery of the fault itself also
fails.

The cause is in the **task segment**, and it is a layout defect:

- The 64-bit mode task segment **is not** the one of the protected mode.
  The 64-bit mode structure does not have the stack segment selector field,
  and the task segment fields start at other offsets: the ring 3 stack
  (`RSP0`) is at **offset 4**, and not at 8; the interrupt stack table
  (`IST`) starts at **offset 36**; the structure has **104 bytes**, and the
  segment limit is 103.
- The kernel used the protected mode layout: the ring 3 stack was at offset
  8 and the interrupt stack table at 40. The processor read, at offset 4,
  the reserved field and the low half of the stack pointer: the value read
  was not a stack address, and the interrupt frame was written to an
  invalid address.
- The kernel's structure was declared as an `extern struct`, and the
  compiler inserts **implicit alignment**: the first `u64` of an
  `extern struct` lands at offset 8, even after a `u32` at offset 0. The
  structure has to be `packed`, and the compiler adds eight bytes of
  padding at the end, so that the relevant size is an architecture
  constant, and not `@sizeOf`.

**The correction** was to rewrite the structure with the architecture's
offsets, with the compile-time verification of the offsets and of the size,
and with the segment limit in the last valid byte.

**Consequence:** the delivery of interrupts to the third privilege level
started to work, and the emulator's trace **records no exception** during
the whole execution: neither stack fault, nor double fault, nor page
fault.

### 3.4 The system call path

The call uses the `syscall` instruction, and the kernel has four decisions
of its own for this path:

1. **The instruction is the path from user mode to the kernel, and nothing
   more.** The processor loads the kernel segments and the kernel privilege
   level **before** the entry point runs, and therefore the entry point
   cannot distinguish the privilege level of the caller. The return is
   always an `iretq`, and the kernel calls its own handler with an ordinary
   call, and not with the instruction.
2. **Each task has two stacks.** The user stack is the one the task uses,
   and the kernel stack is the one that receives the interrupt frames and
   the call frames. The call handler **never** runs on the user stack, and
   the user cannot overwrite the handler's frame. The task segment points
   to the kernel stack of the task that is running.
3. **The `IA32_STAR` register has a single layout, and the kernel programs
   it for it.** The architecture defines the operation of the instruction
   like this: the kernel code selector comes from the low half field,
   `IA32_STAR[47:32]`, and the kernel stack selector comes from the value
   eight bytes above it, because the kernel stack is *"SS just above CS"*.
   The kernel's table has the data segment eight bytes after the code
   segment, and therefore the code selector serves for both: the low half
   field receives the kernel code selector, and the kernel stack the
   processor loads is the one of the code selector plus eight. The high
   half field belongs to the return instruction, which the kernel does not
   use, because the return of the call is an interrupt return.
4. **The flags mask has to clear the interrupt.** The entry point builds
   the call frame on the kernel stack, and an interrupt that arrived in the
   middle of that sequence would write its own frame on top of the call
   frame. The mask clears the interrupt, the trap, the direction, and the
   arithmetic flags.

   The mask **does not** take the interrupt away from the caller: the
   processor saves the flags in the `R11` register **before** applying the
   mask, and the return restores the value of `R11`. The measurement
   confirms: with the `0x7fd` mask, the handler read `0x202` in `R11`, with
   the interrupt enabled, and the user mode task came back preemptible, and
   the preemptive scheduler kept choosing it ✓.

### 3.5 Corrections that the investigation produced

- **The 64-bit mode exception vector table is different from the 32-bit
  one.** The page fault is vector 14, and not 13, and the stack segment
  exception is 13, and not 11. The kernel's table used the protected mode
  numbering, and the page fault diagnosis said "floating point error" ✗.
- **The copy of the user program has to happen after the swap of the page
  tables.** Before the swap, the write would use the firmware's tables,
  and the program would land on another physical page, which the task would
  execute as if it were the program ✗.
- **The instruction that halts the processor is privileged.** The user
  program was waiting with `hlt`, which raises a general protection fault
  at the third privilege level ✗. The `pause` instruction is rejected by
  the emulator for the same reason ✗, and the wait becomes a loop that
  only jumps to itself ✓.
- **The segment selector has the privilege level in the two lowest
  fields.** The function that builds the selector placed the table
  indicator in field 3 and the privilege level in field 4, and the user
  selector came out `0x38` and `0x30`: an index outside the table, and with
  the kernel's privilege level. The correction puts the table indicator in
  field 2 and the privilege level in fields 0 and 1, and the user selector
  becomes `0x1b` and `0x23` ✓. The defect was silent: the scheduler's
  hardcoded selectors were right, and only the system call record used the
  wrong values.
- **The interrupt return frame is built in the reverse order.** The
  processor pops the return address, the code selector, the flags, the
  stack pointer, and the stack selector, and therefore the value of the
  return address is the one that ends up in the lowest address of the
  frame. The system call frame was built in the opposite order, and the
  return loaded the wrong value for the return address ✗.
- **The call number cannot be destroyed before being saved.** The entry
  point used the first register to read the user stack pointer, and the
  call number, which is the user's first register, ceased to exist: the
  handler received the stack pointer in place of the number ✗. The
  measurement showed the number `0x404000`, which is the top of the user
  stack.

## 4. Costs and risks

| Risk | Impact | Mitigation |
|-------|---------|------------|
| User stack shared with the handler | Resolved | Each task has a kernel stack, and the call handler runs on it |
| The round-robin policy can generate starvation with blocked tasks | Medium | Blocking does not exist yet; when it exists, the policy will need priority classes |
| The interrupt gate does not deliver the user's system call | Resolved | The gate path is abandoned, and the call uses the `syscall` instruction |
| Task segment with the wrong layout | High | The layout is verified at compile time, and the segment limit is the last byte of the structure |

### 4.1 Migration plan for the system call instruction

1. Write the model registers `IA32_STAR`, `IA32_LSTAR`, and `IA32_SFMASK`,
   with the kernel code selector in `IA32_STAR`. **Done.**
2. Write the system call entry in assembly: the `syscall` instruction does
   not switch the stack, and the entry has to save the user stack pointer
   before jumping to the kernel stack, which the task segment points to.
   **Done.**
3. Record in the task's context the user state that the return needs: the
   return address, the flags and the stack pointer, and the registers that
   the calling convention preserves. **Done:** the return frame is built on
   the kernel stack, with the interrupt return frame.
4. Return to user mode with `iretq`, building the frame with the user
   state. **Done:** the order of the pushes is the inverse of the order in
   which the processor pops, and the interrupt return frame stays at the
   top of the stack.
5. Handle preemption inside the system call: the task suspended inside the
   handler has to return to the handler, and not to user mode. **Done by
   construction:** the call frame stays on the kernel stack of the task, and
   the context switch saves the interrupt frame on top of it, so that the
   resumption returns the task to the handler.

## 5. Consequences

- The complete context model is the basis for user mode, for the processes,
  and for the threads: they all share the same mechanics.
- The measurement of the cost of the context switch is the reference for
  the performance decisions of milestone F10.
- Each task has two stacks, and the kernel stack is the one the task
  segment points to. User mode stopped running the handler on the stack
  that the user controls.
- The task segment layout is verified at compile time, because an offset
  error produces a stack fault whose diagnosis is indirect, and the defect
  that this record describes consumed an entire increment.

## 6. The order of the initialization

The VNX message channel delivered nothing, and the defect was not in the
channel: it was in the **order** of the kernel initialization.

The initialization sequence enables the timer interrupts, and the scheduler
starts to choose the tasks at that instant. The user mode task runs in its
first turn, and it sends the first message in that turn. The channels'
initialization came **after** the timer, and it restarted the queues, and
therefore erased the message that the task had sent.

The measurement that closed the diagnosis shows the counters of the two
queues of the same channel, read in the same execution: at the instant of
the message, the kernel queue counted one message sent, and in the next
verification, an instant later, the two queues counted zero. The channel was
the same, and the only thing that passed between the two readings was the
initialization.

**The rule that the defect teaches:** everything the tasks can use has to
exist **before** the timer, because the timer is what starts to execute the
tasks. The initialization that comes after the timer is a late
initialization, and it runs with the tasks in execution.

**Consequence:** the initialization of the VNX channels comes before the
timer, and the delivery of the message started to work: the message that
the user mode task sends reaches the kernel, the kernel responds, and the
response comes back to the task.

## 7. The tolerance of the overlap in the copy

The copy call copies a block of memory between two ranges that user mode
chooses. The first implementation used the copy instruction, which
**requires** that the two ranges do not overlap, and the requirement raises
a panic in the kernel, and the kernel's panic halts the machine.

The defect is a denial of service: a user mode task brought the system
down with two arguments, and no isolation prevents this, because the source
range and the destination range are both valid.

The measurement confirms: with the copy without the tolerance, the user
mode program raises the `@memcpy arguments alias` panic and the kernel
halts ✓. With the tolerance, the same copy with the overlapping ranges
returns the number of bytes, and the user mode program continues ✓.

**The rule:** a call that works with ranges chosen by the caller has to
tolerate the overlap, or it has to reject the call with its own error.
Raising a panic in the kernel is not one of the two.

## 8. Note of the next increment

The increment of the processes, registered in
[`ADR-0006-address-spaces-and-processes.md`](ADR-0006-address-spaces-and-processes.md),
found **three deeper defects** in the task model that this document
describes, and that the diagnosis here had not reached:

1. the task's context held only the registers that the architecture
   preserves between calls, and the result of a system call was lost on
   every context switch;
2. the processor frame of the return was built on the stack of the
   interrupted code, and therefore, for a user mode task, on a page that
   the user owns;
3. the user mode window had a fixed address inside the kernel image, which
   is mapped by identity and grows.

The decisions and the measurements are in ADR-0006. This document remains
valid as the record of the diagnosis of the task segment defect, and its
rules — the initialization before the timer and the tolerance of the
overlap — remain in force.
