// Copyright 2026 Numan (numan856@gmail.com)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//! Combines the output of several benchmark harnesses into README-style
//! per-implementation blocks followed by a side-by-side ns/op table.
const std = @import("std");
const builtin = @import("builtin");
const bench_output = @import("bench_output.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const label_column = 19;

const Row = struct {
    key_name: []const u8,
    label: []const u8,
    ops: []const u8,
    secs: []const u8,
    ns_per_op: []const u8,
    ops_per_sec_text: []const u8,
    ops_per_sec: u64,
};

const Implementation = struct {
    /// First line of the harness output, such as `google/btree (Go, btree.BTreeG)`.
    title: []const u8,
    /// Everything after `config: `.
    config: []const u8,
    items: u64,
    runs: u64,
    rows: []const Row,

    /// The title up to the language note, such as `google/btree`.
    fn name(self: Implementation) []const u8 {
        const end = std.mem.indexOf(u8, self.title, " (") orelse self.title.len;
        return self.title[0..end];
    }
};

const Error = error{
    MissingTitle,
    MissingConfigLine,
    MissingBenchmarkRow,
    MismatchedRunParameters,
    MismatchedBenchmarkRows,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) {
        std.debug.print("usage: bench-all-summary FILE...\n", .{});
        std.process.exit(2);
    }

    const implementations = try allocator.alloc(Implementation, args.len - 1);
    for (args[1..], implementations) |path, *implementation| {
        const output = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024 * 1024));
        implementation.* = parseImplementation(allocator, path, output) catch std.process.exit(1);
    }
    validate(implementations) catch std.process.exit(1);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try writeSummary(stdout, implementations);
    try stdout.flush();
}

fn fail(err: Error, comptime fmt: []const u8, args: anytype) Error {
    // Tests check the returned error; the message is for people running the tool.
    if (!builtin.is_test) std.debug.print("error: {s}: " ++ fmt ++ "\n", .{@errorName(err)} ++ args);
    return err;
}

fn parseImplementation(allocator: Allocator, source: []const u8, output: []const u8) (Error || Allocator.Error)!Implementation {
    var title: ?[]const u8 = null;
    var config: ?[]const u8 = null;
    var first_section: ?bench_output.Section = null;
    var key_name: []const u8 = "";
    var rows: std.ArrayList(Row) = .empty;

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        if (title == null) {
            title = line;
            continue;
        }
        if (std.mem.startsWith(u8, line, "config: ")) {
            config = line["config: ".len..];
            continue;
        }
        if (bench_output.parseSectionHeader(line)) |section| {
            if (first_section) |first| {
                if (first.items != section.items or first.runs != section.runs) {
                    return fail(error.MismatchedRunParameters, "{s}: section '{s}' reports {d} items / {d} runs, but '{s}' reported {d} / {d}", .{
                        source, section.key_name, section.items, section.runs, first.key_name, first.items, first.runs,
                    });
                }
            } else {
                first_section = section;
            }
            key_name = section.key_name;
            continue;
        }
        if (key_name.len == 0) continue;
        var row = parseResultLine(line) orelse continue;
        row.key_name = key_name;
        try rows.append(allocator, row);
    }

    const found_title = title orelse return fail(error.MissingTitle, "{s} is empty", .{source});
    const found_config = config orelse return fail(error.MissingConfigLine, "{s} has no 'config:' line", .{source});
    const section = first_section orelse return fail(error.MissingBenchmarkRow, "{s} has no 'Benchmarking' section", .{source});
    if (rows.items.len == 0) return fail(error.MissingBenchmarkRow, "{s} has no result rows", .{source});

    return .{
        .title = found_title,
        .config = found_config,
        .items = section.items,
        .runs = section.runs,
        .rows = rows.items,
    };
}

/// Parses `LABEL OPS ops in SECS secs NS ns/op OPS_PER_SEC op/sec`, with any spacing.
/// The returned row has an empty key name.
fn parseResultLine(line: []const u8) ?Row {
    var fields: [10][]const u8 = undefined;
    var count: usize = 0;
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    while (tokens.next()) |token| : (count += 1) {
        if (count == fields.len) return null;
        fields[count] = token;
    }
    if (count != fields.len) return null;
    const markers = [_]struct { usize, []const u8 }{ .{ 2, "ops" }, .{ 3, "in" }, .{ 5, "secs" }, .{ 7, "ns/op" }, .{ 9, "op/sec" } };
    for (markers) |marker| {
        if (!std.mem.eql(u8, fields[marker[0]], marker[1])) return null;
    }
    return .{
        .key_name = "",
        .label = fields[0],
        .ops = fields[1],
        .secs = fields[4],
        .ns_per_op = fields[6],
        .ops_per_sec_text = fields[8],
        .ops_per_sec = bench_output.parseCommaU64(fields[8]) catch return null,
    };
}

/// Requires every implementation to report the same items, runs and (key type, label) rows as the first.
fn validate(implementations: []const Implementation) Error!void {
    const first = implementations[0];
    for (implementations[1..]) |other| {
        if (other.items != first.items or other.runs != first.runs) {
            return fail(error.MismatchedRunParameters, "{s} ran {d} items / {d} runs, but {s} ran {d} / {d}", .{
                other.title, other.items, other.runs, first.title, first.items, first.runs,
            });
        }
        for (first.rows) |row| {
            if (findRow(other.rows, row.key_name, row.label) == null) {
                return fail(error.MismatchedBenchmarkRows, "{s} has no row '{s}' for {s} keys", .{ other.title, row.label, row.key_name });
            }
        }
        if (other.rows.len != first.rows.len) {
            return fail(error.MismatchedBenchmarkRows, "{s} has {d} rows but {s} has {d}", .{ other.title, other.rows.len, first.title, first.rows.len });
        }
    }
}

fn findRow(rows: []const Row, key_name: []const u8, label: []const u8) ?Row {
    for (rows) |row| {
        if (std.mem.eql(u8, row.key_name, key_name) and std.mem.eql(u8, row.label, label)) return row;
    }
    return null;
}

fn writeSummary(writer: *Writer, implementations: []const Implementation) !void {
    const first = implementations[0];
    try writer.writeAll("Benchmarking ");
    try writeThousands(writer, first.items);
    try writer.print(" items, {d} runs, using the median\n\n", .{first.runs});
    for (implementations) |implementation| {
        try writer.print("{s}\n  {s}\n", .{ implementation.title, implementation.config });
    }

    var key_start: usize = 0;
    while (key_start < first.rows.len) {
        const key_rows = rowsForKey(first.rows, key_start);
        try writer.print("\n### {s} keys\n", .{key_rows[0].key_name});
        for (implementations) |implementation| {
            try writer.print("\n{s}\n", .{implementation.name()});
            for (key_rows) |first_row| {
                try writeResultRow(writer, findRow(implementation.rows, first_row.key_name, first_row.label).?);
            }
        }
        key_start += key_rows.len;
    }

    try writer.writeAll("\n### ns/op by implementation (lower is better, * marks the fastest)\n");
    key_start = 0;
    while (key_start < first.rows.len) {
        const key_rows = rowsForKey(first.rows, key_start);
        try writer.print("\n{s} keys\n", .{key_rows[0].key_name});
        try writeComparisonTable(writer, implementations, key_rows);
        key_start += key_rows.len;
    }
}

/// Returns the run of rows starting at `start` that share its key type.
fn rowsForKey(rows: []const Row, start: usize) []const Row {
    var end = start + 1;
    while (end < rows.len and std.mem.eql(u8, rows[end].key_name, rows[start].key_name)) end += 1;
    return rows[start..end];
}

fn writeResultRow(writer: *Writer, row: Row) !void {
    try writer.writeAll(row.label);
    try writer.splatByteAll(' ', label_column -| row.label.len);
    if (row.label.len >= label_column) try writer.writeByte(' ');
    try writer.print("{s:>9} ops in {s:>7} secs {s:>7} ns/op {s:>13} op/sec\n", .{
        row.ops, row.secs, row.ns_per_op, row.ops_per_sec_text,
    });
}

fn writeComparisonTable(writer: *Writer, implementations: []const Implementation, key_rows: []const Row) !void {
    const operation_header = "operation";
    var label_width: usize = operation_header.len;
    for (key_rows) |row| label_width = @max(label_width, row.label.len);

    try writer.writeAll(operation_header);
    try writer.splatByteAll(' ', label_width - operation_header.len);
    for (implementations) |implementation| try writer.print("   {s:>10} ", .{implementation.name()});
    try writer.writeByte('\n');

    for (key_rows) |first_row| {
        var fastest: u64 = 0;
        for (implementations) |implementation| {
            fastest = @max(fastest, findRow(implementation.rows, first_row.key_name, first_row.label).?.ops_per_sec);
        }

        try writer.writeAll(first_row.label);
        try writer.splatByteAll(' ', label_width - first_row.label.len);
        for (implementations) |implementation| {
            const row = findRow(implementation.rows, first_row.key_name, first_row.label).?;
            const width = @max(implementation.name().len, 10);
            try writer.writeAll("   ");
            try writer.splatByteAll(' ', width -| row.ns_per_op.len);
            try writer.writeAll(row.ns_per_op);
            try writer.writeByte(if (row.ops_per_sec == fastest) '*' else ' ');
        }
        try writer.writeByte('\n');
    }
}

fn writeThousands(writer: *Writer, value: u64) !void {
    var digits_buf: [20]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{value}) catch unreachable;
    for (digits, 0..) |digit, index| {
        if (index != 0 and (digits.len - index) % 3 == 0) try writer.writeByte(',');
        try writer.writeByte(digit);
    }
}

test {
    _ = bench_output;
}

test "parseResultLine reads every harness format" {
    const zig = parseResultLine("insert(seq)        2,000 ops in 0.000 secs 10.0 ns/op 100,205,421 op/sec").?;
    try std.testing.expectEqualStrings("insert(seq)", zig.label);
    try std.testing.expectEqualStrings("2,000", zig.ops);
    try std.testing.expectEqualStrings("10.0", zig.ns_per_op);
    try std.testing.expectEqual(@as(u64, 100_205_421), zig.ops_per_sec);

    const go = parseResultLine("get(rand)           2,000 ops in   0.000 secs   134.0 ns/op     7,460,348 op/sec").?;
    try std.testing.expectEqualStrings("get(rand)", go.label);
    try std.testing.expectEqualStrings("134.0", go.ns_per_op);
    try std.testing.expectEqual(@as(u64, 7_460_348), go.ops_per_sec);

    // Labels of 19 or more characters are followed by a single space.
    const long = parseResultLine("deleteRangeAt(ret) 100 ops in 0.000 secs 5.0 ns/op 200,000,000 op/sec").?;
    try std.testing.expectEqualStrings("deleteRangeAt(ret)", long.label);

    try std.testing.expect(parseResultLine("config: go=go1.27.4 GOMAXPROCS=14 warmups=2") == null);
    try std.testing.expect(parseResultLine("Benchmarking 2000 items, int32 keys, 3 times, using median") == null);
}

const zig_output =
    \\
    \\zbtree (Zig)
    \\config: optimize=ReleaseFast safety=off allocator=smp search=auto warmups=2
    \\Benchmarking 2000 items, int32 keys, 3 times, using median
    \\insert(seq)        2,000 ops in 0.000 secs 10.0 ns/op 100,000,000 op/sec
    \\get(rand)          2,000 ops in 0.000 secs 40.0 ns/op 25,000,000 op/sec
    \\
    \\Benchmarking 2000 items, string keys, 3 times, using median
    \\insert(seq)        2,000 ops in 0.000 secs 80.0 ns/op 12,500,000 op/sec
    \\
;

const go_output =
    \\google/btree (Go, btree.BTreeG)
    \\config: go=go1.27.4 GOMAXPROCS=14 degree=32 warmups=2
    \\Benchmarking 2000 items, int32 keys, 3 times, using median
    \\insert(seq)         2,000 ops in   0.000 secs    70.0 ns/op    14,285,714 op/sec
    \\get(rand)           2,000 ops in   0.000 secs    20.0 ns/op    50,000,000 op/sec
    \\
    \\Benchmarking 2000 items, string keys, 3 times, using median
    \\insert(seq)         2,000 ops in   0.000 secs   100.0 ns/op    10,000,000 op/sec
    \\
;

test "parseImplementation reads title, config and rows per key type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parseImplementation(arena.allocator(), "zig", zig_output);

    try std.testing.expectEqualStrings("zbtree (Zig)", parsed.title);
    try std.testing.expectEqualStrings("zbtree", parsed.name());
    try std.testing.expectEqualStrings("optimize=ReleaseFast safety=off allocator=smp search=auto warmups=2", parsed.config);
    try std.testing.expectEqual(@as(u64, 2000), parsed.items);
    try std.testing.expectEqual(@as(u64, 3), parsed.runs);
    try std.testing.expectEqual(@as(usize, 3), parsed.rows.len);
    try std.testing.expectEqualStrings("string", parsed.rows[2].key_name);
}

test "validate rejects implementations that ran different rows or sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const zig = try parseImplementation(allocator, "zig", zig_output);
    const go = try parseImplementation(allocator, "go", go_output);
    try validate(&.{ zig, go });

    var fewer_rows = go;
    fewer_rows.rows = go.rows[0..2];
    try std.testing.expectError(error.MismatchedBenchmarkRows, validate(&.{ zig, fewer_rows }));

    var other_items = go;
    other_items.items = 1000;
    try std.testing.expectError(error.MismatchedRunParameters, validate(&.{ zig, other_items }));
}

test "comparison table marks the fastest implementation per row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const implementations = [_]Implementation{
        try parseImplementation(allocator, "zig", zig_output),
        try parseImplementation(allocator, "go", go_output),
    };

    var output: Writer.Allocating = .init(allocator);
    try writeComparisonTable(&output.writer, &implementations, rowsForKey(implementations[0].rows, 0));
    try std.testing.expectEqualStrings(
        \\operation         zbtree    google/btree 
        \\insert(seq)         10.0*           70.0 
        \\get(rand)           40.0            20.0*
        \\
    , output.written());
}
