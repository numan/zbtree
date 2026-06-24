const std = @import("std");

const Allocator = std.mem.Allocator;

const Row = struct {
    key_name: []const u8,
    label: []const u8,
    ops_per_sec: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.InvalidBenchmarkSummaryArgs;

    const zig_output = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(zig_output);
    const go_output = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(go_output);

    var zig_rows: std.ArrayList(Row) = .empty;
    defer zig_rows.deinit(allocator);
    var go_rows: std.ArrayList(Row) = .empty;
    defer go_rows.deinit(allocator);

    try parseRows(allocator, zig_output, &zig_rows);
    try parseRows(allocator, go_output, &go_rows);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};
    try stdout.writeAll(zig_output);
    if (!std.mem.endsWith(u8, zig_output, "\n")) try stdout.writeAll("\n");
    try stdout.writeAll(go_output);
    if (!std.mem.endsWith(u8, go_output, "\n")) try stdout.writeAll("\n");
    try writeComparison(stdout, zig_rows.items, go_rows.items);
}

fn parseRows(allocator: Allocator, output: []const u8, rows: *std.ArrayList(Row)) !void {
    var key_name: []const u8 = "";
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        if (parseKeyName(line)) |parsed| {
            key_name = parsed;
            continue;
        }
        if (key_name.len == 0) continue;
        const parsed = parseBenchmarkLine(line) orelse continue;
        try rows.append(allocator, .{
            .key_name = try allocator.dupe(u8, key_name),
            .label = try allocator.dupe(u8, parsed.label),
            .ops_per_sec = parsed.ops_per_sec,
        });
    }
}

fn parseKeyName(line: []const u8) ?[]const u8 {
    const prefix = "Benchmarking ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const items_marker = " items, ";
    const keys_marker = " keys,";
    const items_index = std.mem.indexOf(u8, line, items_marker) orelse return null;
    const key_start = items_index + items_marker.len;
    const key_end_rel = std.mem.indexOf(u8, line[key_start..], keys_marker) orelse return null;
    return line[key_start .. key_start + key_end_rel];
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

fn writeComparison(stdout: anytype, zig_rows: []const Row, go_rows: []const Row) !void {
    try stdout.writeAll("Comparison summary (median throughput)\n");
    try stdout.print("{s:<10} {s:<18} {s:>15} {s:>15} {s:<8} {s:>10}\n", .{ "key", "api", "zig ops/sec", "go ops/sec", "winner", "relative" });
    for (zig_rows) |zig_row| {
        const go_row = findRow(go_rows, zig_row.key_name, zig_row.label) orelse return error.MissingGoBenchmarkRow;
        const winner = if (zig_row.ops_per_sec >= go_row.ops_per_sec) "zig" else "go";
        const faster = @max(zig_row.ops_per_sec, go_row.ops_per_sec);
        const slower = @min(zig_row.ops_per_sec, go_row.ops_per_sec);
        try stdout.print("{s:<10} {s:<18} {d:>15} {d:>15} {s:<8} ", .{
            zig_row.key_name,
            zig_row.label,
            zig_row.ops_per_sec,
            go_row.ops_per_sec,
            winner,
        });
        if (slower == 0) {
            try stdout.writeAll("       n/a\n");
        } else {
            const relative = @as(f64, @floatFromInt(faster)) / @as(f64, @floatFromInt(slower));
            try stdout.print("{d:>9.2}x\n", .{relative});
        }
    }
}

fn findRow(rows: []const Row, key_name: []const u8, label: []const u8) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key_name, key_name) and std.mem.eql(u8, row.label, label)) return row;
    }
    return null;
}
