const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zbtree_module = b.addModule("zbtree_ds", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = addExecutable(b, .{
        .name = "zbtree_ds",
        .root_source_file = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .zbtree_module = zbtree_module,
    });
    b.installArtifact(exe);

    addRunStep(b, exe);
    addBenchStep(b, target, optimize, zbtree_module);
    addTestStep(b, zbtree_module, exe);
}

const ExecutableOptions = struct {
    name: []const u8,
    root_source_file: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zbtree_module: *std.Build.Module,
};

fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = options.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(options.root_source_file),
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{
                .{ .name = "zbtree_ds", .module = options.zbtree_module },
            },
        }),
    });
}

fn addRunStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    if (b.args) |args| run_cmd.addArgs(args);
}

fn addBenchStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zbtree_module: *std.Build.Module,
) void {
    const bench_exe = addExecutable(b, .{
        .name = "zbtree_ds-bench",
        .root_source_file = "benchmark/bench.zig",
        .target = target,
        .optimize = optimize,
        .zbtree_module = zbtree_module,
    });
    const compare_exe = b.addExecutable(.{
        .name = "zbtree_ds-bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmark/compare_summary.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const bench_step = b.step("bench", "Benchmark zbtree_ds against tidwall/btype");

    const zig_bench_cmd = b.addRunArtifact(bench_exe);
    zig_bench_cmd.has_side_effects = true;
    const zig_output = zig_bench_cmd.captureStdOut(.{ .basename = "zig-bench.txt" });

    const go_bench_cmd = b.addSystemCommand(&.{ "go", "run", "." });
    go_bench_cmd.setCwd(b.path("benchmark/reference_btype"));
    go_bench_cmd.has_side_effects = true;
    const go_output = go_bench_cmd.captureStdOut(.{ .basename = "go-bench.txt" });

    const compare_cmd = b.addRunArtifact(compare_exe);
    compare_cmd.step.dependOn(&zig_bench_cmd.step);
    compare_cmd.step.dependOn(&go_bench_cmd.step);
    compare_cmd.addFileArg(zig_output);
    compare_cmd.addFileArg(go_output);
    bench_step.dependOn(&compare_cmd.step);

    if (b.args) |args| {
        zig_bench_cmd.addArgs(args);
        go_bench_cmd.addArgs(args);
    }
}

fn addTestStep(
    b: *std.Build,
    zbtree_module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
) void {
    const module_tests = b.addTest(.{ .root_module = zbtree_module });
    const run_module_tests = b.addRunArtifact(module_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
