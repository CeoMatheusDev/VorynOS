//************************************************************************//
//  capability.zig                                                        //
//************************************************************************//
//                         This file is part of:                          //
//                               VorynOS                                  //
//              https://github.com/CeoMatheusDev/VorynOS                  //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.                               //
//                                                                        //
// SPDX-License-Identifier: GPL-3.0-only                                  //
//************************************************************************//

//! The capability fabric of the VNC: the table of the capabilities and
//! the set that each process holds.
//!
//! A capability is a **permission that can be given away**. The kernel
//! keeps the table of the capabilities, and every process holds a set of
//! them. The processes of the user mode do not decide what they can do:
//! the kernel decides, and the only thing a process can do with a
//! capability is to give it to another process, and to take it back.
//!
//! The model has three parts:
//!
//!   * the **table**, in the kernel, with one entry per capability. The
//!     entry says what the capability is about and what it allows;
//!   * the **set** of each process, with the capabilities that the process
//!     holds and the rights that it holds over each one of them;
//!   * the **rights**, the bits that say what the holder can do with the
//!     capability.
//!
//! The rights are held **per holder**, and not only in the table. The
//! consequence is the property that makes the model worth its cost: a
//! capability that is delegated without the right of delegation cannot be
//! delegated again. The possession of a capability is not, by itself, the
//! right to create more of them.
//!
//! The table is **not** exposed to the user mode. The handle of a
//! capability is an index of the table, and it means nothing outside the
//! kernel. The calls of the user mode name the **subject** of the
//! capability — the channel — and the kernel finds the capability that the
//! caller holds over it.

const std = @import("std");

/// The kinds of capability that the table holds.
pub const Kind = enum {
    /// The capability of a channel of the VNX.
    ///
    /// The subject of the capability is the identifier of the channel.
    channel,
};

/// The rights of a capability.
///
/// The rights are bits, and a holder can have a subset of the rights that
/// the table entry carries.
pub const Rights = struct {
    /// The right to put a message in the subject.
    pub const send: u64 = 1 << 0;
    /// The right to take a message of the subject.
    pub const receive: u64 = 1 << 1;
    /// The right to give the capability to another process.
    pub const delegate: u64 = 1 << 2;
    /// Every right of a capability.
    pub const all: u64 = send | receive | delegate;
    /// The rights of a holder that can use the subject, but that cannot
    /// give it away.
    pub const use: u64 = send | receive;
};

/// The number of entries of the table of capabilities.
pub const max_capabilities = 16;

/// The number of capabilities that a process holds.
pub const max_held = 8;

/// The number of processes that can hold capabilities.
///
/// The number is the one of the spaces of address of the kernel, and the
/// process that the kernel creates is the one that owns the first of them.
pub const max_processes = 8;

/// An entry of the table of capabilities.
const Entry = struct {
    /// What the capability is about.
    kind: Kind = .channel,
    /// The subject of the capability: the identifier of the channel.
    subject: u64 = 0,
    /// The rights that the capability carries.
    rights: u64 = 0,
    /// True when the entry holds a capability.
    used: bool = false,
};

/// A capability that a process holds.
const Held = struct {
    /// The handle of the capability in the table.
    handle: u64 = 0,
    /// The rights that the process holds over the capability.
    rights: u64 = 0,
};

/// The capabilities that a process holds.
const Set = struct {
    /// The entries of the set.
    entries: [max_held]Held = @splat(.{}),
    /// The number of entries that the set holds.
    count: u8 = 0,
};

/// The table of the capabilities of the kernel.
var table: [max_capabilities]Entry = @splat(.{});

/// The set of capabilities of each process, indexed by the identifier of
/// the process.
var sets: [max_processes]Set = @splat(.{});

/// Prepares the table and the sets.
///
/// The function is called once, before the processes exist, and it leaves
/// the kernel with no capability and every process with no set.
pub fn init() void {
    table = @splat(.{});
    sets = @splat(.{});
}

/// Creates a capability and returns its handle.
///
/// The function is the authority of the root: only the kernel calls it, and
/// the capability it creates belongs to nobody until a process is given it.
pub fn create(kind: Kind, subject: u64, rights: u64) ?u64 {
    for (&table, 0..) |*entry, index| {
        if (entry.used) continue;
        entry.* = .{
            .kind = kind,
            .subject = subject,
            .rights = rights,
            .used = true,
        };
        return index;
    }
    return null;
}

/// Gives a capability to a process, without any check on the giver.
///
/// The function is the authority of the root, and it is the path of the
/// kernel when it hands the first capability of a channel to the process
/// that owns it.
///
/// The rights that the process receives have to be a subset of the rights
/// that the capability carries: a process cannot be given a right that the
/// capability does not have.
pub fn give(process: u64, handle: u64, rights: u64) bool {
    if (process >= max_processes) return false;
    if (handle >= table.len) return false;

    const entry = table[@intCast(handle)];
    if (!entry.used) return false;
    if (rights & ~entry.rights != 0) return false;

    const set = &sets[@intCast(process)];

    // The process that already holds the capability receives the new rights
    // with the rights it already had.
    for (set.entries[0..set.count]) |*held| {
        if (held.handle != handle) continue;
        held.rights |= rights;
        return true;
    }

    if (set.count >= max_held) return false;
    set.entries[set.count] = .{ .handle = handle, .rights = rights };
    set.count += 1;
    return true;
}

/// Transfers a capability of the caller to another process.
///
/// The caller has to hold the capability with the right of delegation, and
/// the rights that the target receives have to be a subset of the rights
/// that the caller holds. The right of delegation is **not** part of what
/// the target receives, unless the caller asks for it explicitly: the
/// delegation that does not carry the right of delegation is the one that
/// stops the chain.
pub fn transfer(caller: u64, target: u64, handle: u64, rights: u64) bool {
    if (!holds(caller, handle, Rights.delegate)) return false;

    const caller_rights = rightsOf(caller, handle) orelse return false;
    if (rights & ~caller_rights != 0) return false;

    return give(target, handle, rights);
}

/// Revokes a capability of a process.
///
/// The caller has to hold the capability with the right of delegation: the
/// owner of the capability takes it back from the process it gave it to.
pub fn revoke(caller: u64, target: u64, handle: u64) bool {
    if (!holds(caller, handle, Rights.delegate)) return false;
    if (target >= max_processes) return false;

    const set = &sets[@intCast(target)];
    var index: u8 = 0;
    while (index < set.count) : (index += 1) {
        if (set.entries[index].handle != handle) continue;

        // The last entry takes the place of the one that is removed, and
        // the set does not grow.
        set.entries[index] = set.entries[set.count - 1];
        set.count -= 1;
        return true;
    }
    return false;
}

/// True when the process holds the capability with the right.
pub fn holds(process: u64, handle: u64, right: u64) bool {
    const rights = rightsOf(process, handle) orelse return false;
    return rights & right == right;
}

/// The rights that the process holds over the capability.
pub fn rightsOf(process: u64, handle: u64) ?u64 {
    if (process >= max_processes) return null;
    if (handle >= table.len) return null;

    const set = &sets[@intCast(process)];
    for (set.entries[0..set.count]) |held| {
        if (held.handle == handle) return held.rights;
    }
    return null;
}

/// True when the process holds a capability of the kind over the subject,
/// with the right.
///
/// The function is the check that the calls of the user mode do: the
/// process that does not hold the capability of the channel does not use
/// the channel.
pub fn holdsSubject(process: u64, kind: Kind, subject: u64, right: u64) bool {
    if (process >= max_processes) return false;

    const set = &sets[@intCast(process)];
    for (set.entries[0..set.count]) |held| {
        if (held.handle >= table.len) continue;
        const entry = table[@intCast(held.handle)];
        if (!entry.used) continue;
        if (entry.kind != kind) continue;
        if (entry.subject != subject) continue;
        if (held.rights & right == right) return true;
    }
    return false;
}

/// The handle of the capability that the process holds over the subject.
///
/// The function returns null when the process holds no capability over the
/// subject, and the caller of the system call refuses the call.
pub fn handleOf(process: u64, kind: Kind, subject: u64) ?u64 {
    if (process >= max_processes) return null;

    const set = &sets[@intCast(process)];
    for (set.entries[0..set.count]) |held| {
        if (held.handle >= table.len) continue;
        const entry = table[@intCast(held.handle)];
        if (!entry.used) continue;
        if (entry.kind != kind) continue;
        if (entry.subject != subject) continue;
        return held.handle;
    }
    return null;
}

/// The number of capabilities that the process holds.
pub fn count(process: u64) u64 {
    if (process >= max_processes) return 0;
    return sets[@intCast(process)].count;
}

/// The number of entries of the table of capabilities.
pub fn tableUsed() u64 {
    var used: u64 = 0;
    for (table) |entry| {
        if (entry.used) used += 1;
    }
    return used;
}

// ---------------------------------------------------------------------------
// The tests of the contract
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a capability that nobody holds does not authorize anything" {
    init();

    const handle = create(.channel, 0, Rights.all).?;

    // The process that holds nothing does not hold the capability, even
    // though the capability exists in the table.
    try testing.expect(!holds(0, handle, Rights.send));
    try testing.expect(!holdsSubject(0, .channel, 0, Rights.send));
    try testing.expectEqual(@as(u64, 0), count(0));
}

test "the owner of a capability holds the rights that it was given" {
    init();

    const handle = create(.channel, 3, Rights.all).?;
    try testing.expect(give(0, handle, Rights.all));

    try testing.expect(holds(0, handle, Rights.send));
    try testing.expect(holds(0, handle, Rights.receive));
    try testing.expect(holds(0, handle, Rights.delegate));
    try testing.expect(holdsSubject(0, .channel, 3, Rights.send));
    try testing.expectEqual(@as(u64, 1), count(0));

    // The capability of one channel is not the capability of another.
    try testing.expect(!holdsSubject(0, .channel, 4, Rights.send));
}

test "a process cannot be given a right that the capability does not have" {
    init();

    const handle = create(.channel, 0, Rights.use).?;
    try testing.expect(give(0, handle, Rights.use));

    // The capability does not carry the right of delegation, and the
    // process cannot be given a right that the capability does not have.
    try testing.expect(!give(0, handle, Rights.delegate));
    try testing.expect(!holds(0, handle, Rights.delegate));
    try testing.expect(holds(0, handle, Rights.send));
}

test "the delegation that does not carry the right of delegation stops the chain" {
    init();

    const handle = create(.channel, 0, Rights.all).?;
    try testing.expect(give(0, handle, Rights.all));

    // The owner delegates the use of the channel, without the right of
    // delegation.
    try testing.expect(transfer(0, 1, handle, Rights.use));

    try testing.expect(holdsSubject(1, .channel, 0, Rights.send));
    try testing.expect(holdsSubject(1, .channel, 0, Rights.receive));
    try testing.expect(!holds(1, handle, Rights.delegate));

    // The holder cannot delegate what it cannot delegate.
    try testing.expect(!transfer(1, 2, handle, Rights.use));
    try testing.expect(!holdsSubject(2, .channel, 0, Rights.send));
}

test "the delegation cannot widen the rights of the holder" {
    init();

    const handle = create(.channel, 0, Rights.all).?;
    try testing.expect(give(0, handle, Rights.all));
    try testing.expect(transfer(0, 1, handle, Rights.use));

    // The holder has the right of delegation only because the owner kept
    // it for itself; the delegation cannot give more than the holder has.
    try testing.expect(transfer(0, 1, handle, Rights.delegate));
    try testing.expect(holds(1, handle, Rights.delegate));
}

test "the owner takes the capability back" {
    init();

    const handle = create(.channel, 0, Rights.all).?;
    try testing.expect(give(0, handle, Rights.all));
    try testing.expect(transfer(0, 1, handle, Rights.use));
    try testing.expect(holdsSubject(1, .channel, 0, Rights.send));

    // The revocation removes the capability of the target, and the target
    // does not use the channel any more.
    try testing.expect(revoke(0, 1, handle));
    try testing.expect(!holdsSubject(1, .channel, 0, Rights.send));
    try testing.expectEqual(@as(u64, 0), count(1));

    // The owner still holds it.
    try testing.expect(holdsSubject(0, .channel, 0, Rights.send));

    // The revocation of a capability that the target does not hold fails.
    try testing.expect(!revoke(0, 1, handle));
}

test "a process that holds nothing cannot delegate anything" {
    init();

    const handle = create(.channel, 0, Rights.all).?;
    try testing.expect(!transfer(2, 1, handle, Rights.use));
    try testing.expect(!revoke(2, 1, handle));
    try testing.expectEqual(@as(u64, 0), count(1));
}

test "the table does not grow without a limit" {
    init();

    var handles: [max_capabilities]u64 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = create(.channel, index, Rights.all).?;
    }

    // The table is full, and the kernel does not invent a
    try testing.expect(create(.channel, 99, Rights.all) == null);
    try testing.expectEqual(@as(u64, max_capabilities), tableUsed());
}

test "the set of a process does not grow without a limit" {
    init();

    var handles: [max_capabilities]u64 = undefined;
    for (&handles, 0..) |*handle, index| {
        handle.* = create(.channel, index, Rights.all).?;
    }

    var given: u32 = 0;
    for (handles) |handle| {
        if (!give(0, handle, Rights.all)) break;
        given += 1;
    }

    // The set holds what it can, and the rest is refused.
    try testing.expectEqual(@as(u32, max_held), given);
    try testing.expectEqual(@as(u64, max_held), count(0));
}

test "the handle of a capability is found by its subject" {
    init();

    const handle = create(.channel, 2, Rights.all).?;
    try testing.expect(give(1, handle, Rights.all));

    try testing.expectEqual(handle, handleOf(1, .channel, 2).?);
    try testing.expect(handleOf(1, .channel, 3) == null);
    try testing.expect(handleOf(2, .channel, 2) == null);
}
