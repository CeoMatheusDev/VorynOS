//************************************************************************//
//  cpu.zig                                                               //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! x86_64 processor control.
//!
//! Access to control registers, model specific registers and the CPU
//! identification instructions. The functions are the low level primitives
//! used by the segment, paging and timer subsystems.

const std = @import("std");

/// Reads the `CR0` control register.
pub fn readCr0() u64 {
    var value: u64 = undefined;
    asm volatile ("movq %%cr0, %[value]"
        : [value] "=r" (value),
    );
    return value;
}

/// Writes the `CR0` control register.
pub fn writeCr0(value: u64) void {
    asm volatile ("movq %[value], %%cr0"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// Reads the `CR2` control register, which holds the address that caused a
/// page fault.
pub fn readCr2() u64 {
    var value: u64 = undefined;
    asm volatile ("movq %%cr2, %[value]"
        : [value] "=r" (value),
    );
    return value;
}

/// Reads the `CR3` control register, which holds the physical address of the
/// root page table.
pub fn readCr3() u64 {
    var value: u64 = undefined;
    asm volatile ("movq %%cr3, %[value]"
        : [value] "=r" (value),
    );
    return value;
}

/// Writes the `CR3` control register, switching the active address space.
///
/// The argument must be the physical address of a level 4 page table whose
/// physical address is stored in the low bits of the register.
pub fn writeCr3(value: u64) void {
    asm volatile ("movq %[value], %%cr3"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// Reads the `CR4` control register.
pub fn readCr4() u64 {
    var value: u64 = undefined;
    asm volatile ("movq %%cr4, %[value]"
        : [value] "=r" (value),
    );
    return value;
}

/// Writes the `CR4` control register.
pub fn writeCr4(value: u64) void {
    asm volatile ("movq %[value], %%cr4"
        :
        : [value] "r" (value),
        : .{ .memory = true });
}

/// Invalidates the TLB entry that maps the given virtual address.
///
/// The instruction is privileged and the host unit tests never execute it.
/// The assembly function exists in the image of the kernel; a host build
/// resolves the call to a no-op, so that the modules that describe the
/// tables can still be tested on the host.
pub fn invlpg(address: u64) void {
    if (comptime @import("builtin").os.tag == .freestanding) {
        voryn_invlpg(address);
    }
}

extern fn voryn_invlpg(address: u64) void;

/// Executes the `CPUID` instruction.
pub fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = leaf;
    var ebx: u32 = subleaf;
    var ecx: u32 = 0;
    var edx: u32 = 0;

    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ebx}" (subleaf),
        : .{ .cc = true });

    return .{ eax, ebx, ecx, edx };
}

/// Reads a model specific register.
pub fn readMsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;

    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
    );

    return (@as(u64, high) << 32) | low;
}

/// Writes a model specific register.
pub fn writeMsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);

    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (low),
          [high] "{edx}" (high),
          [msr] "{ecx}" (msr),
        : .{ .memory = true });
}

/// The model specific register of the extended features of the processor.
pub const msr_efer: u32 = 0xC000_0080;

/// The bit of `EFER` that enables the no-execute bit of the page tables.
pub const efer_nxe: u64 = 1 << 11;

/// Reads the extended features register.
pub fn readEfer() u64 {
    return readMsr(msr_efer);
}

/// Writes the extended features register.
pub fn writeEfer(value: u64) void {
    writeMsr(msr_efer, value);
}

/// True when the processor reports the no-execute feature.
///
/// `CPUID` leaf `0x8000_0001` reports the feature in bit 20 of `EDX`. The
/// extended leaf is only valid when the processor reports a maximum leaf of
/// at least `0x8000_0001`.
pub fn supportsNoExecute() bool {
    const extended = cpuid(0x8000_0000, 0);
    if (extended[0] < 0x8000_0001) return false;

    const features = cpuid(0x8000_0001, 0);
    return (features[3] & (1 << 20)) != 0;
}

/// Enables the no-execute bit of the page tables.
///
/// The bit of the page table entry is reserved until `EFER.NXE` is set, and
/// a reserved bit raises a page fault. The function returns false when the
/// processor does not support the feature, and leaves the register alone in
/// that case.
pub fn enableNoExecute() bool {
    if (!supportsNoExecute()) return false;

    const efer = readEfer();
    if ((efer & efer_nxe) == 0) {
        writeEfer(efer | efer_nxe);
    }

    // The register is read again: a write that the processor ignored would
    // otherwise leave the kernel believing that the feature is on, and the
    // first data page would fault.
    return (readEfer() & efer_nxe) != 0;
}

/// Enables interrupts by setting the interrupt enable flag.
pub fn enableInterrupts() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

/// Disables interrupts by clearing the interrupt enable flag.
pub fn disableInterrupts() void {
    asm volatile ("cli" ::: .{ .memory = true });
}

/// Halts the processor until the next interrupt.
pub fn halt() void {
    asm volatile ("hlt" ::: .{ .memory = true });
}

/// The control word of the x87 unit.
var control_word: u16 = 0x037F;

/// The control and the status words of the unit.
var status_word: u32 = 0x1F80;

/// Prepares the processor for the use of the floating point unit.
///
/// The firmware leaves the coprocessor disabled, and an attempt to execute a
/// floating point instruction raises a coprocessor error. The kernel enables
/// the unit, the state of the registers is saved by the processor and the
/// exceptions of the unit are masked.
pub fn enableFloatingPoint() void {
    // The coprocessor is usable: the bit that reports it as unavailable is
    // cleared, and the bit that makes the processor check the state of the
    // task before every use is set.
    //
    // The bit of the alignment mask is cleared as well: with the bit set,
    // an access that is not aligned raises the exception of the alignment
    // check, and the user mode can ask for it with the flag of the flags.
    // The kernel does not use that exception, and a stack frame that the
    // compiler aligns is not worth an exception that moves the frame.
    var cr0 = readCr0();
    cr0 &= ~(@as(u64, 1) << 2);
    cr0 |= @as(u64, 1) << 1;
    cr0 &= ~(@as(u64, 1) << 18);
    writeCr0(cr0);

    // The state of the unit is saved by the processor and the exceptions of
    // the unit are reported to the kernel.
    var cr4 = readCr4();
    cr4 |= (1 << 9) | (1 << 10);
    writeCr4(cr4);

    // Every exception of the unit is masked. The control word is given in
    // memory, because the instruction has no immediate form. The words live
    // in the data of the kernel, so that they have a fixed address.
    control_word = 0x037F;
    asm volatile ("fldcw %[control]"
        :
        : [control] "m" (control_word),
        : .{ .memory = true });

    // The control and the status words of the unit.
    status_word = 0x1F80;
    asm volatile ("ldmxcsr %[status]"
        :
        : [status] "m" (status_word),
        : .{ .memory = true });
}

/// Information about the processor, collected with `CPUID`.
pub const ProcessorInfo = struct {
    /// Family, model and stepping of the processor.
    family: u8,
    model: u8,
    stepping: u8,
    /// Brand string, when the processor provides one.
    brand: [48]u8,
    /// Number of logical processors in the package.
    logical_processors: u32,
    /// Physical address width in bits.
    physical_address_bits: u32,
    /// Linear address width in bits.
    linear_address_bits: u32,
    /// True when the processor reports the `invariant TSC` feature.
    invariant_tsc: bool,
};

/// Collects the information about the processor.
///
/// The brand string is read from the extended leaves `0x80000002` to
/// `0x80000004`; a processor that does not implement them returns zeros.
pub fn detectProcessor() ProcessorInfo {
    const family_id = cpuid(1, 0);
    const extended = cpuid(0x8000_0000, 0);

    var info: ProcessorInfo = .{
        .family = 0,
        .model = 0,
        .stepping = 0,
        .brand = @splat(0),
        .logical_processors = 1,
        .physical_address_bits = 0,
        .linear_address_bits = 0,
        .invariant_tsc = false,
    };

    const base_family = @as(u8, @truncate(family_id[0] >> 8));
    const base_model = @as(u8, @truncate(family_id[0] >> 4));
    const extended_family = @as(u8, @truncate(family_id[0] >> 20));
    const extended_model = @as(u8, @truncate(family_id[0] >> 16));

    info.stepping = @truncate(family_id[0]);
    info.family = if (base_family == 0xF) base_family + extended_family else base_family;
    info.model = if (base_family == 0x6 or base_family == 0xF) base_family + extended_model else base_model;

    const features = cpuid(1, 0);
    info.logical_processors = @as(u32, @truncate((features[1] >> 16) & 0xFF)) + 1;

    const address_sizes = cpuid(0x8000_0008, 0);
    info.physical_address_bits = @as(u32, @truncate(address_sizes[0] & 0xFF));
    info.linear_address_bits = @as(u32, @truncate((address_sizes[0] >> 8) & 0xFF));

    const power = cpuid(0x8000_0007, 0);
    info.invariant_tsc = (power[3] & (1 << 8)) != 0;

    if (extended[0] >= 0x8000_0004) {
        var brand: [48]u8 = @splat(0);
        var leaf: u32 = 0x8000_0002;
        var offset: usize = 0;
        while (leaf <= 0x8000_0004) : (leaf += 1) {
            const registers = cpuid(leaf, 0);
            inline for (registers) |register| {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, register, .little);
                for (bytes) |byte| {
                    if (offset < brand.len) {
                        brand[offset] = byte;
                        offset += 1;
                    }
                }
            }
        }
        info.brand = brand;
    }

    return info;
}
