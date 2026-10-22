//************************************************************************//
//  ADR-0009.md                                                          //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0009 — The capability fabric of the VNC

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-22 |
| **Scope** | The permissions of the processes and the channels of the VNX |

## 1. Context

The processes of the user mode had **no permissions**. Every process that
reached a system call could use every channel of the VNX: the channel was
a global object of the kernel, and the identifier of the channel was
enough to put a message in it, or to take one of it.

The consequence is direct: the isolation between the processes came only
from the tables of address. A process that knew the identifier of a
channel could talk to the service that owns it, and nothing in the kernel
said that it had the right to do so.

The question that ADR-0001 left open — the model of capability — is the
answer to this. The model has to answer three questions:

1. **Who decides?** The process cannot decide what it may do, because the
   process is the one that would lie.
2. **What is a permission?** It cannot be a flag inside the process: the
   process could change it.
3. **How is it given and how is it taken back?** A permission that cannot
   be given away is a role, and a role does not scale.

The answer that the industry converged on is the **capability**: a
permission that the kernel holds and that the process cannot forge, because
the process only carries a **handle** — an opaque reference that means
nothing outside the kernel.

## 2. The decision

### 2.1 The kernel holds the table, the process holds the set

The model has two halves, and the separation between them is the whole
point:

- the **table**, in the kernel, with one entry per capability. The entry
  says what the capability is about (its **subject**) and what it allows
  (its **rights**);
- the **set** of each process, with the capabilities that the process
  holds and the rights that it holds over each one of them.

The handle of a capability is the index of the entry in the table. It is
never exposed to the user mode: the calls of the user mode name the
**subject** — the channel — and the kernel finds the capability that the
caller holds over it.

### 2.2 The rights belong to the holder, and not only to the table

The rights are held **per holder**, and not only in the entry of the
table. A process that receives a capability receives a **subset** of the
rights, and the subset is chosen by the one that gives it.

The consequence is the property that makes the model worth its cost: **a
capability that is delegated without the right of delegation cannot be
delegated again**. The possession of a permission is not, by itself, the
right to create more permissions. The chain of delegation stops at the
first process that receives a capability without the right to delegate it.

The four rights of the increment are:

| Right | Meaning |
|---|---|
| `send` | The right to put a message in the subject. |
| `receive` | The right to take a message of the subject. |
| `delegate` | The right to give the capability to another process. |
| `write` | The right to write in the address space of the process that the capability names. |

### 2.3 The call that uses a channel needs the capability

The calls that touch a channel — `send`, `receive` and `receive_blocking` —
check the capability of the process of the caller before they touch the
channel. A process that does not hold the capability of the channel does
not use it, and the call answers with the error 10, `not_authorized`.

The check is done **before** the queue is touched, and not after: a
process that is refused must not be able to leave a mark in the queue.

### 2.4 The call that writes in another space needs the capability

The `copy_to` call writes a block in the space of another process, and the
capability of the target process is what authorizes the write. A process
that does not hold the capability of the address space of the target does
not write in it, and the call answers with the error 10, `not_authorized`.

The check is done **before** the check of the ranges: a caller without the
capability must not learn anything about the addresses of the target, not
even whether they are mapped.

The subject of the capability of a process is the identifier of the
process, and the right that it carries is `write`. The right of delegation
follows the same rule of the other subjects: the holder that receives the
write without the right of delegation cannot lend the space to a third
process.

### 2.5 The root authority is the kernel

The kernel creates the capabilities and gives the first one to the process
that owns the subject. The `give` of the root is not the same operation as
the delegation of a process: the root has no caller to check, because the
root is the kernel.

In the boot of the kernel, the capability of the channel 0 belongs to the
process of role zero, which is the process that starts the conversation,
and the process that answers holds the **use** of the channel and not the
right of delegation.

The capability of the address space of the process that answers belongs to
the process of role zero as well: it starts the other processes, and it is
the only one that may write in their spaces. The process of role two holds
no capability of an address space, and the copy that it tries is refused.

### 2.6 The delegation and the revocation are calls of the user mode

Two calls carry the model to the processes:

| Call | Number | Arguments |
|---|---|---|
| `grant` | 9 | the target process, the subject of the capability, the rights |
| `revoke` | 10 | the target process, the subject of the capability |

The `grant` moves a capability to another process, and the rights that the
target receives have to be a subset of the rights that the caller holds.
The `revoke` takes the capability back, and only the holder of the right
of delegation can do it: the owner of the capability takes it back from the
process it gave it to.

The contract of the calls moves from the version 3 to the version 4. The
calls 1 to 8 **do not change** their number nor their meaning.

## 3. What was discarded

### 3.1 The role inside the process

Discarded. The role is inside the process, and the process can change it.
A permission that the subject can rewrite is not a permission.

### 3.2 The flag inside the process

Discarded, for the same reason. The kernel would have to trust a value
that the user mode owns.

### 3.3 The check of the owner in the table of the channel

Discarded. The owner of the channel would be checked in every call, and
the delegation would need a second structure to say who may use the
channel. The capability **is** that structure.

### 3.4 The capability of everything, at once

Discarded for now. A capability that carries the right of every operation
of the process would be the same as no capability at all. The increment
applies the model to the channels and to the address space of a process,
which are the resources that the processes actually share, and the model
is the same for the other subjects.

## 4. The consequence for the contract

The contract of the system call moves to the version 4, with the calls 9
and 10, and with the error 10, `not_authorized`.

The calls 1 to 8 keep their number and their meaning, and **their
behavior changes in two points**: the calls that touch a channel now need
the capability of the channel, and the call that copies a block into
another space now needs the capability of the address space of the target.
A program that was compiled against the version 3 and that used a channel
that nobody gave it, or that wrote in the space of a process without the
capability of that space, **stops working**; the program that used the
resources that the kernel gave it keeps working.

This is a break of the contract, and it is deliberate: the version 3 let
every process use every channel, and that was the defect. The rule of the
VVS-0001 says that a break of the layout of a contract needs a `MAJOR` of
the system or a bigger version of the contract, and the version 4 of the
contract is exactly that.

## 5. The consequence for the kernel

The kernel holds one more table, and the table is small: sixteen
capabilities and eight capabilities per process. The cost of a check is a
loop over the set of the process, and the set has at most eight entries.

The new module is `kernel/security/capability.zig`, which is the place
that the VN-NAMES-0001 reserves for the VNC. The module does not depend
on the architecture, and its unit tests run on the host.

## 6. The verification

The automated boot test verifies, in addition to what was already verified:

- that a process that holds **no** capability is **refused** when it uses
  a channel, and that the refusal is the error 10;
- that the **delegation** of the owner reaches the process that the owner
  chose, and that the process holds the capability of the channel after
  it;
- that the **revocation** of the owner takes the capability back, and that
  the process that answered does not hold it any more;
- that the conversation between the two processes **completes** the round
  trip, with the capability that the kernel gave to both of them;
- that a process **without** the capability of an address space is refused
  when it copies a block into that space, and that the refusal is the
  error 10.

The unit tests of the module verify the properties of the model itself:
the capability that nobody holds authorizes nothing, the rights of the
holder are a subset of the rights of the capability, the delegation that
does not carry the right of delegation stops the chain, the revocation
takes the capability back, and the table and the set do not grow without a
limit.

## 7. The state

| Item | State |
|------|--------|
| The table of the capabilities in the kernel | IMPLEMENTED — LOCALLY TESTED |
| The set of capabilities of each process | IMPLEMENTED — LOCALLY TESTED |
| The rights per holder, and not only in the table | IMPLEMENTED — LOCALLY TESTED |
| The chain of delegation that stops | IMPLEMENTED — LOCALLY TESTED |
| The check of the capability in the calls of the channel | IMPLEMENTED — LOCALLY TESTED |
| The call `grant` | IMPLEMENTED — LOCALLY TESTED |
| The call `revoke` | IMPLEMENTED — LOCALLY TESTED |
| The capability of the address space of a process | IMPLEMENTED — LOCALLY TESTED |
| The capability that carries a memory range | PROPOSED |
| The capability of a device | PROPOSED |
