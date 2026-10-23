//************************************************************************//
//  ADR-0012.md                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0012 — The RamFS layout of the first increment

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-23 |
| **Scope** | Storage, the file system calls and the native application path |

## 1. Context

The F5 loader needs a file system from which to read an ELF64 image. The
project does not have a block driver, a disk format or a VFSX layer yet, and
waiting for all of them would block the runtime milestone. The file system
also has to be testable on the host, because the loader and the file system
share the same validation code.

The previous attempt stored files in a 1 MiB array but did not have a real
bitmap, did not write the block pointers into the inode, returned a slice of
a stack local from the read path and did not have a directory table. None of
that code was compiled by the build.

## 2. Decision

### 2.1 Fixed geometry

The RamFS of this increment is:

- 256 blocks of 4 KiB, 1 MiB total;
- block 0 reserved for the superblock, never handed to a file;
- 32 inodes, inode 0 is the root directory;
- 64 directory entries, each with parent, name (up to 64 bytes) and inode;
- 12 direct block pointers per inode, 48 KiB maximum file size.

The geometry is a compile-time constant, and `init()` resets every byte,
the bitmap, the inode table and the directory table. A test that runs after
another one starts from the same state.

### 2.2 The bitmap has one bit per block

Bit `n` of the bitmap represents block `n`, and a set bit means **used**.
`allocateBlock` returns the block number, and `freeBlock` receives the block
number. The block number and the byte offset are different units, and the
API keeps them separate: the previous code mixed the two and the allocator
freed the wrong bit.

### 2.3 The inode owns the blocks

`writeFile` allocates the new blocks before releasing the old ones, copies
the content into the blocks, and only then updates `i_block` and `i_size`.
A refused write leaves the previous content intact. `writeFileAt` extends
the file on demand and zeroes the gap because the new blocks start zeroed.
`truncate` releases the blocks beyond the new size and zeroes the tail of
the last surviving block.

### 2.4 The read takes the buffer of the caller

`readFile` and `readFileAt` receive a buffer and return the number of bytes
read. They never return a slice of a local buffer. A read at or beyond the
end of the file returns zero, which is the behavior a file descriptor
expects.

### 2.5 The directory is a table, not a file

The directory entries live in a fixed table, not in data blocks. The table
makes lookup and listing trivial and keeps the increment small. The cost is
the global limit of 64 entries and the absence of `.` and `..`; the resolver
refuses `..` instead of guessing a parent.

### 2.6 The descriptor table is global

The facade keeps 16 open files and an offset per descriptor. The table is
global because the syscall contract does not have a process-scoped file
table yet. The limitation is recorded in the roadmap and in the ABI
specification; it is not hidden.

## 3. Consequences

- The RamFS compiles for the host and for the kernel from the same source.
  `zig build test` runs 13 file-system tests (8 of the RamFS and 5 of the
  facade) and `zig build` compiles the same code into the kernel.
- The kernel exercises a create/write/read round trip during boot, and the
  boot test requires the two console lines that report it.
- A file above 48 KiB is refused with `FileTooLarge`, and the previous
  content is preserved.
- The file system disappears on power-off, and there is no recovery.
- A process can see the descriptors of another process, because the table is
  global. This is acceptable while the user program does not call the file
  system, and it must be fixed before native applications share the machine.
- The directory table can fill before the inodes or the blocks. The error is
  `DirectoryFull`, and the caller is expected to handle it.

## 4. Alternatives considered

- **Wait for the VFSX and a block driver.** Correct for the long term, but it
  would keep the loader without a source of files and would delay the F5
  verification.
- **Use the heap for file data.** The kernel heap is a fixed 256 KiB region,
  and a file system that competes with the kernel allocations would make the
  failure modes harder to reason about. A fixed region is simpler to verify.
- **Store file data contiguously and return a slice.** It avoids the block
  indirection, but it cannot reuse freed space and it makes the read path
  return a pointer into a global buffer that a later write can change under
  the caller.
- **Use indirect blocks in the first increment.** It raises the file limit
  and also the number of failure paths. The 12 direct blocks cover the test
  images and the first native applications; indirect blocks belong to the
  next storage increment.

## 5. References

- `kernel/fs/ramfs.zig` — blocks, inodes, directory table and tests.
- `kernel/fs/fs.zig` — descriptors, paths and tests.
- `kernel/arch/x86_64/syscall.zig` — calls 13 to 18.
- `docs/specs/syscall-abi.md` — version 9.
- `docs/roadmap/phase-status.md` — F4 and F5 state.
