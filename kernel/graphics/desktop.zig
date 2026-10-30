// VorynOS F9: bounded, allocation-free managed desktop scene.
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
//! Builds the boot desktop through the same owner-checked window manager
//! used by input and presentation. No physical memory access occurs here.
const std = @import("std");
const frame_mod = @import("frame.zig");
const bridge = @import("framebuffer_bridge.zig");
const renderer = @import("window_renderer.zig");
const wm = @import("window_manager.zig");
const compositor = @import("compositor.zig");
const taskbar = @import("taskbar.zig");
const cursor_mod = @import("cursor.zig");

comptime {
    // `pointer_input.zig` não é importado por nenhum outro módulo gráfico: é o
    // adaptador entre o dispositivo de ponteiro e o `Frame`, usado por quem
    // tem hardware. Sem esta linha os testes dele ficariam fora do binário —
    // que é exatamente o defeito que esta raiz corrige.
    _ = @import("pointer_input.zig");
}

pub const system_owner: u64 = 1;

/// A shell do desktop: por enquanto, a barra de tarefas.
///
/// A barra é opcional. Um desktop sem shell é exatamente o de antes desta
/// mudança, e é isso que mantém os testes existentes — que comparam a
/// composição incremental com `renderer.render` — válidos sem reescrevê-los.
pub const Shell = struct {
    bar: taskbar.Bar,
    palette: taskbar.Palette,
};

/// O ponteiro do desktop: a posição e as cores da seta.
///
/// O cursor é desenhado **depois** de tudo, inclusive da barra: ele é o que
/// o usuário está movendo, e nada deve cobri-lo.
pub const Pointer = struct {
    cursor: cursor_mod.Cursor,
    palette: cursor_mod.Palette,
};

pub const Desktop = struct {
    frame: frame_mod.Frame,
    back: wm.Handle,
    front: wm.Handle,
    /// `null` até `enableShell` ser chamado.
    shell: ?Shell = null,
    /// `null` até `enablePointer` ser chamado. Um desktop sem ponteiro é o
    /// de antes de F6.32, e é isso que mantém os testes existentes válidos.
    pointer: ?Pointer = null,

    pub fn initInPlace(self: *Desktop, width: usize, height: usize, palette: renderer.Palette) !void {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        self.* = .{ .frame = .{ .palette = palette }, .back = undefined, .front = undefined };
        try self.frame.session_state.registerClient(system_owner);
        self.back = try self.frame.createWindow(system_owner, width / 8, height / 8, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 2));
        self.front = try self.frame.createWindow(system_owner, width / 4, height / 4, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 3));
    }

    pub fn init(width: usize, height: usize, palette: renderer.Palette) !Desktop {
        if (width == 0 or height == 0) return error.InvalidGeometry;
        var desktop: Desktop = undefined;
        // Sem estas linhas os campos opcionais nascem indefinidos, e um
        // desktop sem shell pintaria uma barra de altura arbitrária ou uma
        // seta em posição inventada.
        desktop.shell = null;
        desktop.pointer = null;
        desktop.frame = frame_mod.Frame.init(palette);
        try desktop.frame.session_state.registerClient(system_owner);
        desktop.back = try desktop.frame.createWindow(system_owner, width / 8, height / 8, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 2));
        desktop.front = try desktop.frame.createWindow(system_owner, width / 4, height / 4, @max(@as(usize, 1), width / 2), @max(@as(usize, 1), height / 3));
        return desktop;
    }

    /// Habilita a barra da shell e invalida o quadro: a primeira apresentação
    /// depois desta chamada tem de mostrar a barra.
    pub fn enableShell(self: *Desktop, shell: Shell) void {
        self.shell = shell;
        self.frame.invalidate();
    }

    /// Pinta a barra sobre uma superfície já validada. Zero sem shell.
    pub fn paintShellMapping(self: *Desktop, mapping: bridge.Mapping) bridge.Error!usize {
        const shell = self.shell orelse return 0;
        var surface = try mapping.surface();
        return shell.bar.paint(&surface, &self.frame.session_state.windows, shell.palette);
    }

    /// Liga o ponteiro, posicionado exatamente onde o chamador pedir.
    pub fn enablePointer(self: *Desktop, pointer: Pointer) void {
        self.pointer = pointer;
        self.frame.invalidate();
    }

    /// Move a seta sem passar pelo deslocamento relativo; útil para o boot e
    /// para os testes.
    pub fn placePointer(self: *Desktop, x: usize, y: usize) void {
        if (self.pointer) |*pointer| pointer.cursor = .{ .x = x, .y = y };
        self.frame.invalidate();
    }

    /// Pinta a seta sobre uma superfície já validada. Zero sem ponteiro.
    pub fn paintPointerMapping(self: *Desktop, mapping: bridge.Mapping) bridge.Error!usize {
        const pointer = self.pointer orelse return 0;
        var surface = try mapping.surface();
        return pointer.cursor.paint(&surface, pointer.palette);
    }

    pub fn present(self: *Desktop, mapping: bridge.Mapping) bridge.Error!bool {
        const changed = try bridge.present(&self.frame, mapping);
        // A barra é pintada depois das janelas e mesmo quando o quadro não
        // mudou: ela ocupa linhas que nenhuma janela alcança, e a pintura é o
        // que garante que a primeira apresentação a mostre.
        _ = try self.paintShellMapping(mapping);
        // O ponteiro é o último: nada deve cobri-lo.
        _ = try self.paintPointerMapping(mapping);
        return changed;
    }

    /// Move a seta e repinta somente o que mudou.
    ///
    /// A área da seta antiga é **recomposta** a partir do modelo das janelas
    /// (e da barra) antes de a nova ser desenhada: guardar os pixels antigos
    /// espalharia uma cena que já pode ter mudado. O retorno conta os pixels
    /// escritos na recomposição e no desenho.
    pub fn movePointerAndPresent(self: *Desktop, mapping: bridge.Mapping, dx: i32, dy: i32) bridge.Error!usize {
        var surface = try mapping.surface();
        const pointer = self.pointer orelse return 0;
        const next = pointer.cursor.moved(dx, dy, surface.width, surface.height);
        if (next.x == pointer.cursor.x and next.y == pointer.cursor.y) return 0;

        var pixels: usize = 0;
        pixels +|= self.frame.presentDirty(&surface, pointer.cursor.rect(surface.width, surface.height));
        pixels +|= self.frame.presentDirty(&surface, next.rect(surface.width, surface.height));
        pixels +|= try self.paintShellMapping(mapping);
        self.pointer = .{ .cursor = next, .palette = pointer.palette };
        pixels +|= try self.paintPointerMapping(mapping);
        return pixels;
    }

    /// Passa o foco para a próxima janela visível e repinta o quadro inteiro.
    ///
    /// Trocar o foco muda a cor de duas janelas, então não há recorte parcial
    /// que sirva: a apresentação é completa. A ordem do z-order não muda.
    pub fn cycleFocusAndPresent(self: *Desktop, mapping: bridge.Mapping) bridge.Error!?wm.Handle {
        const next = self.frame.session_state.windows.focusNext() orelse return null;
        self.frame.invalidate();
        _ = try self.present(mapping);
        return next;
    }

    /// Repaint only the old and new front-window footprints. Overlap may be
    /// painted twice; the returned count is framebuffer pixel writes.
    /// A pending full invalidation takes precedence over partial updates.
    pub const StageTiming = struct {
        movement_cycles: u64 = 0,
        composition_cycles: u64 = 0,
        geometry_cycles: u64 = 0,
        paint_cycles: u64 = 0,
    };

    pub fn moveFrontAndPresent(self: *Desktop, mapping: bridge.Mapping, x: usize, y: usize) (bridge.Error || wm.Error)!usize {
        return self.moveFrontAndPresentTimed(mapping, x, y, null, null);
    }

    /// Optional timestamp hook keeps the compositor platform-independent.
    /// Timings cover window state mutation and dirty-region presentation.
    pub fn moveFrontAndPresentTimed(
        self: *Desktop,
        mapping: bridge.Mapping,
        x: usize,
        y: usize,
        clock: ?*const fn () u64,
        timing: ?*StageTiming,
    ) (bridge.Error || wm.Error)!usize {
        if (timing) |result| result.* = .{};
        var surface = try mapping.surface();
        const slot = self.frame.session_state.windows.slots[self.front.slot];
        if (!slot.occupied or slot.generation != self.front.generation) return error.InvalidHandle;
        const previous = slot.window;
        if (previous.x == x and previous.y == y) {
            const changed = if (self.frame.present(&surface)) surface.width *| surface.height else 0;
            return changed +| try self.paintShellMapping(mapping);
        }
        const full_redraw = self.frame.dirty;
        const movement_start: u64 = if (clock) |read| read() else 0;
        try self.moveFront(x, y);
        const movement_end: u64 = if (clock) |read| read() else 0;
        if (timing) |result| result.movement_cycles = movement_end - movement_start;
        const composition_start: u64 = if (clock) |read| read() else 0;
        if (full_redraw) {
            _ = self.frame.present(&surface);
            if (timing) |result| result.composition_cycles = if (clock) |read| read() - composition_start else 0;
            return (surface.width *| surface.height) +| try self.paintShellMapping(mapping);
        }
        const old_rect: compositor.Rect = .{ .x = previous.x, .y = previous.y, .width = previous.width, .height = previous.height };
        const new_rect: compositor.Rect = .{ .x = x, .y = y, .width = previous.width, .height = previous.height };
        // Paint the old footprint excluding its overlap with the new one.
        // The new footprint is painted once, so overlapping pixels are not
        // written twice. Clip before calculating endpoints to avoid overflow.
        const ox = @min(old_rect.x, surface.width);
        const oy = @min(old_rect.y, surface.height);
        const oright = ox + @min(old_rect.width, surface.width - ox);
        const obottom = oy + @min(old_rect.height, surface.height - oy);
        const nx = @min(new_rect.x, surface.width);
        const ny = @min(new_rect.y, surface.height);
        const nright = nx + @min(new_rect.width, surface.width - nx);
        const nbottom = ny + @min(new_rect.height, surface.height - ny);
        const ix = @max(ox, nx);
        const iy = @max(oy, ny);
        const iright = @min(oright, nright);
        const ibottom = @min(obottom, nbottom);
        const paint_start: u64 = if (clock) |read| read() else 0;
        if (timing) |result| result.geometry_cycles = paint_start - composition_start;
        var pixels: usize = 0;
        if (ix < iright and iy < ibottom) {
            pixels +|= self.frame.presentDirty(&surface, .{ .x = ox, .y = oy, .width = oright - ox, .height = iy - oy });
            pixels +|= self.frame.presentDirty(&surface, .{ .x = ox, .y = ibottom, .width = oright - ox, .height = obottom - ibottom });
            pixels +|= self.frame.presentDirty(&surface, .{ .x = ox, .y = iy, .width = ix - ox, .height = ibottom - iy });
            pixels +|= self.frame.presentDirty(&surface, .{ .x = iright, .y = iy, .width = oright - iright, .height = ibottom - iy });
        } else {
            pixels +|= self.frame.presentDirty(&surface, old_rect);
        }
        pixels +|= self.frame.presentDirty(&surface, new_rect);
        self.frame.dirty = false;
        const paint_end: u64 = if (clock) |read| read() else 0;
        if (timing) |result| {
            result.paint_cycles = paint_end - paint_start;
            result.composition_cycles = paint_end - composition_start;
        }
        return pixels +| try self.paintShellMapping(mapping);
    }

    pub fn moveFront(self: *Desktop, x: usize, y: usize) wm.Error!void {
        try self.frame.moveWindow(system_owner, self.front, x, y);
    }
};

test "managed desktop presents, moves and skips unchanged frames" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(8, 8, palette);
    var pixels: [8 * 8 * 4]u8 = @splat(0xaa);
    const mapping: bridge.Mapping = .{
        .bytes = &pixels,
        .width = 8,
        .height = 8,
        .pitch = 32,
        .bits_per_pixel = 32,
    };
    try std.testing.expect(try desktop.present(mapping));
    try std.testing.expect(!(try desktop.present(mapping)));
    try desktop.moveFront(0, 0);
    try std.testing.expect(try desktop.present(mapping));
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, pixels[0..4]);
    try std.testing.expect(!(try desktop.present(mapping)));
}

test "desktop rejects empty geometry and retains dirty state on bad mapping" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    try std.testing.expectError(error.InvalidGeometry, Desktop.init(0, 8, palette));
    var desktop = try Desktop.init(8, 8, palette);
    var short: [4]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooSmall, desktop.present(.{
        .bytes = &short,
        .width = 8,
        .height = 8,
        .pitch = 32,
        .bits_per_pixel = 32,
    }));
    try std.testing.expect(desktop.frame.dirty);
}

test "incremental desktop movement matches full composition and preserves unrelated pixels" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(12, 8, palette);
    var pixels: [12 * 8 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 12, .height = 8, .pitch = 48, .bits_per_pixel = 32 };
    try std.testing.expect(try desktop.present(mapping));
    const untouched = pixels[0];
    const positions = [_][2]usize{ .{ 4, 2 }, .{ 0, 0 }, .{ 10, 7 }, .{ 3, 2 } };
    for (positions) |pos| {
        const count = try desktop.moveFrontAndPresent(mapping, pos[0], pos[1]);
        try std.testing.expect(count <= 2 * 6 * 2 + 2 * 6 * 2);
        var expected: [12 * 8 * 4]u8 = @splat(0);
        var surface = try @import("raster.zig").Surface.init(&expected, 12, 8, 48);
        renderer.render(&surface, &desktop.frame.session_state.windows, palette);
        try std.testing.expectEqualSlices(u8, &expected, &pixels);
    }
    _ = untouched;
}

test "invalid mapping does not move desktop window" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(8, 8, palette);
    var short: [4]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooSmall, desktop.moveFrontAndPresent(.{
        .bytes = &short,
        .width = 8,
        .height = 8,
        .pitch = 32,
        .bits_per_pixel = 32,
    }, 5, 5));
    const slot = desktop.frame.session_state.windows.slots[desktop.front.slot];
    try std.testing.expectEqual(@as(usize, 2), slot.window.x);
}

test "overlapping movement paints each pixel at most once" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    var desktop = try Desktop.init(32, 24, palette);
    var pixels: [32 * 24 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 32, .height = 24, .pitch = 128, .bits_per_pixel = 32 };
    try std.testing.expect(try desktop.present(mapping));
    // Front footprint is 16x8. Moving one pixel horizontally yields
    // a union of 17x8, rather than the former 32x8 writes.
    const writes = try desktop.moveFrontAndPresent(mapping, 9, 6);
    try std.testing.expectEqual(@as(usize, 17 * 8), writes);
    var expected: [32 * 24 * 4]u8 = @splat(0);
    var surface = try @import("raster.zig").Surface.init(&expected, 32, 24, 128);
    renderer.render(&surface, &desktop.frame.session_state.windows, palette);
    try std.testing.expectEqualSlices(u8, &expected, &pixels);
}

test "the shell bar is painted after the windows, only in its own rows" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    const shell_palette: taskbar.Palette = .{
        .bar = .{ 0x10, 0x10, 0x10, 0xff },
        .active = .{ 0x90, 0x90, 0x90, 0xff },
        .inactive = .{ 0x40, 0x40, 0x40, 0xff },
    };
    var desktop = try Desktop.init(8, 8, palette);
    var pixels: [8 * 8 * 4]u8 = @splat(0xaa);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 8, .height = 8, .pitch = 32, .bits_per_pixel = 32 };
    try std.testing.expect(try desktop.present(mapping));
    // Sem shell, a última linha continua sendo a composição das janelas.
    try std.testing.expect(!std.mem.eql(u8, &shell_palette.bar, pixels[7 * 32 ..][0..4]));

    desktop.enableShell(.{ .bar = .{ .height = 2 }, .palette = shell_palette });
    try std.testing.expect(try desktop.present(mapping));
    // As duas últimas linhas são da barra. Na coluna da calha aparece o fundo
    // da barra; na coluna do primeiro botão, a cor do botão por cima dele.
    var buttons: [taskbar.max_buttons]taskbar.Button = undefined;
    const bar: taskbar.Bar = .{ .height = 2 };
    const count = bar.layout(&desktop.frame.session_state.windows, 8, &buttons);
    try std.testing.expectEqual(@as(usize, 2), count);
    const gutter_column = (buttons[0].width) * 4;
    try std.testing.expectEqualSlices(u8, &shell_palette.bar, pixels[6 * 32 + gutter_column ..][0..4]);
    try std.testing.expectEqualSlices(u8, &shell_palette.bar, pixels[7 * 32 + gutter_column ..][0..4]);
    try std.testing.expectEqualSlices(u8, &shell_palette.inactive, pixels[7 * 32 ..][0..4]);
    // A linha imediatamente acima da barra continua sendo das janelas.
    try std.testing.expect(!std.mem.eql(u8, &shell_palette.bar, pixels[5 * 32 ..][0..4]));
    try std.testing.expectEqual(@as(usize, 16), try desktop.paintShellMapping(mapping));
}

test "a window dragged over the bar does not hide it" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    const shell_palette: taskbar.Palette = .{
        .bar = .{ 0x10, 0x10, 0x10, 0xff },
        .active = .{ 0x90, 0x90, 0x90, 0xff },
        .inactive = .{ 0x40, 0x40, 0x40, 0xff },
    };
    var desktop = try Desktop.init(8, 8, palette);
    desktop.enableShell(.{ .bar = .{ .height = 2 }, .palette = shell_palette });
    var pixels: [8 * 8 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 8, .height = 8, .pitch = 32, .bits_per_pixel = 32 };
    try std.testing.expect(try desktop.present(mapping));
    // A janela da frente (4x2) desce e passa a cobrir as linhas 4 e 5.
    _ = try desktop.moveFrontAndPresent(mapping, 0, 4);
    try std.testing.expectEqualSlices(u8, &palette.active, pixels[4 * 32 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &palette.active, pixels[5 * 32 ..][0..4]);
    // A barra continua nas duas últimas linhas: a calha é o fundo da barra,
    // inclusive quando uma janela é arrastada até embaixo.
    var buttons: [taskbar.max_buttons]taskbar.Button = undefined;
    const bar: taskbar.Bar = .{ .height = 2 };
    const count = bar.layout(&desktop.frame.session_state.windows, 8, &buttons);
    try std.testing.expectEqual(@as(usize, 2), count);
    const gutter_column = buttons[0].width * 4;
    try std.testing.expectEqualSlices(u8, &shell_palette.bar, pixels[6 * 32 + gutter_column ..][0..4]);
    try std.testing.expectEqualSlices(u8, &shell_palette.bar, pixels[7 * 32 + gutter_column ..][0..4]);
}

test "cycling the focus repaints both windows and keeps the bar" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    const shell_palette: taskbar.Palette = .{
        .bar = .{ 0x10, 0x10, 0x10, 0xff },
        .active = .{ 0x90, 0x90, 0x90, 0xff },
        .inactive = .{ 0x40, 0x40, 0x40, 0xff },
    };
    var desktop = try Desktop.init(16, 12, palette);
    desktop.enableShell(.{ .bar = .{ .height = 2 }, .palette = shell_palette });
    var pixels: [16 * 12 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 16, .height = 12, .pitch = 64, .bits_per_pixel = 32 };
    try std.testing.expect(try desktop.present(mapping));

    const front = desktop.front;
    try std.testing.expectEqual(front, desktop.frame.session_state.windows.focused.?);
    // A primeira volta devolve a outra janela do desktop e troca as cores.
    const next = (try desktop.cycleFocusAndPresent(mapping)).?;
    try std.testing.expectEqual(desktop.back, next);
    try std.testing.expectEqual(next, desktop.frame.session_state.windows.focused.?);
    const back_window = desktop.frame.session_state.windows.slots[desktop.back.slot].window;
    try std.testing.expectEqualSlices(u8, &palette.active, pixels[(back_window.y * 16 + back_window.x) * 4 ..][0..4]);
    // 16 / 2 = 8 por coluna: os botões ocupam 0..6 e 8..14, e a coluna 7 é a
    // calha, onde se vê o fundo da barra.
    try std.testing.expectEqualSlices(u8, &shell_palette.bar, pixels[11 * 64 + 7 * 4 ..][0..4]);
    // E a volta seguinte devolve o foco à janela da frente.
    try std.testing.expectEqual(front, (try desktop.cycleFocusAndPresent(mapping)).?);
}
test "the pointer is painted on top of the windows and of the bar" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    const shell_palette: taskbar.Palette = .{
        .bar = .{ 0x10, 0x10, 0x10, 0xff },
        .active = .{ 0x90, 0x90, 0x90, 0xff },
        .inactive = .{ 0x40, 0x40, 0x40, 0xff },
    };
    const pointer_palette: cursor_mod.Palette = .{
        .outline = .{ 0x00, 0x00, 0x00, 0xff },
        .fill = .{ 0xff, 0xff, 0xff, 0xff },
    };
    var desktop = try Desktop.init(32, 24, palette);
    desktop.enableShell(.{ .bar = .{ .height = 2 }, .palette = shell_palette });
    var pixels: [32 * 24 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 32, .height = 24, .pitch = 128, .bits_per_pixel = 32 };
    // Sem ponteiro, a cena é a mesma de antes de F6.32: nada é pintado por cima.
    _ = try desktop.present(mapping);
    var without_pointer: [32 * 24 * 4]u8 = undefined;
    @memcpy(&without_pointer, &pixels);
    try std.testing.expectEqual(@as(usize, 0), try desktop.paintPointerMapping(mapping));

    desktop.enablePointer(.{ .cursor = .{ .x = 4, .y = 2 }, .palette = pointer_palette });
    try std.testing.expect(try desktop.present(mapping));
    const written = try desktop.paintPointerMapping(mapping);
    try std.testing.expect(written > 0);
    // A ponta da seta é o contorno, e ela está exatamente em (4, 2).
    try std.testing.expectEqualSlices(u8, &pointer_palette.outline, pixels[(2 * 32 + 4) * 4 ..][0..4]);
    // Uma posição longe da seta não mudou por causa dela.
    try std.testing.expectEqualSlices(
        u8,
        without_pointer[(20 * 32 + 20) * 4 ..][0..4],
        pixels[(20 * 32 + 20) * 4 ..][0..4],
    );
}

test "moving the pointer matches a full presentation at the new position" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    const shell_palette: taskbar.Palette = .{
        .bar = .{ 0x10, 0x10, 0x10, 0xff },
        .active = .{ 0x90, 0x90, 0x90, 0xff },
        .inactive = .{ 0x40, 0x40, 0x40, 0xff },
    };
    const pointer_palette: cursor_mod.Palette = .{
        .outline = .{ 0x00, 0x00, 0x00, 0xff },
        .fill = .{ 0xff, 0xff, 0xff, 0xff },
    };
    const mapping_of = struct {
        fn make(bytes: []u8) bridge.Mapping {
            return .{ .bytes = bytes, .width = 64, .height = 48, .pitch = 256, .bits_per_pixel = 32 };
        }
    };

    var fast = try Desktop.init(64, 48, palette);
    fast.enableShell(.{ .bar = .{ .height = 3 }, .palette = shell_palette });
    fast.enablePointer(.{ .cursor = .{ .x = 8, .y = 8 }, .palette = pointer_palette });
    var fast_pixels: [64 * 48 * 4]u8 = @splat(0);
    _ = try fast.present(mapping_of.make(&fast_pixels));

    var reference = try Desktop.init(64, 48, palette);
    reference.enableShell(.{ .bar = .{ .height = 3 }, .palette = shell_palette });
    reference.enablePointer(.{ .cursor = .{ .x = 21, .y = 30 }, .palette = pointer_palette });
    var reference_pixels: [64 * 48 * 4]u8 = @splat(0);
    _ = try reference.present(mapping_of.make(&reference_pixels));

    // Um movimento em dois passos parciais chega ao mesmo destino.
    _ = try fast.movePointerAndPresent(mapping_of.make(&fast_pixels), 9, 14);
    _ = try fast.movePointerAndPresent(mapping_of.make(&fast_pixels), 4, 8);
    try std.testing.expectEqual(@as(usize, 21), fast.pointer.?.cursor.x);
    try std.testing.expectEqual(@as(usize, 30), fast.pointer.?.cursor.y);
    // Byte a byte: o caminho incremental não deixa rastro da posição antiga.
    try std.testing.expectEqualSlices(u8, &reference_pixels, &fast_pixels);
}

test "the pointer stops at the edges and a move without change writes nothing" {
    const palette: renderer.Palette = .{
        .background = .{ 0, 0, 0, 0 },
        .active = .{ 9, 9, 9, 9 },
        .inactive = .{ 3, 3, 3, 3 },
    };
    const pointer_palette: cursor_mod.Palette = .{
        .outline = .{ 0x00, 0x00, 0x00, 0xff },
        .fill = .{ 0xff, 0xff, 0xff, 0xff },
    };
    var desktop = try Desktop.init(40, 30, palette);
    desktop.enablePointer(.{ .cursor = .{ .x = 5, .y = 5 }, .palette = pointer_palette });
    var pixels: [40 * 30 * 4]u8 = @splat(0);
    const mapping: bridge.Mapping = .{ .bytes = &pixels, .width = 40, .height = 30, .pitch = 160, .bits_per_pixel = 32 };
    _ = try desktop.present(mapping);

    _ = try desktop.movePointerAndPresent(mapping, 10_000, 10_000);
    try std.testing.expectEqual(@as(usize, 40 - cursor_mod.Arrow.width), desktop.pointer.?.cursor.x);
    try std.testing.expectEqual(@as(usize, 30 - cursor_mod.Arrow.height), desktop.pointer.?.cursor.y);
    // No limite, repetir o movimento não escreve nada: nada mudou na tela.
    _ = try desktop.movePointerAndPresent(mapping, 50, 50);
    try std.testing.expectEqual(@as(usize, 0), try desktop.movePointerAndPresent(mapping, 50, 50));
}
