const std = @import("std");
pub const c = @import("lmdb_c");

pub const Error = error{ MapFull, ReadersFull, CorruptStore, StorageIo, OutOfMemory };

pub fn check(rc: c_int) Error!void {
    return switch (rc) {
        c.MDB_SUCCESS => {},
        c.MDB_MAP_FULL => error.MapFull,
        c.MDB_READERS_FULL => error.ReadersFull,
        c.MDB_CORRUPTED, c.MDB_PAGE_NOTFOUND, c.MDB_INVALID, c.MDB_VERSION_MISMATCH, c.MDB_BAD_VALSIZE => error.CorruptStore,
        c.ENOMEM => error.OutOfMemory,
        else => error.StorageIo,
    };
}

pub const Environment = struct {
    handle: *c.MDB_env,

    pub fn open(path: [:0]const u8, map_size: usize) !Environment {
        if (map_size < 64 * 1024) return error.InvalidMapSize;
        var handle: ?*c.MDB_env = null;
        try check(c.mdb_env_create(&handle));
        errdefer c.mdb_env_close(handle);
        try check(c.mdb_env_set_mapsize(handle, map_size));
        try check(c.mdb_env_set_maxdbs(handle, 4));
        try check(c.mdb_env_set_maxreaders(handle, 64));
        try check(c.mdb_env_open(handle, path.ptr, c.MDB_NOTLS, 0o600));
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Environment) void {
        c.mdb_env_close(self.handle);
        self.* = undefined;
    }

    pub fn begin(self: *Environment, readonly: bool) Error!Transaction {
        var handle: ?*c.MDB_txn = null;
        try check(c.mdb_txn_begin(self.handle, null, if (readonly) c.MDB_RDONLY else 0, &handle));
        return .{ .handle = handle };
    }
};

pub const Transaction = struct {
    handle: ?*c.MDB_txn,

    pub fn abort(self: *Transaction) void {
        if (self.handle) |handle| c.mdb_txn_abort(handle);
        self.handle = null;
    }

    pub fn commit(self: *Transaction) Error!void {
        const handle = self.handle.?;
        self.handle = null;
        try check(c.mdb_txn_commit(handle));
    }

    pub fn openDatabase(self: *Transaction, name: [:0]const u8) Error!c.MDB_dbi {
        var database: c.MDB_dbi = undefined;
        try check(c.mdb_dbi_open(self.handle, name.ptr, c.MDB_CREATE, &database));
        return database;
    }

    pub fn get(self: *Transaction, db: c.MDB_dbi, key: []const u8) Error!?[]const u8 {
        var k = value(key);
        var v: c.MDB_val = undefined;
        const rc = c.mdb_get(self.handle, db, &k, &v);
        if (rc == c.MDB_NOTFOUND) return null;
        try check(rc);
        return bytes(v);
    }

    pub fn put(self: *Transaction, db: c.MDB_dbi, key: []const u8, data: []const u8) Error!void {
        var k = value(key);
        var v = value(data);
        try check(c.mdb_put(self.handle, db, &k, &v, 0));
    }

    pub fn delete(self: *Transaction, db: c.MDB_dbi, key: []const u8) Error!void {
        var k = value(key);
        const rc = c.mdb_del(self.handle, db, &k, null);
        if (rc == c.MDB_NOTFOUND) return error.CorruptStore;
        try check(rc);
    }

    pub fn count(self: *Transaction, db: c.MDB_dbi) Error!usize {
        var stat: c.MDB_stat = undefined;
        try check(c.mdb_stat(self.handle, db, &stat));
        return stat.ms_entries;
    }

    pub fn clear(self: *Transaction, db: c.MDB_dbi) Error!void {
        try check(c.mdb_drop(self.handle, db, 0));
    }

    pub fn hasPrefix(self: *Transaction, db: c.MDB_dbi, prefix: []const u8) Error!bool {
        var cursor: ?*c.MDB_cursor = null;
        try check(c.mdb_cursor_open(self.handle, db, &cursor));
        defer c.mdb_cursor_close(cursor);
        var k = value(prefix);
        var v: c.MDB_val = undefined;
        const rc = c.mdb_cursor_get(cursor, &k, &v, c.MDB_SET_RANGE);
        if (rc == c.MDB_NOTFOUND) return false;
        try check(rc);
        return std.mem.startsWith(u8, bytes(k), prefix);
    }
};

pub fn value(data: []const u8) c.MDB_val {
    return .{ .mv_size = data.len, .mv_data = @ptrCast(@constCast(data.ptr)) };
}

pub fn bytes(v: c.MDB_val) []const u8 {
    if (v.mv_size == 0) return "";
    return @as([*]const u8, @ptrCast(v.mv_data.?))[0..v.mv_size];
}
