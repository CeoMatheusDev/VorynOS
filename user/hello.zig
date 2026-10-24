//************************************************************************//
//  hello.zig                                                             //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Aplicação ELF64 nativa usando a interface pública do SDK VorynOS.
const sdk = @import("voryn_sdk");

/// Number of polls of the non-blocking input probe. The automated input
/// test sends the key after the `input probe ready` marker; the limit is
/// long enough for the monitor round trip and short enough for the boot
/// test, which sends no key.
const input_poll_attempts: u32 = 200_000;

export fn _start() noreturn {
    // Smoke test da ABI antes de usar o console.
    if (sdk.ping() != 0x42) sdk.exit(2);

    // F6.25/F6.26: consulta a metadata e apresenta um retângulo de pixels
    // sem receber acesso ao MMIO do framebuffer.
    const pattern: [256]u32 = @splat(0x000000FF);
    var display_info: sdk.display.DisplayInfo = .{};
    const info_status = sdk.displayInfo(&display_info);
    var presentable = false;
    var present_width: u32 = 0;
    var present_format: u32 = sdk.display.pixel_format_unknown;
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
            presentable = true;
            present_width = display_info.width;
            present_format = display_info.pixel_format;
            var request: sdk.display.PresentRequest = .{
                .version = sdk.display.present_version,
                .x = 0,
                .y = 0,
                .width = 16,
                .height = 16,
                .stride = 16 * 4,
                .pixel_format = present_format,
                .buffer = @intFromPtr(&pattern),
                .length = @sizeOf(@TypeOf(pattern)),
            };
            const present_status = sdk.present(&request);
            if (sdk.syscall.isError(present_status) or present_status != 0) sdk.exit(9);
            _ = sdk.write("display present\n");
        }
    }

    // F6.27: retira um evento da fila do serviço gráfico. A chamada não
    // bloqueia; o teste automatizado envia a seta direita depois do
    // marcador. Sem tecla, o laço termina e o boot continua.
    _ = sdk.write("input probe ready\n");
    var event: sdk.input.InputEvent = .{};
    var input_seen = false;
    var attempts: u32 = 0;
    while (attempts < input_poll_attempts) : (attempts += 1) {
        const status = sdk.inputPoll(&event);
        if (sdk.syscall.isError(status)) {
            const code = sdk.syscall.errorCode(status) orelse 0;
            if (code == @intFromEnum(sdk.syscall.Error.no_input) or
                code == @intFromEnum(sdk.syscall.Error.not_authorized))
            {
                _ = sdk.write("input unavailable\n");
            } else {
                _ = sdk.write("input error\n");
            }
            break;
        }
        if (status == 0) continue;
        if (status != 1) {
            _ = sdk.write("input invalid\n");
            break;
        }
        sdk.input.validate(&event) catch {
            _ = sdk.write("input invalid\n");
            break;
        };
        const pressed = (event.flags & sdk.input.flag_pressed) != 0;
        const extended = (event.flags & sdk.input.flag_extended) != 0;

        // The I key selects the kernel interactive mode. The kernel already
        // has its own copy in the diagnostic queue; the probe leaves the
        // user copy here instead of spending the whole poll budget.
        if (pressed and !extended and event.code == 0x17) break;

        if (!pressed or !extended or event.code != 0x4d) continue;

        _ = sdk.write("input event scancode=0x4d pressed=1 extended=1\n");
        if (presentable and present_width >= 32) {
            var request: sdk.display.PresentRequest = .{
                .version = sdk.display.present_version,
                .x = 16,
                .y = 0,
                .width = 16,
                .height = 16,
                .stride = 16 * 4,
                .pixel_format = present_format,
                .buffer = @intFromPtr(&pattern),
                .length = @sizeOf(@TypeOf(pattern)),
            };
            const present_status = sdk.present(&request);
            if (sdk.syscall.isError(present_status) or present_status != 0) sdk.exit(10);
            _ = sdk.write("input present x=16 y=0\n");
        }
        input_seen = true;
        break;
    }
    if (!input_seen) _ = sdk.write("input timeout\n");

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
