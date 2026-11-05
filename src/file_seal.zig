//! Optional content baseline for an idle mutable generation. Never a signature:
//! backend metadata is trusted, and the first baseline assumes replica agreement.
const std = @import("std");
const objects = @import("objects.zig");
const wal = @import("file_wal.zig");
const Io = std.Io;

pub const Seal = struct {
    next: u64,
    size: u64,
    sha256: [32]u8,

    pub fn read(io: Io, dir: Io.Dir, identity: wal.Identity) !?Seal {
        const file = dir.openFile(io, "seal", .{ .follow_symlinks = false, .allow_directory = false }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io);
        var bytes: [104]u8 = undefined;
        if ((try file.stat(io)).size != bytes.len or try file.readPositionalAll(io, &bytes, 0) != bytes.len) return error.CorruptSeal;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..72], &digest, .{});
        if (!std.mem.eql(u8, bytes[0..8], "NASSE001") or !std.mem.eql(u8, &digest, bytes[72..104])) return error.CorruptSeal;
        if (std.mem.readInt(u64, bytes[8..16], .little) != identity.inode or std.mem.readInt(u64, bytes[16..24], .little) != identity.generation) return error.SealIdentityMismatch;
        return .{ .next = std.mem.readInt(u64, bytes[24..32], .little), .size = std.mem.readInt(u64, bytes[32..40], .little), .sha256 = bytes[40..72].* };
    }

    pub fn load(io: Io, dirs: [2]Io.Dir, identity: wal.Identity, next: u64, size: u64) !?Seal {
        const a = try read(io, dirs[0], identity);
        const b = try read(io, dirs[1], identity);
        if (a != null and b != null and !std.meta.eql(a.?, b.?)) return error.SealDiverged;
        const seal = a orelse b orelse return null;
        if (seal.next != next or seal.size != size) return error.StaleSeal;
        return seal;
    }

    pub fn publish(self: Seal, io: Io, dir: Io.Dir, identity: wal.Identity) !void {
        var bytes: [104]u8 = undefined;
        @memcpy(bytes[0..8], "NASSE001");
        std.mem.writeInt(u64, bytes[8..16], identity.inode, .little);
        std.mem.writeInt(u64, bytes[16..24], identity.generation, .little);
        std.mem.writeInt(u64, bytes[24..32], self.next, .little);
        std.mem.writeInt(u64, bytes[32..40], self.size, .little);
        @memcpy(bytes[40..72], &self.sha256);
        std.crypto.hash.sha2.Sha256.hash(bytes[0..72], bytes[72..104], .{});
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = "seal-" ++ std.fmt.bytesToHex(random, .lower);
        const file = try dir.createFile(io, name, .{ .exclusive = true });
        defer file.close(io);
        defer dir.deleteFile(io, name) catch {};
        try file.writePositionalAll(io, &bytes, 0);
        try file.sync(io);
        try dir.rename(name, dir, "seal", io);
        try objects.syncDir(io, dir);
    }

    pub fn matches(self: Seal, io: Io, file: Io.File) !bool {
        const digest = try objects.hash(io, file);
        return digest.size == self.size and std.mem.eql(u8, &digest.sha256, &self.sha256);
    }

    /// The matching source remains untouched, making an interrupted repair
    /// restartable. Keep the destination inode and its exclusive lock intact.
    pub fn verify(self: Seal, io: Io, data: [2]Io.File, repair: bool) !void {
        const healthy = [2]bool{ try self.matches(io, data[0]), try self.matches(io, data[1]) };
        if (healthy[0] and healthy[1]) return;
        if (!repair) return error.SealedContentMismatch;
        if (!healthy[0] and !healthy[1]) return error.NoVerifiedReplica;
        const source = data[if (healthy[0]) @as(usize, 0) else 1];
        const target = data[if (healthy[0]) @as(usize, 1) else 0];
        var buffer: [256 * 1024]u8 = undefined;
        var offset: u64 = 0;
        while (offset < self.size) {
            const bytes = buffer[0..@min(buffer.len, self.size - offset)];
            if (try source.readPositionalAll(io, bytes, offset) != bytes.len) return error.SourceChanged;
            try target.writePositionalAll(io, bytes, offset);
            offset += bytes.len;
            if (offset == bytes.len) @import("repair_fault.zig").checkpoint(.mutable_first_chunk);
        }
        try target.setLength(io, self.size);
        try target.sync(io);
        @import("repair_fault.zig").checkpoint(.mutable_synced);
        if (!try self.matches(io, source) or !try self.matches(io, target)) return error.SealedContentMismatch;
    }
};
