//************************************************************************//
//  ADR-0014.md                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0014 — Per-process descriptor tables

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-23 |
| **Scope** | Storage, system calls and process isolation |

## 1. Context

The RamFS facade kept a single table of 16 open files. Two processes that
opened the same path shared the same descriptor and the same offset, and
closing a descriptor in one process affected the other. That model is
acceptable for the kernel-side proof of F5.1, but it is not acceptable for
applications: a descriptor is part of the state of a process, not of the
machine.

The previous ADR-0012 documented the global table as a limitation. The
runtime milestone needs independent offsets and independent close, and the
facade is host-testable, so the change can be verified without hardware.

## 2. Decision

### 2.1 One table per process

`kernel/fs/fs.zig` keeps an array of tables, one per process identifier.
The facade does not know how many processes the kernel creates: it accepts
any identifier below `max_processes` (8) and rejects the others with
`UnknownProcess`. The kernel maps the identifier of the address space to
the index of the table.

Each table has 16 descriptors, with the same fields as before: used flag,
inode, offset and flags.

### 2.2 Descriptor operations take the process

`create`, `open`, `close`, `read`, `write`, `seek` and `tell` receive the
process identifier as their first argument. Path-based operations
(`readFile`, `writeFile`, `sizeOf`, `kindOf`, `mkdir`) remain global,
because they do not touch a descriptor.

### 2.3 Syscalls resolve the caller

The handlers of calls 13 to 18 resolve the caller through `callerProcess`
and pass the identifier to the facade. A task without an address space is
refused with `not_authorized`, and a process outside the table range is
refused with `UnknownProcess`.

### 2.4 Kernel uses process zero

The boot installs the files through process 0, which is the first address
space. The RamFS itself does not change: inodes and blocks are still
global, and only the descriptors are separated.

## 3. Consequences

- Two processes can open the same file and read it independently.
- Closing a descriptor in one process does not close it in another.
- The facade gained one host test for independence and one for the
  unknown-process error.
- The limit is now 16 descriptors per process and 8 processes in the
  facade. The kernel still creates four address spaces.
- The error codes did not change. `UnknownProcess` is a facade error, not
  a new syscall error.

## 4. References

- `kernel/fs/fs.zig` — tables, operations and tests.
- `kernel/arch/x86_64/syscall.zig` — handlers of calls 13 to 18.
- `kernel/main.zig` — installation through process 0.
- `docs/adr/ADR-0012-ramfs-layout.md` — the RamFS layout.