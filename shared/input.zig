//************************************************************************//
//  input.zig                                                             //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! Stable input event contract shared by the kernel and the SDK.
//!
//! The kernel fills one event and the user mode reads it. The structure is
//! fixed and versioned; the flags are part of the ABI and not of the
//! keyboard driver. The contract carries key events today; a future version
//! can add pointer events without changing the layout of this one.

const std = @import("std");

/// Version of the input event structure.
pub const input_version: u32 = 1;

/// The event is a key of the PS/2 set 1 subset.
pub const kind_key: u32 = 1;

/// The key is pressed.
pub const flag_pressed: u32 = 1 << 0;

/// The key is extended (the `E0` prefix of set 1).
pub const flag_extended: u32 = 1 << 1;

/// The flags that this version defines.
pub const flag_mask: u32 = flag_pressed | flag_extended;

/// One input event.
///
/// The kernel writes the structure; the user mode reads it. `code` is the
/// make code of set 1, without the release bit, for a key event. The layout
/// is part of the ABI.
pub const InputEvent = extern struct {
    /// Must be `input_version`.
    version: u32 = input_version,
    /// One of the `kind_*` values; `kind_key` today.
    kind: u32 = kind_key,
    /// The make code of set 1 for a key event.
    code: u32 = 0,
    /// The `flag_*` bits.
    flags: u32 = 0,
};

/// The reasons why an event is not acceptable to the user mode.
pub const InputError = error{
    /// The event was produced by a version that the caller does not know.
    InvalidVersion,
    /// The kind is not one that this version defines.
    InvalidKind,
    /// A flag that this version does not define is set.
    InvalidFlags,
    /// The code is outside the supported set 1 subset.
    InvalidCode,
};

/// Builds a key event with the flags of this version.
pub fn keyEvent(scancode: u8, extended: bool, pressed: bool) InputEvent {
    var flags: u32 = 0;
    if (pressed) flags |= flag_pressed;
    if (extended) flags |= flag_extended;
    return .{ .code = scancode, .flags = flags };
}

/// Checks an event that the user mode received.
///
/// The function is pure. It does not trust the flags or the code: the
/// kernel filters the bytes of the controller, and the user mode validates
/// what the kernel wrote before using it.
pub fn validate(event: *const InputEvent) InputError!void {
    if (event.version != input_version) return error.InvalidVersion;
    if (event.kind != kind_key) return error.InvalidKind;
    if (event.flags & ~flag_mask != 0) return error.InvalidFlags;
    if (event.code == 0 or event.code > 0x58) return error.InvalidCode;
}

/// Pointer events use a separate ABI; InputEvent v1 remains unchanged.
pub const pointer_version: u32 = 1;
pub const pointer_kind_motion: u32 = 1;
pub const pointer_kind_button: u32 = 2;
pub const pointer_button_primary: u32 = 1;
pub const pointer_flag_pressed: u32 = 1;

pub const PointerEvent = extern struct {
    version: u32 = pointer_version,
    kind: u32 = pointer_kind_motion,
    x: u32 = 0,
    y: u32 = 0,
    button: u32 = 0,
    flags: u32 = 0,
};

pub const PointerError = error{ InvalidVersion, InvalidKind, InvalidButton, InvalidFlags };

/// Validate untrusted pointer metadata; display bounds are checked by the consumer.
pub fn validatePointer(event: *const PointerEvent) PointerError!void {
    if (event.version != pointer_version) return error.InvalidVersion;
    if (event.kind == pointer_kind_motion) {
        if (event.button != 0) return error.InvalidButton;
        if (event.flags != 0) return error.InvalidFlags;
        return;
    }
    if (event.kind != pointer_kind_button) return error.InvalidKind;
    if (event.button != pointer_button_primary) return error.InvalidButton;
    if (event.flags & ~pointer_flag_pressed != 0) return error.InvalidFlags;
}

test "pointer ABI layout remains fixed" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(PointerEvent));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(PointerEvent, "x"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(PointerEvent, "flags"));
}

test "pointer validator accepts motion and primary press" {
    const motion: PointerEvent = .{ .x = 10, .y = 20 };
    try validatePointer(&motion);
    const press: PointerEvent = .{ .kind = pointer_kind_button, .button = pointer_button_primary, .flags = pointer_flag_pressed };
    try validatePointer(&press);
}

test "pointer validator rejects malformed motion" {
    var event: PointerEvent = .{};
    event.version = pointer_version + 1;
    try std.testing.expectError(error.InvalidVersion, validatePointer(&event));
    event = .{};
    event.button = pointer_button_primary;
    try std.testing.expectError(error.InvalidButton, validatePointer(&event));
    event = .{};
    event.flags = pointer_flag_pressed;
    try std.testing.expectError(error.InvalidFlags, validatePointer(&event));
}

test "pointer validator rejects unsupported button events" {
    var event: PointerEvent = .{ .kind = pointer_kind_button, .button = pointer_button_primary };
    try validatePointer(&event);
    event.button = 0;
    try std.testing.expectError(error.InvalidButton, validatePointer(&event));
    event.button = pointer_button_primary;
    event.flags = 2;
    try std.testing.expectError(error.InvalidFlags, validatePointer(&event));
    event = .{ .kind = 99 };
    try std.testing.expectError(error.InvalidKind, validatePointer(&event));
}

/// Reject pointer coordinates outside the active surface.
pub fn pointerInBounds(event: *const PointerEvent, width: u32, height: u32) bool {
    return event.x < width and event.y < height;
}

test "pointer bounds use exclusive surface edges" {
    const event: PointerEvent = .{ .x = 31, .y = 23 };
    try std.testing.expect(pointerInBounds(&event, 32, 24));
    try std.testing.expect(!pointerInBounds(&event, 31, 24));
    try std.testing.expect(!pointerInBounds(&event, 32, 23));
    try std.testing.expect(!pointerInBounds(&event, 0, 24));
}

/// Validate both pointer metadata and the destination surface bounds.
pub fn validatePointerForSurface(event: *const PointerEvent, width: u32, height: u32) (PointerError || error{OutOfBounds})!void {
    try validatePointer(event);
    if (!pointerInBounds(event, width, height)) return error.OutOfBounds;
}

test "pointer surface validation rejects out-of-range coordinates" {
    const inside: PointerEvent = .{ .x = 31, .y = 23 };
    try validatePointerForSurface(&inside, 32, 24);
    const outside: PointerEvent = .{ .x = 32, .y = 23 };
    try std.testing.expectError(error.OutOfBounds, validatePointerForSurface(&outside, 32, 24));
}

test "input event layout is stable" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(InputEvent));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(InputEvent, "version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(InputEvent, "kind"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(InputEvent, "code"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(InputEvent, "flags"));
}

test "input event defaults are explicit" {
    const event: InputEvent = .{};
    try std.testing.expectEqual(input_version, event.version);
    try std.testing.expectEqual(kind_key, event.kind);
    try std.testing.expectEqual(@as(u32, 0), event.code);
    try std.testing.expectEqual(@as(u32, 0), event.flags);
}

test "key event sets the pressed and extended flags" {
    const press = keyEvent(0x4d, true, true);
    try std.testing.expectEqual(@as(u32, 0x4d), press.code);
    try std.testing.expectEqual(flag_pressed | flag_extended, press.flags);

    const release = keyEvent(0x4d, true, false);
    try std.testing.expectEqual(flag_extended, release.flags);
}

test "a well formed input event is accepted" {
    const event = keyEvent(0x1e, false, true);
    try validate(&event);
}

test "an input event of an unknown version is refused" {
    var event = keyEvent(0x1e, false, true);
    event.version = input_version + 1;
    try std.testing.expectError(error.InvalidVersion, validate(&event));
}

test "an input event of an unknown kind is refused" {
    var event = keyEvent(0x1e, false, true);
    event.kind = kind_key + 1;
    try std.testing.expectError(error.InvalidKind, validate(&event));
}

test "an input event with an unknown flag is refused" {
    var event = keyEvent(0x1e, false, true);
    event.flags |= 1 << 2;
    try std.testing.expectError(error.InvalidFlags, validate(&event));
}

test "an input event with an unsupported code is refused" {
    var event = keyEvent(0x1e, false, true);
    event.code = 0;
    try std.testing.expectError(error.InvalidCode, validate(&event));

    event.code = 0x59;
    try std.testing.expectError(error.InvalidCode, validate(&event));
}
