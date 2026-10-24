//************************************************************************//
//  vfsx.zig                                                               //
//************************************************************************//
// Copyright (C) 2026 VorynOS contributors.
// SPDX-License-Identifier: GPL-3.0-only
//************************************************************************//

//! VFSX mount namespace and longest-prefix path routing.
//! This first increment is independent of storage hardware and preserves
//! the existing RamFS facade. Backend dispatch follows in the next increment.

const std = @import("std");

pub const max_mounts: usize = 8;
pub const max_path_len: usize = 255;

pub const Backend = enum { ramfs };
pub const Error = error{
    InvalidPath,
    InvalidMountPoint,
    MountTableFull,
    AlreadyMounted,
    NotMounted,
    RootMountRequired,
    MountBusy,
};

pub const Mount = struct {
    path: [max_path_len + 1]u8 = @splat(0),
    length: usize = 0,
    backend: Backend = .ramfs,
    active: bool = false,

    pub fn name(self: *const Mount) []const u8 {
        return self.path[0..self.length];
    }
};

pub const Route = struct {
    slot: usize,
    backend: Backend,
    relative_path: []const u8,
};

pub const Namespace = struct {
    mounts: [max_mounts]Mount = @splat(.{}),

    pub fn init(self: *Namespace) void {
        self.* = .{};
        self.mounts[0] = makeMount("/", .ramfs);
    }

    fn makeMount(path: []const u8, backend: Backend) Mount {
        var result: Mount = .{ .active = true, .backend = backend, .length = path.len };
        @memcpy(result.path[0..path.len], path);
        return result;
    }

    fn validPath(path: []const u8) bool {
        if (path.len == 0 or path.len > max_path_len or path[0] != '/') return false;
        if (path.len > 1 and path[path.len - 1] == '/') return false;
        var i: usize = 1;
        while (i < path.len) {
            const start = i;
            while (i < path.len and path[i] != '/') : (i += 1) {
                if (path[i] == 0) return false;
            }
            const part = path[start..i];
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
            if (i < path.len) i += 1;
        }
        return true;
    }

    fn matches(mount_path: []const u8, path: []const u8) bool {
        if (std.mem.eql(u8, mount_path, "/")) return true;
        return std.mem.eql(u8, mount_path, path) or
            (path.len > mount_path.len and
                std.mem.startsWith(u8, path, mount_path) and
                path[mount_path.len] == '/');
    }

    pub fn mount(self: *Namespace, path: []const u8, backend: Backend) Error!void {
        if (!validPath(path)) return error.InvalidMountPoint;
        for (self.mounts) |entry| {
            if (entry.active and std.mem.eql(u8, entry.name(), path)) return error.AlreadyMounted;
        }
        for (&self.mounts) |*entry| {
            if (!entry.active) {
                entry.* = makeMount(path, backend);
                return;
            }
        }
        return error.MountTableFull;
    }

    pub fn umount(self: *Namespace, path: []const u8) Error!void {
        if (!validPath(path)) return error.InvalidMountPoint;
        if (std.mem.eql(u8, path, "/")) return error.RootMountRequired;
        var target: ?usize = null;
        for (&self.mounts, 0..) |*entry, index| {
            if (!entry.active) continue;
            if (std.mem.eql(u8, entry.name(), path)) target = index;
            if (entry.name().len > path.len and matches(path, entry.name()))
                return error.MountBusy;
        }
        const index = target orelse return error.NotMounted;
        self.mounts[index] = .{};
    }

    /// Returns whether a path is an exact active mount point.
    /// This is independent of longest-prefix routing and does not allocate.
    pub fn isMountPoint(self: *const Namespace, path: []const u8) bool {
        if (!validPath(path)) return false;
        for (self.mounts) |entry| {
            if (entry.active and std.mem.eql(u8, entry.name(), path)) return true;
        }
        return false;
    }

    /// Returns the number of active mounts, including the root mount.
    pub fn activeMountCount(self: *const Namespace) usize {
        var count: usize = 0;
        for (self.mounts) |entry| {
            if (entry.active) count += 1;
        }
        return count;
    }

    pub fn route(self: *const Namespace, path: []const u8) Error!Route {
        if (!validPath(path)) return error.InvalidPath;
        var best: ?usize = null;
        var longest: usize = 0;
        for (&self.mounts, 0..) |*entry, index| {
            if (!entry.active or !matches(entry.name(), path)) continue;
            if (best == null or entry.length > longest) {
                best = index;
                longest = entry.length;
            }
        }
        const index = best orelse return error.NotMounted;
        const relative = if (longest == 1) path else if (path.len == longest) "/" else path[longest..];
        return .{ .slot = index, .backend = self.mounts[index].backend, .relative_path = relative };
    }
};

const testing = std.testing;

test "root is mounted by default" {
    var ns: Namespace = .{};
    ns.init();
    const route = try ns.route("/hello");
    try testing.expectEqual(@as(usize, 0), route.slot);
    try testing.expectEqualStrings("/hello", route.relative_path);
}

test "nested mounts resolve by longest component prefix" {
    var ns: Namespace = .{};
    ns.init();
    try ns.mount("/apps", .ramfs);
    try ns.mount("/apps/data", .ramfs);
    try testing.expectEqualStrings("/x", (try ns.route("/apps/data/x")).relative_path);
    try testing.expectEqualStrings("/", (try ns.route("/apps")).relative_path);
    try testing.expectEqual(@as(usize, 0), (try ns.route("/application")).slot);
}

test "duplicate mount and missing mount are rejected" {
    var ns: Namespace = .{};
    ns.init();
    try testing.expectError(error.AlreadyMounted, ns.mount("/", .ramfs));
    try testing.expectError(error.NotMounted, ns.umount("/missing"));
}

test "nested mounts prevent unmounting parent" {
    var ns: Namespace = .{};
    ns.init();
    try ns.mount("/apps", .ramfs);
    try ns.mount("/apps/data", .ramfs);
    try testing.expectError(error.MountBusy, ns.umount("/apps"));
    try ns.umount("/apps/data");
    try ns.umount("/apps");
    try testing.expectEqual(@as(usize, 0), (try ns.route("/apps")).slot);
}

test "root cannot be unmounted" {
    var ns: Namespace = .{};
    ns.init();
    try testing.expectError(error.RootMountRequired, ns.umount("/"));
}

test "invalid and noncanonical paths are rejected" {
    var ns: Namespace = .{};
    ns.init();
    for ([_][]const u8{ "", "relative", "/a/", "/a//b", "/a/./b", "/a/../b", "/a\x00b" }) |path| {
        try testing.expectError(error.InvalidMountPoint, ns.mount(path, .ramfs));
        try testing.expectError(error.InvalidPath, ns.route(path));
    }
}

test "mount table is bounded and freed slots can be reused" {
    var ns: Namespace = .{};
    ns.init();
    for (1..max_mounts) |i| {
        var path: [2]u8 = .{ '/', @as(u8, @intCast('a' + i)) };
        try ns.mount(&path, .ramfs);
    }
    try testing.expectError(error.MountTableFull, ns.mount("/z", .ramfs));
    try ns.umount("/b");
    try ns.mount("/z", .ramfs);
    try testing.expectEqualStrings("/", (try ns.route("/z")).relative_path);
}

test "mount metadata counts active entries without changing routing" {
    var ns: Namespace = .{};
    ns.init();
    try testing.expectEqual(@as(usize, 1), ns.activeMountCount());
    try testing.expect(ns.isMountPoint("/"));
    try testing.expect(!ns.isMountPoint("/apps"));
    try ns.mount("/apps", .ramfs);
    try ns.mount("/apps/data", .ramfs);
    try testing.expectEqual(@as(usize, 3), ns.activeMountCount());
    try testing.expect(ns.isMountPoint("/apps"));
    try testing.expect(ns.isMountPoint("/apps/data"));
    try testing.expect(!ns.isMountPoint("/apps/data/file"));
    try testing.expect(!ns.isMountPoint("/apps/../data"));
    try ns.umount("/apps/data");
    try testing.expectEqual(@as(usize, 2), ns.activeMountCount());
    try testing.expect(!ns.isMountPoint("/apps/data"));
    try testing.expectEqualStrings("/data/file", (try ns.route("/apps/data/file")).relative_path);
}

test "mount routing preserves component boundaries and slot reuse" {
    var ns: Namespace = .{};
    ns.init();
    try ns.mount("/vol", .ramfs);
    const slot = (try ns.route("/vol/file")).slot;
    try testing.expect(slot != 0);
    try testing.expectEqual(@as(usize, 0), (try ns.route("/volume/file")).slot);
    try ns.umount("/vol");
    try testing.expectEqual(@as(usize, 0), (try ns.route("/vol/file")).slot);
    try ns.mount("/other", .ramfs);
    try testing.expectEqual(slot, (try ns.route("/other/file")).slot);
    try testing.expectEqualStrings("/file", (try ns.route("/other/file")).relative_path);
}
