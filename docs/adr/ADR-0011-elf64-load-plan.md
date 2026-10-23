//************************************************************************//
//  ADR-0011.md                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0011 — The ELF64 load plan and W^X

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-23 |
| **Scope** | Native applications, memory protection and the runtime |

## 1. Context

The F5 milestone needs to execute a native program read from the RamFS. The
kernel already has an ELF64 reader in `shared/elf64.zig`, but the reader only
answers whether the image is well formed. It does not decide which pages the
process needs, with which permissions, or whether the image can be placed in
the window that the process owns.

The materialization of an image touches the physical page allocator, the page
tables and the scheduler. Those modules cannot run on the host, and a loader
that mixes validation with hardware access cannot be tested with hostile
inputs: a malformed image would have to reach the hardware before it is
refused.

The kernel also runs the user mode without W^X today: the embedded user
program is copied into a page that is writable and executable. A native
loader that repeated that layout would make every native application a
write-and-execute region.

## 2. Decision

### 2.1 The loader has two layers

The loader is split into:

1. **the load plan** (`kernel/elf_loader.zig`), a pure function that takes
   the bytes of an image and returns a `LoadPlan` with the virtual address,
   the file range, the memory range, the flags and the page span of every
   segment, plus the entry point and the relative relocations;
2. **the materialization**, a hardware-dependent layer that allocates pages,
   maps them in the address space of the process, copies the file content,
   zeroes the BSS and creates the task.

Both layers exist in this increment. The second is `kernel/elf_materializer.zig`:
it consumes a `LoadPlan`, checks the window, the stack and the image bounds,
and then allocates, maps, copies, applies relocations and creates the stack.
It never re-validates the image.

### 2.2 The plan has fixed storage

`LoadPlan` holds up to 16 segments and 64 relocations in arrays inside the
structure. The planner does not allocate, does not fail halfway through an
allocation and can live on the stack of the caller. An image with more
segments or more relocations is refused with an error, and not truncated.

### 2.3 The validation rules are part of the contract

The plan refuses an image when:

- it has no useful loadable segment;
- a segment is not congruent with its file offset modulo the alignment
  (`p_vaddr ≡ p_offset (mod p_align)`);
- a segment or the entry point falls outside the requested window;
- two segments share a page;
- a segment requests write and execute at the same time;
- the entry point is not inside an executable segment that comes from the
  file;
- a relative relocation points outside a writable segment;
- a non-relocatable `ET_EXEC` image receives a non-zero load bias.

The overlap rule is by **page**, and not by byte range: the page table has
one permission per page, and two segments with different permissions on the
same page would be resolved by one of them in silence.

### 2.4 W^X is enforced at plan time

A segment with both `PF_W` and `PF_X` is refused. The decision is made before
any page is allocated, so a policy violation never leaves a partially mapped
process behind. The materialization maps executable segments read-execute
and writable segments read-write; it does not add the write bit to a code
page. With `EFER.NXE` enabled, the leaf entries carry the no-execute bit
for data and stack pages, and the kernel reads the resulting permissions
back before it starts the task.

### 2.5 The window belongs to the process

The planner receives the base and the size of the window that the process
owns. The window is page aligned, and the plan never places a segment outside
it. This keeps the loader from colliding with the image of the kernel, which
is mapped by identity in every address space.

## 3. Consequences

- The plan is testable on the host with synthetic and hostile images. The
  F5.1 increment added nine planner tests, including a round trip through
  the RamFS, and F5.2 added the native image and its round trip.
- The kernel compiles the planner, the materializer and the file system into
  the image, so a type error or a missing import fails `zig build` even
  before the boot. The host suite has 89 tests, and the QEMU boot is the
  verification of the hardware path.
- The materializer checks the physical allocation and the page-table failure
  paths, undoes partial mappings and frees the pages. The plan proves the
  image, and the boot proves the machine.
- The fixed storage is a limit: 16 segments and 64 relocations. An image
  above the limit is refused, which is the safe behavior.
- An `ET_EXEC` image cannot be placed at an arbitrary address. A future
  position-independent application has to be built as `ET_DYN`.
- The native application of this increment is a bootstrap built by the
  kernel, not by an SDK. The materializer does not depend on that detail,
  and the builder can be replaced without changing the loader.

## 4. Alternatives considered

- **Load directly in `shared/elf64.zig`.** The reader is used by the
  bootloader, which has its own memory map and no process. Adding process
  policy there would couple the bootloader to the kernel's address spaces.
- **Validate and map in one function.** Simpler to write, but impossible to
  test without hardware, and a validation failure after a partial mapping
  would leak pages.
- **Allow W+X for the first native application.** It would make the first
  demonstration shorter and would establish the wrong default for every
  later application. The refusal is cheap, and the correct layout is known.
- **Allow overlapping segments.** It would accept some real-world images
  that share a page between code and data. Those images need a page split
  and a copy, which belongs to the materialization, not to the planner.

## 5. References

- `kernel/elf_loader.zig` — the planner and its tests.
- `kernel/elf_materializer.zig` — the materializer and its cleanup path.
- `kernel/native_image.zig` — the bootstrap ET_DYN image.
- `shared/elf64.zig` — the parser, with its own bounds checks.
- `docs/specs/syscall-abi.md` — version 9, the file system calls.
- `docs/roadmap/phase-status.md` — F5 state and pending work.
- `docs/adr/ADR-0013-elf-materialization-and-nx.md` — NX, W^X and the bootstrap native image.
