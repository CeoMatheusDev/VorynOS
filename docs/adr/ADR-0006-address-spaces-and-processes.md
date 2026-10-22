# ADR-0006 — Per-process address spaces and the processor frame

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-22 |
| **Scope** | The memory model of VorynOS and the context switch |

## 1. Context

ADR-0005 closed the user mode milestone with a defect in the design of the
task state segment, and the F3 milestone was left with two pending items:
**processes** and **the delivery of a message between two processes**.

While processes did not exist, the kernel had a single hierarchy of page
tables, and the user mode task lived in it. The audit of this increment
found three defects that came from that design, and that were the cause of
all the observed symptoms:

1. **The context switch did not save the registers that the architecture
   does not preserve across calls.** The context had only `rbx`, `rbp`,
   `r12` through `r15`, the stack pointer, the flags, the instruction
   address, and the segment selectors. The result of a system call lives in
   `rax`, and the arguments of the next call live in `rdi`, `rsi`, and `rdx`.
   A task that was interrupted in the middle of a call came back with
   another task's result, and the symptom appeared far from the cause: the
   user mode program wrote values that were not its own, the message
   receive loop exited with another task's `rax` register, and the kernel
   went into wait for a reply that never arrived.

2. **The processor frame of the return was built on top of the stack of the
   interrupted code.** For a kernel task, that stack is the stack of the
   code itself, and the frame sat right above it, at an address the code
   was about to use. For a user mode task, the code stack is a page the
   **user** owns, and the processor frame — which decides the privilege
   level of the return — sat in a page the user can rewrite. It was a
   privilege escalation inside the return mechanism itself.

3. **The user mode window had a fixed address, and the kernel image is
   mapped identity.** The window sat at `0x400000`, and the kernel image
   is loaded at `0x200000` and grows with the kernel. The page of the user
   program replaced the page of the kernel's own data segment. The defect
   only showed up when the image grew past two megabytes, and the failure
   was a **page fault** inside the kernel.

## 2. The decision

### 2.1 The context saves all registers

The context now has the fifteen general-purpose registers, the interrupt
vector, the stack pointer, the flags, the instruction address, and the two
segment selectors. The switch routine reads the frame of the interrupt stub
and writes the entire state, and builds the frame of the incoming process
with the same format as the stub frame.

The frame format is the same for a practical reason: a task interrupted
**inside** an interrupt handler has to return to the middle of the handler,
and the handler assumes the stub format.

### 2.2 Each task has two stacks

The code stack of the task and the kernel stack of the task are different
memories. The processor frame is built on the kernel stack of the incoming
task, and the code stack is restored by the frame itself.

The kernel stack lives in the kernel image, and the image is mapped in
**all** address spaces, including those of the processes. Therefore the
frame can be built and read in any space.

### 2.3 The return frame skips the kernel stack

The frame of the incoming process is built on the kernel stack of the
process, and the `iretq` of the return loads the code stack pointer from
the frame. The TSS `rsp0` points to the kernel stack of the current task,
and it is from there that the processor starts when the interrupt comes
from user mode.

### 2.4 Each process has its own address space

The space of a process is a **copy** of the kernel tables: the root, the
third level, and the second level are copied, and the user mode window
receives a private chain. The copy is what keeps the kernel image and the
video frame mapped inside the space of the process, and it is necessary
because the kernel runs in the space of the process that interrupted it.

The scheduler switches the space together with the task context. The switch
happens at the same point as the context switch, and the value is the
address of the root table of the incoming process.

The consequence is **isolation**: two processes that use the same virtual
address for their data do not see the same pages, and a copy between the
two is a real copy.

### 2.5 The user mode window has no fixed address

The window sits **below** the kernel image, and its address is delivered to
the task in the `rbx` register when the task starts. The window is
described in the shared module, because the user mode program is written in
assembly and both sides have to agree on the design byte by byte.

The window of the process lives in a single two-megabyte block, and the
private chain of the space uses a first-level table of its own.

### 2.6 The copy between processes goes through the kernel stack

The kernel does not copy the block from one process to the other with a
single move, because the two spaces do not name the same pages. The read
of the source happens with the space of the caller active, the block stays
in a buffer that lives in the kernel image, and the write to the destination
happens with the destination space active. The buffer is reachable in both
directions because the image is mapped in all spaces.

### 2.7 The channel takes the sides as arguments

The call that sends and the one that receives a message take the **side** of
the channel as an argument. A channel belongs to two tasks, and each side
of the channel is a task: the sender chooses the side of the receiver.

The previous rule — the sender writes to the kernel queue and the receiver
reads from the user queue — only works with a single pair of tasks, and it
prevented two processes from talking over the same channel without taking
the message away from each other.

## 3. What was discarded

### 3.1 The window with a fixed address

A fixed address is simpler for the user program, and it is what the first
version used. The kernel image is mapped identity and grows, and the fixed
window ended up inside the image. The alternative would be to reserve a
fixed region of the image for the window, and that couples the user mode
address to the size of the kernel.

### 3.2 The intermediate pages for the copy between processes

The first version of the design in another branch of the repository used
intermediate pages: the kernel mapped the physical page of the process into
a private window and read through it. The solution works, and it avoids
switching the address space in the middle of a call.

It was discarded because it requires a physical window that the process does
not own, a second hierarchy of tables for the intermediate pages, and a
synchronization between the window and the space of the process. Switching
the space inside a call is simpler, and the cost is one table switch per
copy, not per byte.

### 3.3 The frame built on top of the code stack

The first version built the frame of the incoming process on top of the
stack of the interrupted code, and the result worked. It worked by
accident: the address was free at the moment the frame was built, and the
processor checked nothing. A user who wrote to the frame address would
control the privilege level of the return.

## 4. The consequence for the call contract

The `syscall` instruction writes `rcx` with the return address and `r11`
with the flags of the caller. The fourth argument of a call **has to travel
in `r8`**.

The user mode program used `rcx` for the message value, and the kernel
received the return address in place of the value. The symptom was a
process that waited for a reply that never had the right value.

## 5. The consequence for diagnostics

The exception report began reporting the **address that caused the fault**
(the `CR2` register), and not only the processor frame. Without it, a
mapping defect shows up as an instruction address that makes no sense, and
the investigation depends on an external debugger.

The `CR2` is read at the moment of the exception, and the page that caused
the fault is mapped with the user bit, and therefore the address is the
real origin of the defect.

## 6. The verification

The automated boot test verifies, in this order:

- both processes exist, each one with its own address space;
- each process writes its marker at the **same** virtual address, and the
  markers are different, which proves isolation;
- the message leaves one process and reaches the other, and the reply comes
  back through the same channel;
- the copy between the two processes writes into the space of the
  destination, and the space of the caller **does not** change, which proves
  that the copy is a copy and not a page share;
- the copy with overlapping ranges moves the block in the right direction.

The boot test runs in `zig build qemu-test`, and the full suite
(`zig build check`) runs the unit tests and the boot test.

## 7. The status

| Item | Status |
|------|--------|
| Per-process address spaces | IMPLEMENTED — LOCALLY TESTED |
| Space switch with the task | IMPLEMENTED — LOCALLY TESTED |
| Isolation between two processes | IMPLEMENTED — LOCALLY TESTED |
| Copy between two processes | IMPLEMENTED — LOCALLY TESTED |
| Message delivery between two processes | IMPLEMENTED — LOCALLY TESTED |
| VNC capability transfer | PROPOSED |
| Call that blocks waiting for a message | PROPOSED |
| Measurement of the delivery latency with the processor clock | IMPLEMENTED — LOCALLY TESTED |
