const std = @import("std");

const SearchMode = enum { auto, linear };

/// What the benchmarked zbtree maps store per key.
const BenchValues = enum { usize, none };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize_explicit = b.user_input_options.contains("optimize");
    const optimize = b.standardOptimizeOption(.{});
    const search_mode = b.option(
        SearchMode,
        "search-mode",
        "Node search of the benchmarked maps: auto (default) or linear",
    ) orelse .auto;

    const zbtree_module = b.addModule("zbtree", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = addExecutable(b, .{
        .name = "zbtree",
        .root_source_file = "src/main.zig",
        .target = target,
        .optimize = optimize,
        .zbtree_module = zbtree_module,
    });
    b.installArtifact(exe);

    const compare_module = b.createModule(.{
        .root_source_file = b.path("benchmark/compare_summary.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bench_all_summary_module = b.createModule(.{
        .root_source_file = b.path("benchmark/bench_all_summary.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Benchmarks only make sense with an explicitly chosen release mode.
    const benchmarkable = optimize_explicit and optimize != .debug;
    const bench_exe: ?*std.Build.Step.Compile = if (benchmarkable)
        addBenchExecutable(b, target, optimize, search_mode, zbtree_module, .usize)
    else
        null;
    // Upstream btree-bench measures key-only collections, so bench-all does too.
    const key_only_bench_exe: ?*std.Build.Step.Compile = if (benchmarkable)
        addBenchExecutable(b, target, optimize, search_mode, zbtree_module, .none)
    else
        null;

    addRunStep(b, exe);
    addBenchStep(b, bench_exe, compare_module);
    addBenchAllStep(b, target, key_only_bench_exe, bench_all_summary_module);
    addTestStep(b, zbtree_module, exe, &.{ compare_module, bench_all_summary_module });
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
                .{ .name = "zbtree", .module = options.zbtree_module },
            },
        }),
    });
}

fn addRunStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    run_cmd.addPassthruArgs();
}

const bench_mode_message =
    "zig build bench needs an explicit optimize mode: -Doptimize=safe " ++
    "or -Doptimize=fast. " ++
    "Example: zig build bench -Doptimize=safe -- --items 100000 --runs 10";

fn addBenchExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    search_mode: SearchMode,
    zbtree_module: *std.Build.Module,
    values: BenchValues,
) *std.Build.Step.Compile {
    const bench_exe = addExecutable(b, .{
        .name = switch (values) {
            .usize => "zbtree-bench",
            .none => "zbtree-bench-key-only",
        },
        .root_source_file = "benchmark/bench.zig",
        .target = target,
        .optimize = optimize,
        .zbtree_module = zbtree_module,
    });
    const bench_options = b.addOptions();
    bench_options.addOption(SearchMode, "search_mode", search_mode);
    bench_options.addOption(BenchValues, "values", values);
    bench_exe.root_module.addOptions("build_options", bench_options);
    return bench_exe;
}

fn addBenchStep(
    b: *std.Build,
    bench_exe_or_null: ?*std.Build.Step.Compile,
    compare_module: *std.Build.Module,
) void {
    const bench_step = b.step(
        "bench",
        "Benchmark zbtree against tidwall/btree (needs -Doptimize=safe|fast)",
    );

    const bench_exe = bench_exe_or_null orelse {
        bench_step.dependOn(&b.addFail(bench_mode_message).step);
        return;
    };

    const compare_exe = b.addExecutable(.{
        .name = "zbtree-bench-compare",
        .root_module = compare_module,
    });

    // The scored Zig run uses the default smp allocator.
    const zig_bench_cmd = b.addRunArtifact(bench_exe);
    zig_bench_cmd.has_side_effects = true;
    const zig_output = zig_bench_cmd.captureStdOut(.{ .basename = "zig-bench.txt" });

    // Reference run of the same binary; --allocator is Zig-only, so it is added here and never passed through.
    const zig_arena_cmd = b.addRunArtifact(bench_exe);
    zig_arena_cmd.addArgs(&.{"--allocator=arena"});
    zig_arena_cmd.has_side_effects = true;
    const zig_arena_output = zig_arena_cmd.captureStdOut(.{ .basename = "zig-arena-bench.txt" });

    const go_bench_cmd = b.addSystemCommand(&.{ "go", "run", "." });
    go_bench_cmd.setCwd(b.path("benchmark/reference_btree"));
    go_bench_cmd.has_side_effects = true;
    const go_output = go_bench_cmd.captureStdOut(.{ .basename = "go-bench.txt" });

    const compare_cmd = b.addRunArtifact(compare_exe);
    compare_cmd.addArg("--zig");
    compare_cmd.addFileArg(zig_output);
    compare_cmd.addArg("--zig-arena");
    compare_cmd.addFileArg(zig_arena_output);
    compare_cmd.addArg("--go");
    compare_cmd.addFileArg(go_output);

    // Run 1 at a time
    zig_arena_cmd.step.dependOn(&zig_bench_cmd.step);
    go_bench_cmd.step.dependOn(&zig_arena_cmd.step);
    bench_step.dependOn(&compare_cmd.step);

    zig_bench_cmd.addPassthruArgs();
    zig_arena_cmd.addPassthruArgs();
    go_bench_cmd.addPassthruArgs();
}

const bench_all_mode_message =
    "zig build bench-all needs an explicit optimize mode: -Doptimize=safe " ++
    "or -Doptimize=fast. " ++
    "Example: zig build bench-all -Doptimize=fast -- --items 100000 --runs 10";

/// The rows from the tidwall/btree README benchmark that every implementation runs.
const readme_rows = "insert(seq),insert(rand),get(seq),get(rand)";

/// Compares zbtree with the B-trees from the tidwall/btree README on its four rows.
/// Every implementation stores keys only, as in upstream btree-bench.
/// The harnesses run one at a time; only the summary is printed.
fn addBenchAllStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    bench_exe_or_null: ?*std.Build.Step.Compile,
    summary_module: *std.Build.Module,
) void {
    const bench_all_step = b.step(
        "bench-all",
        "Benchmark zbtree, tidwall/btree, google/btree, Rust BTreeSet and frozenca/btree (needs -Doptimize=safe|fast)",
    );

    const bench_exe = bench_exe_or_null orelse {
        bench_all_step.dependOn(&b.addFail(bench_all_mode_message).step);
        return;
    };
    // Lazy, so debug builds and tests never fetch it.
    const frozenca = b.lazyDependency("frozenca_btree", .{}) orelse return;

    // Upstream btree-bench builds frozenca with -O3, so it is always ReleaseFast.
    const frozenca_exe = b.addExecutable(.{
        .name = "frozenca-bench",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libcpp = true,
        }),
    });
    frozenca_exe.root_module.addCSourceFile(.{
        .file = b.path("benchmark/frozenca_btree/bench.cpp"),
        .flags = &.{"-std=c++20"},
    });
    frozenca_exe.root_module.addIncludePath(frozenca.path("include"));

    const zig_cmd = b.addRunArtifact(bench_exe);
    zig_cmd.addArg("--bench=" ++ readme_rows);

    const tidwall_cmd = b.addSystemCommand(&.{ "go", "run", "-tags=keyonly", ".", "-bench=" ++ readme_rows });
    tidwall_cmd.setCwd(b.path("benchmark/reference_btree"));

    const google_cmd = b.addSystemCommand(&.{ "go", "run", "." });
    google_cmd.setCwd(b.path("benchmark/google_btree"));

    const rust_cmd = b.addSystemCommand(&.{ "cargo", "run", "--release", "--quiet", "--" });
    rust_cmd.setCwd(b.path("benchmark/rust_btree"));

    const frozenca_cmd = b.addRunArtifact(frozenca_exe);

    const summary_exe = b.addExecutable(.{
        .name = "zbtree-bench-all-summary",
        .root_module = summary_module,
    });
    const summary_cmd = b.addRunArtifact(summary_exe);

    const commands = [_]struct { *std.Build.Step.Run, []const u8 }{
        .{ zig_cmd, "zbtree.txt" },
        .{ tidwall_cmd, "tidwall_btree.txt" },
        .{ google_cmd, "google_btree.txt" },
        .{ rust_cmd, "rust_btree.txt" },
        .{ frozenca_cmd, "frozenca_btree.txt" },
    };
    // Compile the C++ harness before any measurement starts, then run 1 at a time.
    zig_cmd.step.dependOn(&frozenca_exe.step);
    for (commands, 0..) |command, index| {
        const run, const basename = command;
        run.has_side_effects = true;
        run.addPassthruArgs();
        summary_cmd.addFileArg(run.captureStdOut(.{ .basename = basename }));
        if (index > 0) run.step.dependOn(&commands[index - 1][0].step);
    }
    // Keep the summary build out of the measurements too.
    zig_cmd.step.dependOn(&summary_exe.step);

    bench_all_step.dependOn(&summary_cmd.step);
}

fn addTestStep(
    b: *std.Build,
    zbtree_module: *std.Build.Module,
    exe: *std.Build.Step.Compile,
    benchmark_tool_modules: []const *std.Build.Module,
) void {
    const module_tests = b.addTest(.{ .root_module = zbtree_module });
    const run_module_tests = b.addRunArtifact(module_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    for (benchmark_tool_modules) |module| {
        const tool_tests = b.addTest(.{ .root_module = module });
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }
}
