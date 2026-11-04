const std = @import("std");
const t = std.testing;
const objects = @import("objects.zig");
const m = @import("metadata.zig");

test "corrupt repair validates source before replacement and preserves existing handles" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const store = try objects.Store.open(t.io, path, true);
    defer store.close();
    const source = try tmp.dir.createFile(t.io, "source", .{ .read = true });
    defer source.close(t.io);
    try source.writePositionalAll(t.io, "payload", 0);
    const digest = try objects.hash(t.io, source);
    const version: m.Version = .{ .id = 1, .inode = 2, .size = digest.size, .sha256 = digest.sha256, .backends = .{ 1, 2 } };
    var buffer: [96]u8 = undefined;
    const name = try objects.name(&buffer, version);
    const damaged = try store.objects.createFile(t.io, name, .{ .read = true });
    defer damaged.close(t.io);
    try damaged.writePositionalAll(t.io, "damaged", 0);
    const before = try objects.hash(t.io, damaged);
    try source.writePositionalAll(t.io, "changed", 0);
    try t.expectError(error.SourceChanged, store.repairCorrupt(source, version));
    const unchanged = try store.objects.openFile(t.io, name, .{});
    defer unchanged.close(t.io);
    try t.expectEqualDeep(before, try objects.hash(t.io, unchanged));
    try source.writePositionalAll(t.io, "payload", 0);
    try t.expectError(error.ChecksumMismatch, store.put(source, version));
    try store.repairCorrupt(source, version);
    try store.repairCorrupt(source, version);
    const fixed = try store.openVerified(version);
    defer fixed.close(t.io);
    try t.expect(objects.matches(try objects.hash(t.io, fixed), version));
    try t.expectEqualDeep(before, try objects.hash(t.io, damaged));
    try t.expectEqualDeep(before, try objects.hash(t.io, unchanged));
    var iterator = store.staging.iterate();
    try t.expectEqual(null, try iterator.next(t.io));
}

test "a changed source cannot install an object under an earlier digest" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const store = try objects.Store.open(t.io, path, true);
    defer store.close();
    const file = try tmp.dir.createFile(t.io, "source", .{ .read = true });
    defer file.close(t.io);
    try file.writePositionalAll(t.io, "original", 0);
    const digest = try objects.hash(t.io, file);
    const version: m.Version = .{ .id = 1, .inode = 2, .size = digest.size, .sha256 = digest.sha256, .backends = .{ 1, 0 } };
    try file.writePositionalAll(t.io, "modified", 0);
    try t.expectError(error.SourceChanged, store.put(file, version));
    try t.expectError(error.FileNotFound, store.openVerified(version));
    var iterator = store.staging.iterate();
    try t.expectEqual(null, try iterator.next(t.io));
}

test "verified objects survive reopen and export never replaces an existing destination" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(path);
    const file = try tmp.dir.createFile(t.io, "source", .{ .read = true });
    defer file.close(t.io);
    try file.writePositionalAll(t.io, "payload", 0);
    const digest = try objects.hash(t.io, file);
    const version: m.Version = .{ .id = 1, .inode = 2, .size = digest.size, .sha256 = digest.sha256, .backends = .{ 1, 0 } };
    {
        const store = try objects.Store.open(t.io, path, true);
        defer store.close();
        try store.put(file, version);
        try store.put(file, version);
    }
    const reopened = try objects.Store.open(t.io, path, false);
    defer reopened.close();
    const object = try reopened.openVerified(version);
    defer object.close(t.io);
    const destination = try std.fs.path.join(t.allocator, &.{ path, "download" });
    defer t.allocator.free(destination);
    try objects.exportFile(t.io, object, destination, version);
    try t.expectError(error.PathAlreadyExists, objects.exportFile(t.io, object, destination, version));
    const downloaded = try tmp.dir.readFileAlloc(t.io, "download", t.allocator, .limited(100));
    defer t.allocator.free(downloaded);
    try t.expectEqualStrings("payload", downloaded);
}
