//************************************************************************//
//  fs.zig                                                                //
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

//! Access to the boot volume through `EFI_SIMPLE_FILE_SYSTEM_PROTOCOL`.
//!
//! The loader reads the kernel image from the volume it was loaded from. The
//! firmware takes care of the actual file system format (FAT on virtually
//! every current platform), so VorynOS does not need a file system driver in
//! the bootloader. The kernel image is the only file the loader looks for.
//!
//! Every protocol that the loader uses is wrapped in `Protocol`, which
//! detects at runtime whether the firmware prefixes the structure with the
//! `EFI_REVISION` header. The detection matters here: the `EFI_FILE_PROTOCOL`
//! of the tested firmware carries the header, while the Graphics Output
//! Protocol and the Simple Text Output Protocol of the same firmware do not.

const std = @import("std");
const uefi = std.os.uefi;
const voryn = @import("voryn_shared");
const protocols = @import("protocols.zig");

/// The file protocol of the firmware.
const FileProtocol = protocols.Protocol(protocols.FileBody);

/// Errors reported by the file system helpers.
pub const Error = error{
    /// The firmware does not expose the loaded image protocol.
    NoLoadedImage,
    /// The boot device does not expose a simple file system.
    NoFileSystem,
    /// The file system did not return a volume.
    NoVolume,
    /// The requested file does not exist.
    FileNotFound,
    /// The firmware failed to read the file.
    ReadFailed,
    /// The file is larger than the destination buffer.
    FileTooLarge,
    /// The reported file size is not usable.
    BadFileSize,
};

/// Maximum length of a file path, in UTF-16 code units.
const max_path_length = 128;

/// Opens the volume that the loader image was loaded from.
///
/// The device of the loaded image is preferred, because it is the volume the
/// loader itself was read from. When the loaded image protocol does not
/// expose a device handle, the first simple file system of the system is
/// used instead.
pub fn openBootVolume(boot_services: *uefi.tables.BootServices) Error!FileProtocol {
    if (protocols.handleProtocol(boot_services, uefi.handle, &protocols.loaded_image_guid)) |interface| {
        const image = protocols.Protocol(protocols.LoadedImageBody).init(interface);
        if (image.body.device_handle) |device| {
            if (openVolumeOf(boot_services, device)) |volume| {
                return volume;
            }
        }
    }

    // Fallback: any simple file system of the system will do, the kernel
    // image is the only file that is looked for.
    const fs_interface = protocols.locateProtocol(boot_services, &protocols.simple_file_system_guid) orelse
        return error.NoFileSystem;
    const filesystem = protocols.Protocol(protocols.SimpleFileSystemBody).init(fs_interface);

    var volume: *protocols.FileBody = undefined;
    if (filesystem.body.open_volume(filesystem.thisPointer(), &volume) != .success) return error.NoVolume;
    return FileProtocol.init(volume);
}

/// Opens the volume of the simple file system exported by `device`.
fn openVolumeOf(
    boot_services: *uefi.tables.BootServices,
    device: protocols.Handle,
) ?FileProtocol {
    const fs_interface = protocols.handleProtocol(
        boot_services,
        device,
        &protocols.simple_file_system_guid,
    ) orelse return null;
    const filesystem = protocols.Protocol(protocols.SimpleFileSystemBody).init(fs_interface);

    var volume: *protocols.FileBody = undefined;
    if (filesystem.body.open_volume(filesystem.thisPointer(), &volume) != .success) return null;
    return FileProtocol.init(volume);
}

/// Opens a file of the volume for reading.
fn openFile(volume: FileProtocol, path: []const u8) Error!FileProtocol {
    var utf16_path: [max_path_length]u16 = undefined;
    const utf16 = toUefiPath(path, &utf16_path) orelse return error.FileNotFound;

    var file: *protocols.FileBody = undefined;
    const status = volume.body.open(volume.thisPointer(), &file, utf16, protocols.FileOpenMode.read, 0);
    if (status == .not_found) return error.FileNotFound;
    if (status != .success) return error.ReadFailed;

    return FileProtocol.init(file);
}

/// Queries the size of the file at `path` without reading its content.
pub fn queryFileSize(volume: FileProtocol, path: []const u8) Error!usize {
    const file = try openFile(volume, path);
    defer _ = file.body.close(file.thisPointer());

    return fileSize(file);
}

/// Reads the whole content of `path` into `buffer`.
///
/// Returns the number of bytes that were read.
pub fn readFile(volume: FileProtocol, path: []const u8, buffer: []u8) Error!usize {
    const file = try openFile(volume, path);
    defer _ = file.body.close(file.thisPointer());

    const size = try fileSize(file);

    var total: usize = 0;
    while (total < size) {
        const chunk = size - total;
        if (chunk > buffer.len - total) return error.FileTooLarge;

        var read: usize = chunk;
        const destination: [*]u8 = @ptrCast(buffer[total..].ptr);
        const read_status = file.body.read(file.thisPointer(), &read, destination);
        if (read_status != .success) return error.ReadFailed;
        if (read == 0) break;
        total += read;
    }

    return total;
}

/// Queries the size of an open file.
///
/// The `EFI_FILE_INFO` structure describes the file, not its content, so a
/// small buffer is enough. The firmware is asked for the structure directly
/// instead of asking for the required size first, because not every
/// implementation supports a query with a null buffer.
fn fileSize(file: FileProtocol) Error!usize {
    var info: [512]u8 = undefined;
    var size: usize = info.len;
    const status = file.body.get_info(file.thisPointer(), &protocols.file_info_guid, &size, &info);
    if (status != .success) return error.BadFileSize;
    if (size < @sizeOf(u64) * 2) return error.BadFileSize;

    const file_size = std.mem.readInt(u64, info[8..16], .little);
    if (file_size == 0) return error.BadFileSize;
    if (file_size > std.math.maxInt(usize)) return error.BadFileSize;

    return @intCast(file_size);
}

/// Converts an ASCII path such as `\boot\vorynk.elf` into the UTF-16
/// representation used by the firmware, including the terminating zero.
fn toUefiPath(path: []const u8, buffer: *[max_path_length]u16) ?[*:0]const u16 {
    if (path.len == 0 or path.len >= buffer.len - 1) return null;

    for (path, 0..) |byte, index| {
        if (byte > 0x7F) return null;
        buffer[index] = byte;
    }
    buffer[path.len] = 0;
    const encoded: [:0]const u16 = buffer[0..path.len :0];
    return @ptrCast(encoded);
}
