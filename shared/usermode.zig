//************************************************************************//
// usermode.zig                                                           //
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

const std = @import("std");
const testing = std.testing;

/// The offset of the page of the program inside the window.
pub const code_offset: u64 = 0x0000;

/// The offset of the page of the data inside the window.
pub const data_offset: u64 = 0x1000;

/// The offset of the first page of the stack inside the window.
///
/// The native ELF image places its writable segment below this offset. The
/// F6.28 composition code made that segment end exactly at 0x4000, so the
/// stack starts at the next page instead of at 0x3000. The materializer
/// still rejects any segment or stack page that leaves the window.
pub const stack_offset: u64 = 0x4000;

/// The number of pages of the stack of the user mode.
pub const stack_pages: u64 = 2;

/// The size of the window, in bytes.
pub const window_size: u64 = stack_offset + stack_pages * 0x1000;

/// The page below the base of the window that holds the contract of the
/// client of the compositor.
///
/// The page belongs to the same block of two megabytes as the window, but it
/// is not part of the window: the materializer does not map it and the
/// program does not see it unless the kernel maps it in the space of the
/// client. The page of the surface of the compositor is the next one below.
pub const contract_below: u64 = 0x1000;

/// The page below the base of the window that holds the surface of the
/// compositor.
///
/// The page is mapped only in the space of the compositor. The client writes
/// in it through `copy_to`, which switches to the space of the compositor
/// after checking the capability of the target process.
pub const surface_below: u64 = 0x2000;

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

/// The offset of the result of the copy to the other process.
pub const data_copy_result: u64 = 0x58;

/// The offset of the block that the copy to the other process writes in the
/// space of the other process.
pub const data_copy_target: u64 = 0x60;
/// The result of the call that a process without the capability makes.
pub const data_capability_refused: u64 = 0x68;
/// The result of the revocation of a capability.
pub const data_capability_revoked: u64 = 0x70;
/// The result of the delegation of a capability.
pub const data_capability_granted: u64 = 0x78;
/// The result of the copy that a process without the capability of the
/// address space made.
pub const data_copy_refused: u64 = 0x80;
/// The result of the delegation of the capability of the address space
/// through the call.
pub const data_process_granted: u64 = 0x88;
/// The result of the revocation of the capability of the address space
/// through the call.
pub const data_process_revoked: u64 = 0x90;
/// The result of the grant with a kind that the kernel does not know.
pub const data_kind_refused: u64 = 0x98;
/// The result of the grant with a right of another kind.
pub const data_rights_refused: u64 = 0xA0;
/// The result of the wait with a timeout.
pub const data_timeout: u64 = 0xA8;
/// The result of the presentation that a process without the display
/// capability made.
pub const data_present_refused: u64 = 0xB0;
/// The result of the input call that a process without the input capability
/// made.
pub const data_input_refused: u64 = 0xB8;

/// The block that the program of the user mode writes for the copy with the
/// overlapping ranges.
pub const overlap_pattern: u64 = 0x1122_3344_5566_7788;

test "the window does not hold two pages in the same place" {
    try testing.expect(code_offset != data_offset);
    try testing.expect(data_offset != stack_offset);
    try testing.expectEqual(@as(u64, 0), code_offset % 0x1000);
    try testing.expectEqual(@as(u64, 0), data_offset % 0x1000);
    try testing.expectEqual(@as(u64, 0), stack_offset % 0x1000);
    try testing.expect(stack_offset >= data_offset + 0x1000);
    try testing.expectEqual(@as(u64, 0), window_size % 0x1000);
    try testing.expect(stack_offset + stack_pages * 0x1000 == window_size);
}

test "the pages below the window are aligned and distinct" {
    try testing.expect(contract_below >= 0x1000);
    try testing.expect(surface_below >= 0x1000);
    try testing.expectEqual(@as(u64, 0), contract_below % 0x1000);
    try testing.expectEqual(@as(u64, 0), surface_below % 0x1000);
    try testing.expect(contract_below != surface_below);
    try testing.expect(contract_below + 0x1000 <= surface_below or
        surface_below + 0x1000 <= contract_below);
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
        data_copy_result,
        data_copy_target,
        data_capability_refused,
        data_capability_revoked,
        data_capability_granted,
        data_copy_refused,
        data_process_granted,
        data_process_revoked,
        data_kind_refused,
        data_rights_refused,
        data_timeout,
        data_present_refused,
        data_input_refused,
    };

    for (words, 0..) |word, index| {
        try testing.expectEqual(@as(u64, 0), word % 8);
        for (words[index + 1 ..]) |other| {
            try testing.expect(word != other);
        }
    }
}
