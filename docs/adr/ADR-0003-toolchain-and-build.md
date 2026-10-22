# ADR-0003 — Languages, toolchain, and build system

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED |
| **Date** | 2026-10-21 |
| **Decided by** | VorynOS Engineering |

## 1. Context

The VorynOS is written from scratch. The language and build choices
determine the size of the kernel, auditability, portability, and the
maintenance cost.

## 2. Decision

### 2.1 Primary language: Zig 0.17.0

- Target version pinned to `0.17.0`, registered in `build.zig.zon`
  (`minimum_zig_version`). The version is not changed without authorization.
- Before using any API, it is checked against the installed standard
  library (`$(zig env | jq -r .std_dir)`). APIs from earlier versions are
  not reused from memory.
- The kernel and the bootloader are built without libc, `single_threaded`,
  for `x86_64-freestanding` and `x86_64-uefi` respectively.

**Rationale:** Zig allows the absence of libc, explicit control of memory
layout, predictable allocation, and a single compiler for kernel,
bootloader, tools, and tests. The language imposes no runtime, which is
essential for a minimal privileged component.

### 2.2 C23: restricted and justified use

C23 is accepted only when there is real technical justification:

- ABI interfaces that need to interoperate with third-party code;
- components that must be built by another toolchain;
- portability of an algorithm outside the kernel.

The same implementation is not maintained in both Zig and C. The current
kernel **contains no** C code; the decision is preventive, not descriptive.

### 2.3 Assembly: restricted and justified use

Assembly is used for direct control of hardware and privilege state.
In the current state there is exactly one file:
`kernel/arch/x86_64/entry.s`, which:

- receives control from the bootloader with the contract pointer in `RDI`;
- establishes the kernel's own stack before touching any memory;
- respects the 16-byte alignment required by the SysV ABI;
- keeps `RDI` (caller-saved) without needing to preserve it;
- declares the boot stack in `.bss`, inside the image itself, so that the
  kernel owns its stack from the very first instruction.

Every assembly file documents the ABI, stack alignment, preserved
registers, and side effects.

### 2.4 Build System

`build.zig` is the only build system. Steps:

| Step | Function |
|-------|--------|
| `zig build` | Builds the bootloader, kernel, and tools and generates the disk image |
| `zig build test` | Unit tests on the host |
| `zig build qemu-test` | Automated boot test on QEMU/OVMF |
| `zig build qemu` | Interactive boot on QEMU |
| `zig build check` | Unit + boot |
| `zig build image` | Disk image only |

The disk image is produced by `tools/voryn-fsimg`, a tool from the project
itself, which eliminates `mtools` and `dosfstools` from the build chain.

## 3. Runtime Dependencies

None. The VorynOS does not depend on a Linux, Windows, or BSD kernel
running natively. The only third-party dependency at build time is the
UEFI firmware, which is the system's entry point by definition.

## 4. Costs

- The Zig 0.17.0 compiler is still evolving and the standard library API
  changes between versions; the cost is absorbed by the API verification rule.
- No `libc` means reimplementing part of the standard library inside
  the kernel. It is an accepted cost: the kernel needs full control over
  allocation and layout, and the host standard library would bring
  unnecessary dependencies.

## 5. Consequences

- Every new module must be registered explicitly in `build.zig` and
  tested independently whenever possible.
- The unit suite runs on the host, over the same code as the kernel and
  the bootloader; that is what makes it possible to test the ELF64 logic,
  memory map, and handoff contract without an emulator.
