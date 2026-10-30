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
| **F5** | Applications | 🟡 Active | Native ELF loading, SDK, and the **VEX and VLIB containers** (codec + boot self-test); runtime linking pending |
| **F6** | Graphics | 🟡 Active | Rasterizer, compositor, damage tracking, managed scene desktop, PS/2 keyboard input and a **taskbar shell with keyboard focus switching**; no text, cursor or mouse driver |
| **F7** | Drivers | 🟡 Active | **VVDI + modern VirtIO PCI + block I/O**; wider hardware support pending |
| **F8** | Compatibility | 🟡 Active | Native ELF/VEX and the Voryn ABI; **no PE, Win32 or Linux ABI layer exists** |
| **F9** | AI | 🟢 Tested (host) | **Native CPU inference as syscall 24**, gated by an `execute` capability; one embedded model, no GPU |
| **F10** | Readiness | 🟡 Partial | Initial hardening (NX, W^X, stack canary); **no installer, updates or on-target recovery** |

**Status key:** Complete = milestone scope met · Tested = validated in the
documented environment · Active/Partial = work remains. These labels do not
mean the OS is production-ready.

### Latest increment · The desktop gets a bar (F6.31)

Closing a gap turned up two documentation defects. First: the README and the
roadmap said "focus pending", but focus between clients **already existed** —
the session delivers the keyboard only to the focused window, a click changes
focus, and the renderer colours the focused window. Second, and worse: **29
tests in eight graphics files had never run**, because no test binary imported
`frame.zig`, `session.zig`, `window_manager.zig`, `window_renderer.zig`,
`pointer_input.zig`, `event_queue.zig`, `framebuffer_bridge.zig` or
`desktop.zig`. They existed in the repository and counted in nobody's summary.

Both are addressed. `desktop-tests` is a real `zig build test` target now
(**49** tests: the 29 that never ran, 11 new, 9 harmless repeats), and the
first piece of the shell exists: `kernel/graphics/taskbar.zig`.

```text
[VNK] shell: bar height=33 buttons=2 windows=2
[VNK] shell: the first button answers a click at x=0 y=1079
[VNK] shell: focus cycled to slot=1 frame=1920x1080
```

The bar is a **model**: it lays out one button per visible window in z-order,
answers which window sits under a point, and paints itself with the focused
window highlighted. It is not a window — it stays out of the z-order and the
desktop paints it after the windows, so nothing covers it. The boot kills
itself if the first button does not answer a click, if the gutter belongs to a
button, or if switching focus does not change windows.

**Stated limits:** there is no font, so buttons are rectangles without titles;
there is no cursor; and there is **no mouse driver** — `pointer_input` →
`buttonAt` → focus is implemented and tested, but the kernel's PS/2 path reads
the keyboard (IRQ1), not the mouse (IRQ12). The focus switch that runs at boot
comes from the keyboard.

**Validated locally:** 689 Zig tests (0 failures) and `zig build` completing
15/15 steps — 19 of those tests come from the VVDI fault-injection increment
already merged from `main`. The three new boot assertions are implemented but
**were not executed in this session** (no QEMU/OVMF).

[F6.31 report](docs/reports/f6/shell-taskbar.md) ·
[Roadmap](docs/roadmap/phase-status.md)

### Previous increment · A library becomes a container (F5)

The F5 gap called "VLIB" was a **format**, not a runtime. A `.vlb` file
carries a native library — an ELF64 relocatable image — together with what
the kernel must know **before** it executes a single byte of that code: the
library name, the symbols it exports, the system call ABI it was built for
and the capabilities it requires.

`formats/vlib.zig` implements the codec as a pure module — no syscalls, no
allocation and no I/O — with **two** checksums, because the two failures
differ: `image_crc32` covers the *code*, and `symbol_table_crc32` covers the
records, the symbol names and the library name. Without the second, a
corrupted name offset could point at a still-valid region and the wrong
export would pass the bounds check.

The boot self-test closes the whole cycle on the image that the toolchain
actually produced (pack → RamFS → VNV commit → recovery → validate):

```text
[VNK] vlib: packed libvoryn symbols=4 image=... bytes abi=13 requires=0x4 total=... bytes
[VNK] vlib: /lib/libvoryn.vlb validated after recovery symbols=4 image=... bytes segments=...
[VNK] vlib: export voryn_main at 0x1000, hidden internal_helper not exported
[VNK] vlib: pack/persist/recover/validate round trip ok
```

A `hidden` symbol is never returned by `findExport`: the lookup is the
operation of whoever links against the library, and an internal helper is not
part of that interface. The recovered file is compared **byte for byte**
against the buffer the kernel packed, and the ELF inside it is parsed, so the
container is proven to carry code and not an opaque blob.

**Scope, stated honestly:** VLIB is a **container codec**. There is no
linker, no relocation processing and no library loading into a process in
this increment. The `relocatable` flag declares a property of the image; it
is not a promise that the kernel can already use it.

**Validated locally:** 621 Zig tests (0 failures, `vlib-tests` among them)
and `zig build` completing 15/15 steps. The boot assertions are implemented
but **were not executed in this session** (no QEMU/OVMF); the CI run is what
confirms them.

[VLIB spec](docs/specs/vlib.md) · [VPK spec](docs/specs/vpk.md) ·
[Roadmap](docs/roadmap/phase-status.md)

### Previous milestone · Inference becomes a system call

Until now the AI code (`kernel/ai/`) was a **library that the kernel never
imported**: tested on the host, unreachable from the operating system. The
F9 increment of 2026-10-30 makes it a capability.

The kernel embeds **one** model image built at compile time
(`kernel/ai/embedded.zig`), validates it — magic, geometry, offsets and the
CRC32 of the weights — and runs it before the timer starts: a kernel that
cannot run its own model halts instead of answering with numbers that look
valid. A process reaches it through **syscall 24 `ai_infer`**, and only if it
holds the **`ai` capability (kind 4, right `execute`)**.

The boot proves both sides of the boundary:

```text
[VNK] ai: model validated id=0 input=4 hidden=4 output=3 image=124 bytes weights=48 bytes crc ok
[VNK] ai: inference ok output_x1000=2125,5250,4000 checksum=0x30f2bf7325eecf35 model=0
[VNK] capabilities: the inference engine belongs to the process 3
[VNK] syscall 24 from user ai_infer result 0xc          # 12 bytes, the composing process
ai infer ok checksum=0x30f2bf7325eecf35
[VNK] syscall 24 from user ai_infer result 0xfffffffffffffff6   # error 10
ai infer denied without the capability                  # the client holds nothing
```

The geometry is fixed (4 features in, 3 out, one dense layer with ReLU), the
weights are powers of two so the result is **bit exact**, and the process
never sees the weights, the workspace or the address of the model. There is
no GPU acceleration, no quantization and no batching — and none is claimed.

**Validated locally at the time of that increment:** 612 Zig tests (0 failures; the
suite has since grown to 621 with `vlib-tests`), `zig build` produces the
kernel, the 128 MiB image and the host tool. The nine new boot assertions are
implemented but **were not executed in this session** (no QEMU/OVMF); the CI
run is what confirms them.

[F9 report](docs/reports/f9/f9-inference-call.md) ·
[ADR-0023](docs/adr/ADR-0023-ai-inference-capability.md) ·
[System call contract v13](docs/specs/syscall-abi.md)

### Earlier milestone · Persistent block I/O

**PR #15** brought a native VirtIO Block driver to **VVDI (Voryn Virtual
Device Interface)**: DMA-backed reads and writes, optional FLUSH, bounded
waits and completion/error handling.

**Verified in CI:** a QEMU/OVMF two-boot test. Boot 1 writes, reads and
compares data on a disposable disk separate from the EFI image; Boot 2 reuses
that disk and verifies the data **without rewriting it**.

**Still ahead:** connecting the filesystem to durable block storage, automatic
mounting, broader device support and physical-hardware validation. Some
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
formats/             Container codecs: VEX, VPK and VLIB
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
- [VPK container specification](docs/specs/vpk.md)
- [VLIB container specification](docs/specs/vlib.md)
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

*README last reviewed on October 30, 2026.*
