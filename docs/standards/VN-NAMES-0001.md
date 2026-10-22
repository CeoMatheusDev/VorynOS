# VN-NAMES-0001 — VorynOS naming conventions

| Field | Value |
|-------|-------|
| **State** | ACCEPTED |
| **Date** | 2026-10-21 |
| **Scope** | Code, directories, artifacts and native formats |

## 1. Principle

The name of an artifact of the VorynOS has to allow the identification, by
the reading of the name, of **what it is**, **to which component it
belongs** and, when applicable, **in which format or layer it lives**.
Names do not describe an implementation: `VNC` is the component, and not its
version.

## 2. The components of the Voryn Fabric

Three letter acronyms, prefix `V` + the initial of the name in English:

| Acronym | Name | Meaning |
|-------|------|-------------|
| VNB | Voryn Native Boot | UEFI loader |
| VNK | Voryn Nucleus Kernel | Privileged kernel |
| VNH | Voryn Hardware Nexus | Hardware discovery |
| VNM | Voryn Nexus Memory | Memory management |
| VNT | Voryn Task Fabric | Tasks and scheduling |
| VNX | Voryn Exchange | Communication between processes |
| VNC | Voryn Capability Fabric | Capabilities |
| VND | Voryn Device Fabric | Drivers |
| VSN | Voryn Service Node | Services |

The acronym of a component cannot be reused by another component.

## 3. Native formats

| Format | Extension | Content |
|---------|----------|----------|
| VEX | `.vex` | Executable |
| VLIB | `.vlb` | Library |
| VPK | `.vpk` | Application package |
| VDRV | `.vdr` | Driver package |
| VCFG | `.vcfg` | Structured configuration |
| VARC | `.varc` | File container |
| VIMG | `.vimg` | Volume image |

## 4. Code identifiers

In technical English, to keep the interoperability with the Zig ecosystem
and with the external tools.

| Element | Convention | Example |
|----------|-----------|---------|
| Function, method | `camelCase` | `planLoad`, `exitBootServices` |
| Local variable, field | `camelCase` | `loadBias`, `memoryMapEntries` |
| Compile time constant | `snake_case` | `max_memory_descriptors` |
| Type, structure, union | `PascalCase` | `BootHandoff`, `MemoryDescriptor` |
| Enumeration | `PascalCase` | `PixelFormat` |
| Enumeration variant | `camelCase` | `runtimeServicesData` |
| Acronym, type or constant in UPPER CASE | `SCREAMING_SNAKE_CASE` | `PT_LOAD`, `EFI_REVISION` |
| Module, file | `snake_case` | `memmap.zig`, `loader.zig` |
| Directory | `snake_case` | `shared/`, `boot/uefi/` |

Additional rules:

1. An identifier that represents a value of the firmware or of a
   specification preserves the original spelling (`PT_LOAD`,
   `EFI_FILE_PROTOCOL`).
2. Type names do not use a module prefix (`Memmap.MemoryDescriptor` and
   `handoff.MemoryDescriptor` are the same type).
3. Public functions of a module have the verb at the beginning: `open`,
   `read`, `fetch`, `place`, `validate`, `summarize`.

## 5. Directory structure

```text
VorynOS/
├── boot/uefi/        VNB loader
├── kernel/           VNK kernel
│   ├── arch/x86_64/  architecture specific code
│   ├── memory/       VNM
│   ├── task/         VNT
│   ├── ipc/          VNX
│   ├── syscall/      syscall interface
│   └── security/     VNC
├── drivers/          VND
├── services/         VSN
├── storage/          VNV
├── formats/          readers and writers of the native formats
├── runtime/          user runtime
├── libraries/        native libraries
├── graphics/         VGR
├── desktop/          VSH
├── apps/             native applications
├── ai/               VAI
├── compatibility/    VCB
├── sdk/              SDK and development tools
├── shared/           contracts and code shared between the loader and the kernel
├── tools/            development tools (host executables)
├── tests/            tests that do not belong to a module
├── docs/
│   ├── adr/          architecture decisions
│   ├── architecture/ overview of the architecture
│   ├── standards/    standards (VVS, VN-NAMES)
│   ├── specs/        normative specifications
│   ├── roadmap/      milestones and state
│   └── testing/      testing strategy
└── scripts/          automation scripts
```

`shared/` holds **only** what is really shared between the loader and the
kernel (contracts and architecture primitives). An accidental reuse between
kernel modules does not justify a dependency on `shared/`.

## 6. File names

- `snake_case` with the extension according to the content:
  - `.zig` for Zig;
  - `.c` / `.h` for C23;
  - `.s` for Assembly (with no assembler specific extension, so as not to
    confuse the integrated assembler of Zig with the GNU as);
  - `.md` for documentation;
  - `.sh` for scripts.
- A test file accompanies the tested module: `elf64.zig` holds its own
  tests; the integration tests live in `tests/`.
- The names of the generated artifacts use the prefix `voryn-`:
  `voryn-boot.efi`, `voryn-kernel`, `voryn-fsimg`.

## 7. Boot volume names

The EFI boot volume of the VorynOS uses short names, compatible with FAT
8.3, because the firmware of many platforms only guarantees the reading of
a FAT volume with short names:

| Path | Content |
|---------|----------|
| `/EFI/BOOT/BOOTX64.EFI` | VNB loader |
| `/BOOT/VORYNK.ELF` | Kernel image |

The VFSX (milestone F4) will replace that volume with a **VIMG** image,
with support for long names and metadata of its own.

## 8. Names of the exported symbols

Global symbols exported by a binary use the prefix of the component:

```text
voryn_kernel_entry          entry trampoline of the VNK
voryn_kmain                 Zig entry point of the VNK
voryn_boot_stack            boot stack of the kernel
```

No exported symbol conflicts with the firmware, which matters because the
loader and the kernel coexist in the same address space during the
transition.
