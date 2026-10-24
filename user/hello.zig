//************************************************************************//
//  hello.zig                                                             //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only

//! Aplicação ELF64 nativa usando a interface pública do SDK VorynOS.
const sdk = @import("voryn_sdk");

export fn _start() noreturn {
    // Smoke test da ABI antes de usar o console.
    if (sdk.ping() != 0x42) sdk.exit(2);

    // F6.25/F6.26: consulta a metadata e apresenta um retângulo de pixels
    // sem receber acesso ao MMIO do framebuffer.
    var display_info: sdk.display.DisplayInfo = .{};
    const info_status = sdk.displayInfo(&display_info);
    if (sdk.syscall.isError(info_status)) {
        if (sdk.syscall.errorCode(info_status) != @intFromEnum(sdk.syscall.Error.no_display)) {
            sdk.exit(6);
        }
        _ = sdk.write("display unavailable\n");
    } else {
        if (info_status != @sizeOf(sdk.display.DisplayInfo)) sdk.exit(7);
        if (display_info.version != sdk.display.info_version or
            display_info.width == 0 or
            display_info.height == 0)
        {
            sdk.exit(8);
        }
        _ = sdk.write("display metadata\n");

        if (display_info.bits_per_pixel == 32 and
            display_info.width >= 16 and
            display_info.height >= 16 and
            (display_info.pixel_format == sdk.display.pixel_format_rgb32 or
                display_info.pixel_format == sdk.display.pixel_format_bgr32))
        {
            const pattern: [256]u32 = @splat(0x000000FF);
            var request: sdk.display.PresentRequest = .{
                .version = sdk.display.present_version,
                .x = 0,
                .y = 0,
                .width = 16,
                .height = 16,
                .stride = 16 * 4,
                .pixel_format = display_info.pixel_format,
                .buffer = @intFromPtr(&pattern),
                .length = @sizeOf(@TypeOf(pattern)),
            };
            const present_status = sdk.present(&request);
            if (sdk.syscall.isError(present_status) or present_status != 0) sdk.exit(9);
            _ = sdk.write("display present\n");
        }
    }

    // F4/F5: exercita syscalls de arquivo pelo SDK, sem acesso ao kernel.
    const fd = sdk.fsOpen("/apps/hello.txt", 0);
    if (sdk.syscall.isError(fd)) sdk.exit(3);
    var data: [7]u8 = undefined;
    const count = sdk.fsRead(fd, &data);
    if (sdk.syscall.isError(count) or count != data.len) sdk.exit(4);
    if (sdk.fsClose(fd) != 0) sdk.exit(5);
    const message = "toolchain ELF\n";
    const result = sdk.write(message);
    sdk.exit(if (sdk.syscall.isError(result)) 1 else 0);
}
