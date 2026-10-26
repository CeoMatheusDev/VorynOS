//************************************************************************//
//  vfsx.zig                                                               //
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
    MountGenerationExhausted,
    UnsupportedVolume,
    VolumeAlreadyRegistered,
    VolumeRegistryFull,
    VolumeBusy,
    StaleMount,
};

pub const Mount = struct {
    path: [max_path_len + 1]u8 = @splat(0),
    length: usize = 0,
    backend: Backend = .ramfs,
    active: bool = false,
    generation: u64 = 0,
    volume_id: u32 = 0,

    pub fn name(self: *const Mount) []const u8 {
        return self.path[0..self.length];
    }
};

pub const Route = struct {
    slot: usize,
    backend: Backend,
    relative_path: []const u8,
    generation: u64,
    volume_id: u32,
};

pub const Namespace = struct {
    mounts: [max_mounts]Mount = @splat(.{}),
    next_generation: u64 = 1,
    registered_volumes: [max_mounts]?u32 = @splat(null),

    pub fn init(self: *Namespace) void {
        self.* = .{};
        self.registered_volumes[0] = 0;
        self.mounts[0] = makeMount("/", .ramfs);
        self.mounts[0].generation = self.next_generation;
        self.next_generation += 1;
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

    /// Registers a volume identity for later storage binding by the FS facade.
    /// This registry does not imply that an underlying storage instance exists.
    pub fn registerVolume(self: *Namespace, volume_id: u32) Error!void {
        if (volume_id == 0 or self.hasVolume(volume_id)) return error.VolumeAlreadyRegistered;
        for (&self.registered_volumes) |*slot| {
            if (slot.* == null) {
                slot.* = volume_id;
                return;
            }
        }
        return error.VolumeRegistryFull;
    }

    pub fn hasVolume(self: *const Namespace, volume_id: u32) bool {
        for (self.registered_volumes) |slot| {
            if (slot != null and slot.? == volume_id) return true;
        }
        return false;
    }

    pub fn unregisterVolume(self: *Namespace, volume_id: u32) Error!void {
        if (volume_id == 0) return error.RootMountRequired;
        for (self.mounts) |entry| {
            if (entry.active and entry.volume_id == volume_id) return error.VolumeBusy;
        }
        for (&self.registered_volumes) |*slot| {
            if (slot.* != null and slot.*.? == volume_id) {
                slot.* = null;
                return;
            }
        }
        return error.UnsupportedVolume;
    }

    /// Legacy mounts alias the root RamFS volume (volume zero).
    pub fn mount(self: *Namespace, path: []const u8, backend: Backend) Error!void {
        return self.mountVolume(path, backend, 0);
    }

    /// Registers a mount for an explicitly registered volume identity.
    /// The FS facade must bind storage before performing I/O on nonzero volumes.
    pub fn mountVolume(self: *Namespace, path: []const u8, backend: Backend, volume_id: u32) Error!void {
        if (!self.hasVolume(volume_id)) return error.UnsupportedVolume;
        if (!validPath(path)) return error.InvalidMountPoint;
        for (self.mounts) |entry| {
            if (entry.active and std.mem.eql(u8, entry.name(), path)) return error.AlreadyMounted;
        }
        for (&self.mounts) |*entry| {
            if (!entry.active) {
                if (self.next_generation == 0) return error.MountGenerationExhausted;
                entry.* = makeMount(path, backend);
                entry.generation = self.next_generation;
                entry.volume_id = volume_id;
                self.next_generation = self.next_generation +% 1;
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

    /// Unmount only when the caller holds the current mount generation.
    /// Prevents a stale administrative request from removing a replacement
    /// mount that reused the same path and slot.
    pub fn umountChecked(self: *Namespace, path: []const u8, generation: u64) Error!void {
        if (!validPath(path)) return error.InvalidMountPoint;
        var found: ?usize = null;
        for (self.mounts, 0..) |entry, index| {
            if (entry.active and std.mem.eql(u8, entry.name(), path)) {
                found = index;
                break;
            }
        }
        const index = found orelse return error.NotMounted;
        if (self.mounts[index].generation != generation) return error.StaleMount;
        return self.umount(path);
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

    /// Checks that an existing route still owns its original path prefix.
    /// This prevents accepting a route shadowed by a newer nested mount.
    pub fn isCurrentPathRoute(self: *const Namespace, path: []const u8, route_info: Route) bool {
        if (!self.isCurrentRoute(route_info)) return false;
        const current = self.route(path) catch return false;
        return current.slot == route_info.slot and
            current.generation == route_info.generation and
            current.volume_id == route_info.volume_id and
            current.backend == route_info.backend and
            std.mem.eql(u8, current.relative_path, route_info.relative_path);
    }

    /// Checks that a cached route still refers to the same mount instance.
    /// A slot can be reused after umount, but its generation cannot.
    pub fn isCurrentRoute(self: *const Namespace, route_info: Route) bool {
        if (route_info.slot >= max_mounts) return false;
        const mount_entry = self.mounts[route_info.slot];
        return mount_entry.active and mount_entry.generation == route_info.generation and mount_entry.backend == route_info.backend and mount_entry.volume_id == route_info.volume_id;
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
        return .{ .slot = index, .backend = self.mounts[index].backend, .relative_path = relative, .generation = self.mounts[index].generation, .volume_id = self.mounts[index].volume_id };
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

test "route generation rejects stale references after mount slot reuse" {
    var ns: Namespace = .{};
    ns.init();
    try ns.mount("/volume", .ramfs);
    const old = try ns.route("/volume/file");
    try testing.expect(ns.isCurrentRoute(old));
    try ns.umount("/volume");
    try testing.expect(!ns.isCurrentRoute(old));
    try ns.mount("/replacement", .ramfs);
    const fresh = try ns.route("/replacement/file");
    try testing.expectEqual(old.slot, fresh.slot);
    try testing.expect(old.generation != fresh.generation);
    try testing.expect(!ns.isCurrentRoute(old));
    try testing.expect(ns.isCurrentRoute(fresh));
}

test "route generation remains stable while a mount is active" {
    var ns: Namespace = .{};
    ns.init();
    const root = try ns.route("/one");
    try ns.mount("/volume", .ramfs);
    const first = try ns.route("/volume/one");
    const second = try ns.route("/volume/two");
    try testing.expectEqual(first.generation, second.generation);
    try testing.expect(ns.isCurrentRoute(first));
    try testing.expect(ns.isCurrentRoute(root));
    try ns.umount("/volume");
    try testing.expect(ns.isCurrentRoute(root));
    try testing.expect(!ns.isCurrentRoute(first));
}

test "mount generation exhaustion does not modify namespace" {
    var ns: Namespace = .{};
    ns.init();
    ns.next_generation = 0;
    try testing.expectError(error.MountGenerationExhausted, ns.mount("/new", .ramfs));
    try testing.expectEqual(@as(usize, 1), ns.activeMountCount());
    try testing.expect(!ns.isMountPoint("/new"));
    try testing.expectEqual(@as(usize, 0), (try ns.route("/new/file")).slot);
}

test "route identity rejects invalid slots and mismatched backends" {
    var ns: Namespace = .{};
    ns.init();
    const root = try ns.route("/file");
    try testing.expect(ns.isCurrentRoute(root));
    var invalid = root;
    invalid.slot = max_mounts;
    try testing.expect(!ns.isCurrentRoute(invalid));
    invalid = root;
    invalid.generation = 0;
    try testing.expect(!ns.isCurrentRoute(invalid));
}

test "volume identity remains root alias until independent storage exists" {
    var ns: Namespace = .{};
    ns.init();
    try testing.expectError(error.UnsupportedVolume, ns.mountVolume("/separate", .ramfs, 1));
    try testing.expectEqual(@as(usize, 1), ns.activeMountCount());
    try testing.expect(!ns.isMountPoint("/separate"));
    try ns.mountVolume("/alias", .ramfs, 0);
    const root = try ns.route("/file");
    const alias = try ns.route("/alias/file");
    try testing.expectEqual(@as(u32, 0), root.volume_id);
    try testing.expectEqual(root.volume_id, alias.volume_id);
    try testing.expect(ns.isCurrentRoute(alias));
}

test "route identity includes volume metadata" {
    var ns: Namespace = .{};
    ns.init();
    const root = try ns.route("/file");
    var altered = root;
    altered.volume_id = 1;
    try testing.expect(!ns.isCurrentRoute(altered));
    try testing.expect(ns.isCurrentRoute(root));
}

test "checked unmount rejects stale generation after remount" {
    var ns: Namespace = .{};
    ns.init();
    try ns.mount("/data", .ramfs);
    const original = try ns.route("/data/file");
    try ns.umountChecked("/data", original.generation);
    try ns.mount("/data", .ramfs);
    const replacement = try ns.route("/data/file");
    try testing.expect(original.generation != replacement.generation);
    try testing.expectError(error.StaleMount, ns.umountChecked("/data", original.generation));
    try testing.expect(ns.isCurrentRoute(replacement));
    try ns.umountChecked("/data", replacement.generation);
    try testing.expect(!ns.isMountPoint("/data"));
}

test "checked unmount respects nested mounts and protects root" {
    var ns: Namespace = .{};
    ns.init();
    const root = try ns.route("/");
    try testing.expectError(error.RootMountRequired, ns.umountChecked("/", root.generation));
    try ns.mount("/data", .ramfs);
    const parent = try ns.route("/data");
    try ns.mount("/data/nested", .ramfs);
    try testing.expectError(error.MountBusy, ns.umountChecked("/data", parent.generation));
    try testing.expect(ns.isMountPoint("/data"));
    try testing.expect(ns.isMountPoint("/data/nested"));
    try testing.expectError(error.NotMounted, ns.umountChecked("/missing", parent.generation));
}

test "path route detects shadowing by nested mount" {
    var ns: Namespace = .{};
    ns.init();
    try ns.mount("/apps", .ramfs);
    const path = "/apps/data/file";
    const old = try ns.route(path);
    try testing.expect(ns.isCurrentPathRoute(path, old));
    try ns.mount("/apps/data", .ramfs);
    try testing.expect(ns.isCurrentRoute(old));
    try testing.expect(!ns.isCurrentPathRoute(path, old));
    const updated = try ns.route(path);
    try testing.expect(ns.isCurrentPathRoute(path, updated));
    try ns.umount("/apps/data");
    try testing.expect(!ns.isCurrentPathRoute(path, updated));
    try testing.expect(ns.isCurrentPathRoute(path, old));
}

test "path route rejects mismatched paths and malformed inputs" {
    var ns: Namespace = .{};
    ns.init();
    const original = try ns.route("/one");
    try testing.expect(ns.isCurrentPathRoute("/one", original));
    try testing.expect(!ns.isCurrentPathRoute("/two", original));
    try testing.expect(!ns.isCurrentPathRoute("/../one", original));
    try testing.expect(!ns.isCurrentPathRoute("", original));
}

test "volume registry permits explicit mounts and prevents unsafe reuse" {
    var ns: Namespace = .{};
    ns.init();
    try testing.expectError(error.UnsupportedVolume, ns.mountVolume("/data", .ramfs, 7));
    try ns.registerVolume(7);
    try testing.expectError(error.VolumeAlreadyRegistered, ns.registerVolume(7));
    try ns.mountVolume("/data", .ramfs, 7);
    const route_info = try ns.route("/data/file");
    try testing.expectEqual(@as(u32, 7), route_info.volume_id);
    try testing.expect(ns.isCurrentRoute(route_info));
    try testing.expectError(error.VolumeBusy, ns.unregisterVolume(7));
    try ns.umount("/data");
    try testing.expect(!ns.isCurrentRoute(route_info));
    try ns.unregisterVolume(7);
    try testing.expect(!ns.hasVolume(7));
    try testing.expectError(error.UnsupportedVolume, ns.mountVolume("/data", .ramfs, 7));
    try testing.expectError(error.RootMountRequired, ns.unregisterVolume(0));
}
