const std = @import("std");
const zbtree_ds = @import("zbtree_ds");
const map = zbtree_ds.map;
const order = zbtree_ds.order;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const Options = struct {
    items: usize,
    runs: usize,
};

pub fn main(init: std.process.Init) !void {
    const args_allocator = init.arena.allocator();
    const options = try parseOptions(init, args_allocator);

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    try stdout.print("\nzbtree_ds (Zig)\n", .{});
    try benchType(
        order.OrderedKey(i32, void),
        "int32",
        options,
        allocator,
        init.io,
        stdout,
    );
    try benchType(
        order.OrderedKey(u64, void),
        "uint64",
        options,
        allocator,
        init.io,
        stdout,
    );
    try benchType(
        order.OrderedKey([]const u8, void),
        "string",
        options,
        allocator,
        init.io,
        stdout,
    );
}

fn parseOptions(init: std.process.Init, arena: Allocator) !Options {
    var options = Options{
        .items = try envUsize(init, "N", 1_000_000),
        .runs = try envUsize(init, "R", 50),
    };

    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--items") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i == args.len) return error.MissingBenchmarkArgument;
            options.items = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.startsWith(u8, arg, "--items=")) {
            options.items = try std.fmt.parseInt(usize, arg["--items=".len..], 10);
        } else if (std.mem.eql(u8, arg, "--runs") or std.mem.eql(u8, arg, "-r")) {
            i += 1;
            if (i == args.len) return error.MissingBenchmarkArgument;
            options.runs = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.startsWith(u8, arg, "--runs=")) {
            options.runs = try std.fmt.parseInt(usize, arg["--runs=".len..], 10);
        } else {
            return error.UnknownBenchmarkArgument;
        }
    }

    if (options.items == 0 or options.runs == 0) return error.InvalidBenchmarkOption;
    return options;
}

fn envUsize(init: std.process.Init, name: []const u8, default: usize) !usize {
    const value = init.environ_map.get(name) orelse return default;
    return std.fmt.parseInt(usize, value, 10);
}

fn benchType(
    comptime Order: type,
    comptime key_name: []const u8,
    options: Options,
    allocator: Allocator,
    io: Io,
    stdout: anytype,
) !void {
    const K = Order.Key;
    const Map = map.Map(K, void, .{ .use_string_prefix = Order.use_string_prefix });
    const Ctx = BenchContext(K, Map);

    var ctx = Ctx{
        .allocator = allocator,
        .prng = std.Random.DefaultPrng.init(0xdecafbad),
        .items = options.items,
        .tree = Map.init(),
    };
    defer ctx.deinit();

    try stdout.print("Benchmarking {d} items, {s} keys, {d} times, using median\n", .{ options.items, key_name, options.runs });
    try runBenchmark(
        Ctx,
        &ctx,
        "insert(seq)",
        options.runs,
        Ctx.preInsertSeq,
        Ctx.insertAll,
        allocator,
        io,
        stdout,
    );
    try runBenchmark(
        Ctx,
        &ctx,
        "insert(rand)",
        options.runs,
        Ctx.preInsertRand,
        Ctx.insertAll,
        allocator,
        io,
        stdout,
    );
    try runBenchmark(
        Ctx,
        &ctx,
        "get(seq)",
        options.runs,
        Ctx.preGetSeq,
        Ctx.getAll,
        allocator,
        io,
        stdout,
    );
    try runBenchmark(
        Ctx,
        &ctx,
        "get(rand)",
        options.runs,
        Ctx.preGetRand,
        Ctx.getAll,
        allocator,
        io,
        stdout,
    );
    try stdout.print("\n", .{});
}

fn BenchContext(comptime K: type, comptime Map: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        prng: std.Random.DefaultPrng,
        items: usize,
        tree: Map,
        keys: []K = &.{},
        string_bytes: if (K == []const u8) []u8 else void = if (K == []const u8) &.{} else {},
        checksum: usize = 0,

        resident_string_bytes: if (K == []const u8) []u8 else void = if (K == []const u8) &.{} else {},

        fn deinit(self: *Self) void {
            self.tree.deinit(self.allocator);
            self.freeKeys();
            self.freeResidentStringBytes();
        }

        fn freeKeys(self: *Self) void {
            if (self.keys.len != 0) self.allocator.free(self.keys);
            if (K == []const u8 and self.string_bytes.len != 0) self.allocator.free(self.string_bytes);
            self.keys = &.{};
            if (K == []const u8) self.string_bytes = &.{};
        }

        fn freeResidentStringBytes(self: *Self) void {
            if (K != []const u8) return;
            if (self.resident_string_bytes.len == 0) return;
            self.allocator.free(self.resident_string_bytes);
            self.resident_string_bytes = &.{};
        }

        fn makeKeys(self: *Self, random_order: bool) !void {
            self.freeKeys();
            self.keys = try makeKeySlice(K, self.allocator, self.items);
            errdefer self.freeKeys();
            if (random_order) self.prng.random().shuffle(K, self.keys);
        }

        fn makeStringKeys(self: *Self, random_order: bool) !void {
            self.freeKeys();
            self.keys = try self.allocator.alloc([]const u8, self.items);
            errdefer self.freeKeys();

            var total_len: usize = 0;
            for (0..self.items) |i| total_len += decimalLength(i);
            self.string_bytes = try self.allocator.alloc(u8, total_len);
            var offset: usize = 0;
            for (0..self.items) |i| {
                const written = try std.fmt.bufPrint(self.string_bytes[offset..], "{d}", .{i});
                self.keys[i] = self.string_bytes[offset .. offset + written.len];
                offset += written.len;
            }
            if (random_order) {
                self.prng.random().shuffle([]const u8, self.keys);
            } else {
                std.sort.pdq([]const u8, self.keys, {}, stringLessThan);
            }
        }

        fn prepareKeys(self: *Self, random_order: bool) !void {
            if (K == []const u8) {
                try self.makeStringKeys(random_order);
            } else {
                try self.makeKeys(random_order);
            }
        }

        pub fn preInsertSeq(self: *Self) !void {
            self.tree.clear(self.allocator);
            self.freeResidentStringBytes();
            try self.prepareKeys(false);
        }

        pub fn preInsertRand(self: *Self) !void {
            self.tree.clear(self.allocator);
            self.freeResidentStringBytes();
            try self.prepareKeys(true);
        }

        pub fn preGetSeq(self: *Self) !void {
            try self.prepareKeys(false);
        }

        pub fn preGetRand(self: *Self) !void {
            try self.prepareKeys(true);
        }

        pub fn insertAll(self: *Self) !void {
            for (self.keys) |key| {
                if (!try self.tree.insert(self.allocator, key, {})) return error.BenchmarkDuplicateKey;
            }
            if (K == []const u8) {
                self.freeResidentStringBytes();
                self.resident_string_bytes = self.string_bytes;
                self.string_bytes = &.{};
            }
            std.mem.doNotOptimizeAway(self.tree.len());
        }

        pub fn getAll(self: *Self) !void {
            var found: usize = 0;
            for (self.keys) |key| {
                _ = self.tree.get(key) orelse return error.BenchmarkMissingKey;
                found += 1;
            }
            self.checksum +%= found;
            std.mem.doNotOptimizeAway(self.checksum);
        }
    };
}

fn makeKeySlice(comptime K: type, allocator: Allocator, items: usize) ![]K {
    if (items > std.math.maxInt(K)) return error.TooManyBenchmarkItems;
    const keys = try allocator.alloc(K, items);
    for (keys, 0..) |*key, i| key.* = @intCast(i);
    return keys;
}

fn runBenchmark(
    comptime Ctx: type,
    ctx: *Ctx,
    label: []const u8,
    runs: usize,
    comptime pre: fn (*Ctx) anyerror!void,
    comptime op: fn (*Ctx) anyerror!void,
    allocator: Allocator,
    io: Io,
    stdout: anytype,
) !void {
    const elapsed = try allocator.alloc(u64, runs);
    defer allocator.free(elapsed);

    for (elapsed) |*sample| {
        try pre(ctx);
        const start = benchTime(io);
        try op(ctx);
        const end = benchTime(io);
        sample.* = @intCast(end - start);
    }

    std.sort.pdq(u64, elapsed, {}, lessU64);
    try writeResult(stdout, label, ctx.items, elapsed[runs / 2]);
}

fn benchTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn writeResult(stdout: anytype, label: []const u8, items: usize, elapsed_ns: u64) !void {
    try stdout.print("{s}", .{label});
    var padding = if (label.len < 19) 19 - label.len else 1;
    while (padding > 0) : (padding -= 1) try stdout.writeAll(" ");

    const secs = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(items));
    const ops_per_sec: usize = @intFromFloat(@as(f64, @floatFromInt(items)) / secs);

    try writeCommaized(stdout, items);
    try stdout.print(" ops in {d:.3} secs {d:.1} ns/op ", .{ secs, ns_per_op });
    try writeCommaized(stdout, ops_per_sec);
    try stdout.print(" op/sec\n", .{});
}

fn writeCommaized(stdout: anytype, value: usize) !void {
    var buffer: [32]u8 = undefined;
    const raw = try std.fmt.bufPrint(&buffer, "{d}", .{value});
    const first_group_len = if (raw.len % 3 == 0) 3 else raw.len % 3;

    try stdout.writeAll(raw[0..first_group_len]);
    var index = first_group_len;
    while (index < raw.len) : (index += 3) {
        try stdout.writeAll(",");
        try stdout.writeAll(raw[index .. index + 3]);
    }
}

fn decimalLength(value: usize) usize {
    var n = value;
    var len: usize = 1;
    while (n >= 10) : (len += 1) n /= 10;
    return len;
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.order(u8, lhs, rhs) == .lt;
}

fn lessU64(_: void, lhs: u64, rhs: u64) bool {
    return lhs < rhs;
}
