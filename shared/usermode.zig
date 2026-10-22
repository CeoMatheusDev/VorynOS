// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 VorynOS contributors

//! The window of the user mode.
//!
//! A task that runs in the third level of privilege sees a window of virtual
//! addresses that holds its program, its data and its stack. The window is
//! described here, and not in the kernel, because the program of the user
//! mode is written in assembly and both sides have to agree on the layout
//! to the byte.
//!
//! The window has no fixed address. The kernel chooses an address that does
//! not collide with the image of the kernel — the image is mapped by
//! identity, and a window inside the image would overwrite the code and the
//! data of the kernel — and it hands the address to the task in the first
//! register, which is the way a process receives the information of its own
//! memory when it starts.

/// The offset of the page of the program inside the window.
pub const code_offset: u64 = 0x0000;

/// The offset of the page of the data inside the window.
pub const data_offset: u64 = 0x1000;

/// The offset of the first page of the stack inside the window.
pub const stack_offset: u64 = 0x2000;

/// The number of pages of the stack of the user mode.
pub const stack_pages: u64 = 2;

/// The size of the window, in bytes.
pub const window_size: u64 = (stack_offset + stack_pages * 0x1000);

/// The offset of the marker inside the page of the data.
pub const data_marker: u64 = 0x00;

/// The offset of the result of the call of the probe inside the page of the
/// data.
pub const data_result: u64 = 0x08;

/// The offset of the result of the call that writes in the console.
pub const data_write: u64 = 0x10;

/// The offset of the result of the call that copies a block.
pub const data_copy: u64 = 0x18;

/// The offset of the content that the call that copies a block wrote.
pub const data_content: u64 = 0x20;

/// The offset of the message that the program writes in the console.
pub const data_message: u64 = 0x28;

/// The offset of the answer of the call that the kernel refused.
pub const data_refused: u64 = 0x30;

/// The offset of the answer of the channel.
pub const data_answer: u64 = 0x38;

/// The offset of the block that the copy with the overlapping ranges takes
/// as its origin.
pub const data_overlap_origin: u64 = 0x40;

/// The offset of the block that the copy with the overlapping ranges writes
/// in the destination.
pub const data_overlap_destination: u64 = 0x44;

/// The offset of the result of the copy with the overlapping ranges.
pub const data_overlap_result: u64 = 0x50;

/// The block that the program of the user mode writes for the copy with the
/// overlapping ranges.
pub const overlap_pattern: u64 = 0x1122_3344_5566_7788;

const std = @import("std");
const testing = std.testing;

test "the window does not hold two pages in the same place" {
    try testing.expect(code_offset != data_offset);
    try testing.expect(data_offset != stack_offset);
    try testing.expect(stack_offset + stack_pages * 0x1000 == window_size);
}

test "the words of the page of the data do not overlap" {
    const words = [_]u64{
        data_marker,
        data_result,
        data_write,
        data_copy,
        data_content,
        data_message,
        data_refused,
        data_answer,
        data_overlap_origin,
        data_overlap_result,
    };

    for (words, 0..) |word, index| {
        try testing.expectEqual(@as(u64, 0), word % 8);
        for (words[index + 1 ..]) |other| {
            try testing.expect(word != other);
        }
    }
}
