//! Validate the mount of an already-open directory, not just its pathname.
const std = @import("std");
const Io = std.Io;
const allocator = std.heap.smp_allocator;

pub const Identity = struct {
    mountpoint: []const u8,
    source: []const u8,
    address: []const u8,
};

fn readProc(io: Io, path: []const u8, limit: usize) ![]u8 {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    // procfs reports st_size=0; size-based readFileAlloc would return an empty slice.
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

pub fn mountId(io: Io, dir: Io.Dir) !u64 {
    var buffer: [80]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "/proc/self/fdinfo/{d}", .{dir.handle});
    const data = try readProc(io, path, 16 * 1024);
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "mnt_id:")) return std.fmt.parseUnsigned(u64, std.mem.trim(u8, line[7..], " \t"), 10);
    }
    return error.BackendMountMismatch;
}

pub fn validate(io: Io, dir: Io.Dir, identity: Identity) !u64 {
    const id = try mountId(io, dir);
    const data = try readProc(io, "/proc/self/mountinfo", 4 * 1024 * 1024);
    defer allocator.free(data);
    if (!matches(data, id, identity)) return error.BackendMountMismatch;
    return id;
}

fn option(options: []const u8, key: []const u8) ?[]const u8 {
    var tokens = std.mem.splitScalar(u8, options, ',');
    while (tokens.next()) |token| {
        if (std.mem.startsWith(u8, token, key)) return token[key.len..];
    }
    return null;
}

fn decodedEqual(encoded: []const u8, plain: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < encoded.len) : (j += 1) {
        var byte = encoded[i];
        if (byte == '\\') {
            if (i + 3 >= encoded.len) return false;
            byte = std.fmt.parseUnsigned(u8, encoded[i + 1 ..][0..3], 8) catch return false;
            i += 4;
        } else i += 1;
        if (j >= plain.len or byte != plain[j]) return false;
    }
    return j == plain.len;
}

fn matches(data: []const u8, id: u64, identity: Identity) bool {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const candidate = std.fmt.parseUnsigned(u64, fields.next() orelse continue, 10) catch continue;
        if (candidate != id) continue;
        _ = fields.next() orelse return false; // parent mount ID
        _ = fields.next() orelse return false; // device
        if (!std.mem.eql(u8, fields.next() orelse return false, "/")) return false;
        if (!decodedEqual(fields.next() orelse return false, identity.mountpoint)) return false;
        while (fields.next()) |field| {
            if (std.mem.eql(u8, field, "-")) break;
        } else return false;
        if (!std.mem.eql(u8, fields.next() orelse return false, "cifs")) return false;
        if (!decodedEqual(fields.next() orelse return false, identity.source)) return false;
        const options = fields.next() orelse return false;
        if (!std.mem.eql(u8, option(options, "addr=") orelse return false, identity.address)) return false;
        return true;
    }
    return false;
}

test "mount identity rejects stale IDs, local fallback, wrong shares and bind subtrees" {
    const t = std.testing;
    const identity: Identity = .{ .mountpoint = "/mnt/nas a", .source = "//server/data", .address = "192.0.2.1" };
    const line = "42 1 0:1 / /mnt/nas\\040a rw shared:2 - cifs //server/data rw,addr=192.0.2.1,port=1445\n";
    try t.expect(matches(line, 42, identity));
    try t.expect(!matches(line, 43, identity));
    var wrong = identity;
    wrong.source = "//server/other";
    try t.expect(!matches(line, 42, wrong));
    wrong = identity;
    wrong.address = "192.0.2.2";
    try t.expect(!matches(line, 42, wrong));
    try t.expect(!matches("42 1 0:1 / /mnt/nas\\040a rw - ext4 /dev/sda rw\n", 42, identity));
    try t.expect(!matches("42 1 0:1 /subdir /mnt/nas\\040a rw - cifs //server/data rw,addr=192.0.2.1,port=1445\n", 42, identity));
}

test "live directory descriptor exposes a mount ID" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(try mountId(std.testing.io, tmp.dir) != 0);
}
