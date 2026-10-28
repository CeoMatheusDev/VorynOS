<div align="center">

# VorynOS

### Freedom • Performance • Control

**An independent x86_64 operating system, built from the bootloader up.**

[![Zig](https://img.shields.io/badge/Zig-0.17.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![Architecture](https://img.shields.io/badge/architecture-x86__64-64748B)](#architecture)
[![Status](https://img.shields.io/badge/status-in%20development-EAB308)](#project-status)
[![License](https://img.shields.io/badge/license-GPL--3.0--only-22C55E)](LICENSE)

[Overview](#overview) ·
[Progress](#project-status) ·
[Quick Start](#build-and-test) ·
[Architecture](#architecture) ·
[Repository](#repository-layout) ·
[Docs](#documentation)

![VorynOS Logo](assets/branding/logos/Logos_VorynOS.png)

</div>

---

## Overview

**VorynOS** is an independent operating system for **x86_64 / UEFI**, built
primarily in **Zig 0.17.0** with x86_64 Assembly where needed. It has its own
bootloader, kernel, memory and process management, system calls, storage
interfaces, and native application path.

It is **not** a Linux distribution or a fork of Windows or BSD. VorynOS
implements its own system components while using public specifications such
as UEFI, ELF and VirtIO.

> **Development preview:** VorynOS boots and runs automated tests in QEMU/OVMF,
> but is not ready for everyday use or validated on physical hardware.

## Project Status

From the first UEFI boot to persistent virtual-disk I/O, the project has
progressed through a series of tested milestones. The table is a quick
snapshot; the [technical roadmap](docs/roadmap/phase-status.md) tracks
implementation details and remaining work.

### Milestone Progress

| Phase | Area | Status | Snapshot |
|:---:|---|---|---|
| **F0** | Foundation | ✅ Complete | Toolchain, build, tests and project conventions |
| **F1** | Boot | ✅ Complete | Native UEFI loader and kernel handoff |
| **F2** | Kernel core | 🟢 Tested | Interrupts, paging and memory management |
| **F3** | Execution | 🟡 Active | Scheduler, user processes, syscalls and IPC; expansion pending |
| **F4** | Storage | 🟡 Active | RamFS, VFSX/VNV and **VirtIO Block persistence in QEMU** |
| **F5** | Applications | 🟡 Active | Native ELF loading, SDK and applications; VLIB pending |
| **F6** | Graphics | 🟡 Active | Rasterizer, compositor and input demo; desktop pending |
| **F7** | Drivers | 🟡 Active | **VVDI + modern VirtIO PCI + block I/O**; wider hardware support pending |
| **F8** | Compatibility | 🟡 Active | ELF/VEX and native ABI; broader support pending |
| **F9** | AI | ✅ Scoped complete | Native CPU inference; no GPU acceleration |
| **F10** | Readiness | 🟡 Partial | Initial hardening; installer, updates and recovery pending |

**Status key:** Complete = milestone scope met · Tested = validated in the
documented environment · Active/Partial = work remains. These labels do not
mean the OS is production-ready.

### Latest milestone · Persistent block I/O

**PR #15** brought a native VirtIO Block driver to **VVDI (Voryn Virtual
Device Interface)**. It supports DMA-backed reads and writes, optional FLUSH,
bounded waits and completion/error handling.

**Verified in CI:** 554 Zig tests and a QEMU/OVMF two-boot test. Boot 1 writes,
reads and compares data on a disposable disk separate from the EFI image;
Boot 2 reuses that disk and verifies the data **without rewriting it**.

**Still ahead:** connecting the filesystem to durable block storage, automatic
mounting, broader device support, and physical-hardware validation. Some
PCI/DMA reset and recovery work also remains.

[Milestone details](docs/roadmap/phase-status.md) ·
[VirtIO Block test report](docs/reports/f7/virtio-blk-pr-d.md) ·
[VVDI known limitations](docs/reports/f7/vvdi-debt.md)

## Build and Test

### Requirements

Linux x86_64, **Zig 0.17.0**, Bash and standard build utilities.
Boot/integration tests additionally require **QEMU** and **OVMF/edk2**.

### Quick Start

```bash
git clone https://github.com/CeoMatheusDev/VorynOS.git
cd VorynOS
zig version          # Must report 0.17.0
zig build            # Build the bootable image
zig build test       # Run host unit tests
zig build check      # Unit + automated QEMU/OVMF checks
```

The generated boot image is `zig-out/bin/vorynos.img`.
To boot it manually, use `zig build qemu` (exit the serial console with
`Ctrl+A`, then `X`).

Other useful commands: `zig build qemu-test` for boot checks,
`zig build qemu-interactive-test` for the experimental graphics/input path,
and `zig build --help` for the full list.

`zig build check` includes the **two-boot VirtIO Block persistence test**
using a separate disposable data disk. QEMU results do not establish
physical-hardware compatibility.

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

The **Voryn Fabric** groups the system into native components. Some entries
are architectural contracts or works in progress, not complete subsystems:

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
boot/                Native UEFI bootloader
kernel/              Kernel, memory, processes, filesystems and graphics
  drivers/vvdi/      Native VirtIO transport and block driver
shared/              Shared interfaces and contracts
sdk/                 Native application SDK
user/                User-space applications
tools/               Build and image utilities
tests/               Unit and QEMU integration tests
docs/                Roadmap, architecture decisions and test reports
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
