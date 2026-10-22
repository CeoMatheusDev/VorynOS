/**************************************************************************/
/*  elf64.zig                                                             */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               VorynOS                                  */
/*              https://github.com/CeoMatheusDev/VorynOS                  */
/**************************************************************************/
/* Copyright (C) 2026 VorynOS contributors.                               */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

//! Minimal ELF64 reader used by the Voryn Native Boot loader.
//!
//! The loader needs to validate and place a kernel image, therefore this
//! module implements the subset of the ELF specification that is required
//! for that: the file header, the program header table, the `PT_LOAD`
//! segments, the dynamic section and the relative relocations of a
//! position independent image.
//!
//! Everything here is pure and bounds checked, so it can be unit tested on
//! the host with arbitrary (including hostile) inputs.
//!
//! See `docs/specs/boot-handoff-spec.md` for how the loaded image is handed
//! over to the kernel.

const std = @import("std");
const memmap = @import("memmap.zig");

/// The four magic bytes at the start of every ELF file.
pub const magic = [4]u8{ 0x7f, 'E', 'L', 'F' };

/// `EI_CLASS` value for 64 bit objects.
pub const class_64: u8 = 2;
/// `EI_DATA` value for little endian objects.
pub const data_lsb: u8 = 1;
/// `EI_VERSION` value, current ELF version.
pub const version_current: u8 = 1;
/// `e_machine` value for x86-64.
pub const machine_x86_64: u16 = 62;
/// `e_type` value for a non-relocatable executable.
pub const type_exec: u16 = 2;
/// `e_type` value for a position independent executable.
pub const type_dyn: u16 = 3;
/// Program header type for a loadable segment.
pub const pt_load: u32 = 1;
/// Program header type for the dynamic section.
pub const pt_dynamic: u32 = 2;

/// Segment flag: executable.
pub const pf_x: u32 = 1;
/// Segment flag: writable.
pub const pf_w: u32 = 2;
/// Segment flag: readable.
pub const pf_r: u32 = 4;

/// Dynamic section tags used by the loader.
pub const DynamicTag = struct {
    pub const none: u64 = 0;
    pub const rela: u64 = 7;
    pub const rela_size: u64 = 8;
    pub const rela_entry_size: u64 = 9;
    pub const rel: u64 = 17;
    pub const rel_size: u64 = 18;
    pub const rel_entry_size: u64 = 19;
};

/// Relocation type of a relative relocation on x86-64.
pub const r_x86_64_relative: u32 = 8;

/// The ELF64 file header.
pub const Ehdr = extern struct {
    ident: [16]u8 = @splat(0),
    type: u16 = 0,
    machine: u16 = 0,
    version: u32 = 0,
    entry: u64 = 0,
    program_header_offset: u64 = 0,
    section_header_offset: u64 = 0,
    flags: u32 = 0,
    header_size: u16 = 0,
    program_header_entry_size: u16 = 0,
    program_header_count: u16 = 0,
    section_header_entry_size: u16 = 0,
    section_header_count: u16 = 0,
    section_name_index: u16 = 0,
};

/// The ELF64 program header.
pub const Phdr = extern struct {
    type: u32 = 0,
    flags: u32 = 0,
    offset: u64 = 0,
    virtual_address: u64 = 0,
    physical_address: u64 = 0,
    file_size: u64 = 0,
    memory_size: u64 = 0,
    alignment: u64 = 0,
};

/// The ELF64 dynamic section entry.
pub const Dyn = extern struct {
    tag: u64 = 0,
    value: u64 = 0,
};

/// The ELF64 relocation entry with an explicit addend.
pub const Rela = extern struct {
    offset: u64 = 0,
    info: u64 = 0,
    addend: i64 = 0,
};

/// Errors reported while validating an ELF64 image.
pub const ParseError = error{
    /// The file is too small to contain an ELF64 header.
    TruncatedHeader,
    /// The magic bytes do not match.
    BadMagic,
    /// The file is not a 64 bit object.
    Not64Bit,
    /// The file is not little endian.
    NotLittleEndian,
    /// The ELF version is not supported.
    BadVersion,
    /// The machine type is not x86-64.
    WrongMachine,
    /// The object type is neither `ET_EXEC` nor `ET_DYN`.
    WrongType,
    /// The program header table is not usable.
    BadProgramHeaders,
    /// A program header describes a region outside of the file.
    SegmentOutOfBounds,
    /// A segment has a memory size smaller than its file size.
    BadSegmentSize,
    /// A segment requests a page alignment that is not a power of two.
    BadSegmentAlignment,
    /// The image does not contain a single loadable segment.
    NoLoadableSegment,
    /// The image contains more segments than the caller can hold.
    TooManySegments,
    /// The image entry point is not inside any loadable segment.
    EntryOutsideSegments,
    /// The image overlaps a region that is not ordinary RAM.
    SegmentNotBackedByRam,
    /// The dynamic section of the image is not usable.
    BadDynamicSection,
    /// The image contains more relocations than the caller can hold.
    TooManyRelocations,
    /// The image uses a relocation type the loader does not implement.
    UnsupportedRelocation,
};

/// A validated loadable segment.
pub const Segment = struct {
    /// Virtual address the segment is linked at.
    virtual_address: u64,
    /// Physical address the segment is linked at, only meaningful for a
    /// non relocatable image.
    physical_address: u64,
    /// Offset of the segment content inside the file.
    file_offset: u64,
    /// Number of bytes present in the file.
    file_size: u64,
    /// Number of bytes the segment occupies in memory.
    memory_size: u64,
    /// Segment flags, see `pf_*`.
    flags: u32,
    /// Alignment requirement of the segment.
    alignment: u64,

    /// True when the segment requests execute access.
    pub fn isExecutable(self: Segment) bool {
        return self.flags & pf_x != 0;
    }
};

/// A relative relocation of the image.
pub const Relocation = struct {
    /// Address the relocation applies to, relative to the load bias.
    offset: u64,
    /// Value the relocated word is set to, relative to the load bias.
    addend: i64,
};

/// The result of validating an ELF64 image.
pub const Image = struct {
    /// Entry point of the image, relative to the load bias.
    entry: u64,
    /// Loadable segments, in the order they appear in the file.
    segments: []const Segment,
    /// Relative relocations that have to be applied after loading.
    relocations: []const Relocation,
    /// Lowest address occupied by the image, relative to the load bias.
    base: u64,
    /// Highest address occupied by the image, relative to the load bias.
    end: u64,
    /// True when the image can be loaded at an arbitrary address.
    relocatable: bool,

    /// True when the image contains an executable segment.
    pub fn isExecutable(self: Image) bool {
        for (self.segments) |segment| {
            if (segment.isExecutable()) return true;
        }
        return false;
    }

    /// Size of the image in bytes.
    pub fn size(self: Image) u64 {
        return self.end - self.base;
    }
};

/// Reads the file header of `bytes` and validates the fields the loader
/// depends on. The program header table is not read yet.
pub fn readHeader(bytes: []const u8) ParseError!Ehdr {
    if (bytes.len < @sizeOf(Ehdr)) return error.TruncatedHeader;

    var header: Ehdr = undefined;
    @memcpy(std.mem.asBytes(&header), bytes[0..@sizeOf(Ehdr)]);

    if (!std.mem.eql(u8, header.ident[0..4], &magic)) return error.BadMagic;
    if (header.ident[4] != class_64) return error.Not64Bit;
    if (header.ident[5] != data_lsb) return error.NotLittleEndian;
    if (header.ident[6] != version_current) return error.BadVersion;
    if (header.version != 1) return error.BadVersion;
    if (header.machine != machine_x86_64) return error.WrongMachine;
    if (header.type != type_exec and header.type != type_dyn) return error.WrongType;
    if (header.program_header_entry_size != @sizeOf(Phdr)) return error.BadProgramHeaders;
    if (header.program_header_count == 0) return error.BadProgramHeaders;

    return header;
}

/// Validates the ELF64 image stored in `bytes` and returns the loadable
/// segments together with the address range they occupy.
///
/// The segment list is written into `segment_buffer` and the relocation list
/// into `relocation_buffer`, which keeps the module free of heap
/// allocations and therefore usable from the bootloader.
pub fn parse(
    bytes: []const u8,
    segment_buffer: []Segment,
    relocation_buffer: []Relocation,
) ParseError!Image {
    const header = try readHeader(bytes);

    const table_bytes = std.math.mul(u64, header.program_header_count, @sizeOf(Phdr)) catch
        return error.BadProgramHeaders;
    const table_end = std.math.add(u64, header.program_header_offset, table_bytes) catch
        return error.BadProgramHeaders;
    if (table_end > bytes.len) return error.BadProgramHeaders;

    var segment_count: usize = 0;
    var base: ?u64 = null;
    var end: ?u64 = null;
    var dynamic: ?Phdr = null;

    var index: u16 = 0;
    while (index < header.program_header_count) : (index += 1) {
        const offset = header.program_header_offset + @as(u64, index) * @sizeOf(Phdr);
        var phdr: Phdr = undefined;
        @memcpy(std.mem.asBytes(&phdr), bytes[@intCast(offset)..][0..@sizeOf(Phdr)]);

        if (phdr.type == pt_dynamic) {
            dynamic = phdr;
            continue;
        }

        if (phdr.type != pt_load) continue;

        if (phdr.memory_size < phdr.file_size) return error.BadSegmentSize;
        if (phdr.alignment != 0 and !std.math.isPowerOfTwo(phdr.alignment)) return error.BadSegmentAlignment;

        const file_end = std.math.add(u64, phdr.offset, phdr.file_size) catch
            return error.SegmentOutOfBounds;
        if (file_end > bytes.len) return error.SegmentOutOfBounds;

        const segment: Segment = .{
            .virtual_address = phdr.virtual_address,
            .physical_address = phdr.physical_address,
            .file_offset = phdr.offset,
            .file_size = phdr.file_size,
            .memory_size = phdr.memory_size,
            .flags = phdr.flags,
            .alignment = phdr.alignment,
        };

        if (base == null or segment.virtual_address < base.?) base = segment.virtual_address;
        const segment_end = std.math.add(u64, segment.virtual_address, segment.memory_size) catch
            return error.SegmentOutOfBounds;
        if (end == null or segment_end > end.?) end = segment_end;

        if (segment_count >= segment_buffer.len) return error.TooManySegments;
        segment_buffer[segment_count] = segment;
        segment_count += 1;
    }

    if (segment_count == 0) return error.NoLoadableSegment;

    var relocation_count: usize = 0;
    if (dynamic) |phdr| {
        relocation_count = try collectRelocations(
            bytes,
            phdr,
            segment_buffer[0..segment_count],
            relocation_buffer,
        );
    }

    const image: Image = .{
        .entry = header.entry,
        .segments = segment_buffer[0..segment_count],
        .relocations = relocation_buffer[0..relocation_count],
        .base = base.?,
        .end = end.?,
        .relocatable = header.type == type_dyn,
    };

    if (!entryIsInsideSegments(image)) return error.EntryOutsideSegments;

    return image;
}

/// Collects the relative relocations of the dynamic section.
///
/// Only `R_X86_64_RELATIVE` relocations are supported, they are the ones a
/// position independent executable needs to be placed at an arbitrary
/// address.
fn collectRelocations(
    bytes: []const u8,
    dynamic: Phdr,
    segments: []const Segment,
    relocation_buffer: []Relocation,
) ParseError!usize {
    const section_end = std.math.add(u64, dynamic.offset, dynamic.file_size) catch
        return error.BadDynamicSection;
    if (section_end > bytes.len) return error.BadDynamicSection;

    var rela_address: ?u64 = null;
    var rela_size: u64 = 0;

    var offset: u64 = 0;
    while (offset + @sizeOf(Dyn) <= dynamic.file_size) : (offset += @sizeOf(Dyn)) {
        var entry: Dyn = undefined;
        @memcpy(std.mem.asBytes(&entry), bytes[@intCast(dynamic.offset + offset)..][0..@sizeOf(Dyn)]);

        switch (entry.tag) {
            DynamicTag.none => break,
            DynamicTag.rela => rela_address = entry.value,
            DynamicTag.rela_size => rela_size = entry.value,
            else => {},
        }
    }

    if (rela_address == null) return 0;
    if (rela_size == 0) return 0;
    if (rela_size % @sizeOf(Rela) != 0) return error.BadDynamicSection;

    const count = rela_size / @sizeOf(Rela);
    if (count > relocation_buffer.len) return error.TooManyRelocations;

    // The relocation table lives inside a loadable segment, the address of
    // the table is a virtual address that has to be translated into an
    // offset of the file.
    var segment_offset: ?u64 = null;
    for (segments) |segment| {
        if (rela_address.? >= segment.virtual_address and
            rela_address.? < segment.virtual_address + segment.file_size)
        {
            segment_offset = segment.file_offset + (rela_address.? - segment.virtual_address);
            break;
        }
    }

    const table_offset = segment_offset orelse return error.BadDynamicSection;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const entry_offset = table_offset + index * @sizeOf(Rela);
        if (entry_offset + @sizeOf(Rela) > bytes.len) return error.BadDynamicSection;

        var rela: Rela = undefined;
        @memcpy(std.mem.asBytes(&rela), bytes[@intCast(entry_offset)..][0..@sizeOf(Rela)]);

        const relocation_type: u32 = @truncate(rela.info);
        if (relocation_type != r_x86_64_relative) return error.UnsupportedRelocation;

        relocation_buffer[index] = .{
            .offset = rela.offset,
            .addend = rela.addend,
        };
    }

    return count;
}

/// Returns true when the entry point of `image` lies inside one of its
/// loadable segments.
pub fn entryIsInsideSegments(image: Image) bool {
    for (image.segments) |segment| {
        if (image.entry >= segment.virtual_address and
            image.entry < segment.virtual_address + segment.file_size) return true;
    }
    return false;
}

/// Validates the ELF64 image in `bytes` and additionally requires that every
/// segment is backed by ordinary RAM according to `map`.
///
/// The map describes the machine, therefore the check is only meaningful for
/// an image that is loaded at a fixed address. A relocatable image is checked
/// by the loader, after the load address has been chosen.
pub fn planLoad(
    bytes: []const u8,
    map: []const memmap.MemoryDescriptor,
    segment_buffer: []Segment,
    relocation_buffer: []Relocation,
) ParseError!Image {
    const image = try parse(bytes, segment_buffer, relocation_buffer);

    if (image.relocatable) return image;

    for (image.segments) |segment| {
        if (segment.memory_size == 0) continue;
        if (!memmap.isUsableRange(map, segment.physical_address, segment.memory_size)) {
            return error.SegmentNotBackedByRam;
        }
    }

    return image;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a minimal but valid ELF64 image in `buffer` and returns it.
fn buildTestImage(buffer: []u8, entry: u64, segment_address: u64) ![]const u8 {
    if (buffer.len < 1024) return error.BufferTooSmall;
    @memset(buffer, 0);

    const header: Ehdr = .{
        .ident = .{ 0x7f, 'E', 'L', 'F', class_64, data_lsb, version_current } ++
            [_]u8{0}**9,
        .type = type_exec,
        .machine = machine_x86_64,
        .version = 1,
        .entry = entry,
        .program_header_offset = @sizeOf(Ehdr),
        .header_size = @sizeOf(Ehdr),
        .program_header_entry_size = @sizeOf(Phdr),
        .program_header_count = 1,
    };
    @memcpy(buffer[0..@sizeOf(Ehdr)], std.mem.asBytes(&header));

    const phdr: Phdr = .{
        .type = pt_load,
        .flags = pf_r | pf_x,
        .offset = 0x1000,
        .physical_address = segment_address,
        .virtual_address = segment_address,
        .file_size = 16,
        .memory_size = 4096,
        .alignment = 0x1000,
    };
    @memcpy(buffer[@sizeOf(Ehdr)..][0..@sizeOf(Phdr)], std.mem.asBytes(&phdr));

    @memset(buffer[0x1000..0x1000 + 16], 0xCC);
    return buffer[0..0x1000 + 16];
}

test "parse accepts a well formed image" {
    var buffer: [4096]u8 = undefined;
    const bytes = try buildTestImage(&buffer, 0x1000000 + 0x1000, 0x1000000);

    var segments: [8]Segment = undefined;
    var relocations: [8]Relocation = undefined;
    const image = try parse(bytes, &segments, &relocations);

    try testing.expectEqual(@as(u64, 0x1000000 + 0x1000), image.entry);
    try testing.expectEqual(@as(u64, 0x1000000), image.base);
    try testing.expectEqual(@as(u64, 0x1000000 + 4096), image.end);
    try testing.expectEqual(@as(usize, 1), image.segments.len);
    try testing.expect(image.isExecutable());
    try testing.expect(!image.relocatable);
}

test "readHeader rejects malformed images" {
    var buffer: [4096]u8 = undefined;
    const bytes = try buildTestImage(&buffer, 0x1000000 + 0x1000, 0x1000000);

    var copy: [4096]u8 = undefined;
    @memcpy(&copy, bytes);

    try testing.expectError(error.TruncatedHeader, readHeader(copy[0..32]));

    copy[1] = 'X';
    try testing.expectError(error.BadMagic, readHeader(&copy));

    @memcpy(&copy, bytes);
    copy[4] = 1;
    try testing.expectError(error.Not64Bit, readHeader(&copy));

    @memcpy(&copy, bytes);
    copy[5] = 2;
    try testing.expectError(error.NotLittleEndian, readHeader(&copy));

    @memcpy(&copy, bytes);
    copy[18] = 0; // e_machine low byte
    try testing.expectError(error.WrongMachine, readHeader(&copy));

    @memcpy(&copy, bytes);
    copy[16] = 1; // e_type low byte
    try testing.expectError(error.WrongType, readHeader(&copy));
}

test "parse rejects a segment that escapes the file" {
    var buffer: [4096]u8 = undefined;
    const bytes = try buildTestImage(&buffer, 0x1000000 + 0x1000, 0x1000000);

    var copy: [4096]u8 = undefined;
    @memcpy(&copy, bytes);

    var segments: [8]Segment = undefined;
    var relocations: [8]Relocation = undefined;

    // p_offset is at 0x20 + 8 within the program header.
    const phdr_offset = @sizeOf(Ehdr);
    std.mem.writeInt(u64, copy[phdr_offset + 8 ..][0..8], 0x100000, .little);
    try testing.expectError(error.SegmentOutOfBounds, parse(&copy, &segments, &relocations));
}

test "parse rejects an entry point outside the loadable segments" {
    var buffer: [4096]u8 = undefined;
    const bytes = try buildTestImage(&buffer, 0x1000000 + 0x1000, 0x1000000);

    var copy: [4096]u8 = undefined;
    @memcpy(&copy, bytes);
    std.mem.writeInt(u64, copy[24..32], 0x9000000, .little);

    var segments: [8]Segment = undefined;
    var relocations: [8]Relocation = undefined;
    try testing.expectError(error.EntryOutsideSegments, parse(&copy, &segments, &relocations));
}

test "parse reports more segments than the buffer can hold" {
    var buffer: [4096]u8 = undefined;
    const bytes = try buildTestImage(&buffer, 0x1000000 + 0x1000, 0x1000000);

    var segments: [0]Segment = undefined;
    var relocations: [8]Relocation = undefined;
    try testing.expectError(error.TooManySegments, parse(bytes, &segments, &relocations));
}

test "planLoad requires the segments to be backed by RAM" {
    var buffer: [4096]u8 = undefined;
    const bytes = try buildTestImage(&buffer, 0x1000000 + 0x1000, 0x1000000);

    const map = [_]memmap.MemoryDescriptor{
        .{
            .memory_type = .conventional,
            .physical_start = 0x1000000,
            .page_count = 1,
        },
    };

    var segments: [8]Segment = undefined;
    var relocations: [8]Relocation = undefined;
    const image = try planLoad(bytes, &map, &segments, &relocations);
    try testing.expectEqual(@as(u64, 0x1000000), image.base);

    const bad_map = [_]memmap.MemoryDescriptor{
        .{
            .memory_type = .memory_mapped_io,
            .physical_start = 0x1000000,
            .page_count = 1,
        },
    };
    try testing.expectError(
        error.SegmentNotBackedByRam,
        planLoad(bytes, &bad_map, &segments, &relocations),
    );
}
