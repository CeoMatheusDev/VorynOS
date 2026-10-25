<div align="center">

# VorynOS

### Freedom • Performance • Your Control

**An independent operating system built from scratch to provide direct hardware control, efficiency, and technological freedom.**

[![Zig](https://img.shields.io/badge/Zig-0.17.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Release](https://img.shields.io/badge/release-v0.1.0--dev.3-2563EB)](https://github.com/CeoMatheusDev/VorynOS/releases/tag/v0.1.0-dev.2)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-22C55E)](LICENSE)
[![Architecture](https://img.shields.io/badge/architecture-x86__64-64748B)](#architecture)
[![Status](https://img.shields.io/badge/status-in%20development-EAB308)](#project-status)

[**Overview**](#overview) ·
[**Current Status**](#project-status) ·
[**Building**](#building) ·
[**Architecture**](#architecture) ·
[**Documentation**](#documentation) ·
[**Release Notes**](https://github.com/CeoMatheusDev/VorynOS/releases/tag/v0.1.0-dev.2)

![VorynOS Logo](assets/branding/logos/Logos_VorynOS.png)

</div>

---

## Engineering principle — Native implementation and measurable performance

VorynOS prioritizes **original, independently maintained implementations of the subsystems it needs**: boot chain, kernel, memory management, scheduler, IPC, filesystem, drivers, native SDK, graphics stack and desktop. Its performance goals are low latency, predictable execution, small memory footprint, efficient CPU use and minimal unnecessary overhead.

- Build essential OS subsystems natively rather than presenting Linux, BSD or third-party desktop software as VorynOS internals.
- Use external development tools and established hardware/file-format/ABI standards when necessary for compatibility and correctness; independently implementing a standard is compatible with architectural originality.
- Prefer straightforward data layouts, bounded allocation, explicit ownership, minimal copying, incremental rendering and isolation by default.
- Require repeatable baselines and benchmarks before claiming performance improvements; compare latency, throughput, CPU cycles, memory usage and binary size where applicable.
- Never trade away memory safety, access control, fault isolation or correctness for speculative optimization. Do not invent proprietary cryptographic primitives.
- Document dependency exceptions, performance hypotheses, measurements, regressions and acceptance criteria. If an optimization has no measurable benefit, revert or simplify it.

**Originality is a design constraint; performance is an evidence-based engineering outcome.**

## Strategic priority — Native graphical desktop (F6)

**The primary product-development focus is a fully native VorynOS graphical interface.** The goal is an independent, interactive desktop running on the VorynOS kernel, not a Linux/BSD-hosted shell or a graphical mockup. Work on F4/F5 and kernel isolation remains necessary where it unblocks safe graphics and native applications.

Development on `feat/native-sdk` should incrementally deliver:

1. **Reliable display and input:** validated framebuffer presentation, keyboard and pointer input, and a persistent event loop in QEMU.
2. **Interactive window management:** focus, movement, stacking, clipping, incremental redraw, and reproducible input-to-pixel tests.
3. **Protected graphics service:** explicit ownership of graphical resources, per-process surfaces, validated shared buffers, capability checks, and a stable user-mode ABI.
4. **Voryn Desktop:** native shell, window decorations, launcher, task switching, and an initial terminal/file browser built with the native SDK.
5. **Quality gates:** Zig 0.17.0 compilation, unit tests, QEMU interaction tests, framebuffer comparisons, fault isolation, and measured frame latency and memory use.

**Current status:** F6 is experimental on this branch. Existing raster, compositor, dirty-region and input modules are foundations, **not** proof of a finished desktop. Do not mark the graphical desktop complete until an interactive Ring 3 application can create and update a window through a permission-checked interface and automated QEMU tests verify the resulting input and pixels. Preserve the existing syscall ABI and document any compatible extension before implementation.

## Overview

**VorynOS** is an independent operating system project developed primarily in **Zig**, using **x86_64 Assembly** for operations requiring direct control over the processor architecture.

The project prioritizes:

- **Independence:** A kernel, bootloader, contracts, and fundamental mechanisms developed specifically for VorynOS.
- **Performance:** Explicit control over memory, execution, interrupts, and communication between components.
- **Efficiency:** Reduced unnecessary abstractions, external dependencies, and operational overhead.
- **Security:** An architecture designed around isolation and capability-based access control, with progressive implementation.
- **Modularity:** Components with clearly defined responsibilities and documented interfaces.
- **Transparency:** Open development, technical documentation, and a clear distinction between implemented and planned features.

VorynOS **is not a Linux distribution, a Windows fork, a BSD variant, or an interface built on top of another operating system**.

Its bootloader and kernel are original implementations.

The project is currently in its early development stages and **does not yet constitute a complete operating system suitable for everyday use**.

---

## Project Status

> **Published version:** `v0.1.0-dev.3` — RAMFS Foundation — [Release Notes](https://github.com/CeoMatheusDev/VorynOS/releases/tag/v0.1.0-dev.3)
>
> - **Initial architecture:** `x86_64`
> - **Primary language:** Zig 0.17.0
> - **Boot firmware:** UEFI
> - **License:** GPL-3.0-only
> - **Last documentation revision:** October 25, 2026

**Current F6 status (2026-10-25, working tree on `main`):** the experimental graphics stack now includes F6.22.2 monitor/ACK instrumentation, F6.23 kernel-side phase timing, F6.24 exposed-strip damage, F6.25 display metadata, F6.26 display presentation, F6.27 input events, F6.28 user-space composition and F6.30 blocking input wait (`input_wait`, syscall 23, ABI v13). The native SDK application calls syscall 19 (`display_info`, ABI 12) and receives a versioned geometry/pixel-layout structure without any framebuffer address; it calls syscall 20 (`present`) with a 16x16 buffer and the display capability (kind 2), then calls syscall 21 (`input_poll`) with the input capability (kind 3, right `read`) and syscall 23 (`input_wait`) to block until an event arrives or the timeout expires. The PS/2 IRQ fills two independent queues: the kernel diagnostic queue and the user input queue. The boot test sends `A` and `right`; the user queue receives the right arrow and the application presents the same 16x16 block at (16,0), while the kernel queue keeps its copy and still moves the diagnostic window. The kernel reads the first pixel back from the framebuffer as `0xff` for both 16x16 presentations. After that probe, the application composes a 32x24 grayscale frame in its own stack buffer with `user/composition.zig` and presents it as one validated rectangle at (0,0); the first pixel reads back as `0x606060`. The boot test captures a P6 screenshot through HMP while the application holds the frame, compares the 32x24 region with the FNV-1a checksum published by the application, then sends `Q` to release it. A third user process without the display and input capabilities calls `present` and `input_poll` with deliberately invalid arguments; both are refused with error 10 before the request or output range is read. The boot test also exercises the blocking input wait: the task is blocked waiting for the event, the right arrow is delivered to the blocked task, and a short timeout expires with error 13. `zig build test` reports all unit tests passing and `zig build qemu-interactive-test` still passes 6/6 movements. The full compositor, surface sharing, window manager, focus, cursor and per-process input queue remain proposed in [`ADR-0015`](docs/adr/ADR-0015-user-space-graphics-service.md). In QEMU/TCG with a 2048x2048 GOP framebuffer, 16 arrow events fell from 35.98 s to 2.38 s in Debug (0.4 to 6.7 events/s). With `-Doptimize=ReleaseFast`, kernel render is 3.79 ms per arrow and the end-to-end test reaches 9.9 events/s, limited by QEMU's 50 ms key-hold pacing rather than by the kernel. The F6.28 evidence is in [`docs/reports/f6/user-space-composition-and-presentation-refusal.md`](docs/reports/f6/user-space-composition-and-presentation-refusal.md); the F6.27 evidence is in [`docs/reports/f6/input-event-capability-and-user-input-probe.md`](docs/reports/f6/input-event-capability-and-user-input-probe.md); the F6.26 evidence is in [`docs/reports/f6/display-presentation-and-display-capability.md`](docs/reports/f6/display-presentation-and-display-capability.md); the performance evidence is in [`docs/reports/f6/input-latency-and-exposed-strip-damage.md`](docs/reports/f6/input-latency-and-exposed-strip-damage.md). The historical notes below may still say "pending" for increments that have since been validated.

The development tree (currently `main` in this checkout) is where the native ELF64 and toolchain execution paths and the experimental **F6 graphics stack** live: GOP framebuffer rendering, opaque window composition, damage tracking, PS/2 Set 1 keyboard decoding through IRQ1, arrow-key window movement, and an event pump during a bounded boot-test window. **F6.9 was verified on Fedora** using `zig build test && zig build && zig build qemu-test` at commit `4a6beb2`; the QEMU test reported four key events, zero drops, and one arrow-key graphics update. **F6.10 was verified on Fedora** at commit `9c144b3`: the full `zig build test && zig build && zig build qemu-test` sequence passed, including the pixel-equivalence regression for successive overlapping window movements. **F6.11 is now under development**: pressing the I key during the PS/2 boot input window selects an experimental persistent event loop after the readiness marker and syscall self-test; normal automated boots still run the fatal invalid-opcode self-test. This new mode has not yet been validated on Fedora. Persistent graphical interaction remains proposed; the freestanding SDK, native ELF execution, per-process descriptors, VFSX routing, VNV persistence and block-device commit/wipe/recover are implemented. These branch-specific features are not a production-ready desktop or a tagged release.

The reorganization of public milestones is documented in [VERSIONING-RESET-2026](docs/releases/VERSIONING-RESET-2026.md).

Development is organized into incremental milestones, each with technical acceptance criteria and documented evidence of functionality.

### Milestone Progress

| Milestone | Description | Status |
|:---:|---|:---:|
| F0 | Foundation, toolchain, build system, and documentation | ✅ Completed |
| F1 | UEFI bootloader and kernel initialization | ✅ Completed |
| F2 | Processor structures, interrupts, and memory | 🟢 Locally Tested |
| F3 | Threads, scheduler, processes, syscalls, and IPC | ✅ Completed |
| F4 | Storage and file systems | 🚧 RamFS, VFSX routing, per-process descriptors, unlink/rename (files and directories with cycle rejection), single indirect blocks, user-mode truncation and the host/kernel VNV codec are verified; block-device persistence and recovery (commit → wipe → recover) are verified over a RAM-backed device, with a physical driver pending |
| F5 | Runtime, SDK, and native applications | 🟢 Locally Tested |
| M0.5 | SMP / APIC / EEVDF / spinlocks / APs (`smp.zig`, `apic.zig`, `scheduler.zig`, `installSmp`) | ✅ Completed — `main` (`53dc842`) |
| F6 | Graphics subsystem and desktop environment | 🚧 Experimental — F6.30 `input_wait` (syscall 23, ABI v13) verified |
| F7 | Virtio drivers / PCI / block / net (`virtio.zig`, `virtio_blk.zig`, `virtio_net.zig`, `pci.zig`) | 🟢 Base completo (`f7adcf5` + loader P0 `7fc34e3`) — F7 base + PCI + blk + net verificado |
| F8 | Compatibility with external formats and APIs | ✅ F8 concluído — `vex.zig` funcional + `elf_compat.zig` + ABI v13 (`12ac3a2`) |
| F9 | Artificial intelligence infrastructure | 🟢 Iniciado — `kernel/ai/tensor.zig` (`matMul` + `relu`), `docs/reports/f9/f9-infra.md` (`798fbf3`) |
| F10 | Installation, security, recovery, and production readiness | 📋 Proposed |

**Important:** These milestone statuses describe the active `feat/native-sdk` development branch where indicated; they do not imply that the same functionality has been merged into `main` or released.

See the [technical roadmap](docs/roadmap/phase-status.md) and the [final cycle report](docs/reports/final-cycle.md) for milestone evidence.

---

## Implemented Features

### VNB — Voryn Native Boot

An independent UEFI bootloader implemented in Zig for the x86_64 architecture.

Implemented responsibilities:

- Initialization as a UEFI application.
- Communication with firmware services.
- Diagnostics through the UEFI console and serial port.
- Framebuffer discovery using GOP.
- Identification of pixel formats and framebuffer properties.
- Retrieval and normalization of the UEFI memory map.
- Loading the kernel image from the EFI volume.
- ELF64 structure validation.
- Loading kernel segments into memory.
- Applying the relocations required by the relocatable kernel image.
- Preparing the boot handoff contract.
- Terminating boot services through `ExitBootServices`.
- Retrying boot service termination when the memory map changes.
- Controlled transfer of execution to the kernel.

**Implementation:** `boot/uefi/`

### VNK — Voryn Nucleus Kernel

An independent kernel implemented in Zig and Assembly.

The kernel provides an initial functional infrastructure for processor management, memory management, and interrupt handling.

**Initialization and x86_64 Architecture**

- Custom entry point.
- Initial stack configuration.
- Validation of the contract received from the bootloader.
- Processor feature identification through CPUID.
- Global Descriptor Table (GDT) configuration.
- Task State Segment (TSS) configuration.
- Interrupt Descriptor Table (IDT) configuration.
- Exception handling with register diagnostics: an exception that comes
  from the user mode kills the process, and the kernel continues.
- Initial hardware interrupt configuration.
- Remapping of the 8259 interrupt controllers.
- Programming the 8254 timer at 100 Hz.
- Initialization of the coprocessor, which the firmware leaves disabled.

**Task Execution**

- Preemptive scheduler driven by timer interrupts.
- Task context containing the complete processor register frame: all fifteen general-purpose registers are preserved during each context switch.
- Round-robin scheduling policy designed to prevent task starvation.
- Kernel tasks with dedicated stacks, and a kernel stack separated from the code stack, ensuring that the processor return frame is never stored on a page writable by user-mode code.
- Task structure prepared for privilege level 3.
- User-page mappings in dedicated page tables.
- System calls through the `syscall` instruction, with a handler implemented in Zig.
- System call contract with eight calls, including validation of user memory ranges against the calling process's page tables before the kernel accesses user memory.
- Context-switch cost measurement using the processor's time counter.
- A user-mode exception that **kills the process** instead of the machine:
  the process is marked as terminated, the processor frame is rewritten to a
  kernel loop, and the scheduler selects another task.

**Processes**

- A dedicated address space for each process, with kernel page-table mappings copied into it and the user-mode window as the only region owned by the process.
- Address-space switching alongside task context switching.
- Process isolation: two processes can use the same virtual address without accessing the same physical pages.
- A dynamically selected user-mode window positioned outside the kernel image and assigned to the task during creation.
- Copying a memory block from one process to another, reading from the source address space and writing to the destination address space.
- VNX message channels supporting message delivery between two processes, with delivery latency measured using the processor clock.
- **Capability fabric of the VNC**: the kernel holds the table of the capabilities and every process holds a set of them. A process that does not hold the capability of a channel does not use it, and the owner of the channel delegates the capability to another process and takes it back. The calls carry the kind of the capability, so the owner of the address space of a process can delegate it as well.
- A **blocking** system call that waits for a message: the waiting task is not scheduled, the scheduler selects another task, and message arrival wakes the waiting task with the result stored in its saved context.
- **Native ELF64 process loaded from the RamFS**: the kernel reads `/apps/hello.elf`, plans its two `PT_LOAD` segments, materializes them in a dedicated address space, applies one `R_X86_64_RELATIVE` relocation, and starts a fourth user task with the entry point from the image.
- **Per-process descriptor tables**: each process has its own table of open files with independent offsets; closing or seeking in one process does not affect another.
- **Hardware W^X**: code pages are mapped read-only and executable, data and stack pages are writable and non-executable, and the boot refuses a CPU without the no-execute feature. The kernel reads the page-table permissions back before it starts the native task.

**Memory Management**

- Bitmap-based physical memory manager.
- Initial physical page tracking.
- Construction of dedicated page tables.
- Page-table switching through CR3.
- Kernel and framebuffer mappings covering the entire described kernel image rather than only its first two megabytes.
- Heap with block metadata.
- Memory block splitting and coalescing.
- Basic heap corruption detection.
- **No-execute support**: `EFER.NXE` is enabled at boot, and the kernel refuses to continue when the processor does not report the feature.
- **Explicit user-page permissions**: mapping, protection and unmapping with `R+X` for code and `R+W+NX` for data and stack.
- **ELF materialization**: allocation, mapping, content copy, zeroed BSS, relative relocations, stack pages and cleanup of a partial load.

**Diagnostics**

- Serial communication through the UART 16550.
- Boot event logging.
- Processor exception diagnostics.
- Validation of critical structures during boot.
- Framebuffer write testing.

**Implementation:** `kernel/`

### Boot Handoff Contract

VorynOS uses a custom contract to transfer information between the bootloader and the kernel.

This contract communicates:

- Framebuffer information.
- Memory map.
- Information required for kernel initialization.
- Contract identifiers and validation data.

The structure includes versioning and structural integrity checks.

**Implementation:** `shared/handoff.zig`

**Specification:** [Boot Handoff Specification](docs/specs/boot-handoff-spec.md)

### Disk Image Tool

The project includes a custom FAT16 image builder implemented in Zig.

This tool prepares the bootable volume used in system tests.

**Implementation:** `tools/fatimg.zig`

---

### Experimental graphics and PS/2 input (`feat/native-sdk`)

The development branch includes a custom framebuffer rasterizer, opaque window compositor, dirty-rectangle tracker, PS/2 keyboard Set 1 decoder and IRQ1 event queue. QEMU's HMP monitor injects the A key and right arrow during the integration test. F6.9 processes queued input during a bounded timer window instead of waiting until its end.

**Verified on Fedora at `4a6beb2`:** `zig build test`, `zig build`, and `zig build qemu-test` passed. The serial output reported `4 events, 2 pressed, 2 released, 6 bytes, 0 dropped` and `event pump 1 arrow presses over 237 ticks`. This is evidence of input handling and redraw execution, **not a framebuffer screenshot or end-to-end input latency benchmark**.

**F6.10 (verified on Fedora at `9c144b3`):** `kernel/graphics/damage.zig` now contains a pixel-by-pixel regression comparing dirty redraw with full composition after four window movements, including overlaps. **F6.11 (interactive integration test implemented, not yet validated on Fedora):** the experimental persistent loop can be selected by pressing the **I key** during the initial keyboard input window; it processes subsequent PS/2 events after `VORYN-KERNEL-READY` instead of running the fatal `ud2` test. Normal automated boots do not select this mode and retain their existing exception test. The independent `qemu-interactive-test` build step verifies the persistent-loop marker and injects a right-arrow key only after it appears. **F6.12 (pending Fedora validation):** the same integration test now captures QEMU HMP `screendump` P6 images before and after the arrow event and checks that the displayed RGB pixels actually change. A compositor fix applies the new window coordinates before dirty-region redraw. **F6.12 passed on Fedora** at commit `5353041`: the QEMU screenshots differed by 87,296 pixels. **F6.13 (validated on Fedora at `a8be274`)** extends the screenshot comparator to check every pixel against the expected background, back-window, and front-window layers before and after the logged movement, including old-area restoration and overlap. It is intentionally separate from the existing fatal-exception boot test. The GUI still has no focus manager or user-space graphics service.

Run on the development branch:

```bash
git switch feat/native-sdk
git pull --ff-only origin feat/native-sdk
zig build test && zig build && zig build qemu-test
zig build qemu-interactive-test  # separate QEMU run; injects I then RIGHT
```

---

## Current Limitations

VorynOS is currently in the infrastructure development stage.

The following limitations are known and documented:

| Subsystem | Limitation |
|---|---|
| Physical memory | Bitmap covering up to 4 GiB |
| Heap | Fixed 256 KiB region |
| Virtual memory | Kernel image and framebuffer mappings, with a dedicated window for each process; native code is R+X and data/stack are R+W+NX |
| Processes | Four processes: three embedded test processes and one native ELF; the address-space limit is a constant defined in the paging module |
| TSS | 64-bit mode structure with a layout verified at compile time |
| Exceptions | A user-mode exception kills the process; an exception in the kernel is fatal |
| Syscalls | 23 system calls (ABI v13), including display metadata, presentation, input poll, blocking input wait and filesystem truncation |
| IPC | Message delivery and waiting between two processes are verified; ordering, guaranteed delivery, and synchronization are not provided |
| Waiting | A wait has a timeout, in ticks of the timer; a task still waits on one channel and one endpoint, and a wait on several channels is not provided |
| Capabilities | The model covers the channels of the VNX; the process still accesses its entire address space |
| Storage | RamFS with VFSX mount namespace, per-process descriptors, unlink/rename, single indirect blocks; VNV block-image codec and commit/wipe/recovery over a RAM-backed block device; physical driver pending |
| Native applications | Freestanding SDK with syscall wrappers, display/input/compositor contracts; native ELF loader and materializer; bootstrap ELF built by the kernel; VLIB remains pending |
| No-execute | Requires a CPU with NX; the kernel refuses to boot without it |
| Drivers | No general-purpose driver infrastructure |
| Graphical interface | Not implemented |
| Physical hardware | No documented validation |

User-mode processes execute at privilege level 3, write to their own data pages, invoke the kernel through the `syscall` instruction, and receive results in the same register.

Each process has its own address space. Two processes using the same virtual address do not access the same physical pages.

The VNX message channel delivers messages between processes, and responses return through the same channel.

Interprocess memory copying performs an actual data copy: the calling process's address space remains unchanged.

Features verified (M0.5): SMP boot via SIPI, per-CPU data, APIC local timer, spinlocks, EEVDF scheduler, IPI reschedule.

Features that do not yet exist include:

- Threads.
- A physical block driver (NVMe/AHCI) and automatic boot mounting from VNV.
- VLIB (native runtime libraries), VPK package manager and on-device toolchain.
- Physical hardware validation.
- On-device toolchain and VPK package manager.

These features belong to upcoming development increments.

---

## Requirements

### Development Environment

| Component | Requirement |
|---|---|
| Reference operating system | Fedora Linux 44 |
| Architecture | x86_64 |
| Zig | 0.17.0 |
| QEMU | 10.x |
| Firmware | OVMF / edk2 |
| Shell | Bash |
| Utilities | Coreutils |

The project uses Zig's native build system.

The primary development environment is Linux, but the resulting kernel is independent of the operating system used to compile it.

### Verify the Toolchain

```bash
zig version
qemu-system-x86_64 --version
```

In the reference Fedora environment, OVMF files are located at:

```text
/usr/share/edk2/ovmf/OVMF_CODE.fd
/usr/share/edk2/ovmf/OVMF_VARS.fd
```

The execution scripts use QEMU and OVMF firmware to boot the system.

---

## Building

### 1. Obtain the Source Code

```bash
git clone https://github.com/CeoMatheusDev/VorynOS.git
cd VorynOS
```

To obtain the exact published milestone:

```bash
git checkout v0.1.0-dev.2
```

**About release artifacts:** The `v0.1.0-dev.2` release provides source distribution artifacts.

No binaries are distributed with this release because the project does not yet maintain a sufficiently reproducible build pipeline to designate a binary artifact as official.

The boot image is built locally by the project itself and is used by the automated boot test.

### 2. Build the Project

```bash
zig build
```

The build process produces:

- The UEFI bootloader.
- The ELF64 kernel.
- The image-building tool.
- The boot image.

### 3. Run the Tests

```bash
zig build test
```

Runs unit tests in the host environment.

```bash
zig build qemu-test
```

Runs the automated boot test using QEMU and OVMF.

```bash
zig build check
```

Runs unit tests and the automated boot test.

### 4. Boot the System

```bash
zig build qemu
```

Starts VorynOS interactively in QEMU.

The serial console is the primary diagnostic channel.

To exit QEMU in serial terminal mode, use:

```text
Ctrl+A, X
```

### Available Commands

| Command | Purpose |
|---|---|
| `zig build` | Compile components and generate the image |
| `zig build image` | Build the boot image |
| `zig build test` | Run unit tests |
| `zig build qemu` | Boot the system interactively |
| `zig build qemu-test` | Run the automated boot test |
| `zig build check` | Run integrated verification |

### Build Artifacts

After compilation, the main artifacts are:

```text
zig-out/
└── bin/
    ├── voryn-boot.efi
    ├── voryn-kernel
    ├── voryn-fsimg
    └── vorynos.img
```

| Artifact | Description |
|---|---|
| `voryn-boot.efi` | Voryn Native Boot UEFI application |
| `voryn-kernel` | Relocatable ELF64 kernel |
| `voryn-fsimg` | FAT16 image-building tool |
| `vorynos.img` | Bootable EFI volume image |

---

## Architecture

The project's architecture is organized around a model called **Voryn Fabric**.

This model defines components with specific responsibilities and explicit communication contracts.

The architecture is documented in:

[ADR-0001 — Voryn Fabric](docs/adr/ADR-0001-voryn-fabric.md)

### Components

| Acronym | Component | Responsibility |
|:---:|---|---|
| VNB | Voryn Native Boot | UEFI initialization and kernel loading |
| VNK | Voryn Nucleus Kernel | Privileged kernel mechanisms |
| VNH | Voryn Hardware Nexus | Hardware discovery and interfaces |
| VNM | Voryn Nexus Memory | Memory management |
| VNT | Voryn Task Fabric | Tasks, threads, and scheduling |
| VNX | Voryn Exchange | Interprocess communication |
| VNC | Voryn Capability Fabric | Capability-based access control |
| VND | Voryn Device Fabric | Driver infrastructure |
| VSN | Voryn Service Node | Services and supervision |

**The names above represent the planned architecture. Not all components have functional implementations.**

Currently, published implementations focus on VNB, VNK, initial memory-management routines, and shared contracts.

### Boot Flow

```text
                 ┌─────────────────────┐
                 │    UEFI Firmware    │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ VNB                 │
                 │ Voryn Native Boot   │
                 └──────────┬──────────┘
                            │
                     ELF64 Loading
                     Memory Map
                     GOP Framebuffer
                     Handoff Contract
                            │
                            ▼
                 ┌─────────────────────┐
                 │  ExitBootServices   │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ VNK                 │
                 │ Voryn Nucleus Kernel│
                 └──────────┬──────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
              ▼             ▼             ▼
          ┌───────┐    ┌─────────┐    ┌────────┐
          │GDT/TSS│    │   IDT   │    │ Memory │
          └───────┘    └─────────┘    └────────┘
              │             │             │
              └─────────────┼─────────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ Initial Kernel      │
                 │ Infrastructure      │
                 └─────────────────────┘
```

This flow represents the currently implemented infrastructure without assuming the existence of additional services or a graphical environment.

### Source Code Organization

```text
VorynOS/
├── .github/
│   └── workflows/
│       └── ci.yml
│
├── boot/
│   └── uefi/
│       ├── main.zig
│       └── vnb/
│
├── kernel/
│   ├── arch/
│   │   └── x86_64/
│   ├── memory/
│   └── main.zig
│
├── shared/
│   ├── arch/
│   ├── elf64.zig
│   ├── handoff.zig
│   ├── memmap.zig
│   └── root.zig
│
├── tools/
│   └── fatimg.zig
│
├── scripts/
│   └── qemu-run.sh
│
├── tests/
│   └── integration/
│       └── boot-qemu.sh
│
├── docs/
│   ├── adr/
│   ├── architecture/
│   ├── roadmap/
│   ├── specs/
│   ├── standards/
│   └── testing/
│
├── internal/            # Development documents (excluded from source packages)
├── CONTRIBUTING.md
├── SECURITY.md
├── LICENSE
├── build.zig
├── build.zig.zon
└── README.md
```

This organization separates architecture-dependent code, shared contracts, host tools, and integration tests.

---

## Testing and Validation

The project uses multiple levels of verification.

### Unit Tests

Unit tests run in the host environment to validate components that do not directly depend on privileged execution.

These include:

- Shared structures.
- Format validation.
- Boot contracts.
- Memory managers.

### Integration Tests

Boot execution is tested in an x86_64 virtual machine using OVMF firmware.

The automated test checks **51 progress markers** emitted by the bootloader and kernel, identifying failure conditions during initialization.

Kernel markers verify **actual data content**, not merely execution progress.

Each process's data-page marker is checked, and both processes write different values to the same virtual address, demonstrating isolation.

Overlapping memory copies are verified byte by byte.

After an interprocess memory copy, the calling process's address space is checked to confirm that the operation performed a copy rather than shared-page mapping.

The serial console is the verified diagnostic channel, and writes to it are atomic: a task disables interrupts while assembling its message.

Without this guarantee, the console would no longer provide reliable evidence because it could report interleaved output that no task actually produced.

### Continuous Integration

The repository includes a GitHub Actions workflow:

`.github/workflows/ci.yml`

The workflow performs:

1. Zig toolchain setup.
2. Installation of emulation dependencies.
3. Unit testing.
4. Artifact compilation.
5. Automated boot testing.
6. Inspection of generated binaries.

The existence of this workflow does not imply that all planned features are implemented or that the system has been validated on physical hardware.

### Evidence and Acceptance Criteria

The testing strategy is documented in:

[Testing Strategy](docs/testing/testing-strategy.md)

The status of each milestone is recorded in:

[Roadmap](docs/roadmap/phase-status.md)

---

## Next Steps

The current architectural objective is **F3 — Execution**, consisting of three major areas: user mode, processes, and interprocess communication.

All three have been implemented and verified. Interprocess communication supports message delivery and blocking reception.

The remaining objectives for this milestone are:

1. **Capabilities of the devices** — the capability fabric covers the channels of the VNX and the address space of a process; the devices are not part of it yet.
2. **Timed waiting** and waiting on multiple channels simultaneously.
3. **Dynamic heap management** through VNM, the **signal in the process**, with a handler in the user space, and the **policy by exception type**, which today is the same for every user-mode exception.
4. Measuring context-switch overhead under **representative workloads**, with more tasks and processes.

These implementations must respect the project's architectural contracts and established validation criteria.

**None of these objectives should be considered complete until the corresponding implementation and supporting evidence are available.**

---

## Documentation

VorynOS maintains technical documentation alongside its source code.

| Document | Description |
|---|---|
| [Architecture Overview](docs/architecture/overview.md) | Architectural organization and contracts |
| [ADR-0001](docs/adr/ADR-0001-voryn-fabric.md) | Voryn Fabric model |
| [ADR-0002](docs/adr/ADR-0002-boot-chain-and-uefi-abi.md) | Boot chain and UEFI ABI |
| [ADR-0003](docs/adr/ADR-0003-toolchain-and-build.md) | Toolchain and build system |
| [ADR-0004](docs/adr/ADR-0004-x86_64-abi-pitfalls.md) | x86_64 ABI details and pitfalls |
| [ADR-0005](docs/adr/ADR-0005-task-model-and-user-mode.md) | Task model and user mode |
| [ADR-0006](docs/adr/ADR-0006-address-spaces-and-processes.md) | Per-process address spaces and processor frames |
| [ADR-0007](docs/adr/ADR-0007-blocking-receive.md) | Blocking message reception syscall |
| [ADR-0008](docs/adr/ADR-0008-exception-recovery.md) | A process exception kills the process, and not the machine |
| [ADR-0009](docs/adr/ADR-0009-capability-model.md) | The capability fabric of the VNC |
| [ADR-0010](docs/adr/ADR-0010-wait-timeout.md) | The wait with a timeout |
| [Boot Handoff](docs/specs/boot-handoff-spec.md) | Boot handoff contract specification |
| [Syscall ABI](docs/specs/syscall-abi.md) | System call contract |
| [v0.1.0-dev.2 Release Notes](https://github.com/CeoMatheusDev/VorynOS/releases/tag/v0.1.0-dev.2) | Process fault recovery, kernel reliability fixes, and validation results |
| [Roadmap](docs/roadmap/phase-status.md) | Milestone status and planning |
| [Testing Strategy](docs/testing/testing-strategy.md) | Validation strategy |
| [VVS-0001](docs/standards/VVS-0001.md) | Versioning policy |
| [VN-NAMES-0001](docs/standards/VN-NAMES-0001.md) | Naming conventions |

Architectural decisions are documented through ADRs, including their rationale, alternatives, and consequences.

---

## Development

VorynOS follows an incremental engineering approach.

Changes should prioritize:

- Correctness and predictability.
- Explicit resource management.
- Memory efficiency.
- Low execution overhead.
- Documented interfaces and contracts.
- Reproducible testing.
- Consistent source code organization.
- Avoidance of unnecessary dependencies.

### Repository Policy

- Main branch: `main`.
- Descriptive commit messages in Brazilian Portuguese.
- Incremental and verifiable changes.
- Documentation updated alongside implementations.
- Changes published only with explicit authorization from the project maintainer.

---

## Contributing

Contributions are welcome.

Before proposing changes, please review:

- [CONTRIBUTING.md](CONTRIBUTING.md) — Contribution guidelines.
- [SECURITY.md](SECURITY.md) — Vulnerability reporting guidelines.

Contributions must respect the existing architecture, documented contracts, and established quality criteria.

---

## Security

VorynOS is still in its early development stages.

Advanced isolation mechanisms, capability-based access control, interprocess protection, and fault recovery remain under development or are planned for future milestones.

**Do not use this system in production environments or to process sensitive information.**

To report vulnerabilities, please refer to [SECURITY.md](SECURITY.md).

---

## License

VorynOS is distributed under the **GNU General Public License, version 3 only (GPL-3.0-only)**.

See the [LICENSE](LICENSE) file for the complete terms.

Contributions are subject to the conditions established in [CONTRIBUTING.md](CONTRIBUTING.md).

---

<div align="center">

### VorynOS

**Freedom • Performance • Your Control**

*Building an independent operating system, one component at a time.*

[Repository](https://github.com/CeoMatheusDev/VorynOS) ·
[Documentation](docs/) ·
[Contribute](CONTRIBUTING.md) ·
[License](LICENSE)

</div>

F6.14 (pending Fedora validation): `zig build qemu-interactive-test` now injects six successive arrow keys (right, down, left, up, left, right), checks each logged position against the expected movement, and compares QEMU framebuffer captures pixel by pixel after every step. The PPM comparator also verifies restoration and window overlap. This is an integration regression test, not a compositor performance benchmark.

F6.14 validated on Fedora/QEMU: six successive arrow movements passed exact framebuffer comparisons, including background restoration and overlap. F6.15 (pending Fedora validation) adds Zig unit regressions for keyboard movement clamping at all framebuffer edges, oversized windows, and incremental compositor clipping (partial/offscreen/re-entry), checked against full composition. Run `zig build test` and `zig build qemu-interactive-test` before marking F6.15 complete.

F6.15 validated on Fedora with Zig 0.17.0 (`zig build test`, `zig build`, `zig build qemu-test`, `zig build qemu-interactive-test`). F6.16 (pending Fedora validation): run `bash tests/integration/interactive-qemu.sh --image=./zig-out/bin/vorynos.img --timeout=180 --edges` after `zig build`. The optional edge route acknowledges every arrow movement and compares framebuffer screenshots at the right, bottom, left, and top fully visible window limits. Normal `zig build qemu-interactive-test` keeps the F6.14 six-movement regression.

F6.16 validated on Fedora/QEMU: 58 acknowledged movements reached all four visible framebuffer limits, with exact pixel comparisons at each edge. F6.17 (pending Fedora validation) adds `--stress` to `tests/integration/interactive-qemu.sh`: 48 sequential acknowledged arrow movements in three repeated right/down/left/up cycles, with full framebuffer geometry checks after each four-key segment. Run `bash tests/integration/interactive-qemu.sh --image=./zig-out/bin/vorynos.img --timeout=180 --stress` after `zig build`. `--stress` and `--edges` are mutually exclusive; the default six-step test remains unchanged.

F6.17 was validated on Fedora/QEMU: `--stress` completed 48/48 acknowledged movements and exited with code 0. F6.18 (awaiting Fedora validation) adds `--bounds` to `tests/integration/interactive-qemu.sh`. It visits all four framebuffer boundaries, sends three additional arrow presses at each boundary, validates every acknowledged coordinate, and compares P6 framebuffer screenshots to require pixel-identical images for clamped/no-op movements. Run `bash tests/integration/interactive-qemu.sh --image=./zig-out/bin/vorynos.img --timeout=300 --bounds` after `zig build`. `--bounds`, `--edges` and `--stress` are mutually exclusive.

### F6 graphics development checkpoint (2026-10-24)

The `main` branch now includes three independent, allocation-free graphics primitives:

- `kernel/graphics/window_manager.zig`: bounded window registry (32 slots), owner checks, generation-safe handles, z-order, focus, and hit testing.
- `kernel/graphics/event_queue.zig`: bounded per-process event mailboxes (32 clients, 64 events per mailbox), FIFO delivery, and explicit overflow errors.
- `kernel/graphics/session.zig`: host-testable pointer-click dispatch to the topmost visible window, plus keyboard event dispatch to the focused window and its owning process.

**Validation status:** on Fedora, the first two modules each passed three standalone Zig tests, and `zig build test` plus `zig build` completed successfully (user-provided terminal log). The initial `session.zig` module passed eight standalone tests on Fedora (user-provided terminal log). Two additional keyboard-focus tests have been added since then and **have not yet been compiled or tested**. These primitives are **not yet wired into the kernel syscall path or the live QEMU desktop**. The graphics router is single-threaded; callers must provide synchronization when used concurrently.

To validate this checkpoint after updating the local checkout:

```sh
zig test kernel/graphics/window_manager.zig
zig test kernel/graphics/event_queue.zig
zig test kernel/graphics/session.zig
zig build test
zig build
```

**F4:** VFSX changes were merged into `main` via PR #5; post-merge runtime/persistence testing remains open. **F5:** SDK ABI and external native-application workflow remain under review. **F6:** user-space graphics service and compositor integration remain open. **F7:** hardware driver expansion follows verified F4/F5/F6 dependencies.

### F6 compositor bridge checkpoint (2026-10-24)

- Added `kernel/graphics/window_renderer.zig`, a bounded adapter that snapshots the window manager's bottom-to-top z-order and renders via `compositor.compose` / `composeDirty`.
- Focused and unfocused windows use a trusted compositor-provided palette; hidden windows are skipped by the compositor. No heap allocation or user-pointer dereference is performed.
- Two new unit tests cover full rendering, z-order/focus highlighting, and dirty-rectangle clipping. **These tests have not yet been executed**.
- Latest user-provided Fedora validation: `zig test kernel/graphics/session.zig` passed **10 tests**; `zig build test` and `zig build` completed, producing a 64 MiB image. This does **not** validate the new renderer or end-to-end QEMU desktop.

Validation commands:

```sh
zig test kernel/graphics/window_renderer.zig
zig test kernel/graphics/session.zig
zig build test
zig build
```

**Next integration:** connect the renderer to the actual kernel graphics loop, surface ownership and input event delivery; run an end-to-end QEMU graphics test.

### F6 click-to-focus checkpoint (2026-10-24)

`kernel/graphics/session.zig` now activates and raises a clicked window **only after** its `pointer_down` event has been accepted by the owner's mailbox. Subsequent keyboard input targets the newly focused window. A full event queue leaves focus and stacking order unchanged. Two unit tests were added for click-to-focus/keyboard routing and rejection under mailbox pressure. **These new tests have not yet been run.**

Previous Fedora evidence: 10 tests passed in `zig test kernel/graphics/session.zig`, with `zig build test` and `zig build` succeeding. The `window_renderer.zig` tests and these new session tests remain pending; the live QEMU graphics path is not integrated.

```sh
zig test kernel/graphics/session.zig
zig test kernel/graphics/window_renderer.zig
zig build test
zig build
```

### F6 frame coordination checkpoint (2026-10-24)

- Added `kernel/graphics/frame.zig`, a bounded coordinator that owns a graphics session, tracks full-frame invalidation, and calls the existing window renderer only when needed.
- Successful focus-changing clicks invalidate the frame; rejected clicks (including full mailboxes) leave the frame clean. Window creation and destruction invalidate the frame. An explicit dirty-region path is also available.
- Two new host-side tests cover redraw behavior and failed-click handling. **Not yet compiled or run**. The Fedora logs previously confirmed 12 passing tests each for `session.zig` and `window_renderer.zig`, and successful image generation.
- This is a host-testable coordinator, **not yet wired into the live kernel input loop or framebuffer**.

```sh
zig test kernel/graphics/frame.zig
zig test kernel/graphics/session.zig
zig test kernel/graphics/window_renderer.zig
zig build test
zig build
```

### F6 window movement checkpoint (2026-10-24)

- `kernel/graphics/frame.zig` now exposes owner-checked `moveWindow` with stale-handle validation and redraw invalidation only when position changes.
- A new test verifies unauthorized movement rejection, no-op movement, old/new pixel repaint, and stale handle rejection after destruction.
- **New code not yet validated by Zig on Fedora.** The last supplied logs confirmed 23 tests passing for `frame.zig` before this change, plus 12 tests each for `session.zig` and `window_renderer.zig` (imported tests overlap).

```sh
zig test kernel/graphics/frame.zig
zig build test
zig build
```

The live PS/2 input loop, framebuffer mapping, and QEMU desktop integration remain pending.

### F6 — Captura e arrasto do ponteiro (2026-10-24)

O módulo `kernel/graphics/frame.zig` agora possui captura do ponteiro após clique aceito, movimentação relativa por `pointerMove` e liberação por `pointerUp`. A aritmética de coordenadas é saturada; a destruição de uma janela cancela a captura, evitando movimentar janelas que reutilizem o mesmo slot. Dois novos testes verificam o arrasto, o limite inferior das coordenadas e a liberação da captura.

**Validação pendente:** esta alteração ainda não foi compilada no Fedora. O último resultado confirmado foi de 24 testes aprovados para `frame.zig`, antes deste incremento. A integração com eventos físicos do mouse e a execução gráfica no QEMU ainda não foram realizadas.

```sh
zig test kernel/graphics/frame.zig
zig build test
zig build
```

### F6 — Validação confirmada no Fedora (2026-10-24)

Após atualização da branch `main` até `36f58ff`, os comandos executados pelo mantenedor apresentaram:

| Comando | Resultado |
| --- | --- |
| `zig test kernel/graphics/frame.zig` | 26 testes aprovados |
| `zig test kernel/graphics/session.zig` | 12 testes aprovados |
| `zig test kernel/graphics/window_renderer.zig` | 12 testes aprovados |
| `zig build test` | Concluído sem erros |
| `zig build` | Concluído sem erros; `zig-out/bin/vorynos.img` com 64 MiB |

Os conjuntos de testes compartilham testes importados e, portanto, as contagens não representam 50 casos distintos. A compilação da imagem **não** constitui validação de execução gráfica no QEMU. Permanecem pendentes a integração do fluxo de eventos físicos do mouse e a renderização na execução real do kernel.

### F7 — Ponte segura para framebuffer mapeado (2026-10-24)

O módulo `kernel/graphics/framebuffer_bridge.zig` valida uma fatia de memória já mapeada e autorizada, com largura, altura, pitch e formato de 32 bits, antes de chamar `Frame.present`. Não converte endereços físicos do firmware em ponteiros. Os testes adicionados cobrem apresentação de janela e rejeição de buffers inválidos sem consumir o estado de atualização pendente.

**Validação pendente:** este novo arquivo ainda não foi compilado com Zig 0.17.0 no Fedora. O último resultado confirmado foi de 28 testes em `pointer_input.zig`, 26 em `frame.zig` e 12 em `session.zig`. A ligação da ponte com o mapeamento real do kernel, a compatibilidade de formatos RGB/BGR e o teste visual no QEMU permanecem pendentes.

```sh
zig test kernel/graphics/framebuffer_bridge.zig
zig build test
zig build
```
