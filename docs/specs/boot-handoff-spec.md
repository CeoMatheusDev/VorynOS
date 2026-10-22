# Specification of the VNB → VNK handoff contract

| Field | Value |
|-------|-------|
| **State** | ACCEPTED — version 1, implemented and validated |
| **Date** | 2026-10-21 |
| **Contract version** | 1 |
| **Code** | `shared/handoff.zig` |

This specification is normative. The loader (VNB) and the kernel (VNK)
compile the same definition, and both have to reject an incompatible
contract.

## 1. Overview

The loader fills a `BootHandoff` structure in memory allocated as
`EfiRuntimeServicesData`, which survives `ExitBootServices`, and passes
the physical address of that structure to the kernel in the `RDI` register,
as the System V AMD64 ABI requires.

The kernel **has to** validate the contract before any use. An invalid
contract interrupts the initialization with an explicit message; the kernel
does not interpret unknown fields.

## 2. Conventions

- Endianness: little endian.
- Alignment: 8 bytes.
- Size of the memory descriptors: 40 bytes, `memory_map_stride`.
- All the integers are unsigned, except where indicated.

## 3. `BootHandoff` structure

| Offset | Size | Field | Description |
|--------|---------|-------|-----------|
| 0 | 8 | `magic` | `0x564F5259_4E424F54` |
| 8 | 4 | `version` | 1 |
| 12 | 4 | `header_size` | `@sizeOf(BootHandoff)` |
| 16 | 8 | `flags` | see §4 |
| 24 | 8 | `handoff_address` | physical address of the structure itself |
| 32 | 8 | `memory_map_address` | physical address of the array of descriptors |
| 40 | 4 | `memory_map_entries` | number of valid descriptors |
| 44 | 4 | `memory_map_stride` | 40 |
| 48 | 96 | `framebuffer` | `FramebufferInfo` |
| 144 | 8 | `kernel_base` | first physical address of the kernel image |
| 152 | 8 | `kernel_end` | physical address after the image |
| 160 | 8 | `kernel_entry` | physical address of the entry point |
| 168 | 8 | `kernel_stack_top` | top of the boot stack of the kernel |
| 176 | 8 | `kernel_stack_bottom` | base of the boot stack of the kernel |
| 184 | 8 | `acpi_rsdp_address` | address of the RSDP, 0 if absent |
| 192 | 4 | `boot_processor_id` | identifier of the processor of the handoff |
| 196 | 4 | `processor_count` | processors reported by the firmware |
| 200 | 8 | `firmware_size` | size of the header of the table of the firmware |
| 208 | 8 | `firmware_revision` | revision of the firmware |

Total size: 216 bytes.

## 4. Flags

| Bit | Name | Meaning |
|-----|------|-------------|
| 0 | `flag_framebuffer` | there is a usable linear framebuffer |
| 1 | `flag_kernel_from_disk` | kernel image read from a volume and validated |
| 2 | `flag_memory_map_final` | map captured immediately before `ExitBootServices` |
| 3 | `flag_identity_mapped` | the first 4 GiB are identity mapped |
| 4 | `flag_acpi_rsdp` | `acpi_rsdp_address` is valid |

Unknown bits **must** be ignored by the consumer, to allow a future
extension of the contract.

## 5. `FramebufferInfo`

| Offset | Size | Field |
|--------|---------|-------|
| 0 | 8 | `base` |
| 8 | 8 | `size` |
| 16 | 4 | `width` |
| 20 | 4 | `height` |
| 24 | 4 | `pitch` |
| 28 | 4 | `bits_per_pixel` |
| 32 | 4 | `pixel_format` |
| 36 | 4 | `red_mask` |
| 40 | 4 | `green_mask` |
| 44 | 4 | `blue_mask` |
| 48 | 1 | `red_shift` |
| 49 | 1 | `green_shift` |
| 50 | 1 | `blue_shift` |
| 51 | 3 | reserved, zero |

`pixel_format`: 0 = `rgb32`, 1 = `bgr32`, `0xFFFFFFFF` = unknown.

## 6. Memory descriptor

| Offset | Size | Field |
|--------|---------|-------|
| 0 | 4 | `memory_type` |
| 4 | 4 | reserved, zero |
| 8 | 8 | `physical_start` |
| 16 | 8 | `virtual_start` |
| 24 | 8 | `page_count` |
| 32 | 8 | `attributes` |

`memory_type` is numerically compatible with `EFI_MEMORY_TYPE`:
0 reserved, 1 loader code, 2 loader data, 3 boot services code, 4 boot
services data, 5 runtime services code, 6 runtime services data, 7
conventional memory, 8 unusable, 9 ACPI reclaim, 10 ACPI NVS, 11 MMIO, 12
PAL code, 13 persistent memory, 14 memory that is not accepted.

## 7. Mandatory validation by the consumer

1. `magic == 0x564F5259_4E424F54`.
2. `version` is supported.
3. `header_size >= @sizeOf(BootHandoff)`.
4. If `memory_map_entries != 0`: `memory_map_address != 0` and
   `memory_map_stride == 40`.

Any failure interrupts the initialization. There is no default value for an
invalid field: the kernel cannot "guess" a memory map.

## 8. Requirements of the producer

1. The memory map is captured **immediately before** `ExitBootServices`,
   because any later allocation invalidates it.
2. If `ExitBootServices` returns `EFI_INVALID_PARAMETER`, the map is
   captured again and the call is repeated. The loader repeats up to eight
   times.
3. The structure and the memory map live in runtime services memory, which
   survives `ExitBootServices`.
4. The physical address and the virtual address of the contract are equal:
   the loader requires that both are below 4 GiB, the range that the
   firmware maps by identity while the boot services are available.
5. No boot service is used after `ExitBootServices`. The console of the
   firmware is decoupled before the call.

## 9. Future compatibility

- New fields are appended at the end, with the increment of `header_size`
  and of `version` when the meaning changes.
- Fields are never removed nor reused.
- The kernel has to ignore unknown flags, but **not** unknown fields: a
  bigger `header_size` is accepted, and the fields beyond the known size
  are ignored.
