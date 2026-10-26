//************************************************************************//
//  ADR-0013.md                                                           //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

# ADR-0013 — ELF materialization, NX and the bootstrap native image

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-23 |
| **Scope** | Native applications, memory protection, the runtime and boot requirements |

## 1. Context

The F5.1 increment left the loader in two halves: a pure planner that
computes pages, permissions and the entry point, and a missing materializer.
No physical page was allocated from a plan, no page-table entry carried the
permissions of a segment, and the user-mode test program was still copied
into a page that was writable and executable.

The kernel also had to start a native program from the RamFS. The SDK and
the toolchain do not exist yet, so the program could not be produced by an
external compiler without adding a dependency that the project does not
have. The first native application therefore has to be built by the kernel
itself, while still being a real ELF64 file that goes through the parser,
the planner and the file system.

The hardware question is separate from the plan. A plan that refuses a
writable-and-executable segment is only a policy; the machine has to refuse
the access. The page table already has the no-execute bit, but it is
reserved until `EFER.NXE` is set, and the kernel had no code to set it.

## 2. Decision

### 2.1 NX is a boot requirement

The kernel enables `EFER.NXE` before it maps any user page. If the
processor does not report the feature, boot is fatal. There is no
fallback to W+X: a policy without hardware enforcement would be a
promise that nothing checks.

The detection uses `CPUID` leaf `0x80000001`, bit 20 of `EDX`, and the
enable uses model-specific register `0xC0000080`. The register is read
again after the write, so a processor that silently ignores the request
does not leave the kernel believing that NX is on.

### 2.2 W^X is enforced in hardware

The materializer maps:

- code pages writable and non-executable while the content is copied, then
  protects them as read-only and executable;
- data pages read-write and non-executable;
- stack pages read-write and non-executable.

No leaf entry is ever writable and executable at the same time. The
materializer changes the permissions with `protectUserPageIn`, which
preserves the physical address and invalidates the TLB entry.

### 2.3 The materializer owns the load path

`kernel/elf_materializer.zig` receives a `LoadPlan`, an image buffer and
the window. It validates the window, the image bounds and the stack before
allocating anything, then:

1. activates the address space of the process;
2. allocates, maps and zeroes one physical page per page span of every
   segment, with the temporary permissions of the copy;
3. copies the file content and leaves the BSS zeroed;
4. applies every relative relocation as `load_bias + addend`;
5. protects each code page as read-only and executable;
6. allocates, maps and zeroes the stack pages;
7. restores the CR3 of the kernel.

On any error, partial mappings are removed and the physical pages return to
the allocator before the CR3 is restored. The task has not been created at
that point, so there is no context to unwind.

The materializer does not re-validate the image: the plan is the contract,
and the materializer only checks that the process described by the plan fits
in the window that the caller gave it.

### 2.4 The native image is a bootstrap

The kernel builds an ET_DYN ELF64 image in memory and writes it to
`/apps/hello.elf` on the RamFS. The image has:

- a code segment at virtual address 0, read-execute, 64 bytes of code in
  one page;
- a data segment at virtual address `0x1000`, read-write, 56 bytes of file
  content in one page;
- a dynamic section with `DT_RELA` and `DT_RELASIZE`;
- one `R_X86_64_RELATIVE` relocation with addend zero, whose target is in
  the data segment.

The code writes `native ELF\n` through the write call, stores the marker
`0x464c456e79726f56` in the data page and ends with the exit call. The
relocation target starts at zero in the file and is filled by the
materializer with the load bias.

The image is a bootstrap, not a product of the SDK: the next increment
replaces the builder with a compiler without changing the loader. The
important property is that the file itself is real and goes through the
RamFS, the parser and the planner.

### 2.5 The fourth process

The kernel creates four processes: the three embedded test processes and
the native one. `paging.max_process_spaces` is 4, so the native process is
the last address space that this kernel can create. The boot ends with
seven tasks: four user tasks and three kernel tasks.

### 2.6 The boot verifies the hardware

After materialization, the kernel reads the page-table entries of the native
process through `paging.permissionsIn` and refuses to continue unless the
code page is R+X and the data and stack pages are R+W+NX. It then waits
for the native task and checks three independent facts:

- the marker in the data page equals `0x464c456e79726f56`, which proves
  that the user code executed;
- the word filled by the relative relocation equals the load bias, which
  proves that the materializer applied the relocation;
- the task state is terminated with exit code 0, which proves that the exit
  call reached the scheduler.

The boot test requires all three lines, the raw `native ELF` output and the
page-permission line.

## 3. Consequences

- The kernel now requires a CPU with NX. QEMU with the default CPU of the
  test environment provides it; a machine without it stops at
  `[VNK] FATAL: the processor does not support the no-execute bit`. There
  is no degraded mode.
- The embedded user processes also use W^X: their code page is protected
  read-only and executable after the copy, and their data and stack pages
  carry the no-execute bit.
- The materializer is not testable on the host, because it allocates
  physical pages and writes page tables. The pure parts (planner, parser,
  native image) are tested on the host, and the hardware path is verified
  by the QEMU boot.
- The fixed number of address spaces is now fully consumed by the
  demonstration. A real runtime will need a larger or dynamic limit.
- The bootstrap image is the only native application. It has no standard
  library, no dynamic linker beyond one relative relocation, and no
  package format.
- The `invlpg` instruction is provided by a small assembly function in
  `kernel/arch/x86_64/cpu.s`, because the inline assembler refused it in a
  debug build.

## 4. Alternatives considered

- **Fall back to W+X when NX is missing.** It would make the kernel boot
  on older processors, but it would silently remove the protection that
  the planner promises. The refusal is the correct default.
- **Emulate NX in software.** The x86-64 page table has the bit, and the
  processor walks it. Software emulation would cost a fault handler per
  access and would still not protect against a compromised kernel.
- **Load an ET_EXEC image at a fixed address.** It would avoid the
  relocation, but the planner already refuses a non-zero bias for ET_EXEC,
  and a fixed address would collide with the kernel image.
- **Produce the native image with an external toolchain.** It would be a
  real application, but it would add a toolchain dependency before the
  runtime exists. The bootstrap builder keeps the increment self-contained
  and is replaced later.
- **Keep the embedded program as the only user process.** It would leave
  the materializer unproven. The native task is what turns the loader from
  a validated plan into executed code.

## 5. References

- `kernel/arch/x86_64/cpu.zig` — detection and enablement of NX.
- `kernel/arch/x86_64/cpu.s` — `voryn_invlpg`.
- `kernel/arch/x86_64/paging.zig` — flags, mapping, protection, unmapping
  and permission reading.
- `kernel/elf_loader.zig` — the pure planner.
- `kernel/elf_materializer.zig` — the materializer.
- `kernel/native_image.zig` — the bootstrap ET_DYN image and its tests.
- `kernel/main.zig` — boot order, installation, verification and report.
- `tests/integration/boot-qemu.sh` — the native ELF assertions.
- `docs/adr/ADR-0011-elf64-load-plan.md` — the planner and W^X policy.

## Correction to §2.5 (2026-10-26)

The process-capacity statement in §2.5 is historical. The current source
sets `paging.max_process_spaces` to 8 (`kernel/arch/x86_64/paging.zig`), not
4. The limit remains fixed; this change does not implement dynamic address
space allocation.
