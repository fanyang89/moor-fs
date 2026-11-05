const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fuse = b.option(bool, "fuse", "Build the FUSE namespace and file adapter") orelse false;
    const relocatable = b.option(bool, "relocatable", "Use a sibling lib directory for the packaged FUSE library") orelse false;
    const fault_injection = b.option(bool, "fault-injection", "Enable test-only repair, write and metadata reply SIGSTOP checkpoints") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "fuse", fuse);
    options.addOption(bool, "fault_injection", fault_injection);
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
    const build_options = options.createModule();
    mod.addImport("build_options", build_options);
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
    exe.root_module.addImport("build_options", build_options);
    if (fuse) {
        const wal_fuse = b.addSystemCommand(&.{ "python3", "tools/test_cluster.py" });
        wal_fuse.addArtifactArg(exe);
        wal_fuse.addArg("--wal-fuse");
        b.step("test-wal-fuse", "Test shared WAL FUSE sessions and crash recovery").dependOn(&wal_fuse.step);
        const wal_smb = b.addSystemCommand(&.{ "python3", "tools/test_e2e.py" });
        wal_smb.addArtifactArg(exe);
        wal_smb.addArg("--wal-smb");
        b.step("test-wal-smb", "Test WAL FUSE/SMB on two CIFS backends (requires sudo)").dependOn(&wal_smb.step);
        exe.root_module.addIncludePath(b.path("third_party/libfuse/include"));
        exe.root_module.addIncludePath(b.path(".deps-build/libfuse"));
        exe.root_module.addCSourceFile(.{ .file = b.path("src/fuse_bridge.c"), .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror" } });
        exe.root_module.addLibraryPath(b.path(".deps-build/libfuse/lib"));
        if (relocatable) {
            exe.each_lib_rpath = false;
            exe.root_module.addRPathSpecial("$ORIGIN/../lib");
        } else {
            exe.root_module.addRPath(b.path(".deps-build/libfuse/lib"));
        }
        exe.root_module.linkSystemLibrary("fuse3", .{});
    }
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nas-fs CLI").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Test metadata and Raft state-machine integration").dependOn(&b.addRunArtifact(tests).step);
    const file_store_test = b.addExecutable(.{
        .name = "file-store-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/file_store_e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nas_fs", .module = mod }},
        }),
    });
    const wal_test = b.addSystemCommand(&.{ "python3", "tools/test_e2e.py" });
    wal_test.addArtifactArg(file_store_test);
    wal_test.addArg("--file-store");
    b.step("test-file-store", "Test mutable WAL files and process death on real CIFS backends (requires sudo)").dependOn(&wal_test.step);
    const mutable_driver = b.addExecutable(.{
        .name = "mutable-access-e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mutable_access_e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "nas_fs", .module = mod }},
        }),
    });
    const mutable_test = b.addSystemCommand(&.{ "python3", "tools/test_e2e.py" });
    mutable_test.addArtifactArg(exe);
    mutable_test.addArg("--mutable-access");
    mutable_test.addArtifactArg(mutable_driver);
    b.step("test-mutable-access", "Test guarded WAL migration and Raft reconciliation on CIFS (requires sudo)").dependOn(&mutable_test.step);
    const deps = b.addSystemCommand(&.{ "python3", "tools/deps.py", "check" });
    b.step("deps-check", "Check pinned dependency sources").dependOn(&deps.step);
    const cluster_test = b.addSystemCommand(&.{ "python3", "tools/test_cluster.py" });
    cluster_test.addArtifactArg(exe);
    if (fault_injection) cluster_test.addArg("--repair-faults");
    b.step("test-cluster", "Test three processes, failover, snapshots and recovery").dependOn(&cluster_test.step);
    const e2e_test = b.addSystemCommand(&.{ "python3", "tools/test_e2e.py" });
    e2e_test.addArtifactArg(exe);
    if (fault_injection) e2e_test.addArg("--repair-faults");
    if (fuse) e2e_test.addArg("--fuse");
    b.step("test-e2e", "Test real Samba/CIFS backends in a private mount namespace (requires sudo)").dependOn(&e2e_test.step);
    if (fuse) {
        const fuse_test = b.addSystemCommand(&.{ "python3", "tools/test_cluster.py" });
        fuse_test.addArtifactArg(exe);
        if (fault_injection) fuse_test.addArg("--repair-faults");
        fuse_test.addArg("--fuse");
        b.step("test-fuse", "Test two FUSE mounts against a three-node cluster").dependOn(&fuse_test.step);
        const smb_test = b.addSystemCommand(&.{ "python3", "tools/test_e2e.py" });
        smb_test.addArtifactArg(exe);
        if (fault_injection) smb_test.addArg("--repair-faults");
        smb_test.addArg("--smb");
        b.step("test-smb", "Test SMB clients through FUSE and CIFS backends (requires sudo)").dependOn(&smb_test.step);
    }
}
