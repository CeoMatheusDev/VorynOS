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

/// Dimensões do quadro composto pelo processo. A superfície fica na página
/// que o kernel mapeia abaixo da janela do compositor; o cliente escreve
/// nela por `copy_to`, sem receber a página no próprio espaço.
const composition_width: u32 = sdk.compositor.surface_width;
const composition_height: u32 = sdk.compositor.surface_height;
const composition_stride: u32 = sdk.compositor.surface_stride;
const composition_background: u32 = 0x00202020;

/// Espera máxima pela mensagem do cliente, em ticks do timer. O cliente é
/// criado depois do compositor; a espera bloqueia a tarefa e o escalonador
/// executa o cliente, que envia o quadro.
const client_receive_ticks: u64 = 1000;
const composition_windows = [_]composition.Window{
    .{ .x = 0, .y = 0, .width = 20, .height = 16, .color = 0x00606060 },
    .{ .x = 12, .y = 8, .width = 20, .height = 16, .color = 0x00C0C0C0 },
    .{ .x = 2, .y = 2, .width = 4, .height = 4, .color = 0x00F0F0F0 },
};

/// Limite da espera pela tecla Q que libera o screenshot. O teste de boot
/// envia Q depois de capturar o quadro; um boot manual sem Q termina a
/// espera e continua, em vez de bloquear a máquina para sempre.
const composition_hold_attempts: u32 = 20_000_000;

export fn voryn_user_main(window_base: u64, role: u64) noreturn {
    _ = role;

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
        if (!presentComposition(window_base, present_format)) sdk.exit(11);
        if (!interactive_requested) holdComposition();
    }

    // F4/F5: exercita syscalls de arquivo pelo SDK, sem acesso ao kernel.
    const fd = sdk.fsOpen("/apps/hello.txt", 0);
    if (sdk.syscall.isError(fd)) sdk.exit(3);
    var data: [7]u8 = undefined;
    const count = sdk.fsRead(fd, &data);
    if (sdk.syscall.isError(count) or count != data.len) sdk.exit(4);
    if (sdk.fsClose(fd) != 0) sdk.exit(5);

    // M0.3.16: prova real da syscall 22 a partir de ring 3.
    // Cria um arquivo isolado, escreve, encolhe, reabre e confere os bytes.
    const truncate_fd = sdk.fsCreate("/apps/truncate-probe.txt");
    if (sdk.syscall.isError(truncate_fd)) sdk.exit(20);
    if (sdk.fsWrite(truncate_fd, "abcdef") != 6) sdk.exit(21);
    if (sdk.fsTruncate(truncate_fd, 3) != 0) sdk.exit(22);
    // A syscall não altera o offset de escrita já avançado.
    if (sdk.fsClose(truncate_fd) != 0) sdk.exit(23);

    const read_fd = sdk.fsOpen("/apps/truncate-probe.txt", 0);
    if (sdk.syscall.isError(read_fd)) sdk.exit(24);
    // A abertura somente-leitura não pode truncar.
    const denied = sdk.fsTruncate(read_fd, 0);
    if (!sdk.syscall.isError(denied)) sdk.exit(25);
    var truncated: [8]u8 = undefined;
    const truncated_count = sdk.fsRead(read_fd, &truncated);
    if (truncated_count != 3 or
        truncated[0] != 'a' or truncated[1] != 'b' or truncated[2] != 'c')
    {
        sdk.exit(26);
    }
    if (sdk.fsClose(read_fd) != 0) sdk.exit(27);
    _ = sdk.write("fs truncate user probe ok\n");

    const message = "toolchain ELF\n";
    const result = sdk.write(message);
    sdk.exit(if (sdk.syscall.isError(result)) 1 else 0);
}

/// Compõe o quadro na superfície do compositor e espera a janela do
/// cliente. O checksum final é calculado sobre a superfície visível e
/// publicado no serial; o teste de boot compara o mesmo valor com o
/// screenshot P6 capturado pelo QEMU.
fn presentComposition(window_base: u64, pixel_format: u32) bool {
    if (window_base <= sdk.compositor.surface_below) return false;
    const surface_address = window_base - sdk.compositor.surface_below;
    const pixels: [*]u32 = @ptrFromInt(@as(usize, @intCast(surface_address)));
    var surface = composition.Surface.init(
        pixels[0..@as(usize, composition_width) * composition_height],
        composition_width,
        composition_height,
        composition_stride,
    ) catch return false;

    surface.compose(composition_background, &composition_windows);
    if (!presentSurface(&surface, surface_address, pixel_format)) return false;

    if (!receiveClientFrame(&surface, surface_address, pixel_format)) return false;

    const hash = surface.checksum();
    writeCompositionMarker(hash);
    return true;
}

/// Apresenta a superfície inteira como um único retângulo validado.
fn presentSurface(surface: *const composition.Surface, address: u64, pixel_format: u32) bool {
    _ = surface;
    var request: sdk.display.PresentRequest = .{
        .version = sdk.display.present_version,
        .x = 0,
        .y = 0,
        .width = composition_width,
        .height = composition_height,
        .stride = composition_stride * 4,
        .pixel_format = pixel_format,
        .buffer = address,
        .length = sdk.compositor.surface_size,
    };
    const status = sdk.present(&request);
    return !sdk.syscall.isError(status) and status == 0;
}

/// Espera o posicionamento da janela e depois o aviso de quadro pronto do
/// cliente. O cliente primeiro comunica a geometria da janela (kind
/// window_place_kind) e depois copia os pixels e envia frame_ready_kind. O
/// compositor valida a geometria, apresenta a superfície e publica o
/// checksum do quadro visível.
fn receiveClientFrame(surface: *const composition.Surface, address: u64, pixel_format: u32) bool {
    // Primeiro espera o posicionamento da janela enviado pelo cliente.
    const placement = sdk.receiveTimeout(
        sdk.compositor.channel_id,
        sdk.compositor.compositor_side,
        client_receive_ticks,
    );
    if (sdk.syscall.isError(placement.status)) {
        if (sdk.syscall.errorCode(placement.status) == @intFromEnum(sdk.syscall.Error.timeout)) {
            _ = sdk.write("window placement timeout\n");
        } else {
            _ = sdk.write("window placement error\n");
        }
        return false;
    }
    if (placement.status != sdk.compositor.window_place_kind) {
        _ = sdk.write("window placement invalid\n");
        return false;
    }

    const geometry = sdk.compositor.unpackWindow(placement.value);
    // Verifica se a geometria cabe na superfície antes de continuar.
    if (!sdk.compositor.validWindow(geometry, composition_width, composition_height))
    {
        _ = sdk.write("window geometry invalid\n");
        return false;
    }

    // Depois espera o aviso de quadro pronto.
    const result = sdk.receiveTimeout(
        sdk.compositor.channel_id,
        sdk.compositor.compositor_side,
        client_receive_ticks,
    );
    if (sdk.syscall.isError(result.status)) {
        if (sdk.syscall.errorCode(result.status) == @intFromEnum(sdk.syscall.Error.timeout)) {
            _ = sdk.write("client frame timeout\n");
        } else {
            _ = sdk.write("client frame error\n");
        }
        return false;
    }
    if (result.status != sdk.compositor.frame_ready_kind) {
        _ = sdk.write("client frame invalid\n");
        return false;
    }

    // The client sends the hash of its declared rectangle. Verify the
    // actual pixels received through copy_to before trusting FRAME1.
    const received_hash = surface.checksumRegion(
        geometry.x, geometry.y, geometry.width, geometry.height,
    ) orelse return false;
    if (received_hash != result.value) {
        _ = sdk.write("client frame checksum mismatch\n");
        return false;
    }
    if (!presentSurface(surface, address, pixel_format)) return false;
    const hash = surface.checksum();
    writeCompositionMarker(hash);
    return true;
}

/// Publica o checksum do quadro composto sem depender de formatador.
fn writeCompositionMarker(hash: u64) void {
    writeHashMarker("composition ready frame=32x24 at=0,0 checksum=0x", hash);
}

/// Publica o checksum da janela que o cliente copiou.
fn writeClientMarker(hash: u64) void {
    writeHashMarker("client frame copied checksum=0x", hash);
}

/// Escreve um prefixo seguido de dezesseis dígitos hexadecimais.
fn writeHashMarker(prefix: []const u8, hash: u64) void {
    var buffer: [96]u8 = undefined;
    if (prefix.len + 17 > buffer.len) return;
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
