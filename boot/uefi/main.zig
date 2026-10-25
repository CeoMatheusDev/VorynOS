//************************************************************************//
//  main.zig                                                              //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Voryn Native Boot (VNB) - the VorynOS UEFI loader.
//!
//! The loader is responsible for the transition between the firmware and the
//! Voryn Nucleus Kernel (VNK). It performs, in order:
//!
//!   1. console initialisation (serial port and firmware console);
//!   2. discovery of the linear framebuffer through the Graphics Output
//!      Protocol;
//!   3. acquisition of the firmware memory map;
//!   4. loading of the kernel image from the boot volume;
//!   5. validation of the kernel image as a non-relocatable ELF64 executable
//!      and placement of its segments in physical memory;
//!   6. construction of the boot handoff structure in memory that survives
//!      `ExitBootServices`;
//!   7. `ExitBootServices` followed by the transfer of control to the kernel.
//!
//! No firmware service may be used after step 7. The loader is written
//! against the UEFI specification, the Zig standard library is only used as
//! the ABI reference for the firmware tables.

const std = @import("std");
const uefi = std.os.uefi;
const voryn = @import("voryn_shared");

const console = @import("vnb/console.zig");
const framebuffer = @import("vnb/framebuffer.zig");
const fs = @import("vnb/fs.zig");
const loader = @import("vnb/loader.zig");
const memory = @import("vnb/memory.zig");

const handoff = voryn.handoff;
const elf64 = voryn.elf64;
const memmap = voryn.memmap;

/// Version of the loader, reported on the console.
const loader_version = "0.1.0-dev.1";

/// Path of the kernel image inside the boot volume.
const kernel_path = "\\boot\\vorynk.elf";

/// Size of the scratch buffer used to read the raw memory map.
const map_scratch_size = 256 * 1024;

/// Maximum number of memory descriptors accepted by the kernel.
const max_memory_descriptors = 1024;

/// Maximum number of loadable segments accepted in the kernel image.
const max_segments = 64;

/// Maximum number of relocations accepted in the kernel image.
const max_relocations = 4096;

/// Alignment used for the kernel image, a large page.
const large_page_size: u64 = 2 * 1024 * 1024;

/// Lowest physical address the kernel image may be loaded at.
///
/// The first megabyte of a PC holds data structures of the firmware, the
/// kernel never uses it.
const minimum_load_address: u64 = 1024 * 1024;

/// Maximum number of attempts to leave the firmware.
const max_exit_attempts = 8;

/// Storage for the validated segment list, avoids heap allocations.
var segment_storage: [max_segments]elf64.Segment = undefined;

/// Storage for the relocations of the kernel image.
var relocation_storage: [max_relocations]elf64.Relocation = undefined;

/// Locates the ACPI root system description pointer.
///
/// The firmware publishes the pointer through the configuration table of
/// the system table, with one of the two GUIDs that the UEFI specification
/// reserves for the ACPI root pointer. The pointer is returned as the
/// physical address that the kernel receives in the handoff; zero means
/// that the firmware did not publish one.
fn findAcpiRsdp() u64 {
    const table = uefi.system_table;
    const acpi_20 = uefi.tables.ConfigurationTable.acpi_20_table_guid;
    const acpi_10 = uefi.tables.ConfigurationTable.acpi_10_table_guid;

    var index: usize = 0;
    while (index < table.number_of_table_entries) : (index += 1) {
        const entry = table.configuration_table[index];
        if (uefi.Guid.eql(entry.vendor_guid, acpi_20) or
            uefi.Guid.eql(entry.vendor_guid, acpi_10))
        {
            return @intFromPtr(entry.vendor_table);
        }
    }
    return 0;
}

/// Chooses the physical address the kernel image is loaded at.
///
/// The address is aligned to 2 MiB when the machine offers a region that is
/// large enough, so that the kernel can later be mapped with large pages.
/// A page aligned address is used as a fallback.
fn chooseLoadBias(
    image: elf64.Image,
    map: []const handoff.MemoryDescriptor,
) !u64 {
    const size = image.end - image.base;
    const aligned_size = std.mem.alignForward(u64, size, handoff.page_size);

    const address = memmap.findLoadRegion(map, aligned_size, large_page_size, minimum_load_address) orelse
        memmap.findLoadRegion(map, aligned_size, handoff.page_size, minimum_load_address) orelse
        return error.NoRoomForKernel;

    if (address < image.base) return error.NoRoomForKernel;
    return address - image.base;
}

/// Entry point of the UEFI application.
pub fn main() uefi.Error!void {
    var out = console.Console.init();

    out.printLine("[VNB] VorynOS {s} - Voryn Native Boot", .{loader_version});
    out.printLine("[VNB] firmware revision: 0x{x}", .{uefi.system_table.hdr.revision});

    boot(&out) catch |err| {
        out.printLine("[VNB] FATAL: {s}", .{@errorName(err)});
        return error.DeviceError;
    };
}

/// Executes the boot chain.
fn boot(out: *console.Console) !void {
    const boot_services = uefi.system_table.boot_services orelse return error.NoBootServices;

    // A firmware watchdog would reset the machine while the kernel runs.
    // A firmware that does not implement the watchdog is not an error.
    _ = boot_services.setWatchdogTimer(0, 0, null) catch {};

    // --- 1. Framebuffer ----------------------------------------------------
    var flags: u64 = 0;
    var framebuffer_info: handoff.FramebufferInfo = .{};
    if (framebuffer.discover(boot_services)) |info| {
        framebuffer_info = info;
        flags |= handoff.flag_framebuffer;
        out.printLine("[VNB] framebuffer {d}x{d} bpp={d} pitch={d} size=0x{x} base=0x{x}", .{
            info.width,
            info.height,
            info.bits_per_pixel,
            info.pitch,
            info.size,
            info.base,
        });
    } else |err| {
        out.printLine("[VNB] framebuffer unavailable: {s}", .{@errorName(err)});
    }

    // --- 2. Memory ----------------------------------------------------------
    // The scratch buffer receives the raw descriptors of the firmware, the
    // runtime buffer receives the normalised descriptors that are handed over
    // to the kernel. Runtime services memory survives ExitBootServices.
    const map_scratch = try boot_services.allocatePool(.loader_code, map_scratch_size);
    const map_buffer = try boot_services.allocatePool(
        .runtime_services_data,
        max_memory_descriptors * @sizeOf(handoff.MemoryDescriptor),
    );
    const map_output: [*]handoff.MemoryDescriptor = @ptrCast(@alignCast(map_buffer.ptr));

    const provisional = try memory.fetch(boot_services, map_scratch, map_output[0..max_memory_descriptors]);
    out.printLine("[VNB] memory map: {d} regions", .{provisional.count});

    // --- 3. Kernel image ---------------------------------------------------
    const volume = try fs.openBootVolume(boot_services);
    const kernel_size = try fs.queryFileSize(volume, kernel_path);
    out.printLine("[VNB] kernel image: {d} bytes", .{kernel_size});

    const kernel_buffer = try boot_services.allocatePool(.loader_data, kernel_size);
    const bytes_read = try fs.readFile(volume, kernel_path, kernel_buffer);
    if (bytes_read != kernel_size) return error.ShortKernelImage;

    // --- 4. Validation and placement ---------------------------------------
    const image = try elf64.planLoad(
        kernel_buffer[0..kernel_size],
        provisional.descriptors,
        &segment_storage,
        &relocation_storage,
    );

    // A position independent image is placed in a region of ordinary RAM
    // that the loader chooses, a fixed address image is placed where the
    // linker put it.
    const load_bias = if (image.relocatable)
        try chooseLoadBias(image, provisional.descriptors)
    else
        0;

    try loader.place(image, kernel_buffer[0..kernel_size], load_bias);
    flags |= handoff.flag_kernel_from_disk;

    const kernel_base = image.base + load_bias;
    const kernel_end = image.end + load_bias;
    const kernel_entry = image.entry + load_bias;

    out.printLine("[VNB] kernel placed: base=0x{x} end=0x{x} entry=0x{x} segments={d} relocations={d}", .{
        kernel_base,
        kernel_end,
        kernel_entry,
        image.segments.len,
        image.relocations.len,
    });

    // --- 5. Handoff memory --------------------------------------------------
    const handoff_buffer = try boot_services.allocatePool(.runtime_services_data, @sizeOf(handoff.BootHandoff));

    const handoff_address = @intFromPtr(handoff_buffer.ptr);
    const map_address = @intFromPtr(map_buffer.ptr);
    if (handoff_address >= loader.identity_mapped_limit or map_address >= loader.identity_mapped_limit) {
        return error.HandoffOutsideIdentityMapping;
    }

    // The ACPI root pointer is read before the firmware is left: after
    // `ExitBootServices` the configuration table is not available anymore,
    // but the table that the pointer describes stays in memory.
    const acpi_rsdp_address = findAcpiRsdp();
    if (acpi_rsdp_address != 0) {
        flags |= handoff.flag_acpi_rsdp;
        out.printLine("[VNB] acpi: rsdp at 0x{x}", .{acpi_rsdp_address});
    } else {
        out.printLine("[VNB] acpi: no root pointer published", .{});
    }

    const target: *handoff.BootHandoff = @ptrCast(@alignCast(handoff_buffer.ptr));

    // --- 6. Leave the firmware ---------------------------------------------
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        // The memory map has to be the last one the firmware produced, so it
        // is fetched again right before the transition. If the firmware
        // reports that the map key is stale, the transition is retried.
        const final_map = try memory.fetch(boot_services, map_scratch, map_output[0..max_memory_descriptors]);
        if (final_map.count > max_memory_descriptors) return error.MemoryMapTooLarge;

        target.* = .{
            .magic = handoff.handoff_magic,
            .version = handoff.handoff_version,
            .header_size = @sizeOf(handoff.BootHandoff),
            .flags = flags | handoff.flag_memory_map_final | handoff.flag_identity_mapped,
            .handoff_address = handoff_address,
            .memory_map_address = map_address,
            .memory_map_entries = final_map.count,
            .memory_map_stride = @sizeOf(handoff.MemoryDescriptor),
            .framebuffer = framebuffer_info,
            .kernel_base = kernel_base,
            .kernel_end = kernel_end,
            .kernel_entry = kernel_entry,
            .kernel_stack_top = 0,
            .kernel_stack_bottom = 0,
            .acpi_rsdp_address = acpi_rsdp_address,
            .boot_processor_id = 0,
            .processor_count = 1,
            .firmware_size = uefi.system_table.hdr.header_size,
            .firmware_revision = uefi.system_table.hdr.revision,
        };

        boot_services.exitBootServices(uefi.handle, final_map.key) catch |err| {
            if (err == error.InvalidParameter and attempt < max_exit_attempts) {
                out.printLine("[VNB] memory map changed, retrying", .{});
                continue;
            }
            return err;
        };
        break;
    }

    // --- 7. Transfer of control --------------------------------------------
    // From this point on no firmware service may be used, the firmware
    // console is detached and only the serial port is used.
    out.disableFirmware();
    out.printLine("[VNB] leaving firmware, entering kernel at 0x{x}", .{kernel_entry});
    jumpToKernel(handoff_address, kernel_entry);
}

/// Transfers control to the kernel entry point.
///
/// The System V AMD64 ABI passes the first integer argument in `RDI`, which
/// is where the kernel expects the address of the handoff structure.
fn jumpToKernel(handoff_address: u64, entry: u64) noreturn {
    asm volatile (
        \\cli
        \\mov %[handoff], %%rdi
        \\mov %[entry], %%rax
        \\jmp *%%rax
        :
        : [handoff] "{rdi}" (handoff_address),
          [entry] "{rax}" (entry),
        : .{ .memory = true });
    unreachable;
}
