/**************************************************************************/
/*  fatimg.zig                                                            */
/**************************************************************************/
/*                         This file is part of:                          */
/*                               VorynOS                                  */
/*              https://github.com/CeoMatheusDev/VorynOS                  */
/**************************************************************************/
/* Copyright (C) 2026 VorynOS contributors.                               */
/*                                                                        */
/* SPDX-License-Identifier: GPL-3.0-only                                  */
/**************************************************************************/

//! VorynOS boot image builder.
//!
//! Builds a bootable EFI system partition image that contains the Voryn
//! Native Boot loader and the Voryn Nucleus Kernel:
//!
//! ```text
//! /EFI/BOOT/BOOTX64.EFI    the UEFI loader
//! /boot/voryn-kernel.elf   the kernel image
//! ```
//!
//! The image is a FAT16 volume, written from scratch so that the build and
//! the test pipeline does not depend on external disk tools. The tool is a
//! development utility, the image format is *not* a VorynOS native format:
//! it only exists to feed the firmware with a boot volume.
//!
//! Usage:
//!
//! ```text
//! voryn-fsimg --output=<path> --efi=<path> --kernel=<path>
//! ```

const std = @import("std");

/// Size of a sector in bytes.
const bytes_per_sector = 512;
/// Number of sectors per cluster.
const sectors_per_cluster = 8;
/// Size of a cluster in bytes.
const cluster_size = bytes_per_sector * sectors_per_cluster;
/// Number of reserved sectors at the beginning of the volume.
const reserved_sectors = 1;
/// Number of copies of the file allocation table.
const fat_count = 2;
/// Number of entries in the root directory.
const root_entries = 512;
/// Number of sectors occupied by the root directory.
const root_dir_sectors = (root_entries * 32 + bytes_per_sector - 1) / bytes_per_sector;
/// Total size of the generated image.
const image_size = 64 * 1024 * 1024;
/// Total number of sectors of the generated image.
const image_sectors = image_size / bytes_per_sector;
/// OEM name written into the BIOS parameter block.
const oem_name = "VORYNOS ";
/// Volume label written into the BIOS parameter block.
const volume_label = "VORYNOS    ";
/// Media descriptor of a fixed disk.
const media_descriptor: u8 = 0xF8;
/// Directory attribute of a FAT directory entry.
const attribute_directory: u8 = 0x10;
/// Read only attribute of a FAT directory entry.
const attribute_read_only: u8 = 0x01;

/// Errors reported by the image builder.
const BuildError = error{
    /// The image is too small for the requested content.
    ImageTooSmall,
    /// The volume ran out of clusters.
    OutOfClusters,
    /// A file name does not fit into a FAT directory entry.
    InvalidFileName,
};

/// A file that has to be placed in the image.
const SourceFile = struct {
    /// Directory entry name, padded to eleven bytes.
    name: [11]u8,
    /// Content of the file.
    data: []const u8,
};

/// The FAT16 writer.
const FatImage = struct {
    /// The complete image.
    bytes: []u8,
    /// Number of sectors occupied by one copy of the file allocation table.
    fat_sectors: u32 = 0,
    /// First sector of the data area.
    data_start_sector: u32 = 0,
    /// Number of clusters that the data area can hold.
    cluster_count: u32 = 0,
    /// Next cluster that will be handed out.
    next_cluster: u32 = 2,

    fn init(bytes: []u8) BuildError!FatImage {
        if (bytes.len < image_size) return error.ImageTooSmall;

        var fat_sectors: u32 = 64;
        var cluster_count: u32 = 0;
        var iterations: u8 = 0;
        while (iterations < 16) : (iterations += 1) {
            const data_sectors = image_sectors - reserved_sectors - root_dir_sectors - fat_count * fat_sectors;
            cluster_count = data_sectors / sectors_per_cluster;
            const required = ((cluster_count + 2) * 2 + bytes_per_sector - 1) / bytes_per_sector;
            if (required == fat_sectors) break;
            fat_sectors = required;
        }

        const data_start = reserved_sectors + fat_count * fat_sectors + root_dir_sectors;

        var image: FatImage = .{
            .bytes = bytes,
            .fat_sectors = fat_sectors,
            .data_start_sector = data_start,
            .cluster_count = cluster_count,
        };

        image.writeBootRecord();
        image.writeFatHeaders();
        return image;
    }

    /// Writes the BIOS parameter block and the boot signature.
    fn writeBootRecord(self: *FatImage) void {
        const bpb = self.bytes[0..bytes_per_sector];

        @memset(bpb, 0);

        bpb[0] = 0xEB; // jmp short
        bpb[1] = 0x3C;
        bpb[2] = 0x90;
        @memcpy(bpb[3..11], oem_name);

        std.mem.writeInt(u16, bpb[11..13], bytes_per_sector, .little);
        bpb[13] = sectors_per_cluster;
        std.mem.writeInt(u16, bpb[14..16], reserved_sectors, .little);
        bpb[16] = fat_count;
        std.mem.writeInt(u16, bpb[17..19], root_entries, .little);
        // The volume is larger than 65535 sectors, the 16 bit field has to be
        // zero and the 32 bit field carries the real size.
        std.mem.writeInt(u16, bpb[19..21], 0, .little);
        bpb[21] = media_descriptor;
        std.mem.writeInt(u16, bpb[22..24], @intCast(self.fat_sectors), .little);
        std.mem.writeInt(u16, bpb[24..26], 63, .little); // sectors per track
        std.mem.writeInt(u16, bpb[26..28], 255, .little); // number of heads
        std.mem.writeInt(u32, bpb[28..32], 0, .little); // hidden sectors
        std.mem.writeInt(u32, bpb[32..36], image_sectors, .little);
        bpb[36] = 0x80; // drive number
        bpb[38] = 0x29; // extended boot signature
        std.mem.writeInt(u32, bpb[39..43], 0x564F_5259, .little); // volume id
        @memcpy(bpb[43..54], volume_label);
        @memcpy(bpb[54..62], "FAT16   ");

        bpb[510] = 0x55;
        bpb[511] = 0xAA;
    }

    /// Writes the two reserved entries of both copies of the file allocation
    /// table.
    fn writeFatHeaders(self: *FatImage) void {
        for (0..fat_count) |copy| {
            const base = (reserved_sectors + copy * self.fat_sectors) * bytes_per_sector;
            std.mem.writeInt(u16, self.bytes[base..][0..2], 0xFFF8, .little);
            std.mem.writeInt(u16, self.bytes[base + 2 ..][0..2], 0xFFFF, .little);
        }
    }

    /// Writes an entry into every copy of the file allocation table.
    fn setFatEntry(self: *FatImage, cluster: u32, value: u16) void {
        for (0..fat_count) |copy| {
            const base = (reserved_sectors + copy * self.fat_sectors) * bytes_per_sector;
            const offset = base + @as(usize, cluster) * 2;
            std.mem.writeInt(u16, self.bytes[offset..][0..2], value, .little);
        }
    }

    /// Reserves `count` consecutive clusters and returns the first one.
    fn allocateClusters(self: *FatImage, count: u32) BuildError!u32 {
        if (count == 0) return error.OutOfClusters;
        const first = self.next_cluster;
        if (first + count > self.cluster_count + 2) return error.OutOfClusters;

        self.next_cluster += count;
        for (0..count - 1) |index| {
            self.setFatEntry(first + @as(u32, @intCast(index)), @intCast(first + @as(u32, @intCast(index)) + 1));
        }
        self.setFatEntry(first + count - 1, 0xFFFF);

        return first;
    }

    /// Writes `data` into the cluster chain that starts at `first_cluster`.
    fn writeClusterData(self: *FatImage, first_cluster: u32, data: []const u8) void {
        var offset: usize = 0;
        var cluster = first_cluster;

        while (offset < data.len) {
            const sector = self.data_start_sector + (cluster - 2) * sectors_per_cluster;
            const destination = self.bytes[@as(usize, sector) * bytes_per_sector ..];
            const chunk = @min(cluster_size, data.len - offset);
            @memcpy(destination[0..chunk], data[offset..][0..chunk]);
            // The remainder of the cluster has to be zeroed.
            @memset(destination[chunk..cluster_size], 0);

            offset += chunk;
            cluster += 1;
        }
    }

    /// Writes a directory into a freshly allocated cluster.
    fn writeDirectory(self: *FatImage, entries: []const DirectoryEntry) BuildError!u32 {
        const first = try self.allocateClusters(1);

        var buffer: [cluster_size]u8 = @splat(0);
        for (entries, 0..) |entry, index| {
            const offset = index * 32;
            if (offset + 32 > buffer.len) break;
            writeDirectoryEntry(buffer[offset..][0..32], entry);
        }

        self.writeClusterData(first, &buffer);
        return first;
    }
};

/// A directory entry of the FAT file system.
const DirectoryEntry = struct {
    /// Name, padded to eleven bytes.
    name: [11]u8,
    /// Attributes.
    attributes: u8 = attribute_read_only,
    /// First cluster of the file, zero for an empty file.
    first_cluster: u16 = 0,
    /// Size of the file in bytes.
    size: u32 = 0,
};

/// Writes a directory entry into `destination`.
fn writeDirectoryEntry(destination: []u8, entry: DirectoryEntry) void {
    @memset(destination, 0);
    @memcpy(destination[0..11], &entry.name);
    destination[11] = entry.attributes;
    std.mem.writeInt(u16, destination[14..16], 0, .little); // creation time
    std.mem.writeInt(u16, destination[16..18], 0x4C21, .little); // creation date
    std.mem.writeInt(u16, destination[18..20], 0x4C21, .little); // last access date
    std.mem.writeInt(u16, destination[20..22], 0, .little); // high cluster
    std.mem.writeInt(u16, destination[22..24], 0x4C21, .little); // write time
    std.mem.writeInt(u16, destination[24..26], 0x4C21, .little); // write date
    std.mem.writeInt(u16, destination[26..28], entry.first_cluster, .little);
    std.mem.writeInt(u32, destination[28..32], entry.size, .little);
}

/// Builds a padded FAT name from a base name and an extension.
fn fatName(base: []const u8, extension: []const u8) BuildError![11]u8 {
    var name: [11]u8 = @splat(' ');
    if (base.len > 8 or extension.len > 3) return error.InvalidFileName;
    @memcpy(name[0..base.len], base);
    @memcpy(name[8 .. 8 + extension.len], extension);
    return name;
}

/// Parses the command line.
const Options = struct {
    output: []const u8,
    efi: []const u8,
    kernel: []const u8,
};

/// Reads the options from the process arguments.
fn parseOptions(init: std.process.Init) !Options {
    var output: ?[]const u8 = null;
    var efi: ?[]const u8 = null;
    var kernel: ?[]const u8 = null;

    var arguments = init.minimal.args.iterate();
    _ = arguments.skip(); // program name

    while (arguments.next()) |argument| {
        if (std.mem.startsWith(u8, argument, "--output=")) {
            output = argument["--output=".len..];
        } else if (std.mem.startsWith(u8, argument, "--efi=")) {
            efi = argument["--efi=".len..];
        } else if (std.mem.startsWith(u8, argument, "--kernel=")) {
            kernel = argument["--kernel=".len..];
        } else {
            std.log.err("unknown argument: {s}", .{argument});
            return error.InvalidArgument;
        }
    }

    return .{
        .output = output orelse return error.MissingOutput,
        .efi = efi orelse return error.MissingEfi,
        .kernel = kernel orelse return error.MissingKernel,
    };
}

/// Entry point of the image builder.
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const options = parseOptions(init) catch |err| {
        std.log.err(
            "usage: voryn-fsimg --output=<path> --efi=<path> --kernel=<path>",
            .{},
        );
        return err;
    };

    const directory = std.Io.Dir.cwd();

    const efi_data = try directory.readFileAlloc(init.io, options.efi, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(efi_data);
    const kernel_data = try directory.readFileAlloc(init.io, options.kernel, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(kernel_data);

    const image = try allocator.alloc(u8, image_size);
    defer allocator.free(image);

    // The image is written from scratch, every byte that is not filled with
    // meaningful content has to be zero: the firmware and the file system
    // drivers read the unused areas of the allocation tables.
    @memset(image, 0);

    var fat = try FatImage.init(image);

    // The files that go into the image.
    const sources = [_]SourceFile{
        .{ .name = try fatName("BOOTX64", "EFI"), .data = efi_data },
        .{ .name = try fatName("VORYNK", "ELF"), .data = kernel_data },
    };

    // /EFI/BOOT holds the loader, /boot holds the kernel.
    const boot_directory_entries = [_]DirectoryEntry{
        .{
            .name = try fatName("BOOTX64", "EFI"),
            .attributes = attribute_read_only,
            .first_cluster = 0, // filled in below
            .size = @intCast(efi_data.len),
        },
    };
    const kernel_directory_entries = [_]DirectoryEntry{
        .{
            .name = try fatName("VORYNK", "ELF"),
            .attributes = attribute_read_only,
            .first_cluster = 0, // filled in below
            .size = @intCast(kernel_data.len),
        },
    };

    // Allocate the clusters of the data files first so that the directory
    // entries can reference them.
    var file_clusters: [sources.len]u32 = undefined;
    for (sources, 0..) |source, index| {
        const clusters = (@as(usize, source.data.len) + cluster_size - 1) / cluster_size;
        file_clusters[index] = try fat.allocateClusters(@intCast(clusters));
        fat.writeClusterData(file_clusters[index], source.data);
    }

    // The directories /EFI/BOOT and /boot.
    var boot_entries = boot_directory_entries;
    boot_entries[0].first_cluster = @intCast(file_clusters[0]);
    const boot_directory_cluster = try fat.writeDirectory(&boot_entries);

    var kernel_entries = kernel_directory_entries;
    kernel_entries[0].first_cluster = @intCast(file_clusters[1]);
    const kernel_directory_cluster = try fat.writeDirectory(&kernel_entries);

    // The directory /EFI, which contains /EFI/BOOT.
    const efi_entries = [_]DirectoryEntry{
        .{
            .name = try fatName("BOOT", ""),
            .attributes = attribute_directory,
            .first_cluster = @intCast(boot_directory_cluster),
        },
    };
    const efi_directory_cluster = try fat.writeDirectory(&efi_entries);

    // The root directory contains /EFI and /boot.
    const root_entries_data = [_]DirectoryEntry{
        .{
            .name = try fatName("EFI", ""),
            .attributes = attribute_directory,
            .first_cluster = @intCast(efi_directory_cluster),
        },
        .{
            .name = try fatName("boot", ""),
            .attributes = attribute_directory,
            .first_cluster = @intCast(kernel_directory_cluster),
        },
    };

    const root_sector = reserved_sectors + fat_count * fat.fat_sectors;
    const root_start = @as(usize, root_sector) * bytes_per_sector;
    for (root_entries_data, 0..) |entry, index| {
        writeDirectoryEntry(image[root_start + index * 32 ..][0..32], entry);
    }

    try directory.writeFile(init.io, .{ .sub_path = options.output, .data = image });

    std.log.info(
        "wrote {s}: {d} MiB, {d} clusters, FAT at sector {d}, data at sector {d}",
        .{
            options.output,
            image_size / (1024 * 1024),
            fat.cluster_count,
            reserved_sectors,
            fat.data_start_sector,
        },
    );
}
