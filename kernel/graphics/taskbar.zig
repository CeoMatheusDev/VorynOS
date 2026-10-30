//************************************************************************//
//  taskbar.zig                                                           //
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

//! F6.31: a barra da shell — o modelo da barra de tarefas do desktop.
//!
//! A barra é a primeira parte da shell que existe. Ela é **modelo**: calcula
//! a geometria dos botões, responde a um ponto e pinta a si mesma em uma
//! superfície. Não lê dispositivos, não aloca e não conhece processos.
//!
//! Duas decisões conscientes:
//!
//!   * **sem texto** — não há fonte no kernel ainda, então cada botão é um
//!     retângulo: o da janela em foco usa a cor ativa, os outros a inativa.
//!     Um botão sem rótulo é feio, mas não é uma mentira sobre o que existe;
//!   * **a barra não é uma janela** — ela não entra no z-order do gerenciador
//!     de janelas nem no compositor. O desktop reserva as linhas de baixo e
//!     pinta a barra por cima, depois das janelas. Assim uma janela nunca
//!     cobre a barra, e a barra nunca disputa foco.
//!
//! O que ainda **não** existe: um driver de mouse. O mapeamento
//! `buttonAt` → foco está implementado e testado no host, mas nenhum
//! dispositivo o alimenta; a troca de foco que roda no boot vem do teclado
//! (ver `window_manager.focusNext`).

const std = @import("std");
const raster = @import("raster.zig");
const wm = @import("window_manager.zig");

/// Máximo de botões que a barra mostra. Janelas além disso continuam
/// existindo e participando do z-order: só não ganham botão.
pub const max_buttons: usize = 8;

/// Largura mínima de um botão, em pixels. Com menos que isso o botão não
/// seria visível e não haveria o que clicar.
pub const min_button_width: usize = 3;

/// Separação entre dois botões, em pixels.
pub const gutter: usize = 1;

pub const Palette = struct {
    /// Cor do fundo da barra.
    bar: [4]u8,
    /// Cor do botão da janela em foco.
    active: [4]u8,
    /// Cor do botão das outras janelas.
    inactive: [4]u8,
};

pub const Button = struct {
    handle: wm.Handle,
    /// Coluna inicial do botão, já sem a calha.
    x: usize,
    width: usize,
};

pub const Bar = struct {
    /// Altura da barra em pixels, medida a partir da última linha.
    height: usize,

    /// Primeira linha do framebuffer que pertence à barra.
    pub fn top(self: Bar, surface_height: usize) usize {
        return surface_height -| self.height;
    }

    /// Área da barra em pixels, com os limites da superfície.
    pub fn area(self: Bar, width: usize, height: usize) usize {
        const rows = @min(self.height, height);
        return rows *| width;
    }

    /// Distribui um botão por janela visível, na ordem do z-order, e devolve
    /// quantos botões caberam.
    ///
    /// As janelas visíveis dividem a largura em partes iguais, com uma calha
    /// entre elas. A divisão igual é ingênua de propósito: uma barra que
    /// dimensiona o botão pelo título precisaria de texto, e não há fonte
    /// ainda. Com mais janelas que `max_buttons`, as primeiras do z-order
    /// ganham botão; as outras continuam existindo e recebendo foco.
    pub fn layout(self: Bar, manager: *const wm.Manager, width: usize, out: *[max_buttons]Button) usize {
        // A altura não muda a distribuição das colunas; o parâmetro fica para
        // que a chamada continue legível no desktop.
        _ = self;
        if (width == 0) return 0;

        var visible: usize = 0;
        for (manager.order[0..manager.count]) |slot_index| {
            if (visible == max_buttons) break;
            const slot = &manager.slots[slot_index];
            if (!slot.occupied or !slot.window.visible) continue;
            visible += 1;
        }
        if (visible == 0) return 0;
        const slot_width = width / visible;
        if (slot_width < min_button_width + gutter) return 0;
        const button_width = slot_width - gutter;

        var count: usize = 0;
        for (manager.order[0..manager.count]) |slot_index| {
            if (count == visible) break;
            const slot = &manager.slots[slot_index];
            if (!slot.occupied or !slot.window.visible) continue;
            out[count] = .{
                .handle = .{ .slot = slot_index, .generation = slot.generation },
                .x = count * slot_width,
                .width = button_width,
            };
            count += 1;
        }
        return count;
    }

    /// A janela cujo botão está sob o ponto, ou `null`.
    ///
    /// Um ponto na calha, acima da barra ou em uma coluna sem botão não
    /// seleciona nada: clicar no vazio não deve mudar o foco.
    pub fn buttonAt(
        self: Bar,
        manager: *const wm.Manager,
        width: usize,
        height: usize,
        x: usize,
        y: usize,
    ) ?wm.Handle {
        if (x >= width or y < self.top(height) or y >= height) return null;
        var buttons: [max_buttons]Button = undefined;
        const count = self.layout(manager, width, &buttons);
        for (buttons[0..count]) |button| {
            if (x >= button.x and x - button.x < button.width) return button.handle;
        }
        return null;
    }

    /// Pinta a barra e os botões. Devolve a área da barra em pixels.
    ///
    /// O retorno conta **pixels cobertos**, não escritas: um botão sobrescreve
    /// o fundo da barra, e somar as duas escritas inflaria o número.
    pub fn paint(self: Bar, surface: *raster.Surface, manager: *const wm.Manager, palette: Palette) usize {
        const first_row = self.top(surface.height);
        if (first_row >= surface.height or self.height == 0) return 0;
        const rows = surface.height - first_row;
        surface.fillRect(0, first_row, surface.width, rows, palette.bar);

        var buttons: [max_buttons]Button = undefined;
        const count = self.layout(manager, surface.width, &buttons);
        const focused = manager.focused;
        for (buttons[0..count]) |button| {
            const active = if (focused) |focus|
                focus.slot == button.handle.slot and focus.generation == button.handle.generation
            else
                false;
            surface.fillRect(button.x, first_row, button.width, rows, if (active) palette.active else palette.inactive);
        }
        return self.area(surface.width, surface.height);
    }
};

const test_palette: Palette = .{
    .bar = .{ 0x10, 0x10, 0x10, 0xff },
    .active = .{ 0x90, 0x90, 0x90, 0xff },
    .inactive = .{ 0x40, 0x40, 0x40, 0xff },
};

fn testManager(visible: usize, invisible: usize) wm.Manager {
    var manager = wm.Manager{};
    for (0..invisible) |_| {
        _ = manager.create(.{ .owner = 9, .x = 0, .y = 0, .width = 1, .height = 1, .visible = false }) catch unreachable;
    }
    for (0..visible) |_| {
        _ = manager.create(.{ .owner = 1, .x = 0, .y = 0, .width = 4, .height = 4 }) catch unreachable;
    }
    return manager;
}

test "layout distributes equal columns and skips invisible windows" {
    const manager = testManager(3, 2);
    const bar: Bar = .{ .height = 4 };
    var buttons: [max_buttons]Button = undefined;
    const count = bar.layout(&manager, 64, &buttons);
    try std.testing.expectEqual(@as(usize, 3), count);
    // 64 / 3 = 21 por coluna, menos 1 de calha.
    try std.testing.expectEqual(@as(usize, 0), buttons[0].x);
    try std.testing.expectEqual(@as(usize, 20), buttons[0].width);
    try std.testing.expectEqual(@as(usize, 21), buttons[1].x);
    try std.testing.expectEqual(@as(usize, 42), buttons[2].x);
    // As duas janelas invisíveis ocupam os primeiros slots e não ganham
    // botão: a ordem dos botões é a do z-order, sem elas.
    try std.testing.expectEqual(@as(u8, 2), buttons[0].handle.slot);
    try std.testing.expectEqual(@as(u8, 4), buttons[2].handle.slot);
}

test "layout caps at max_buttons and refuses a bar too narrow for one button" {
    const manager = testManager(max_buttons + 2, 0);
    const bar: Bar = .{ .height = 4 };
    var buttons: [max_buttons]Button = undefined;
    try std.testing.expectEqual(max_buttons, bar.layout(&manager, 200, &buttons));
    // 200 / 8 = 25 por coluna.
    try std.testing.expectEqual(@as(usize, 25), buttons[1].x);
    // 15 / 8 = 1 por coluna: menos que a calha mais a largura mínima.
    try std.testing.expectEqual(@as(usize, 0), bar.layout(&manager, 15, &buttons));
    try std.testing.expectEqual(@as(usize, 0), bar.layout(&manager, 0, &buttons));
}

test "buttonAt selects the pressed button and ignores the gutter, the bar edge and the area above" {
    const manager = testManager(4, 0);
    const bar: Bar = .{ .height = 6 };
    var buttons: [max_buttons]Button = undefined;
    const count = bar.layout(&manager, 64, &buttons);
    try std.testing.expectEqual(@as(usize, 4), count);

    for (buttons[0..count], 0..) |button, index| {
        const expected = manager.order[index];
        try std.testing.expectEqual(expected, bar.buttonAt(&manager, 64, 20, button.x, 19).?.slot);
        try std.testing.expectEqual(expected, bar.buttonAt(&manager, 64, 20, button.x + button.width - 1, 14).?.slot);
        // A calha não pertence a botão nenhum.
        try std.testing.expect(bar.buttonAt(&manager, 64, 20, button.x + button.width, 19) == null);
    }
    // Acima da barra é a área das janelas.
    try std.testing.expect(bar.buttonAt(&manager, 64, 20, 0, 13) == null);
    // Uma coluna além do último botão está vazia.
    try std.testing.expect(bar.buttonAt(&manager, 64, 20, 63, 19) == null);
    // Fora da superfície não há botão.
    try std.testing.expect(bar.buttonAt(&manager, 64, 20, 64, 19) == null);
}

test "paint covers only the bar rows and highlights the focused button" {
    const manager = testManager(2, 0);
    const bar: Bar = .{ .height = 4 };
    var pixels: [8 * 8 * 4]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&pixels, 8, 8, 32);
    const pixels_written = bar.paint(&surface, &manager, test_palette);

    // 8 colunas * 4 linhas da barra.
    try std.testing.expectEqual(@as(usize, 32), pixels_written);
    // A última janela criada está em foco: ela é a do último botão.
    const focused = manager.focused.?;
    var buttons: [max_buttons]Button = undefined;
    const count = bar.layout(&manager, 8, &buttons);
    try std.testing.expectEqual(@as(usize, 2), count);
    for (buttons[0..count]) |button| {
        const active = button.handle.slot == focused.slot;
        const expected: [4]u8 = if (active) test_palette.active else test_palette.inactive;
        const offset = 4 * surface.pitch + button.x * 4;
        try std.testing.expectEqualSlices(u8, &expected, pixels[offset..][0..4]);
    }
    // A linha imediatamente acima da barra não foi tocada.
    try std.testing.expectEqual(@as(u8, 0xaa), pixels[3 * surface.pitch]);
}

test "paint clips a bar taller than the surface and draws nothing when hidden" {
    const manager = testManager(1, 0);
    const tall: Bar = .{ .height = 8 };
    var small: [2 * 2 * 4]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&small, 2, 2, 8);
    try std.testing.expectEqual(@as(usize, 4), tall.paint(&surface, &manager, test_palette));
    try std.testing.expectEqualSlices(u8, &test_palette.bar, small[0..4]);

    const none: Bar = .{ .height = 0 };
    var pixels: [2 * 2 * 4]u8 = @splat(0xaa);
    var fresh = try raster.Surface.init(&pixels, 2, 2, 8);
    try std.testing.expectEqual(@as(usize, 0), none.paint(&fresh, &manager, test_palette));
    for (pixels) |byte| try std.testing.expectEqual(@as(u8, 0xaa), byte);
}

test "an empty manager paints the bar background and offers no button" {
    const manager = wm.Manager{};
    const bar: Bar = .{ .height = 2 };
    var pixels: [4 * 4 * 4]u8 = @splat(0xaa);
    var surface = try raster.Surface.init(&pixels, 4, 4, 16);
    try std.testing.expectEqual(@as(usize, 8), bar.paint(&surface, &manager, test_palette));
    try std.testing.expect(bar.buttonAt(&manager, 4, 4, 0, 3) == null);
    try std.testing.expectEqualSlices(u8, &test_palette.bar, pixels[2 * surface.pitch ..][0..4]);
}
