//! Resident-core handle ownership. Transport assigns connection IDs; no pointer
//! crosses the boundary. All Access operations are serialized, including cleanup.
const std = @import("std");
const access = @import("mutable_access.zig");
const objects = @import("objects.zig");

pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    metadata: access.Metadata,
    mappings: []const objects.Mapping,
    migration_pair: [2]u64,
    mutex: std.Io.Mutex = .init,
    sessions: std.AutoHashMapUnmanaged(u64, *Session) = .empty,
    handles: std.AutoHashMapUnmanaged(u64, Handle) = .empty,
    connections: std.AutoHashMapUnmanaged(u64, void) = .empty,
    next_id: u64 = 1,
    max_handles: usize = 1024,
    max_connections: usize = 128,

    const Session = struct { file: access.Access, refs: usize = 0, writer: bool = false };
    const Handle = struct { owner: u64, inode: u64, session: *Session, writable: bool };
    pub const Opened = struct { handle: u64, size: u64 };

    // IDs are never reused during this service lifetime. A restarted transport
    // must reject all connections from its previous instance.
    fn id(self: *Service) !u64 {
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        const result = self.next_id;
        self.next_id += 1;
        return result;
    }

    pub fn connect(self: *Service) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (self.connections.count() >= self.max_connections) return error.ConnectionLimit;
        const owner = try self.id();
        try self.connections.put(self.allocator, owner, {});
        return owner;
    }

    pub fn open(self: *Service, owner: u64, inode: u64, writable: bool) !Opened {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.connections.contains(owner)) return error.InvalidConnection;
        if (self.handles.count() >= self.max_handles) return error.HandleLimit;
        const key = try self.id();
        try self.handles.ensureUnusedCapacity(self.allocator, 1);
        const existing = self.sessions.get(inode);
        const session = existing orelse blk: {
            try self.sessions.ensureUnusedCapacity(self.allocator, 1);
            const new = try self.allocator.create(Session);
            errdefer self.allocator.destroy(new);
            new.* = .{ .file = try access.Access.open(self.allocator, self.io, self.metadata, self.mappings, inode, self.migration_pair) };
            break :blk new;
        };
        errdefer if (existing == null) {
            session.file.close();
            self.allocator.destroy(session);
        };
        if (writable and session.writer) return error.FileBusy;
        const current_size = try session.file.size();
        if (existing == null) self.sessions.putAssumeCapacity(inode, session);
        self.handles.putAssumeCapacity(key, .{ .owner = owner, .inode = inode, .session = session, .writable = writable });
        session.refs += 1;
        if (writable) session.writer = true;
        return .{ .handle = key, .size = current_size };
    }

    fn get(self: *Service, owner: u64, key: u64) !Handle {
        const handle = self.handles.get(key) orelse return error.InvalidHandle;
        if (handle.owner != owner) return error.InvalidHandle;
        return handle;
    }

    pub fn read(self: *Service, owner: u64, key: u64, bytes: []u8, offset: u64) !usize {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const handle = try self.get(owner, key);
        return handle.session.file.read(bytes, offset);
    }

    pub fn write(self: *Service, owner: u64, key: u64, bytes: []const u8, offset: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const handle = try self.get(owner, key);
        if (!handle.writable) return error.ReadOnlyHandle;
        try handle.session.file.write(bytes, offset);
    }

    pub fn truncate(self: *Service, owner: u64, key: u64, length: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const handle = try self.get(owner, key);
        if (!handle.writable) return error.ReadOnlyHandle;
        try handle.session.file.truncate(length);
    }

    pub fn size(self: *Service, owner: u64, key: u64) !u64 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const handle = try self.get(owner, key);
        return handle.session.file.size();
    }

    pub fn sync(self: *Service, owner: u64, key: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const handle = try self.get(owner, key);
        try handle.session.file.sync();
    }

    fn release(self: *Service, key: u64, handle: Handle) void {
        _ = self.handles.remove(key);
        const session = handle.session;
        if (handle.writable) session.writer = false;
        session.refs -= 1;
        if (session.refs == 0) {
            _ = self.sessions.remove(handle.inode);
            session.file.close();
            self.allocator.destroy(session);
        }
    }

    /// Close releases the handle even if checkpointing fails. Surviving handles
    /// retain the failed session; only the last release permits recovery on open.
    pub fn close(self: *Service, owner: u64, key: u64) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const handle = try self.get(owner, key);
        defer self.release(key, handle);
        if (handle.writable) try handle.session.file.sync();
    }

    /// Disconnect does not imply fsync success. Acknowledged writes already have
    /// dual durable WALs; dirty last-release state is recovered by the next open.
    pub fn disconnect(self: *Service, owner: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        while (true) {
            var iterator = self.handles.iterator();
            var found: ?u64 = null;
            while (iterator.next()) |entry| {
                if (entry.value_ptr.owner == owner) {
                    found = entry.key_ptr.*;
                    break;
                }
            }
            const key = found orelse break;
            self.release(key, self.handles.get(key).?);
        }
        _ = self.connections.remove(owner);
    }

    /// Called after the transport has joined all request workers.
    pub fn deinit(self: *Service) void {
        var iterator = self.sessions.valueIterator();
        while (iterator.next()) |session| {
            session.*.file.close();
            self.allocator.destroy(session.*);
        }
        self.sessions.deinit(self.allocator);
        self.handles.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.* = undefined;
    }
};
