//************************************************************************//
//  ADR-0007.md                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//**************************************************************************

# ADR-0007 — The call that blocks waiting for a message

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-22 |
| **Scope** | Interprocess communication and the scheduler |

## 1. Context

The delivery of a message between two processes existed since the previous
increment, and it worked. What did **not** exist was the **wait**: the
call that takes a message returned the empty queue error, and the user
program repeated the call until the message arrived.

The repetition works, and it has three costs:

1. **The woken task occupies the processor.** The repetition loop is a
   busy wait: the task calls, receives the error, calls again, and the
   scheduler picks it again on the next tick. The kernel has no useful
   work to do in the meantime, and the delivery delay is that of the timer
   tick, and not that of the work the other task had to do.
2. **The measured latency is not the delivery latency.** What the channel
   measured was the interval between the message leaving and the next
   check, and not the interval between the message leaving and the message
   arriving.
3. **The user program needs to know the wait protocol.** The repetition
   loop is a convention, and it is different for each form of wait.

The pending item of the F3 milestone was, therefore, the **real wait**: the
task that waits is **not** executed, and the scheduler picks another.

## 2. The decision

### 2.1 The blocking call is a new call

The call that takes a message **does not change meaning**. The new call,
number 8, is the one that blocks, and it receives the new contract
`syscall_abi = 3`.

The reason for not changing the meaning of the old call is a rule of the
contract itself: a program compiled against the previous version has to
keep working, and the meaning of a published call is its identity.

### 2.2 The waiting task is not executed

The waiting task is marked as blocked, and the scheduler does not pick it.
The task **does not** stay in a loop, and the processor executes another
task.

The scheduler gained a precaution: the task that leaves the processor is
marked as ready **only when it was running**. A blocked task that leaves
the processor stays blocked, and it is picked again only when the message
arrives. Without this precaution, the blocked task would be rescheduled on
the next tick, and the wait would be a busy loop with a longer path.

### 2.3 The delivery writes the result into the saved task context

The message that arrives at a waiting task **does not stay in the queue**.
The delivery writes the type and the value **directly into the saved task context**,
in the fields the call returned, and wakes the task up.

The task continues **after** the call, with the result in the same
registers as a call that had answered immediately. The user program does
not know that there was a wait: it called, and the result is where the
contract says it would be.

The channel does not know the scheduler. The wait is a pair of pointers to
the two words of the result, plus the address of the task and the routine
that wakes it up, and the scheduler is the one that delivers the routine.
The channel writes only to the two pointers.

### 2.4 The call frame has the format of the interrupt frame

The blocked task leaves the kernel through the **same path** through which
a preempted task leaves: the entry of the call hands control to the
scheduler, and the context switch builds the frame of the incoming process.

For the same switch to serve both cases, the system call frame has to have
**exactly** the format of the interrupt stub frame: the fifteen registers,
the vector, the error code word, and the processor return frame. The entry
of the call began to build the two words of the vector and of the error
code, and on the way back to user mode it skips the two words, as the stub
does.

**What this unification prevents:** the entry of the call and the interrupt
stub would read the frame with different offsets, and the frame saved from
a blocked task would be read in the wrong place — the return address
swapped with the flags, for example.

### 2.5 The delivery is direct, and the latency is the delivery latency

The single path of a message that leaves is what marks the moment of the
exit. The delivery marks the moment of the arrival, and the latency is the
difference between the two.

The result is a real measurement: the time between the message leaving and
the task that was waiting for it receiving it. The measurement is read in
the processor clock, and the reported value is about two hundred thousand
cycles, which is on the order of tens of microseconds.

### 2.6 A wait with no other task is an error

The blocking call returns error 9 when there is no other task to execute.
A wait that would be the only task in the system would be a busy loop, and
the kernel has to say so instead of waiting forever.

## 3. What was discarded

### 3.1 The wait by rotation

The waiting task could stay in the readiness queue, and the scheduler would
pick it again, and it would check the queue again. It is the simple
implementation, and it is the one the user program already did by hand.

It was discarded because the woken task occupies the processor, and because
the delivery latency remains that of the timer tick.

### 3.2 The blocking call with the same number as the non-blocking one

The call that takes a message could have gained an argument that said
whether it blocks, and the contract would not change its number.

It was discarded because the argument would have to have a default value
for the old programs, and the call would have two behaviors with the same
number. The contract of the project is explicit: the number is the identity
of the call.

### 3.3 The wait loop in the kernel

The wait could be done with an `hlt` loop inside the kernel, and the task
would be woken up by a tick. This is not a wait: the task keeps occupying
the kernel stack, and the kernel cannot do anything in the meantime.

## 4. The consequence for the scheduler

The scheduler gained three states with meaning: ready, blocked, and
terminated. The blocked task is not picked, and the routine that wakes it up
returns it to the ready state.

The context switch gained a new path, and the old path — the switch
through the timer — stays the same. Both paths end in the same switch, and
therefore the switch reads the same frame format.

## 5. The consequence for the contract

The system call contract moved to version 3, with call 8. Calls 1 through 7
**did not change** their number or their meaning.

Call 8 has two properties that the contract needs to declare:

1. the result of the call arrives **afterwards**, in the saved context of
   the task, and the task continues after the call;
2. the call can return error 9, and error 9 is the only one that says the
   wait was **not** possible.

## 6. The verification

The automated boot test verifies, in addition to what was already
verified:

- that the two user tasks **blocked** and were woken up by the message, and
  not by a repetition loop: the user mode program **no longer** has a
  repetition loop, and the reply from the other process arrived;
- that the delivery was **direct**, with the delivery counter at a task
  that was waiting;
- that the reported latency is the **delivery** latency, and not that of the
  timer tick;
- that the number of ready tasks and the number of blocked tasks are
  reported, with a pattern match check, because the numbers vary from one
  run to the next.

The test runs in `zig build qemu-test`, and the full suite runs in
`zig build check`.

## 7. The status

| Item | Status |
|------|--------|
| Real wait, without occupying the processor | IMPLEMENTED — LOCALLY TESTED |
| Direct delivery into the task context | IMPLEMENTED — LOCALLY TESTED |
| Call frame with the format of the interrupt frame | IMPLEMENTED — LOCALLY TESTED |
| Delivery latency measured | IMPLEMENTED — LOCALLY TESTED |
| Wait with timeout | PROPOSED |
| Multiple waits per task | PROPOSED |
| VNC capability transfer | PROPOSED |
