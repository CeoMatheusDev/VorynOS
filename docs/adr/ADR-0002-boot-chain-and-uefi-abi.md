# ADR-0002 — Boot chain, handoff contract, and UEFI ABI

| Field | Value |
|-------|-------|
| **Status** | ACCEPTED — implemented and validated on QEMU/OVMF |
| **Date** | 2026-10-21 |
| **Decided by** | VorynOS Engineering |
| **Supersedes** | — |

## 1. Context

The VorynOS needs a reproducible, verifiable boot path that is
independent of the firmware. The bootloader receives control from an
x86_64 UEFI firmware and must hand the kernel a valid image, a faithful
memory map, and a verifiable contract, without using boot services after
`ExitBootServices`.

## 2. Decision

1. **VNB is a standalone UEFI application**, written in Zig, target
   `x86_64-uefi`, without libc, single-threaded.
2. **The kernel is a relocatable ELF64 image** (`ET_DYN`, PIE), loaded from
   the boot volume and placed by the bootloader in a RAM region chosen at
   runtime.
3. **The contract between bootloader and kernel is a versioned structure**,
   `shared/handoff.zig`, filled in runtime services memory (which survives
   `ExitBootServices`) and verified on both sides.
4. **The serial console (COM1) is the primary diagnostic channel**, written
   directly by the 16550 UART. The firmware console is secondary and is
   decoupled before `ExitBootServices`.
5. **The test image is built by the project itself** (`tools/fatimg.zig`),
   a FAT16 volume written from scratch, without depending on external
   disk tools.

## 3. Handoff Contract

Condensed; the normative specification is in
[`docs/specs/boot-handoff-spec.md`](../specs/boot-handoff-spec.md).

| Field | Value |
|-------|-------|
| `magic` | `0x564F5259_4E424F54` ("VORYNBOT") |
| `version` | 1 |
| `header_size` | `@sizeOf(BootHandoff)` |
| `flags` | framebuffer present, kernel coming from disk, final map, identity map, RSDP |
| `memory_map_address` | physical address of the normalized descriptor array |
| `memory_map_entries` | number of valid descriptors |
| `memory_map_stride` | `@sizeOf(MemoryDescriptor)`, 40 bytes |
| `kernel_base` / `kernel_end` / `kernel_entry` | physical addresses of the image |
| `framebuffer` | base, size, resolution, pitch, format, and channel masks |

The kernel validates the magic, version, header size, and memory map
coherence before any use. An invalid handoff aborts the boot with an
explicit message, without attempting to use the structure.

## 4. ABI Findings in the Firmware (Experimental Evidence)

The UEFI ABI measured on the OVMF used by the tests diverges from the
schematic description in the specification in three points. Each point
was confirmed experimentally on the firmware itself, not by assumption.

### 4.1 Missing `EFI_REVISION` header on some protocols

The firmware's `EFI_FILE_PROTOCOL` **does** have the `EFI_REVISION` header
(`0x00010000` in the first eight bytes), while the
`EFI_GRAPHICS_OUTPUT_PROTOCOL` and `EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL` of the
**same** firmware **do not**: the first eight bytes are the pointer to the
first function.

Evidence: a test application called the member at offset 8 and the member
at offset 16. Offset 8 printed the expected message; offset 16 printed
nothing (it called `TestString`, which does not write).

**Consequence:** the bootloader assumes neither variant. `Protocol` in
`boot/uefi/vnb/protocols.zig` detects the variant at runtime (comparing
the first eight bytes with `0x00010000`) and keeps **two** pointers: the
*body* of the protocol, used to read the members, and the `*this*` pointer,
which is the address the firmware expects to receive as the first
argument of each callback. Passing the body as `this` would make the
firmware read members at the wrong offsets.

### 4.2 Memory Descriptor Size

The firmware reports `DescriptorSize = 48` in `GetMemoryMap`, and not the
40 bytes of the specification's `EFI_MEMORY_DESCRIPTOR`. The observed structure is:

```text
+0   Type (u32) + reserved (u32)
+8   PhysicalStart (u64)
+16  VirtualStart (u64)
+24  NumberOfPages (u64)
+32  Attribute (u64)
+40  additional word, always zero in the observed descriptors
```

**Consequence:** the bootloader never assumes the descriptor size. It reads
the fields at a fixed offset, which is identical in both variants, and
ignores whatever the firmware appends at the end. The size reported by the
firmware is always respected.

### 4.3 `SizeOfInfo` in graphics mode

`EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE_INFORMATION` contains, between the
`Info` pointer and `FrameBufferBase`, a `SizeOfInfo` field (36 bytes on
this machine). Without it, `FrameBufferBase` is read from the wrong value.

**Consequence:** the VorynOS mode structure declares `size_of_info`.

## 5. Rationale for the Decisions

- **Relocatable image instead of a fixed address**: with a fixed address,
  the kernel is loaded where the linker placed it. On the test machine,
  that address (16 MiB) falls in boot services memory, and the load
  fails correctly but unusably. With a relocatable image, the bootloader
  chooses a conventional RAM region, aligned to 2 MiB when possible,
  above 1 MiB (the low PC area holds firmware structures).
- **Versioned contract instead of passing loose pointers**: it allows the
  contract to evolve, detects incorrect loading, and is verifiable by
  unit tests on the host.
- **Serial as the primary channel**: the only channel that survives the
  firmware/kernel boundary and works in automation without human interaction.
- **Own FAT16 volume**: it removes `mtools`/`dosfstools` from the build
  and test chain, and serves as the basis for the future VFSX.

## 6. Costs and Risks

| Cost | Reason | Accepted because |
|-------|--------|---------------|
| Runtime layout detection | Firmwares diverge | The alternative is breaking on real hardware |
| Relocation support in the bootloader | Bootloader complexity | Necessary for robustness across machines |
| Own FAT16 table (~350 lines) | Maintenance | Removes an external dependency and validates the format |
| 8.3 names on the test volume | FAT limit | The test volume is not the final product |

## 7. Rejected Alternatives

- **Kernel with a fixed address and a low link address**: rejected, it
  breaks on machines whose RAM does not cover the linker-chosen address.
- **Loader in C with GNU-EFI**: rejected, it adds an external library
  dependency to a component that must be minimal and auditable.
- **Depend on the firmware console for diagnostics**: rejected, the
  firmware console does not survive `ExitBootServices` and is not automatable.
- **Use `mtools` to build the image**: rejected, external dependency in
  the test chain.

## 8. Future Consequences

- The kernel format will evolve into **VEX**, the project's native
  format; the current bootloader already has the necessary structure
  (segments, relative relocations, capability manifest) to be reused.
- The handoff contract will be extended with ACPI (RSDP), the firmware
  interrupt descriptor table, and SMP information at the F2 milestone.
