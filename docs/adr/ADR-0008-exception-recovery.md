//************************************************************************//
//  ADR-0008.md                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0008 — The exception of a process kills the process, and not the machine

| Field | Value |
|-------|-------|
| **State** | ACCEPTED |
| **Date** | 2026-10-22 |
| **Scope** | The handling of exceptions and the recovery of the processes |

## 1. Context

The kernel treated **every** exception in the same way: it printed the
diagnosis and stopped the machine. The user mode existed and worked, but a
process that wrote in an address that was not mapped brought the whole
system down.

That is wrong for three reasons:

1. **A defect of a process is not a defect of the kernel.** The process
   that writes outside its window has a defect, and the defect is its own.
   The machine has other processes, and bringing them down because of one
   is turning a local error into a general one.
2. **The system loses the evidence of the defect.** With the machine
   stopped, the diagnosis is what remains, and there is no way to compare
   the behavior of the process that failed with the one of the ones that
   continued.
3. **The limit of privilege becomes decorative.** The third privilege level
   isolates the **memory**, and not the **behavior**: a process can, with a
   single instruction, stop the system.

The pending item of the F3 milestone was exactly this: the **handling by
type** of the exceptions, with a test of recovery.

### 1.1 The defect that hid the problem

The frame that the processor leaves when an exception happens has **two
shapes**, and the difference is the presence of the error code.

The processor pushes, in this order: the error code (only on the
exceptions that have one), the `RIP`, the `CS`, the flags, the `RSP` and
the `SS`. The stub of the exception pushes, on top of that: a marker, the
vector number and the fifteen registers.

The result is that the frame of the exceptions that **have** an error code
is **eight bytes larger** than the one of the ones that do not have it. The
error code sits between the vector number and the `RIP`, and every offset
after it changes.

The handler and the context switch read the positions of the frame in **one
of the two shapes**, and the choice depended on the vector. A switch that
read the frame in the wrong shape reads the `SS` where the `RFLAGS` is, and
the processor returns to the code of the user with a stack segment that is
not a stack segment at all: the result is the exception 13, the stack
segment fault, with an `SS` equal to zero.

This defect **already existed** before the increment. It did not show
because no exception with an error code had happened in the path of
recovery: until then, every exception stopped the machine anyway.

### 1.2 The shape of the frame is a contract, and not a detail

The structural correction is not "read the frame in the right shape in each
call". The correction is **one single shape**.

The stub of an exception **with** an error code **normalizes** the frame:
it saves the error code in a known position and moves the five words of the
return of the processor **eight bytes down**. The stub of an exception
**without** an error code already produces the frame in that shape.

After the normalization, the handler, the context switch and the return of
the processor read **the same positions**, and the shape of the frame stops
being a concern of each call. It is the same rule that ADR-0007 established
for the frame of the system call: one frame, one switch.

## 2. The decision

### 2.1 The exception is classified by the code segment

The classification is done by the `CS` of the frame of the processor, which
is the most direct evidence of the privilege level in which the error
happened:

| Origin | `CS` | Handling |
|--------|------|------------|
| User mode | `0x1b` | The process is killed, and the kernel continues |
| Kernel mode | `0x08` | The machine stops |

The exception in the kernel is fatal **by principle**, and not for lack of
an alternative: the state of the kernel is unknown after an error, and
continuing from it is worse than stopping. A kernel that continues with the
corrupted state produces errors that have no relation to the cause.

### 2.2 The killed process does not go back to the code that failed

The killed process cannot go back to the instruction that raised the
exception: the instruction that raised the page fault raises the page fault
**again**, and the kernel enters a loop of exceptions.

The frame of the processor is **rewritten** on the way back:

- the `RIP` points to the **loop of the killed task**, in the kernel;
- the `CS` and the `SS` are the segments of the kernel;
- the `RSP` is the kernel stack of the task.

The flags are **not** touched. The loop waits for an interrupt with the
`hlt`, and the timer is what takes the task out of there. A loop with the
`cli` would stop the whole machine, because the killed task would be
waiting with the interrupts disabled.

The scheduler **does not** choose the task again, because the task was
marked as terminated. The next tick of the timer chooses the first ready
task, and the killed task stays in the loop, without running.

### 2.3 The killed task is counted

The scheduler counts the killed tasks, and the report of the kernel shows
the number. A number that is zero on every run is a number that says
nothing; the number is the evidence that the recovery happened.

## 3. What was discarded

### 3.1 Letting the process repeat the exception

Discarded. The instruction that failed fails again, and the console fills
with reports of exception until the kernel stops. The loop of exceptions is
a symptom, and not a recovery policy.

### 3.2 The recovery inside the process, with a signal

Discarded **for now**. The delivery of a signal to the process, with a
handler in the user space, is the model of POSIX and is the right model
for a system that will have libraries. It requires, before: a way for the
process to install the handler, a delivery frame in the user space, and the
preservation of the state of the task for the return. It is the next
increment, and not this one.

### 3.3 Killing the machine and rebooting

Discarded. The goal of the milestone is that a process can fail without
bringing the system down, and rebooting the machine is not that.

### 3.4 The exception with the handling in the switch

Discarded. The context switch is called in two moments: the preemption and
the blocking of a task. It does not know where it came from, and making the
switch aware of the origin of the frame mixes two responsibilities that
are separated on purpose.

## 4. The consequence for the scheduler

The scheduler gained one operation, `killCurrent`, which marks the current
task as terminated, counts the death and **does not** return the task to
the queue of the ready ones.

The rule that already existed in `prepareNext` — the task that leaves only
comes back to ready if it **was** running — is the one that makes the
operation safe: a blocked task and a terminated task do not come back to
the queue by accident. The increment **did not** need to change that rule,
and that is why the rule existed.

## 5. The consequence for the contract

The contract of the system call **does not change**: no new call, and no
call changes its number or its meaning.

The contract of the **call** does not change because the death of the
process is an event of the kernel, and not a result of a call. The process
that provoked the exception does not receive an error code: it receives
nothing, because it does not continue.

The only visible change is the **shape of the frame**, and it is internal to
the kernel: the stubs, the handler and the switch read the same shape. The
frame continues to be the same object — the context saved of the task, with
the fifteen registers, the vector and the words of the return of the
processor.

## 6. The verification

The automated boot test verifies, in addition to what was already verified:

- that a third process, which writes in an address that is not mapped,
  **provokes** the exception 14, with the error code 6, and that the report
  shows the `RIP` of the user and the `CS` of the user;
- that the process is **killed**, and that the console says that the kernel
  continues;
- that the number of killed tasks is **reported**;
- that the machine **continues**: the timer keeps counting, the conversation
  between the other two processes **completes** the round trip, and the
  machine reaches the `VORYN-KERNEL-READY` marker.

The test runs in `zig build qemu-test`, and the complete set runs in
`zig build check`.

## 7. The state

| Item | State |
|------|--------|
| Processor frame with one single shape | IMPLEMENTED — LOCALLY TESTED |
| Exception of the user mode kills the process | IMPLEMENTED — LOCALLY TESTED |
| Exception of the kernel is fatal | IMPLEMENTED — LOCALLY TESTED |
| The kernel continues after the death of the process | IMPLEMENTED — LOCALLY TESTED |
| The killed task does not go back to the code that failed | IMPLEMENTED — LOCALLY TESTED |
| Count of the killed tasks | IMPLEMENTED — LOCALLY TESTED |
| Signal in the process, with a handler in the user space | PROPOSED |
| Exception by type, with a different policy per vector | PROPOSED |
| Report of the state of the process at the moment of the death | PROPOSED |
