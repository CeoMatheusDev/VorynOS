//************************************************************************//
//  ADR-0010.md                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0010 — The wait with a timeout

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-22 |
| **Scope** | Interprocess communication, the scheduler and the timer |

## 1. Context

The call 8, `receive_blocking`, made the wait real: the task that waits is
not executed, and the message wakes it up. The wait has no bound, and the
unbounded wait is a defect of the service, and not of the client:

- a service that waits for a message of a client that died waits
  **forever**, and the dead client never sends the message;
- the service cannot do anything else, because the wait has no deadline
  and no way to be abandoned;
- the only way out of the wait with the existing calls is the error 9,
  which depends on the rest of the system and not on the service.

The F3 milestone listed the timeout as a pending item, and it is the
subject of this decision.

## 2. The decision

### 2.1 The timeout is a new call

The timeout is the call 11, `receive_timeout`, and it is **additive**: the
call 8 keeps its meaning, and the contract moves to the version 6. The rule
2 of the contract — a new call enters at the end of the list, and the
contract increments the version — is what allows the addition.

The call takes the same arguments as the call 8, plus the timeout in the
third register: the identifier of the channel, the side that holds the
message and the timeout, in ticks of the timer.

### 2.2 The deadline lives in the waiter, and the clock is the tick

The wait gains a **deadline**, in the ticks of the timer that the
scheduler already counts. The value zero means that the deadline does not
exist, and the wait is then the wait of the call 8: the call with a
timeout of zero is the blocking receive.

The counter of the ticks is the clock of the scheduler, and not a new
clock. The tick has three properties that the decision needs:

- it **exists**: the timer moves it at 100 Hz, and the scheduler already
  depends on it;
- it is **shared**: every wait counts in the same unit, and two waits of
  the same duration expire in the same window;
- it is **bounded**: a scan of the queues on every tick is a bounded cost,
  and the kernel does not need a structure of deadlines to find the waits
  that expired.

The deadline **saturates**: a timeout that would overflow the counter sets
the deadline to the maximum value, and the wait expires at the end of the
counter and not before. A wait that would wrap and expire at once would
break the meaning of the timeout.

### 2.3 The expiry runs in the timer, before the next task

The handler of the timer expires the waits whose deadline has passed
**before** it chooses the next task, and the wake of the expired task is
what makes it ready for the choice of the same tick. The order matters: an
expiry that ran after the choice would delay the woken task by a whole
tick.

The expiry delivers the result with the **same mechanism** of the
delivery of a message: the result is written straight into the context
saved of the task, through the two words of the waiter, and the task
continues after the call. A second mechanism would mean a second path of
wake, and the two paths would drift apart.

The expiry **removes the wait**, and it **does not** touch the queue: the
message that arrives later stays in the queue, for the next call of the
task. The timeout takes the waiter, and not the message.

### 2.4 The error of the timeout is its own error

The wait that expires answers with the error 13, `timeout`. The three
errors of the wait are distinct, and the user program tells them apart
without guessing:

| Error | Meaning | What the program knows |
|---|---|---|
| 5 | empty queue | the call did not wait |
| 9 | impossible wait | the wait was not possible, and it did not happen |
| 13 | timeout | the wait happened, and it expired without a message |

The check of the impossible wait comes **before** the deadline: with no
other task to run the wait would be a busy loop, and the timeout does not
turn a busy loop into a wait.

### 2.5 The scheduler does not know the contract

The scheduler counts the tick and expires the waits, and it receives the
result of the expired call as an **argument**. The code of the error 13
belongs to the contract of the calls, and the scheduler does not import
the numbers: an error that changed its code would not force a change in
the scheduler.

## 3. The alternatives that were discarded

| Alternative | Why it was discarded |
|---|---|
| Busy loop in the user mode, with `receive` and a check of the clock | It occupies the processor, and it defeats the blocking wait: the task that waits is executed, and it is the wait that ADR-0007 removed |
| Deadline in cycles of the time stamp counter | It is precise, and it needs a calibration between the counter and the tick. The tick is already the clock of the scheduler, and a second clock is a second thing to calibrate and to verify |
| A structure of deadlines sorted by time | It is the right answer for thousands of simultaneous waits. With four channels, two sides and eight waiters per side, the scan is bounded by sixty four entries, and the structure would add a path of insertion and removal that no measurement demands yet |
| An independent timer per wait | The programmable interval timer has one channel, and a second timer is a device of its own. The timer that exists is enough for the granularity of the tick |
| The timeout in milliseconds | The tick is the unit that the kernel has, and the conversion from milliseconds to ticks belongs to the service, which knows its own client. A unit that the kernel does not measure would be a promise that the kernel cannot keep |

## 4. The consequences

- The system call contract moves to the version 6, with the call 11 and
  the error 13. The existing calls do not change.
- Every waiter carries one word more, the deadline. The queues do not
  change their size beyond that word.
- The handler of the timer scans four channels, two sides and eight
  positions per side on every tick: sixty four entries at 100 Hz. The
  cost is bounded, and the scan walks the whole array of waiters of each
  side.
- The granularity of the timeout is **one tick**. A timeout of one tick
  can expire between the tick that starts the wait and the next one, and
  the contract documents the granularity instead of hiding it.
- The message that arrives after the expiry stays in the queue, and the
  next call of the task takes it. No message is lost, and the queue does
  not need a rollback.

## 5. The verification

The unit tests of the module of the channel verify the expiry without the
hardware:

1. a wait **without** a deadline never expires, whatever the clock says;
2. a wait expires **on** the deadline, and not before it;
3. the expiry takes only the waits that are due, and leaves the others;
4. a wait that was **delivered** does not expire, and the message is not
   overwritten by the result of the timeout.

The automated boot test verifies the call end to end: the process that
answers waits for a message of the channel 1 that nobody sends, the timer
expires the wait, the page of data of the process receives the negative
value of the error 13, the counter of the queue reports the expiry, and
the conversation of the two processes completes after the timeout. The
test runs in `zig build qemu-test`, and the full suite runs in
`zig build check`.

## 6. The status

| Item | Status |
|------|--------|
| Wait with a deadline, in ticks of the timer | IMPLEMENTED — LOCALLY TESTED |
| Expiry in the timer, before the choice of the task | IMPLEMENTED — LOCALLY TESTED |
| Error 13 of the timeout | IMPLEMENTED — LOCALLY TESTED |
| Unit tests of the expiry of the queue | IMPLEMENTED — LOCALLY TESTED |
| Wait on **several** channels | PROPOSED |
| Capability of a device | PROPOSED |
| Dynamic heap of the VNM | PROPOSED |
