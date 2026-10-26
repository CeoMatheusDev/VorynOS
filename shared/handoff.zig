//************************************************************************//
//  handoff.zig                                                           //
//************************************************************************//
//                        This file is part of:                           //
//                              VorynOS                                   //
//             https://github.com/CeoMatheusDev/VorynOS                   //
//************************************************************************//
// Copyright (C) 2020 - 2026 Matheus.A.Santos contributors.               //
// Copyright (C) 2026 VorynOS - All Rights Reserved.                      //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//
//  Toolchain:  Zig 0.17.0 · C23 (ISO/IEC 9899:2024) · x86-64 (AMD64)     //
//************************************************************************//

//! VorynOS boot handoff contract (VNB -> VNK).
//!
//! This module is the single source of truth for the structure that the Voryn
//! Native Boot loader (VNB) hands over to the Voryn Nucleus Kernel (VNK).
//!
//! It is compiled into *both* the bootloader and the kernel, therefore it
//! must not depend on any operating system facility and must keep a stable,
//! explicitly sized layout. Every field is `extern` so the layout matches the
//! SysV AMD64 ABI exactly.
//!
//! See `docs/specs/boot-handoff-spec.md` for the normative description.

const std = @import("std");

/// Magic value stored in `BootHandoff.magic` ("VORYNBOT" in ASCII, big endian
/// ordering of the characters).
pub const handoff_magic: u64 = 0x564F_5259_4E42_4F54;

/// Version of the handoff contract implemented by this build.
pub const handoff_version: u32 = 1;

/// Page size of the x86_64 architecture, in bytes.
pub const page_size: u64 = 4096;

/// Upper bound of the region that the firmware identity maps while boot
/// services are available. Addresses below this limit can be used directly
/// as physical addresses.
pub const identity_mapped_limit: u64 = 4 * 1024 * 1024 * 1024;

/// Bit mask of `BootHandoff.flags`: the firmware left a framebuffer available.
pub const flag_framebuffer: u64 = 1 << 0;
/// Bit mask of `BootHandoff.flags`: the kernel image was loaded from a file
/// system and validated as a non-relocatable ELF64 executable.
pub const flag_kernel_from_disk: u64 = 1 << 1;
/// Bit mask of `BootHandoff.flags`: the memory map was captured immediately
/// before `ExitBootServices` and is the final map seen by the firmware.
pub const flag_memory_map_final: u64 = 1 << 2;
/// Bit mask of `BootHandoff.flags`: the firmware identity-mapped the first
/// 4 GiB, so physical and virtual addresses are equal at handoff time.
pub const flag_identity_mapped: u64 = 1 << 3;
/// Bit mask of `BootHandoff.flags`: an ACPI RSDP was located.
pub const flag_acpi_rsdp: u64 = 1 << 4;

/// Pixel layout of the framebuffer handed over by the firmware.
pub const PixelFormat = enum(u32) {
    /// 32 bits per pixel, 8 bits per channel, described by the masks below.
    rgb32 = 0,
    /// 32 bits per pixel, 8 bits per channel, channel order is reversed.
    bgr32 = 1,
    /// The firmware did not report a usable pixel layout.
    unknown = 0xFFFF_FFFF,
};

/// Description of the linear framebuffer provided by the firmware.
pub const FramebufferInfo = extern struct {
    /// Physical (and, while identity mapped, virtual) base address.
    base: u64 = 0,
    /// Size of the framebuffer region in bytes.
    size: u64 = 0,
    /// Visible width in pixels.
    width: u32 = 0,
    /// Visible height in pixels.
    height: u32 = 0,
    /// Number of bytes between the start of two consecutive rows.
    pitch: u32 = 0,
    /// Bits per pixel.
    bits_per_pixel: u32 = 0,
    /// Channel layout.
    pixel_format: PixelFormat = .unknown,
    /// Channel masks, only meaningful for 32 bpp modes.
    red_mask: u32 = 0,
    green_mask: u32 = 0,
    blue_mask: u32 = 0,
    /// Channel shifts, only meaningful for 32 bpp modes.
    red_shift: u8 = 0,
    green_shift: u8 = 0,
    blue_shift: u8 = 0,
    _reserved: [3]u8 = .{ 0, 0, 0 },
};

/// Memory region classification, numerically compatible with the UEFI
/// `EFI_MEMORY_TYPE` values so the bootloader can transfer them verbatim.
pub const MemoryType = enum(u32) {
    reserved = 0,
    loader_code = 1,
    loader_data = 2,
    boot_services_code = 3,
    boot_services_data = 4,
    runtime_services_code = 5,
    runtime_services_data = 6,
    conventional = 7,
    unavailable = 8,
    acpi_reclaim = 9,
    acpi_nvs = 10,
    bad_sector = 11,
    memory_mapped_io = 12,
    pal_code = 13,
    persistent_memory = 14,
    unaccepted_memory = 15,
    _,

    /// True when the region is ordinary RAM that the kernel may hand out.
    pub fn isUsableRam(self: MemoryType) bool {
        return switch (self) {
            .conventional, .persistent_memory => true,
            else => false,
        };
    }

    /// Human readable name, used by the kernel diagnostic output.
    pub fn name(self: MemoryType) []const u8 {
        return switch (self) {
            .reserved => "reserved",
            .loader_code => "loader-code",
            .loader_data => "loader-data",
            .boot_services_code => "boot-services-code",
            .boot_services_data => "boot-services-data",
            .runtime_services_code => "runtime-services-code",
            .runtime_services_data => "runtime-services-data",
            .conventional => "conventional",
            .unavailable => "unusable",
            .acpi_reclaim => "acpi-reclaim",
            .acpi_nvs => "acpi-nvs",
            .bad_sector => "bad-sector",
            .memory_mapped_io => "mmio",
            .pal_code => "pal-code",
            .persistent_memory => "persistent",
            .unaccepted_memory => "unaccepted",
            _ => "unknown",
        };
    }
};

/// Attributes of a memory region, numerically compatible with the UEFI
/// `EFI_MEMORY_DESCRIPTOR.Attribute` bits.
pub const MemoryAttributes = enum(u64) {
    /// Bit 0: the region requires a special caching mode.
    uc = 1 << 0,
    /// Bit 1: write-back cachable.
    wc = 1 << 1,
    /// Bit 2: write-through cachable.
    wt = 1 << 2,
    /// Bit 3: write-back, write-allocate cachable.
    wb = 1 << 3,
    /// Bit 4: uncacheable, exportable.
    uce = 1 << 4,
    /// Bit 7: write-protected.
    wp = 1 << 7,
    /// Bit 8: read-protected.
    rp = 1 << 8,
    /// Bit 9: the region is executable.
    xp = 1 << 9,
    /// Bit 10: the region is non-volatile.
    nv = 1 << 10,
    /// Bit 11: the region is more reliable than the default.
    more_reliable = 1 << 11,
    /// Bit 12: the region is read-only.
    ro = 1 << 12,
    _,
};

/// A single entry of the memory map handed over to the kernel.
pub const MemoryDescriptor = extern struct {
    /// Region classification.
    memory_type: MemoryType = .reserved,
    _reserved0: u32 = 0,
    /// First physical page of the region.
    physical_start: u64 = 0,
    /// Virtual base address reported by the firmware. The VorynOS physical
    /// memory manager ignores this field, it is kept for diagnostics.
    virtual_start: u64 = 0,
    /// Number of pages in the region.
    page_count: u64 = 0,
    /// Region attributes, see `MemoryAttributes`.
    attributes: u64 = 0,

    /// Total size of the region in bytes.
    pub fn byteSize(self: MemoryDescriptor) u64 {
        return self.page_count * page_size;
    }

    /// First physical address past the end of the region.
    pub fn endAddress(self: MemoryDescriptor) u64 {
        return self.physical_start + self.byteSize();
    }

    /// True when the region may be used as ordinary RAM.
    pub fn isUsableRam(self: MemoryDescriptor) bool {
        return self.memory_type.isUsableRam();
    }
};

/// The structure transferred from the bootloader to the kernel.
///
/// The bootloader fills this structure in memory that survives
/// `ExitBootServices` and passes its physical address to the kernel entry
/// point in `RDI`. The `magic` field is the first thing the kernel checks.
pub const BootHandoff = extern struct {
    /// Must equal `handoff_magic`.
    magic: u64 = 0,
    /// Must equal `handoff_version`.
    version: u32 = 0,
    /// Size of this structure in bytes, allows forward compatible extension.
    header_size: u32 = 0,
    /// Bit mask of the `flag_*` constants.
    flags: u64 = 0,
    /// Physical address of this structure.
    handoff_address: u64 = 0,
    /// Physical address of the memory map array.
    memory_map_address: u64 = 0,
    /// Number of valid entries in the memory map.
    memory_map_entries: u32 = 0,
    /// Distance in bytes between two memory map entries.
    memory_map_stride: u32 = 0,
    /// Framebuffer description, only valid when `flag_framebuffer` is set.
    framebuffer: FramebufferInfo = .{},
    /// First physical address occupied by the kernel image.
    kernel_base: u64 = 0,
    /// First physical address past the kernel image.
    kernel_end: u64 = 0,
    /// Physical entry point of the kernel image.
    kernel_entry: u64 = 0,
    /// Top of the boot stack owned by the kernel image.
    kernel_stack_top: u64 = 0,
    /// Bottom of the boot stack owned by the kernel image.
    kernel_stack_bottom: u64 = 0,
    /// Physical address of the ACPI RSDP, only valid with `flag_acpi_rsdp`.
    acpi_rsdp_address: u64 = 0,
    /// Identifier of the processor that performed the handoff.
    boot_processor_id: u32 = 0,
    /// Number of processors reported by the firmware.
    processor_count: u32 = 1,
    /// Size of the firmware, in bytes.
    firmware_size: u64 = 0,
    /// Revision of the firmware.
    firmware_revision: u64 = 0,
};

/// Result of validating a `BootHandoff` structure.
pub const ValidationError = error{
    /// The magic value does not match `handoff_magic`.
    BadMagic,
    /// The contract version is not supported by this kernel.
    UnsupportedVersion,
    /// The structure is smaller than the version the kernel expects.
    Truncated,
    /// The memory map pointer is null while the entry count is not zero.
    MissingMemoryMap,
    /// The memory map stride does not match the expected descriptor size.
    BadMemoryMapStride,
};

/// Expected size of one memory map entry.
pub const memory_descriptor_size: u32 = @sizeOf(MemoryDescriptor);

/// Validates a handoff structure received from the bootloader.
pub fn validate(handoff: *const BootHandoff) ValidationError!void {
    if (handoff.magic != handoff_magic) return error.BadMagic;
    if (handoff.version != handoff_version) return error.UnsupportedVersion;
    if (handoff.header_size < @sizeOf(BootHandoff)) return error.Truncated;
    if (handoff.memory_map_entries != 0) {
        if (handoff.memory_map_address == 0) return error.MissingMemoryMap;
        if (handoff.memory_map_stride != memory_descriptor_size) return error.BadMemoryMapStride;
    }
}

test "handoff magic and version are checked" {
    var handoff: BootHandoff = .{};
    handoff.header_size = @sizeOf(BootHandoff);
    try std.testing.expectError(error.BadMagic, validate(&handoff));

    handoff.magic = handoff_magic;
    try std.testing.expectError(error.UnsupportedVersion, validate(&handoff));

    handoff.version = handoff_version;
    try validate(&handoff);
}

test "handoff rejects inconsistent memory map metadata" {
    var handoff: BootHandoff = .{};
    handoff.magic = handoff_magic;
    handoff.version = handoff_version;
    handoff.header_size = @sizeOf(BootHandoff);
    handoff.memory_map_entries = 4;
    try std.testing.expectError(error.MissingMemoryMap, validate(&handoff));

    handoff.memory_map_address = 0x1000;
    try std.testing.expectError(error.BadMemoryMapStride, validate(&handoff));

    handoff.memory_map_stride = memory_descriptor_size;
    try validate(&handoff);
}

test "memory descriptor arithmetic" {
    const descriptor: MemoryDescriptor = .{
        .memory_type = .conventional,
        .physical_start = 0x100000,
        .page_count = 4,
    };
    try std.testing.expectEqual(@as(u64, 4 * page_size), descriptor.byteSize());
    try std.testing.expectEqual(@as(u64, 0x100000 + 4 * page_size), descriptor.endAddress());
    try std.testing.expect(descriptor.isUsableRam());
}
