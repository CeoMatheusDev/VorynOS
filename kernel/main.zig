// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! Voryn Nucleus Kernel (VNK) - early bring-up.
//!
//! This is the first code that runs with the kernel image resident in
//! physical memory. It validates the boot handoff contract, reports what the
//! firmware handed over and proves that the framebuffer described by the
//! contract is actually writable.
//!
//! Everything that follows (GDT, IDT, exceptions, memory management, the
//! scheduler) is built on top of the guarantees established here.

const std = @import("std");
const voryn = @import("voryn_shared");

const handoff = voryn.handoff;
const memmap = voryn.memmap;
const port = voryn.port;
const serial = voryn.serial;

/// Version of the kernel, reported on the console.
const kernel_version = "0.1.0-dev.1";

/// Address of the kernel entry point, provided by the assembly trampoline.
extern const voryn_kernel_entry_address: u64;

/// Kernel entry point, called by the assembly trampoline.
///
/// `boot` points to the handoff structure that the loader filled in.
export fn voryn_kmain(boot: *const handoff.BootHandoff) callconv(.c) noreturn {
    serial.init();

    serial.printLine("[VNK] Voryn Nucleus Kernel {s}", .{kernel_version});

    handoff.validate(boot) catch |err| {
        serial.printLine("[VNK] FATAL: invalid handoff: {s}", .{@errorName(err)});
        port.haltForever();
    };

    serial.printLine("[VNK] handoff ok: version={d} flags=0x{x}", .{
        boot.version,
        boot.flags,
    });

    // The entry point the loader used has to match the one of this image,
    // otherwise the kernel is not running where the contract says it is.
    if (voryn_kernel_entry_address != boot.kernel_entry) {
        serial.printLine("[VNK] FATAL: entry mismatch: image=0x{x} handoff=0x{x}", .{
            voryn_kernel_entry_address,
            boot.kernel_entry,
        });
        port.haltForever();
    }

    serial.printLine("[VNK] kernel: base=0x{x} end=0x{x} entry=0x{x}", .{
        boot.kernel_base,
        boot.kernel_end,
        boot.kernel_entry,
    });

    reportMemory(boot);
    reportFramebuffer(boot);

    // Sentinel consumed by the automated boot test.
    serial.printLine("VORYN-KERNEL-READY", .{});

    port.haltForever();
}

/// Reports the memory map that the firmware handed over.
fn reportMemory(boot: *const handoff.BootHandoff) void {
    if (boot.memory_map_entries == 0) {
        serial.printLine("[VNK] memory: no map provided", .{});
        return;
    }

    if (boot.memory_map_address >= handoff.identity_mapped_limit) {
        serial.printLine("[VNK] memory: map at 0x{x} is not identity mapped", .{boot.memory_map_address});
        return;
    }

    const map = @as([*]const handoff.MemoryDescriptor, @ptrFromInt(boot.memory_map_address))[0..boot.memory_map_entries];
    const summary = memmap.summarize(map);

    serial.printLine("[VNK] memory: {d} regions, {d} MiB RAM", .{
        summary.entries,
        summary.total_ram / (1024 * 1024),
    });

    // The largest region that is not ordinary RAM is usually the hole of
    // the address space reserved for the PCI bus, it is reported so that a
    // reader does not mistake it for usable memory.
    var largest: ?handoff.MemoryDescriptor = null;
    for (map) |descriptor| {
        if (descriptor.isUsableRam()) continue;
        if (largest == null or descriptor.byteSize() > largest.?.byteSize()) {
            largest = descriptor;
        }
    }
    if (largest) |descriptor| {
        serial.printLine("[VNK] memory: largest reserved region is {s}, {d} MiB at 0x{x}", .{
            descriptor.memory_type.name(),
            descriptor.byteSize() / (1024 * 1024),
            descriptor.physical_start,
        });
    }

    // The kernel image itself has to be covered by ordinary RAM.
    if (!memmap.isUsableRange(map, boot.kernel_base, boot.kernel_end - boot.kernel_base)) {
        serial.printLine("[VNK] FATAL: kernel image is not backed by RAM", .{});
        port.haltForever();
    }
}

/// Reports the framebuffer and verifies that it can be written.
fn reportFramebuffer(boot: *const handoff.BootHandoff) void {
    if (boot.flags & handoff.flag_framebuffer == 0) {
        serial.printLine("[VNK] framebuffer: none", .{});
        return;
    }

    const framebuffer = boot.framebuffer;
    serial.printLine("[VNK] framebuffer: {d}x{d} bpp={d} pitch={d} base=0x{x}", .{
        framebuffer.width,
        framebuffer.height,
        framebuffer.bits_per_pixel,
        framebuffer.pitch,
        framebuffer.base,
    });

    if (framebuffer.base == 0 or framebuffer.size < 4) return;
    if (framebuffer.base >= handoff.identity_mapped_limit) {
        serial.printLine("[VNK] framebuffer: above the identity mapped range, not probed", .{});
        return;
    }

    // Only probe the framebuffer when the memory map does not report it as
    // ordinary RAM: a stray write into free memory would corrupt the heap
    // of the kernel that is about to be built.
    if (boot.memory_map_entries != 0 and boot.memory_map_address < handoff.identity_mapped_limit) {
        const map = @as([*]const handoff.MemoryDescriptor, @ptrFromInt(boot.memory_map_address))[0..boot.memory_map_entries];
        if (memmap.findRegion(map, framebuffer.base)) |region| {
            if (region.isUsableRam()) {
                serial.printLine("[VNK] framebuffer: reported as RAM, not probed", .{});
                return;
            }
        }
    }

    // Write a known value into the first pixel and read it back.
    const pixel: *volatile u32 = @ptrFromInt(framebuffer.base);
    const original = pixel.*;
    pixel.* = 0x00C0_FFEE;
    const readback = pixel.*;
    pixel.* = original;

    if (readback == 0x00C0_FFEE) {
        serial.printLine("[VNK] framebuffer: write probe succeeded", .{});
    } else {
        serial.printLine("[VNK] framebuffer: write probe failed (readback=0x{x})", .{readback});
    }
}
