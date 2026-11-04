const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const raft = b.dependency("raftz", .{ .target = target, .optimize = optimize });
    const mod = b.addModule("nas_fs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "raftz", .module = raft.module("raftz") }},
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
