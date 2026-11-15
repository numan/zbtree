const std = @import("std");

const Allocator = std.mem.Allocator;

/// A result is a tie when the faster side has less than (100 + tie_percent)% of the slower side's ops/sec.
const tie_percent = 10;

const Row = struct {
    key_name: []const u8,
    label: []const u8,
    ops_per_sec: u64,
};

const Section = struct {
    items: u64,
    key_name: []const u8,
    runs: u64,
};

const Config = struct {
    optimize: ?[]const u8 = null,
    safety: ?[]const u8 = null,
    allocator: ?[]const u8 = null,
    go: ?[]const u8 = null,
    gomaxprocs: ?[]const u8 = null,
    warmups: ?[]const u8 = null,
};

const Verdict = union(enum) {
    /// Percent difference between the two sides in tenths of a percent, truncated.
    tie: u64,
    /// Ratio of Zig ops/sec to Go ops/sec.
    zig_faster: f64,
    /// Ratio of Go ops/sec to Zig ops/sec.
    go_faster: f64,
    na,
};

/// Config fields shown in the summary header, present once the inputs are validated.
const Header = struct {
    optimize: []const u8,
    safety: []const u8,
    warmups: []const u8,
    go: []const u8,
    gomaxprocs: []const u8,
};

const Input = struct {
    config: Config,
    items: u64,
    runs: u64,
    rows: []const Row,
};

const Error = error{
    MissingConfigLine,
    MissingConfigField,
    WrongAllocator,
    MismatchedConfig,
    MismatchedRunParameters,
    MissingBenchmarkRow,
    MismatchedBenchmarkRows,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    const paths = parseArgs(args) catch {
        std.debug.print("error: InvalidBenchmarkSummaryArgs: usage: compare --zig FILE --zig-arena FILE --go FILE\n", .{});
        std.process.exit(2);
    };

    const zig_output = try std.Io.Dir.cwd().readFileAlloc(init.io, paths.zig, allocator, .limited(64 * 1024 * 1024));
    const arena_output = try std.Io.Dir.cwd().readFileAlloc(init.io, paths.zig_arena, allocator, .limited(64 * 1024 * 1024));
    const go_output = try std.Io.Dir.cwd().readFileAlloc(init.io, paths.go, allocator, .limited(64 * 1024 * 1024));

    // Parse and validate everything before writing anything, so a bad input never yields a partial table.
    const zig = parseInput(allocator, "zig", zig_output) catch std.process.exit(1);
    const zig_arena = parseInput(allocator, "zig-arena", arena_output) catch std.process.exit(1);
    const go = parseInput(allocator, "go", go_output) catch std.process.exit(1);
    const header = validateInputs(zig, zig_arena, go) catch std.process.exit(1);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try writeSummary(allocator, stdout, header, zig, zig_arena, go);
    try stdout.flush();
}

const InputPaths = struct {
    zig: []const u8,
    zig_arena: []const u8,
    go: []const u8,
};

fn parseArgs(args: []const []const u8) error{InvalidBenchmarkSummaryArgs}!InputPaths {
    var zig: ?[]const u8 = null;
    var zig_arena: ?[]const u8 = null;
    var go: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.InvalidBenchmarkSummaryArgs;
        const value = args[index + 1];
        if (std.mem.eql(u8, args[index], "--zig")) {
            zig = value;
        } else if (std.mem.eql(u8, args[index], "--zig-arena")) {
            zig_arena = value;
        } else if (std.mem.eql(u8, args[index], "--go")) {
            go = value;
        } else {
            return error.InvalidBenchmarkSummaryArgs;
        }
    }
    return .{
        .zig = zig orelse return error.InvalidBenchmarkSummaryArgs,
        .zig_arena = zig_arena orelse return error.InvalidBenchmarkSummaryArgs,
        .go = go orelse return error.InvalidBenchmarkSummaryArgs,
    };
}

fn fail(err: Error, comptime fmt: []const u8, args: anytype) Error {
    std.debug.print("error: {s}: " ++ fmt ++ "\n", .{@errorName(err)} ++ args);
    return err;
}

fn parseInput(allocator: Allocator, name: []const u8, output: []const u8) (Error || Allocator.Error)!Input {
    var config: ?Config = null;
    var first_section: ?Section = null;
    var key_name: []const u8 = "";
    var rows: std.ArrayList(Row) = .empty;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (parseConfigLine(line)) |parsed| {
            config = parsed;
            continue;
        }
        if (parseSectionHeader(line)) |parsed| {
            if (first_section) |first| {
                if (first.items != parsed.items or first.runs != parsed.runs) {
                    return fail(error.MismatchedRunParameters, "{s} input: section '{s}' reports {d} items / {d} runs, but '{s}' reported {d} / {d}", .{
                        name, parsed.key_name, parsed.items, parsed.runs, first.key_name, first.items, first.runs,
                    });
                }
            } else {
                first_section = parsed;
            }
            key_name = parsed.key_name;
            continue;
        }
        if (key_name.len == 0) continue;
        const parsed = parseBenchmarkLine(line) orelse continue;
        try rows.append(allocator, .{ .key_name = key_name, .label = parsed.label, .ops_per_sec = parsed.ops_per_sec });
    }

    const found_config = config orelse return fail(error.MissingConfigLine, "{s} input has no 'config:' line", .{name});
    const section = first_section orelse return fail(error.MissingBenchmarkRow, "{s} input has no 'Benchmarking' section", .{name});
    if (rows.items.len == 0) return fail(error.MissingBenchmarkRow, "{s} input has no result rows", .{name});

    return .{ .config = found_config, .items = section.items, .runs = section.runs, .rows = rows.items };
}

fn requireField(name: []const u8, field_name: []const u8, value: ?[]const u8) Error![]const u8 {
    return value orelse fail(error.MissingConfigField, "{s} 'config:' line has no {s}= field", .{ name, field_name });
}

fn validateInputs(zig: Input, zig_arena: Input, go: Input) Error!Header {
    const zig_allocator = try requireField("zig", "allocator", zig.config.allocator);
    const arena_allocator = try requireField("zig-arena", "allocator", zig_arena.config.allocator);
    const zig_optimize = try requireField("zig", "optimize", zig.config.optimize);
    const arena_optimize = try requireField("zig-arena", "optimize", zig_arena.config.optimize);
    const zig_safety = try requireField("zig", "safety", zig.config.safety);
    const arena_safety = try requireField("zig-arena", "safety", zig_arena.config.safety);
    const zig_warmups = try requireField("zig", "warmups", zig.config.warmups);
    const go_warmups = try requireField("go", "warmups", go.config.warmups);
    const go_version = try requireField("go", "go", go.config.go);
    const go_gomaxprocs = try requireField("go", "GOMAXPROCS", go.config.gomaxprocs);

    if (!std.mem.eql(u8, zig_allocator, "smp")) {
        return fail(error.WrongAllocator, "the scored zig input reports allocator={s}, expected smp (inputs swapped?)", .{zig_allocator});
    }
    if (!std.mem.eql(u8, arena_allocator, "arena")) {
        return fail(error.WrongAllocator, "the zig-arena input reports allocator={s}, expected arena (inputs swapped?)", .{arena_allocator});
    }
    if (!std.mem.eql(u8, zig_optimize, arena_optimize) or !std.mem.eql(u8, zig_safety, arena_safety)) {
        return fail(error.MismatchedConfig, "zig is optimize={s} safety={s} but zig-arena is optimize={s} safety={s}", .{
            zig_optimize, zig_safety, arena_optimize, arena_safety,
        });
    }
    if (!std.mem.eql(u8, zig_warmups, go_warmups)) {
        return fail(error.MismatchedConfig, "zig warmups={s} but go warmups={s}", .{ zig_warmups, go_warmups });
    }

    if (zig.items != go.items or zig.runs != go.runs or zig.items != zig_arena.items or zig.runs != zig_arena.runs) {
        return fail(error.MismatchedRunParameters, "inputs disagree on items/runs: zig {d}/{d}, zig-arena {d}/{d}, go {d}/{d}", .{
            zig.items, zig.runs, zig_arena.items, zig_arena.runs, go.items, go.runs,
        });
    }

    try matchRows("zig-arena", zig, zig_arena);
    try matchRows("go", zig, go);

    return .{
        .optimize = zig_optimize,
        .safety = zig_safety,
        .warmups = zig_warmups,
        .go = go_version,
        .gomaxprocs = go_gomaxprocs,
    };
}

/// Requires `other` to hold the same (key type, label) rows as the scored zig input, in any order, with the same row count.
fn matchRows(name: []const u8, zig: Input, other: Input) Error!void {
    for (zig.rows) |zig_row| {
        if (findRow(other.rows, zig_row.key_name, zig_row.label) == null) {
            return fail(error.MissingBenchmarkRow, "{s} input has no row '{s}' for {s} keys", .{ name, zig_row.label, zig_row.key_name });
        }
    }
    for (other.rows) |row| {
        if (findRow(zig.rows, row.key_name, row.label) == null) {
            return fail(error.MismatchedBenchmarkRows, "{s} input has row '{s}' for {s} keys that the zig input lacks", .{ name, row.label, row.key_name });
        }
    }
    if (zig.rows.len != other.rows.len) {
        return fail(error.MismatchedBenchmarkRows, "{s} input has {d} rows but the zig input has {d}", .{ name, other.rows.len, zig.rows.len });
    }
}

fn findRow(rows: []const Row, key_name: []const u8, label: []const u8) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key_name, key_name) and std.mem.eql(u8, row.label, label)) return row;
    }
    return null;
}

/// Parses `config: key=value key=value ...`. Returns null for any other line.
fn parseConfigLine(line: []const u8) ?Config {
    const prefix = "config: ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    var config: Config = .{};
    var pairs = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line[prefix.len..], "\r"), ' ');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "optimize")) config.optimize = value;
        if (std.mem.eql(u8, key, "safety")) config.safety = value;
        if (std.mem.eql(u8, key, "allocator")) config.allocator = value;
        if (std.mem.eql(u8, key, "go")) config.go = value;
        if (std.mem.eql(u8, key, "GOMAXPROCS")) config.gomaxprocs = value;
        if (std.mem.eql(u8, key, "warmups")) config.warmups = value;
    }
    return config;
}

/// Parses `Benchmarking N items, KEY keys, R times, using median`.
fn parseSectionHeader(line: []const u8) ?Section {
    const prefix = "Benchmarking ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const items_marker = " items, ";
    const keys_marker = " keys, ";
    const times_marker = " times";
    const items_index = std.mem.indexOf(u8, line, items_marker) orelse return null;
    const items = parseCommaU64(line[prefix.len..items_index]) catch return null;
    const key_start = items_index + items_marker.len;
    const key_end = std.mem.indexOf(u8, line[key_start..], keys_marker) orelse return null;
    const runs_start = key_start + key_end + keys_marker.len;
    const runs_end = std.mem.indexOf(u8, line[runs_start..], times_marker) orelse return null;
    const runs = parseCommaU64(line[runs_start .. runs_start + runs_end]) catch return null;
    return .{ .items = items, .key_name = line[key_start .. key_start + key_end], .runs = runs };
}

const ParsedBenchmarkLine = struct {
    label: []const u8,
    ops_per_sec: u64,
};

fn parseBenchmarkLine(line: []const u8) ?ParsedBenchmarkLine {
    const op_sec_marker = " op/sec";
    const op_sec_end = std.mem.indexOf(u8, line, op_sec_marker) orelse return null;
    const before_op_sec = std.mem.trim(u8, line[0..op_sec_end], " ");
    const op_sec_start = (std.mem.lastIndexOfScalar(u8, before_op_sec, ' ') orelse return null) + 1;
    const ops_per_sec = parseCommaU64(before_op_sec[op_sec_start..]) catch return null;

    const ops_in_marker = " ops in ";
    const ops_in_index = std.mem.indexOf(u8, line, ops_in_marker) orelse return null;
    const before_ops = std.mem.trim(u8, line[0..ops_in_index], " ");
    var label_end: usize = 0;
    while (label_end < before_ops.len and !isDigit(before_ops[label_end])) : (label_end += 1) {}
    const label = std.mem.trim(u8, before_ops[0..label_end], " ");
    if (label.len == 0) return null;

    return .{ .label = label, .ops_per_sec = ops_per_sec };
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn parseCommaU64(raw: []const u8) !u64 {
    var value: u64 = 0;
    for (raw) |byte| {
        if (byte == ',') continue;
        if (!isDigit(byte)) return error.InvalidBenchmarkNumber;
        value = try std.math.mul(u64, value, 10);
        value = try std.math.add(u64, value, byte - '0');
    }
    return value;
}

/// Compares Zig and Go throughput. Ties are decided with exact integer math:
/// the faster side must have at least (100 + tie_percent)% of the slower side's ops/sec to win.
fn verdict(zig_ops: u64, go_ops: u64) Verdict {
    if (zig_ops == 0 or go_ops == 0) return .na;
    const faster: u128 = @max(zig_ops, go_ops);
    const slower: u128 = @min(zig_ops, go_ops);
    if (faster * 100 < slower * (100 + tie_percent)) return .{ .tie = @intCast((faster - slower) * 1000 / slower) };
    const ratio = @as(f64, @floatFromInt(faster)) / @as(f64, @floatFromInt(slower));
    return if (zig_ops > go_ops) .{ .zig_faster = ratio } else .{ .go_faster = ratio };
}

const KeyScore = struct {
    key_name: []const u8,
    score: Score,
};

const Score = struct {
    zig_faster: usize = 0,
    tie: usize = 0,
    go_faster: usize = 0,
    na: usize = 0,

    fn add(score: *Score, v: Verdict) void {
        switch (v) {
            .zig_faster => score.zig_faster += 1,
            .tie => score.tie += 1,
            .go_faster => score.go_faster += 1,
            .na => score.na += 1,
        }
    }
};

fn nsPerOp(buf: []u8, ops_per_sec: u64) []const u8 {
    if (ops_per_sec == 0) return "n/a";
    const ns = 1e9 / @as(f64, @floatFromInt(ops_per_sec));
    return std.fmt.bufPrint(buf, "{d:.1}", .{ns}) catch "n/a";
}

fn verdictText(buf: []u8, v: Verdict) []const u8 {
    const text = switch (v) {
        .tie => |tenths| std.fmt.bufPrint(buf, "tie ({d}.{d}%)", .{ tenths / 10, tenths % 10 }),
        .zig_faster => |ratio| std.fmt.bufPrint(buf, "Zig {d:.2}x faster", .{ratio}),
        .go_faster => |ratio| std.fmt.bufPrint(buf, "Go  {d:.2}x faster", .{ratio}),
        .na => return "n/a",
    };
    return text catch "n/a";
}

fn writeThousands(writer: *std.Io.Writer, value: u64) !void {
    var digits_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{value}) catch unreachable;
    for (digits, 0..) |digit, index| {
        if (index != 0 and (digits.len - index) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

const operation_header = "operation";

fn writeSummary(allocator: Allocator, stdout: *std.Io.Writer, header: Header, zig: Input, zig_arena: Input, go: Input) !void {
    const safety_label = if (std.mem.eql(u8, header.safety, "on")) "ON" else "OFF";

    try stdout.writeAll("zbtree_ds (Zig) vs tidwall/btype (Go)\n");
    try writeThousands(stdout, zig.items);
    try stdout.print(" items · median of {d} runs · {s} warmups\n", .{ zig.runs, header.warmups });
    try stdout.print("  Zig        {s} · runtime safety {s} · std.heap.smp_allocator\n", .{ header.optimize, safety_label });
    try stdout.writeAll("  Zig arena  same build · per-sample ArenaAllocator (reference only, not scored)\n");
    try stdout.print("  Go         {s} · GOMAXPROCS={s} · bounds checks ON\n", .{ header.go, header.gomaxprocs });
    try stdout.writeAll("ns/op = median time per operation, lower is better.\n");
    try stdout.print("Result compares Zig vs Go; differences under {d}% are ties.\n", .{tie_percent});

    var label_width: usize = operation_header.len;
    for (zig.rows) |row| label_width = @max(label_width, row.label.len);

    var key_scores: std.ArrayList(KeyScore) = .empty;
    var total: Score = .{};

    for (zig.rows, 0..) |zig_row, index| {
        const is_new_key = index == 0 or !std.mem.eql(u8, zig.rows[index - 1].key_name, zig_row.key_name);
        if (is_new_key) {
            try key_scores.append(allocator, .{ .key_name = zig_row.key_name, .score = .{} });

            try stdout.print("\n{s} keys\n", .{zig_row.key_name});
            try writeRow(stdout, label_width, operation_header, "Zig ns/op", "Go ns/op", "result", "Zig arena");
        }

        const go_row = findRow(go.rows, zig_row.key_name, zig_row.label).?;
        const arena_row = findRow(zig_arena.rows, zig_row.key_name, zig_row.label).?;
        const v = verdict(zig_row.ops_per_sec, go_row.ops_per_sec);
        key_scores.items[key_scores.items.len - 1].score.add(v);
        total.add(v);

        var zig_buf: [32]u8 = undefined;
        var go_buf: [32]u8 = undefined;
        var result_buf: [32]u8 = undefined;
        var arena_buf: [32]u8 = undefined;
        try writeRow(
            stdout,
            label_width,
            zig_row.label,
            nsPerOp(&zig_buf, zig_row.ops_per_sec),
            nsPerOp(&go_buf, go_row.ops_per_sec),
            verdictText(&result_buf, v),
            nsPerOp(&arena_buf, arena_row.ops_per_sec),
        );
    }

    try stdout.print("\nSummary (Zig vs Go; ties within {d}%)\n", .{tie_percent});
    try stdout.print("{s:<15}{s:>12}{s:>6}{s:>12}\n", .{ "", "Zig faster", "tie", "Go faster" });
    for (key_scores.items) |entry| try writeScoreCounts(stdout, entry.key_name, entry.score);
    try writeScoreCounts(stdout, "all", total);
    if (total.na != 0) try stdout.print("n/a rows (not scored): {d}\n", .{total.na});
}

fn writeRow(
    stdout: *std.Io.Writer,
    label_width: usize,
    operation: []const u8,
    zig_ns: []const u8,
    go_ns: []const u8,
    result: []const u8,
    arena_ns: []const u8,
) !void {
    try stdout.writeAll(operation);
    try stdout.splatByteAll(' ', label_width - operation.len);
    try stdout.print("   {s:>10}   {s:>10}   {s:<18}   {s:>10}\n", .{ zig_ns, go_ns, result, arena_ns });
}

fn writeScoreCounts(stdout: *std.Io.Writer, name: []const u8, score: Score) !void {
    try stdout.print("{s:<15}{d:>12}{d:>6}{d:>12}\n", .{ name, score.zig_faster, score.tie, score.go_faster });
}

test "verdict is a tie below 1.10x and a win at exactly 1.10x" {
    try std.testing.expectEqual(Verdict{ .tie = 0 }, verdict(5_000, 5_000));

    const just_under = verdict(10_999, 10_000);
    try std.testing.expectEqual(Verdict{ .tie = 99 }, just_under);

    // A tie never renders as 10.0%: the percentage is truncated, not rounded.
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("tie (9.9%)", verdictText(&buf, just_under));

    const exact = verdict(11_000, 10_000);
    try std.testing.expect(exact == .zig_faster);
    try std.testing.expectApproxEqAbs(1.10, exact.zig_faster, 1e-9);
}

test "verdict names the faster side with its ratio" {
    const zig = verdict(30_000, 10_000);
    try std.testing.expect(zig == .zig_faster);
    try std.testing.expectApproxEqAbs(3.0, zig.zig_faster, 1e-9);

    const go = verdict(10_000, 25_000);
    try std.testing.expect(go == .go_faster);
    try std.testing.expectApproxEqAbs(2.5, go.go_faster, 1e-9);

    // A tie is symmetric: Go slightly ahead is still a tie.
    try std.testing.expect(verdict(10_000, 10_500) == .tie);
}

test "verdict is n/a when either side measured zero" {
    try std.testing.expectEqual(Verdict.na, verdict(0, 10_000));
    try std.testing.expectEqual(Verdict.na, verdict(10_000, 0));
    try std.testing.expectEqual(Verdict.na, verdict(0, 0));
}

test "parseBenchmarkLine reads label and comma-separated ops/sec from both harness formats" {
    const zig_line = "insert(seq)        2,000 ops in 0.000 secs 10.0 ns/op 100,205,421 op/sec";
    const zig_parsed = parseBenchmarkLine(zig_line).?;
    try std.testing.expectEqualStrings("insert(seq)", zig_parsed.label);
    try std.testing.expectEqual(@as(u64, 100_205_421), zig_parsed.ops_per_sec);

    const go_line = "pushFront(seq)      2,000 ops in   0.000 secs    33.8 ns/op    29,593,240 op/sec";
    const go_parsed = parseBenchmarkLine(go_line).?;
    try std.testing.expectEqualStrings("pushFront(seq)", go_parsed.label);
    try std.testing.expectEqual(@as(u64, 29_593_240), go_parsed.ops_per_sec);

    try std.testing.expect(parseBenchmarkLine("config: optimize=ReleaseFast safety=off allocator=smp warmups=2") == null);
}

test "parseConfigLine reads zig and go config lines" {
    const zig = parseConfigLine("config: optimize=ReleaseFast safety=off allocator=smp warmups=2").?;
    try std.testing.expectEqualStrings("ReleaseFast", zig.optimize.?);
    try std.testing.expectEqualStrings("off", zig.safety.?);
    try std.testing.expectEqualStrings("smp", zig.allocator.?);
    try std.testing.expectEqualStrings("2", zig.warmups.?);
    try std.testing.expect(zig.go == null);

    const go = parseConfigLine("config: go=go1.27.3 GOMAXPROCS=14 warmups=2").?;
    try std.testing.expectEqualStrings("go1.27.3", go.go.?);
    try std.testing.expectEqualStrings("14", go.gomaxprocs.?);

    try std.testing.expect(parseConfigLine("zbtree_ds (Zig)") == null);
}

test "parseSectionHeader reads items, key type and runs" {
    const section = parseSectionHeader("Benchmarking 1,000,000 items, uint64 keys, 50 times, using median").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), section.items);
    try std.testing.expectEqualStrings("uint64", section.key_name);
    try std.testing.expectEqual(@as(u64, 50), section.runs);

    try std.testing.expect(parseSectionHeader("insert(seq)        2,000 ops in 0.000 secs 10.0 ns/op 1 op/sec") == null);
}
