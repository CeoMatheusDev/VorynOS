<div align="center">

# VorynOS

### Freedom • Performance • Control

**An independent operating system built from scratch for x86_64 and UEFI.**

[![Zig](https://img.shields.io/badge/Zig-0.17.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Architecture](https://img.shields.io/badge/architecture-x86__64-64748B)](#architecture)
[![Status](https://img.shields.io/badge/status-in%20development-EAB308)](#project-status)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-22C55E)](LICENSE)

[Overview](#overview) ·
[Project Status](#project-status) ·
[Build and Test](#build-and-test) ·
[Architecture](#architecture) ·
[Documentation](#documentation)

![VorynOS Logo](assets/branding/logos/Logos_VorynOS.png)

</div>

---

## Overview

**VorynOS** is an independent operating system project that includes its own
UEFI bootloader, kernel, component contracts, and development tools. The
bootloader and kernel are written primarily in Zig, with x86_64 Assembly where
direct access to the processor architecture is required.

VorynOS is **not** a Linux distribution, a Windows or BSD fork, or an interface
running on top of another kernel. The project uses external development tools
and established standards such as UEFI and ELF without incorporating them as a
hidden system foundation.

The project is under active development and is **not suitable for everyday
use**. Local QEMU results do not constitute validation on physical hardware.

## Project Status

The `main` branch contains the current development line. Milestone status and
evidence are maintained in the [technical roadmap](docs/roadmap/phase-status.md);
implementation alone does not mean a feature has been validated.

### Milestone Progress

| Milestone | Description | Current status |
|---|---|---|
| F0 | Foundation, toolchain, build system, and documentation | ✅ Completed |
| F1 | UEFI bootloader and kernel initialization | ✅ Completed |
| F2 | Processor structures, interrupts, and memory | 🟢 Locally tested |
| F3 | Threads, scheduler, processes, syscalls, and IPC | 🟡 In development — generic device capabilities, a dynamic heap, and expanded process support remain pending |
| F4 | Storage and file systems | 🟡 In development — RamFS/VFSX and VNV recovery on a RAM-backed device; native VirtIO Block read/write and two-boot persistence verified in QEMU/OVMF; filesystem integration with durable storage and automatic boot mounting remain pending |
| F5 | Runtime, SDK, and native applications | 🟡 In development — native ELF loading and the SDK are present; VLIB remains pending |
| F6 | Graphics subsystem and desktop environment | 🟡 In development — an experimental path is validated in QEMU; a graphics service and complete desktop are not implemented |
| F7 | Drivers, networking, audio, and physical hardware | 🟡 In development — native VVDI modern VirtIO PCI transport, split virtqueue, DMA and functional VirtIO Block driver validated in QEMU/OVMF; networking, audio, broader hardware support and physical-device validation remain pending |
| F8 | Compatibility with external formats and APIs | 🟡 In development — ELF/VEX foundations and an independent ABI are implemented; broad compatibility remains incomplete |
| F9 | Artificial intelligence infrastructure | ✅ Completed within the current scope — native CPU inference and local tests; no GPU acceleration |
| F10 | Installation, security, recovery, and production readiness | 🟡 Partial — hardening fixes and an audit have been performed; production installation, updates, and recovery remain pending |

### Recent verified progress

- **VVDI / VirtIO Block (PR #15):** native modern VirtIO PCI transport and
  split virtqueue integration, DMA-backed block reads and writes, optional
  FLUSH, bounded completion waits and error propagation.
- **Persistence test:** automated QEMU/OVMF two-boot verification with a
  disposable data disk; the second boot reads previously written data without
  rewriting it. The final audited PR head passed CI with **554 Zig tests**
  and **7/7 log-regression scenarios**.
- **Known limits:** this is emulated-device validation, not physical-hardware
  certification. A failed device reset can require retaining PCI BAR/DMA
  resources until reboot; online recovery and explicit PCI Bus Master
  revocation remain outstanding. No general-purpose on-disk filesystem or
  automatic boot mounting is claimed.

See [VirtIO Block PR D report](docs/reports/f7/virtio-blk-pr-d.md) and
[VVDI technical debt](docs/reports/f7/vvdi-debt.md) for evidence and limitations.

“Completed” refers to the documented scope of a milestone; it does not mean
VorynOS as a whole is ready for everyday use. QEMU validation is not equivalent
to physical hardware testing. See the [roadmap](docs/roadmap/phase-status.md)
and reports for each increment's criteria, evidence, and limitations.

## Build and Test

### Requirements

- Linux x86_64 as the reference development environment.
- Zig **0.17.0**.
- Bash and standard system utilities.
- For boot tests: `qemu-system-x86_64` and UEFI OVMF/edk2 firmware.

Clone the repository and verify the compiler version:

```bash
git clone https://github.com/CeoMatheusDev/VorynOS.git
cd VorynOS
zig version
```

The `zig version` command must report `0.17.0`.

### Build and Validate

```bash
# Run host unit tests
zig build test

# Compile the components and generate the bootable image
zig build

# Boot the image in QEMU and run automated checks
zig build qemu-test

# Run unit tests and the automated boot test
zig build check
```

The boot test uses QEMU and OVMF to verify the boot chain and behavioral
markers emitted by the kernel. `zig build check` also includes a VirtIO Block
integration test using a disposable data disk separate from the EFI boot image:
the first boot writes, flushes when supported, reads and compares data; the
second boot reuses the same disk and verifies persistence without rewriting.
These tests do not replace physical hardware testing.

To start the system manually in QEMU:

```bash
zig build qemu
```

In serial console mode, exit QEMU by pressing `Ctrl+A`, then `X`.
`zig build qemu-interactive-test` is a separate test for the experimental
graphics and input path; see the [roadmap](docs/roadmap/phase-status.md) for
its scope and validation status.

The generated image is located at `zig-out/bin/vorynos.img`. Run
`zig build --help` to see all available build steps.

## Architecture

The initial platform is **x86_64 with UEFI firmware**. The boot flow is:

```text
UEFI Firmware
    │
    ▼
VNB — UEFI boot application
    │ validates and loads the ELF64 kernel
    │ prepares the handoff contract
    ▼
ExitBootServices
    │
    ▼
VNK — independent kernel
```

The project organizes system mechanisms under the Voryn Fabric architecture.
The names below describe architectural components and goals; not all of them
have functional implementations:

| Acronym | Component | Responsibility |
|---|---|---|
| VNB | Voryn Native Boot | UEFI initialization and kernel loading |
| VNK | Voryn Nucleus Kernel | Privileged kernel mechanisms |
| VNH / VND | Hardware Nexus / Device Fabric | Hardware discovery and device infrastructure |
| VVDI | Voryn Virtual Device Interface | Native VirtIO device transport, queues and drivers |
| VNM | Voryn Nexus Memory | Memory management |
| VNT | Voryn Task Fabric | Tasks and scheduling |
| VNX / VNC | Voryn Exchange / Capability Fabric | Inter-process communication and capability-based access control |
| VSN | Voryn Service Node | Services and supervision |

For more details, see [ADR-0001 — Voryn Fabric](docs/adr/ADR-0001-voryn-fabric.md).

## Repository Layout

```text
boot/       UEFI bootloader
kernel/     Kernel, memory, execution, filesystem, graphics, and drivers
shared/     Shared contracts and data structures
sdk/        Interfaces for native applications
user/       Native applications and entry code
tools/      Build and image tools
tests/      Unit and integration tests
docs/       Specifications, decisions, roadmap, and reports
```

## Documentation

- [Roadmap and milestone status](docs/roadmap/phase-status.md)
- [Testing strategy](docs/testing/testing-strategy.md)
- [System call ABI specification](docs/specs/syscall-abi.md)
- [Boot handoff specification](docs/specs/boot-handoff-spec.md)
- [Architecture decision records](docs/adr/)
- [Versioning policy](docs/releases/VERSIONING-RESET-2026.md)
- [Engineering instructions for agents](AGENTS.md)

## Contributing and Security

Before proposing a change, review the conventions and technical criteria in
[AGENTS.md](AGENTS.md), the [testing strategy](docs/testing/testing-strategy.md),
and the specifications related to the component. Report vulnerabilities
responsibly according to [SECURITY.md](SECURITY.md).

## License

VorynOS original code is distributed under the
[GPL-3.0-only](LICENSE) license. Third-party notices and licenses must be
preserved.

---

*README last reviewed on October 28, 2026.*
