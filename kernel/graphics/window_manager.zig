// VorynOS F6: bounded window management, independent of framebuffer hardware.
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
const std = @import("std");

pub const capacity: usize = 32;
pub const Error = error{ Full, InvalidHandle, GenerationExhausted, InvalidGeometry };
pub const Handle = struct { slot: u8, generation: u64 };
pub const Window = struct {
    owner: u64,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    visible: bool = true,
};
const Slot = struct {
    generation: u64 = 0,
    occupied: bool = false,
    window: Window = undefined,
};

pub const Manager = struct {
    slots: [capacity]Slot = @splat(.{}),
    order: [capacity]u8 = @splat(0),
    count: usize = 0,
    focused: ?Handle = null,

    fn lookup(self: *Manager, handle: Handle) ?*Slot {
        if (handle.slot >= capacity) return null;
        const slot = &self.slots[handle.slot];
        if (!slot.occupied or slot.generation != handle.generation or handle.generation == 0) return null;
        return slot;
    }

    pub fn create(self: *Manager, window: Window) Error!Handle {
        if (window.width == 0 or window.height == 0) return error.InvalidGeometry;
        var available: ?usize = null;
        var exhausted = false;
        for (&self.slots, 0..) |*slot, index| {
            if (slot.occupied) continue;
            if (slot.generation == std.math.maxInt(u64)) {
                exhausted = true;
                continue;
            }
            available = index;
            break;
        }
        const index = available orelse return if (exhausted) error.GenerationExhausted else error.Full;
        const slot = &self.slots[index];
        slot.generation += 1;
        slot.occupied = true;
        slot.window = window;
        self.order[self.count] = @intCast(index);
        self.count += 1;
        const handle: Handle = .{ .slot = @intCast(index), .generation = slot.generation };
        if (window.visible) self.focused = handle;
        return handle;
    }

    pub fn destroy(self: *Manager, handle: Handle, owner: u64) Error!void {
        const slot = self.lookup(handle) orelse return error.InvalidHandle;
        if (slot.window.owner != owner) return error.InvalidHandle;
        slot.occupied = false;
        var at: usize = 0;
        while (at < self.count and self.order[at] != handle.slot) : (at += 1) {}
        if (at == self.count) unreachable;
        var i = at;
        while (i + 1 < self.count) : (i += 1) self.order[i] = self.order[i + 1];
        self.count -= 1;
        if (self.focused) |focus| {
            if (focus.slot == handle.slot and focus.generation == handle.generation) self.focusTop();
        }
    }

    fn focusTop(self: *Manager) void {
        self.focused = null;
        var i = self.count;
        while (i > 0) {
            i -= 1;
            const index = self.order[i];
            const slot = &self.slots[index];
            if (slot.window.visible) {
                self.focused = .{ .slot = index, .generation = slot.generation };
                return;
            }
        }
    }

    /// Passa o foco para a próxima janela visível, na ordem do z-order, e
    /// devolve o identificador que recebeu o foco.
    ///
    /// A volta é circular e não altera a ordem: trocar de foco por teclado não
    /// deve reordenar as janelas na tela. Uma janela invisível é pulada, e um
    /// gerenciador sem janelas visíveis devolve `null` sem mudar nada. Se o
    /// foco atual não estiver na ordem — o que só acontece com estado
    /// inconsistente —, a volta começa na primeira janela visível.
    pub fn focusNext(self: *Manager) ?Handle {
        if (self.count == 0) return null;

        var start: usize = 0;
        if (self.focused) |focus| {
            while (start < self.count and self.order[start] != focus.slot) : (start += 1) {}
            start = (start + 1) % self.count;
        }
        var step: usize = 0;
        while (step < self.count) : (step += 1) {
            const index = self.order[(start + step) % self.count];
            const slot = &self.slots[index];
            if (!slot.occupied or !slot.window.visible) continue;
            self.focused = .{ .slot = index, .generation = slot.generation };
            return self.focused;
        }
        return null;
    }

    pub fn raise(self: *Manager, handle: Handle, owner: u64) Error!void {
        const slot = self.lookup(handle) orelse return error.InvalidHandle;
        if (slot.window.owner != owner) return error.InvalidHandle;
        var at: usize = 0;
        while (at < self.count and self.order[at] != handle.slot) : (at += 1) {}
        if (at == self.count) unreachable;
        var i = at;
        while (i + 1 < self.count) : (i += 1) self.order[i] = self.order[i + 1];
        self.order[self.count - 1] = handle.slot;
        if (slot.window.visible) self.focused = handle;
    }

    pub fn move(self: *Manager, handle: Handle, owner: u64, x: usize, y: usize) Error!void {
        const slot = self.lookup(handle) orelse return error.InvalidHandle;
        if (slot.window.owner != owner) return error.InvalidHandle;
        slot.window.x = x;
        slot.window.y = y;
    }

    pub fn hitTest(self: *const Manager, x: usize, y: usize) ?Handle {
        var i = self.count;
        while (i > 0) {
            i -= 1;
            const index = self.order[i];
            const slot = &self.slots[index];
            const w = slot.window;
            if (w.visible and x >= w.x and y >= w.y and x - w.x < w.width and y - w.y < w.height)
                return .{ .slot = index, .generation = slot.generation };
        }
        return null;
    }
};

test "window lifecycle, stale handle and owner isolation" {
    var wm = Manager{};
    const w: Window = .{ .owner = 4, .x = 1, .y = 2, .width = 5, .height = 6 };
    const first = try wm.create(w);
    try std.testing.expectError(error.InvalidHandle, wm.move(first, 5, 0, 0));
    try wm.destroy(first, 4);
    try std.testing.expectError(error.InvalidHandle, wm.destroy(first, 4));
    const second = try wm.create(w);
    try std.testing.expectEqual(first.slot, second.slot);
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expectError(error.InvalidHandle, wm.raise(first, 4));
}

test "z-order and hit testing use safe subtraction" {
    var wm = Manager{};
    const a = try wm.create(.{ .owner = 1, .x = 0, .y = 0, .width = 4, .height = 4 });
    const b = try wm.create(.{ .owner = 2, .x = 2, .y = 2, .width = 4, .height = 4 });
    try std.testing.expectEqual(b, wm.hitTest(3, 3).?);
    try wm.raise(a, 1);
    try std.testing.expectEqual(a, wm.hitTest(3, 3).?);
    try std.testing.expect(wm.hitTest(std.math.maxInt(usize), 3) == null);
    try wm.destroy(a, 1);
    try std.testing.expectEqual(b, wm.focused.?);
}

test "capacity and invalid geometry" {
    var wm = Manager{};
    try std.testing.expectError(error.InvalidGeometry, wm.create(.{ .owner = 0, .x = 0, .y = 0, .width = 0, .height = 1 }));
    for (0..capacity) |_| _ = try wm.create(.{ .owner = 0, .x = 0, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectError(error.Full, wm.create(.{ .owner = 0, .x = 0, .y = 0, .width = 1, .height = 1 }));
}

test "focusNext cycles visible windows without touching the z-order" {
    var wm = Manager{};
    const a = try wm.create(.{ .owner = 1, .x = 0, .y = 0, .width = 2, .height = 2 });
    const b = try wm.create(.{ .owner = 2, .x = 1, .y = 1, .width = 2, .height = 2 });
    const hidden = try wm.create(.{ .owner = 3, .x = 2, .y = 2, .width = 2, .height = 2, .visible = false });
    // A última janela criada está em foco; a invisível não recebeu o foco.
    try std.testing.expectEqual(hidden.slot, wm.order[2]);
    try std.testing.expectEqual(b, wm.focused.?);

    const before = wm.order;
    try std.testing.expectEqual(a, wm.focusNext().?);
    try std.testing.expectEqual(b, wm.focusNext().?);
    try std.testing.expectEqual(a, wm.focusNext().?);
    try std.testing.expectEqual(before, wm.order);

    // Esconder a janela em foco também a retira da volta.
    wm.slots[a.slot].window.visible = false;
    try std.testing.expectEqual(b, wm.focusNext().?);
}

test "focusNext returns null without visible windows" {
    var wm = Manager{};
    try std.testing.expect(wm.focusNext() == null);
    _ = try wm.create(.{ .owner = 1, .x = 0, .y = 0, .width = 1, .height = 1, .visible = false });
    try std.testing.expect(wm.focusNext() == null);
    try std.testing.expect(wm.focused == null);
}
