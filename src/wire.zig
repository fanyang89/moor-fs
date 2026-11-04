const std = @import("std");

// Metadata RPCs use the single bytes field declared in proto/metadata.proto.
pub fn encode(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    if (json.len > 4096) return error.MessageTooLarge;
    var header: [6]u8 = undefined;
    header[0] = 10;
    var count: usize = 1;
    var size = json.len;
    while (size >= 128) : (size >>= 7) {
        header[count] = @as(u8, @intCast(size & 127)) | 128;
        count += 1;
    }
    header[count] = @intCast(size);
    count += 1;
    return std.mem.concat(allocator, u8, &.{ header[0..count], json });
}

pub fn decode(data: []const u8) ![]const u8 {
    if (data.len == 0) return "";
    if (data.len < 2 or data[0] != 10) return error.InvalidEnvelope;
    var size: usize = 0;
    for (data[1..], 0..) |byte, i| {
        if (i >= 4) return error.InvalidEnvelope;
        size |= @as(usize, byte & 127) << @intCast(i * 7);
        if (byte & 128 == 0) {
            if (size != data.len - i - 2 or size > 4096) return error.InvalidEnvelope;
            return data[i + 2 ..];
        }
    }
    return error.InvalidEnvelope;
}

test "bounded protobuf envelope round trip and malformed lengths" {
    const t = std.testing;
    for ([_]usize{ 0, 1, 127, 128, 4096 }) |size| {
        const bytes = try t.allocator.alloc(u8, size);
        defer t.allocator.free(bytes);
        @memset(bytes, 'a');
        const encoded = try encode(t.allocator, bytes);
        defer t.allocator.free(encoded);
        try t.expectEqualStrings(bytes, try decode(encoded));
    }
    try t.expectEqualStrings("", try decode(""));
    try t.expectError(error.InvalidEnvelope, decode("\x0a\x05abc"));
    try t.expectError(error.InvalidEnvelope, decode("\x0a\x80\x80\x80\x80\x01"));
    const oversized: [4097]u8 = @splat('a');
    try t.expectError(error.MessageTooLarge, encode(t.allocator, &oversized));
}
