const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuse = b.option(bool, "fuse", "Build the read-only FUSE namespace adapter") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "fuse", fuse);
    const raft = b.dependency("raftz", .{ .target = target, .optimize = optimize });
    const grpc = @import("raftz").grpcLiteDependency(raft, target, optimize);
    const zli = b.dependency("zli", .{ .target = target, .optimize = optimize });
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
            .{ .name = "grpc_lite", .module = grpc.module("grpc_lite") },
        },
    });
    const exe = b.addExecutable(.{
        .name = "nas-fs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nas_fs", .module = mod },
                .{ .name = "zli", .module = zli.module("zli") },
            },
        }),
    });
    b.installArtifact(exe);
    exe.root_module.addOptions("build_options", options);
    if (fuse) {
        exe.root_module.addIncludePath(b.path("third_party/libfuse/include"));
        exe.root_module.addIncludePath(b.path(".deps-build/libfuse"));
        exe.root_module.addCSourceFile(.{ .file = b.path("src/fuse_bridge.c"), .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror" } });
        exe.root_module.addLibraryPath(b.path(".deps-build/libfuse/lib"));
        exe.root_module.addRPath(b.path(".deps-build/libfuse/lib"));
        exe.root_module.linkSystemLibrary("fuse3", .{});
    }
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nas-fs CLI").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Test metadata and Raft state-machine integration").dependOn(&b.addRunArtifact(tests).step);
    const deps = b.addSystemCommand(&.{ "python3", "tools/deps.py", "check" });
    b.step("deps-check", "Check pinned dependency sources").dependOn(&deps.step);
    const cluster_test = b.addSystemCommand(&.{ "python3", "tools/test_cluster.py" });
    cluster_test.addArtifactArg(exe);
    b.step("test-cluster", "Test three processes, failover, snapshots and recovery").dependOn(&cluster_test.step);
    const e2e_test = b.addSystemCommand(&.{ "python3", "tools/test_e2e.py" });
    e2e_test.addArtifactArg(exe);
    if (fuse) e2e_test.addArg("--fuse");
    b.step("test-e2e", "Test real Samba/CIFS backends in a private mount namespace (requires sudo)").dependOn(&e2e_test.step);
    if (fuse) {
        const fuse_test = b.addSystemCommand(&.{ "python3", "tools/test_cluster.py" });
        fuse_test.addArtifactArg(exe);
        fuse_test.addArg("--fuse");
        b.step("test-fuse", "Test two FUSE mounts against a three-node cluster").dependOn(&fuse_test.step);
        const smb_test = b.addSystemCommand(&.{ "python3", "tools/test_e2e.py" });
        smb_test.addArtifactArg(exe);
        smb_test.addArg("--smb");
        b.step("test-smb", "Test SMB clients through FUSE and CIFS backends (requires sudo)").dependOn(&smb_test.step);
    }
}
