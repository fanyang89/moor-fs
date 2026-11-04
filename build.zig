const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const raft = b.dependency("raftz", .{ .target = target, .optimize = optimize });
    const lmdb_headers = b.addTranslateC(.{
        .root_source_file = b.path("src/lmdb_bindings.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lmdb_headers.addIncludePath(b.path("third_party/lmdb/libraries/liblmdb"));
    const lmdb = lmdb_headers.createModule();
    lmdb.addCSourceFiles(.{
        .root = b.path("third_party/lmdb/libraries/liblmdb"),
        .files = &.{ "mdb.c", "midl.c" },
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE" },
    });
    const mod = b.addModule("nas_fs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raftz", .module = raft.module("raftz") },
            .{ .name = "lmdb_c", .module = lmdb },
        },
    });
    const exe = b.addExecutable(.{
        .name = "nas-fs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nas_fs", .module = mod }},
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the metadata demonstration").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Test metadata and Raft state-machine integration").dependOn(&b.addRunArtifact(tests).step);
    const deps = b.addSystemCommand(&.{ "python3", "tools/deps.py", "check" });
    b.step("deps-check", "Check pinned dependency sources").dependOn(&deps.step);
}
