//! Resolve the final byte ranges established by a bounded redo log. Unmodified
//! baseline bytes have no content evidence here. Payloads borrow the parsed WAL.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Range = struct { start: u64, end: u64, payload: ?[]const u8 };
const Event = struct { position: u64, index: usize, start: bool };
pub const Read = struct { offset: u64, bytes: []const u8, requested: usize };

/// Streaming read verification retains only this request's expected bytes and
/// the expected EOF byte. Untouched bytes keep their original caller value.
pub const ReadEvidence = struct {
    allocator: Allocator,
    read: Read,
    expected: []u8,
    size: u64,
    observed_size: u64,
    tail: ?u8 = null,

    pub fn init(allocator: Allocator, baseline_size: u64, observed_size: u64, read: Read) !ReadEvidence {
        _ = try std.math.add(u64, read.offset, read.bytes.len);
        return .{ .allocator = allocator, .read = read, .expected = try allocator.dupe(u8, read.bytes), .size = baseline_size, .observed_size = observed_size };
    }

    pub fn deinit(self: *ReadEvidence) void {
        self.allocator.free(self.expected);
    }

    fn overlay(self: *ReadEvidence, start: u64, end: u64, payload: ?[]const u8) void {
        if (self.observed_size > 0) {
            const tail = self.observed_size - 1;
            if (start <= tail and tail < end) self.tail = if (payload) |bytes| bytes[@intCast(tail - start)] else 0;
        }
        const lower = @max(start, self.read.offset);
        const upper = @min(end, self.read.offset + self.expected.len);
        if (lower >= upper) return;
        const target = self.expected[@intCast(lower - self.read.offset)..@intCast(upper - self.read.offset)];
        if (payload) |bytes| @memcpy(target, bytes[@intCast(lower - start)..][0..target.len]) else @memset(target, 0);
    }

    pub fn write(self: *ReadEvidence, offset: u64, payload: []const u8) !void {
        if (payload.len == 0) return;
        const end = try std.math.add(u64, offset, payload.len);
        if (offset > self.size) self.overlay(self.size, offset, null);
        self.overlay(offset, end, payload);
        self.size = @max(self.size, end);
    }

    pub fn truncate(self: *ReadEvidence, length: u64) void {
        self.overlay(@min(length, self.size), @max(length, self.size), null);
        self.size = length;
    }

    pub fn verify(self: *const ReadEvidence, io: Io, files: [2]Io.File) !void {
        if (self.size != self.observed_size) return error.WalDataSizeMismatch;
        const count = if (self.read.offset >= self.size) 0 else @min(self.read.requested, self.size - self.read.offset);
        if (count != self.read.bytes.len) return error.WalDataSizeMismatch;
        try verifyBounds(io, files, self.size, self.tail);
        if (!std.mem.eql(u8, self.expected, self.read.bytes)) return error.WalDataMismatch;
    }
};

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
        var tail: ?u8 = null;
        if (self.size > 0) {
            var index = self.ranges.items.len;
            while (index > 0) {
                index -= 1;
                const range = self.ranges.items[index];
                if (range.start <= self.size - 1 and range.end >= self.size) {
                    tail = if (range.payload) |bytes| bytes[@intCast(self.size - 1 - range.start)] else 0;
                    break;
                }
            }
        }
        try verifyBounds(io, files, self.size, tail);
        var events: std.ArrayList(Event) = .empty;
        defer events.deinit(self.allocator);
        for (self.ranges.items, 0..) |range, index| {
            if (range.start >= self.size) continue;
            try events.append(self.allocator, .{ .position = range.start, .index = index, .start = true });
            try events.append(self.allocator, .{ .position = @min(range.end, self.size), .index = index, .start = false });
        }
        std.mem.sort(Event, events.items, {}, earlier);
        var active: std.PriorityQueue(usize, void, newer) = .empty;
        defer active.deinit(self.allocator);
        var position: u64 = 0;
        var cursor: usize = 0;
        while (cursor < events.items.len) {
            const next = events.items[cursor].position;
            if (active.peek()) |index| if (position < next) try verifyRange(io, files, self.ranges.items[index], position, next);
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

fn verifyBounds(io: Io, files: [2]Io.File, size: u64, tail: ?u8) !void {
    for (files) |file| {
        if ((try file.stat(io)).size != size) return error.WalDataSizeMismatch;
        // CIFS can retain stale size or zero-fill after server-side truncation.
        var byte: [1]u8 = undefined;
        if (size > 0) {
            if (try file.readPositionalAll(io, &byte, size - 1) != 1) return error.WalDataSizeMismatch;
            if (tail) |expected| if (byte[0] != expected) return error.WalDataMismatch;
        }
        if (try file.readPositionalAll(io, &byte, size) != 0) return error.WalDataSizeMismatch;
    }
}

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
