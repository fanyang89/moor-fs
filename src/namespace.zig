//! Request-scoped namespace views. All strings belong to the supplied arena.
const std = @import("std");
const m = @import("metadata.zig");

pub const Lookup = struct { parent: u64, name: []const u8 };
pub const List = struct { parent: u64, after: ?[]const u8 = null, limit: u8 = 16 };
pub const Page = struct { entries: []const m.Node, next: ?[]const u8 };
pub const Query = union(enum) { get: u64, lookup: Lookup, list: List, check_path: m.PathCheck };
pub const Reply = union(enum) { node: ?m.Node, page: Page, checked: m.Status };
pub const OpenGuarded = struct { path: m.PathCheck, writable: bool };
pub const Api = struct {
    context: *anyopaque,
    query: *const fn (*anyopaque, std.mem.Allocator, Query) anyerror!Reply,
};
pub const Attributes = struct { node: m.Node, size: u64 };
pub const Change = union(enum) {
    create: struct { parent: u64, name: []const u8, kind: m.Kind },
    rename: struct { inode: u64, parent: u64, name: []const u8 },
    remove: struct { inode: u64 },
    rename_checked: m.RenameChecked,
    remove_checked: m.Entry,
    path_guarded: m.GuardedChange,
};
