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
const composition = @import("composition.zig");

/// Number of polls of the non-blocking input probe. The automated input
/// test sends the key after the `input probe ready` marker; the limit is
/// long enough for the monitor round trip and short enough for the boot
/// test, which sends no key.
const input_poll_attempts: u32 = 200_000;

/// Dimensões do quadro composto pelo processo. O buffer é local e
/// pertence à pilha da aplicação; o kernel não conhece janelas, apenas o
/// retângulo validado que recebe em `present`. O quadro é pequeno para
/// caber nas duas páginas de pilha do modo usuário.
const composition_width: u32 = 32;
const composition_height: u32 = 24;
const composition_background: u32 = 0x00202020;
const composition_windows = [_]composition.Window{
    .{ .x = 0, .y = 0, .width = 20, .height = 16, .color = 0x00606060 },
    .{ .x = 12, .y = 8, .width = 20, .height = 16, .color = 0x00C0C0C0 },
    .{ .x = 2, .y = 2, .width = 4, .height = 4, .color = 0x00F0F0F0 },
};

/// Limite da espera pela tecla Q que libera o screenshot. O teste de boot
/// envia Q depois de capturar o quadro; um boot manual sem Q termina a
/// espera e continua, em vez de bloquear a máquina para sempre.
const composition_hold_attempts: u32 = 20_000_000;

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
    var interactive_requested = false;
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
        if (pressed and !extended and event.code == 0x17) {
            interactive_requested = true;
            break;
        }

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

    // F6.28: compõe um quadro no buffer da própria aplicação e o apresenta
    // como um único retângulo validado. O kernel não recebe a lista de
    // janelas nem um mapeamento do framebuffer. O teste de boot captura o
    // screenshot enquanto a aplicação espera a tecla Q; o teste interativo
    // já viu I e não entra na espera.
    if (presentable) {
        if (!presentComposition(present_format)) sdk.exit(11);
        if (!interactive_requested) holdComposition();
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

/// Compõe o quadro e o apresenta. O checksum é calculado sobre o buffer
/// visível e publicado no serial; o teste de boot compara o mesmo valor
/// com o screenshot P6 capturado pelo QEMU.
fn presentComposition(pixel_format: u32) bool {
    var frame: [composition_width * composition_height]u32 = undefined;
    var surface = composition.Surface.init(
        &frame,
        composition_width,
        composition_height,
        composition_width,
    ) catch return false;

    surface.compose(composition_background, &composition_windows);
    const hash = surface.checksum();

    var request: sdk.display.PresentRequest = .{
        .version = sdk.display.present_version,
        .x = 0,
        .y = 0,
        .width = composition_width,
        .height = composition_height,
        .stride = composition_width * 4,
        .pixel_format = pixel_format,
        .buffer = @intFromPtr(&frame),
        .length = @sizeOf(@TypeOf(frame)),
    };
    const status = sdk.present(&request);
    if (sdk.syscall.isError(status) or status != 0) return false;

    writeCompositionMarker(hash);
    return true;
}

/// Publica o checksum do quadro composto sem depender de formatador.
fn writeCompositionMarker(hash: u64) void {
    const prefix = "composition ready frame=32x24 at=0,0 checksum=0x";
    var buffer: [prefix.len + 17]u8 = undefined;
    @memcpy(buffer[0..prefix.len], prefix);

    var shift: u6 = 60;
    var index: usize = prefix.len;
    while (true) {
        const nibble: u8 = @intCast((hash >> shift) & 0xf);
        buffer[index] = "0123456789abcdef"[nibble];
        index += 1;
        if (shift == 0) break;
        shift -= 4;
    }
    buffer[index] = '\n';
    _ = sdk.write(buffer[0 .. index + 1]);
}

/// Espera a tecla Q que libera o screenshot do teste de boot.
fn holdComposition() void {
    var event: sdk.input.InputEvent = .{};
    var attempts: u32 = 0;
    while (attempts < composition_hold_attempts) : (attempts += 1) {
        const status = sdk.inputPoll(&event);
        if (sdk.syscall.isError(status)) return;
        if (status == 0) continue;
        if (status != 1) return;
        sdk.input.validate(&event) catch continue;

        const pressed = (event.flags & sdk.input.flag_pressed) != 0;
        const extended = (event.flags & sdk.input.flag_extended) != 0;
        if (pressed and !extended and event.code == 0x10) {
            _ = sdk.write("composition released\n");
            return;
        }
    }
    _ = sdk.write("composition timeout\n");
}
