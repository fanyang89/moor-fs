const std = @import("std");
const access = @import("mutable_access.zig");
const m = @import("metadata.zig");
const runtime = @import("runtime.zig");
const ns = @import("namespace.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoints: []const u8,

    pub fn api(self: *Client) access.Metadata {
        return .{ .context = self, .get = get, .version = version, .backend = backend, .apply = apply };
    }

    pub fn namespace(self: *Client) ns.Api {
        return .{ .context = self, .query = namespaceQuery };
    }

    fn namespaceQuery(context: *anyopaque, arena: std.mem.Allocator, input: ns.Query) !ns.Reply {
        const self: *Client = @ptrCast(@alignCast(context));
        return switch (input) {
            .get => |id| .{ .node = try self.namespaceRead(?m.Node, arena, "Get", .{ .id = id }) },
            .lookup => |lookup| .{ .node = try self.namespaceRead(?m.Node, arena, "Lookup", lookup) },
            .list => |list| .{ .page = try self.namespaceRead(ns.Page, arena, "List", list) },
        };
    }

    fn namespaceRead(self: *Client, comptime T: type, arena: std.mem.Allocator, method: []const u8, input: anytype) !T {
        const request = try std.json.Stringify.valueAlloc(arena, input, .{});
        const response = try runtime.call(self.allocator, self.endpoints, method, request);
        defer self.allocator.free(response);
        return std.json.parseFromSliceLeaky(T, arena, response, .{ .allocate = .alloc_always });
    }

    fn query(self: *Client, comptime T: type, method: []const u8, input: anytype) !std.json.Parsed(T) {
        const request = try std.json.Stringify.valueAlloc(self.allocator, input, .{});
        defer self.allocator.free(request);
        const response = try runtime.call(self.allocator, self.endpoints, method, request);
        defer self.allocator.free(response);
        return std.json.parseFromSlice(T, self.allocator, response, .{ .allocate = .alloc_always });
    }

    fn get(context: *anyopaque, id: u64) !access.Head {
        const self: *Client = @ptrCast(@alignCast(context));
        const result = try self.query(?m.Node, "Get", .{ .id = id });
        defer result.deinit();
        return access.Head.from(result.value orelse return error.NotFound);
    }

    fn version(context: *anyopaque, id: u64) !m.Version {
        const self: *Client = @ptrCast(@alignCast(context));
        const result = try self.query(?m.Version, "Version", .{ .id = id });
        defer result.deinit();
        return result.value orelse return error.VersionNotFound;
    }

    fn backend(context: *anyopaque, id: u64) !m.Backend {
        const self: *Client = @ptrCast(@alignCast(context));
        const result = try self.query(?m.Backend, "Backend", .{ .id = id });
        defer result.deinit();
        return result.value orelse return error.BackendNotFound;
    }

    fn apply(context: *anyopaque, request: m.Request) !m.Result {
        const self: *Client = @ptrCast(@alignCast(context));
        // runtime.call retains the original serialized request across retries.
        const result = try self.query(m.Result, "Apply", request);
        defer result.deinit();
        return result.value;
    }
};
