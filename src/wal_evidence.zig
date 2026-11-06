//! Resolve the final byte ranges established by a bounded redo log. Unmodified
//! baseline bytes have no content evidence here. Payloads borrow the parsed WAL.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Range = struct { start: u64, end: u64, payload: ?[]const u8 };
const Event = struct { position: u64, index: usize, start: bool };
pub const Read = struct { offset: u64, bytes: []const u8, requested: usize };

pub const Evidence = struct {
    allocator: Allocator,
    size: u64,
    ranges: std.ArrayList(Range) = .empty,

    pub fn deinit(self: *Evidence) void {
        self.ranges.deinit(self.allocator);
    }

    fn add(self: *Evidence, start: u64, end: u64, payload: ?[]const u8) !void {
        if (start == end) return;
        try self.ranges.append(self.allocator, .{ .start = start, .end = end, .payload = payload });
    }

    pub fn write(self: *Evidence, offset: u64, payload: []const u8) !void {
        if (payload.len == 0) return;
        if (offset > self.size) try self.add(self.size, offset, null);
        const end = try std.math.add(u64, offset, payload.len);
        try self.add(offset, end, payload);
        self.size = @max(self.size, end);
    }

    pub fn truncate(self: *Evidence, length: u64) !void {
        // Truncated bytes cannot reappear when a later write extends the file.
        try self.add(@min(length, self.size), @max(length, self.size), null);
        self.size = length;
    }

    fn earlier(_: void, a: Event, b: Event) bool {
        return a.position < b.position;
    }

    fn newer(_: void, a: usize, b: usize) std.math.Order {
        return std.math.order(b, a);
    }

    /// Sweep interval boundaries with the latest operation winning overlaps.
    /// O(records log records), not quadratic for many small overlapping writes.
    pub fn verify(self: *const Evidence, io: Io, files: [2]Io.File) !void {
        try self.verifyWindow(io, files, null);
    }

    /// Check the actual caller-visible bytes, not a second read that could hide
    /// corruption in the already-filled buffer. An empty request checks size only.
    pub fn verifyRead(self: *const Evidence, io: Io, files: [2]Io.File, read: Read) !void {
        const expected = if (read.offset >= self.size) 0 else @min(read.requested, self.size - read.offset);
        if (read.bytes.len != expected) return error.WalDataSizeMismatch;
        try self.verifyWindow(io, files, read);
    }

    fn verifyWindow(self: *const Evidence, io: Io, files: [2]Io.File, read: ?Read) !void {
        for (files) |file| {
            if ((try file.stat(io)).size != self.size) return error.WalDataSizeMismatch;
            // CIFS may retain the old inode size on an open writable handle
            // after out-of-band server changes, even with cache=none/actimeo=0.
            var byte: [1]u8 = undefined;
            if (self.size > 0) {
                if (try file.readPositionalAll(io, &byte, self.size - 1) != 1) return error.WalDataSizeMismatch;
                // An open CIFS handle can zero-fill to its cached EOF after a
                // server-side truncation. Check the byte too when WAL covers it.
                var index = self.ranges.items.len;
                while (index > 0) {
                    index -= 1;
                    const range = self.ranges.items[index];
                    if (range.start <= self.size - 1 and range.end >= self.size) {
                        try compare(range, self.size - 1, &byte);
                        break;
                    }
                }
            }
            if (try file.readPositionalAll(io, &byte, self.size) != 0) return error.WalDataSizeMismatch;
        }
        var events: std.ArrayList(Event) = .empty;
        defer events.deinit(self.allocator);
        const lower = if (read) |value| value.offset else 0;
        const upper = if (read) |value| @min(self.size, try std.math.add(u64, value.offset, value.bytes.len)) else self.size;
        for (self.ranges.items, 0..) |range, index| {
            const start = @max(range.start, lower);
            const end = @min(range.end, upper);
            if (start >= end) continue;
            try events.append(self.allocator, .{ .position = start, .index = index, .start = true });
            try events.append(self.allocator, .{ .position = end, .index = index, .start = false });
        }
        std.mem.sort(Event, events.items, {}, earlier);
        var active: std.PriorityQueue(usize, void, newer) = .empty;
        defer active.deinit(self.allocator);
        var position: u64 = lower;
        var cursor: usize = 0;
        while (cursor < events.items.len) {
            const next = events.items[cursor].position;
            if (active.peek()) |index| {
                if (position < next) {
                    const range = self.ranges.items[index];
                    if (read) |value| {
                        try compare(range, position, value.bytes[@intCast(position - lower)..@intCast(next - lower)]);
                    } else try verifyRange(io, files, range, position, next);
                }
            }
            position = next;
            while (cursor < events.items.len and events.items[cursor].position == position) : (cursor += 1) {
                const event = events.items[cursor];
                if (event.start) try active.push(self.allocator, event.index);
            }
            while (active.peek()) |index| {
                if (self.ranges.items[index].end > position) break;
                _ = active.pop();
            }
        }
    }
};

fn verifyRange(io: Io, files: [2]Io.File, range: Range, start: u64, end: u64) !void {
    var buffer: [64 * 1024]u8 = undefined;
    var offset = start;
    while (offset < end) {
        const bytes = buffer[0..@min(buffer.len, end - offset)];
        for (files) |file| {
            if (try file.readPositionalAll(io, bytes, offset) != bytes.len) return error.WalDataSizeMismatch;
            try compare(range, offset, bytes);
        }
        offset += bytes.len;
    }
}

fn compare(range: Range, offset: u64, bytes: []const u8) !void {
    if (range.payload) |payload| {
        const relative: usize = @intCast(offset - range.start);
        if (!std.mem.eql(u8, bytes, payload[relative..][0..bytes.len])) return error.WalDataMismatch;
    } else {
        for (bytes) |byte| if (byte != 0) return error.WalDataMismatch;
    }
}
