const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const zbtree_ds = @import("zbtree_ds");
const map = zbtree_ds.map;
const order = zbtree_ds.order;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const warmup_runs = 2;

/// Node search the benchmarked maps use, set with `-Dsearch-mode`.
const search_mode: map.SearchMode = switch (build_options.search_mode) {
    .auto => .auto,
    .binary => .binary,
    .linear => .linear,
};

const AllocatorChoice = enum { smp, arena };

/// Which side of the per-row process isolation this process is.
const Role = enum {
    /// The default. Prints the headers and starts one new process per row, so
    /// that no row inherits allocator state from another.
    parent,
    /// Started by a parent with `--child`. Runs its row directly instead of
    /// spawning again, and prints only that row's result line.
    child,
};

const Options = struct {
    items: usize,
    runs: usize,
    allocator: AllocatorChoice = .smp,
    /// Limits the run to one key type, such as `uint64`.
    key_type: ?[]const u8 = null,
    /// Limits the run to one benchmark row, such as `get(rand)`.
    bench: ?[]const u8 = null,
    /// Internal; users should not pass `--child`.
    role: Role = .parent,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const options = try parseOptions(init, allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    defer stdout.flush() catch {};

    if (options.role == .parent) {
        try stdout.print("\nzbtree_ds (Zig)\n", .{});
        try stdout.print("config: optimize={s} safety={s} allocator={s} search={s} warmups={d}\n", .{
            optimizeName(builtin.mode),
            if (std.debug.runtime_safety) "on" else "off",
            @tagName(options.allocator),
            @tagName(search_mode),
            warmup_runs,
        });
    }
    const exe_path = switch (options.role) {
        .parent => try std.process.executablePathAlloc(init.io, allocator),
        .child => "",
    };
    var rows: usize = 0;
    rows += try benchType(order.OrderedKey(i32, void), "int32", options, exe_path, allocator, init.io, stdout);
    rows += try benchType(order.OrderedKey(u64, void), "uint64", options, exe_path, allocator, init.io, stdout);
    rows += try benchType(order.OrderedKey([]const u8, void), "string", options, exe_path, allocator, init.io, stdout);
    if (rows == 0) return error.NoMatchingBenchmark;
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
        } else if (std.mem.eql(u8, arg, "--allocator")) {
            i += 1;
            if (i == args.len) return error.MissingBenchmarkArgument;
            options.allocator = parseAllocatorChoice(args[i]) orelse return error.InvalidAllocatorChoice;
        } else if (std.mem.startsWith(u8, arg, "--allocator=")) {
            options.allocator = parseAllocatorChoice(arg["--allocator=".len..]) orelse return error.InvalidAllocatorChoice;
        } else if (std.mem.eql(u8, arg, "--type")) {
            i += 1;
            if (i == args.len) return error.MissingBenchmarkArgument;
            options.key_type = args[i];
        } else if (std.mem.startsWith(u8, arg, "--type=")) {
            options.key_type = arg["--type=".len..];
        } else if (std.mem.eql(u8, arg, "--bench")) {
            i += 1;
            if (i == args.len) return error.MissingBenchmarkArgument;
            options.bench = args[i];
        } else if (std.mem.startsWith(u8, arg, "--bench=")) {
            options.bench = arg["--bench=".len..];
        } else if (std.mem.eql(u8, arg, "--child")) {
            options.role = .child;
        } else {
            return error.UnknownBenchmarkArgument;
        }
    }

    if (options.items == 0 or options.runs == 0) return error.InvalidBenchmarkOption;
    return options;
}

fn optimizeName(mode: std.builtin.OptimizeMode) []const u8 {
    return switch (mode) {
        .debug => "Debug",
        .safe => "ReleaseSafe",
        .fast => "ReleaseFast",
        .small => "ReleaseSmall",
    };
}

fn parseAllocatorChoice(value: []const u8) ?AllocatorChoice {
    return std.meta.stringToEnum(AllocatorChoice, value);
}

fn envUsize(init: std.process.Init, name: []const u8, default: usize) !usize {
    const value = init.environ_map.get(name) orelse return default;
    return std.fmt.parseInt(usize, value, 10);
}

/// Runs the selected rows for one key type and returns how many there were.
///
/// Each row is measured in a process of its own. std.heap.smp_allocator hands
/// freed nodes back in last-in-first-out order, so in a shared process the
/// node layout a row sees would depend on which rows ran before it.
fn benchType(
    comptime Order: type,
    comptime key_name: []const u8,
    options: Options,
    exe_path: []const u8,
    allocator: Allocator,
    io: Io,
    stdout: *Io.Writer,
) !usize {
    const K = Order.Key;
    const Map = map.Map(K, usize, .{ .use_string_prefix = Order.use_string_prefix, .search_mode = search_mode });
    const Ctx = BenchContext(K, Map);

    // How many operations one timed sample performs, used to compute ns/op.
    const OpCount = enum { items, partial_range, copy_batch };
    const Benchmark = struct {
        label: []const u8,
        ops: OpCount = .items,
        pre: fn (*Ctx) anyerror!void,
        op: fn (*Ctx) anyerror!void,
    };
    const benchmarks = [_]Benchmark{
        .{ .label = "insert(seq)", .pre = Ctx.preInsertSeq, .op = Ctx.insertAll },
        .{ .label = "pushBack(seq)", .pre = Ctx.prePushBackSeq, .op = Ctx.pushBackAll },
        .{ .label = "pushFront(seq)", .pre = Ctx.prePushFrontSeq, .op = Ctx.pushFrontAll },
        .{ .label = "insert(rand)", .pre = Ctx.preInsertRand, .op = Ctx.insertAll },
        .{ .label = "get(seq)", .pre = Ctx.preFullSeq, .op = Ctx.getAll },
        .{ .label = "get(rand)", .pre = Ctx.preFullRand, .op = Ctx.getAll },
        .{ .label = "getMut(rand)", .pre = Ctx.preFullRand, .op = Ctx.getMutAll },
        .{ .label = "set(existing)", .pre = Ctx.preFullRand, .op = Ctx.setAll },
        .{ .label = "replace", .pre = Ctx.preFullRand, .op = Ctx.replaceAll },
        .{ .label = "seek", .pre = Ctx.preFullRand, .op = Ctx.seekAll },
        .{ .label = "seekNext", .pre = Ctx.preFullRand, .op = Ctx.seekNextAll },
        .{ .label = "seekPrev", .pre = Ctx.preFullRand, .op = Ctx.seekPrevAll },
        .{ .label = "indexOf", .pre = Ctx.preFullRand, .op = Ctx.indexOfAll },
        .{ .label = "getAt", .pre = Ctx.preFullRand, .op = Ctx.getAtAll },
        .{ .label = "getAtMut", .pre = Ctx.preFullRand, .op = Ctx.getAtMutAll },
        .{ .label = "ascentMut", .pre = Ctx.preFullRand, .op = Ctx.ascentMutAll },
        .{ .label = "descentMut", .pre = Ctx.preFullRand, .op = Ctx.descentMutAll },
        .{ .label = "delete(rand)", .pre = Ctx.preFullRand, .op = Ctx.deleteAll },
        .{ .label = "deleteAt(front)", .pre = Ctx.preFullSeq, .op = Ctx.deleteAtFrontAll },
        .{ .label = "popFront", .pre = Ctx.preFullSeq, .op = Ctx.popFrontAll },
        .{ .label = "popBack", .pre = Ctx.preFullSeq, .op = Ctx.popBackAll },
        .{ .label = "deleteRangeAt(ret)", .ops = .partial_range, .pre = Ctx.preFullSeq, .op = Ctx.deleteRangeAtReturning },
        .{ .label = "deleteRange(ret)", .ops = .partial_range, .pre = Ctx.preFullSeq, .op = Ctx.deleteRangeReturning },
        .{ .label = "release", .ops = .copy_batch, .pre = Ctx.preReleaseCopies, .op = Ctx.releaseMany },
        .{ .label = "copy", .ops = .copy_batch, .pre = Ctx.preFullSeq, .op = Ctx.copyMany },
    };

    if (options.key_type) |wanted| {
        if (!std.mem.eql(u8, wanted, key_name)) return 0;
    }
    if (options.role == .parent) {
        try stdout.print("Benchmarking {d} items, {s} keys, {d} times, using median\n", .{ options.items, key_name, options.runs });
    }

    var rows: usize = 0;
    inline for (benchmarks) |bench| {
        if (options.bench == null or std.mem.eql(u8, options.bench.?, bench.label)) {
            rows += 1;
            switch (options.role) {
                .parent => {
                    // The child writes its row straight to the shared stdout.
                    try stdout.flush();
                    try runRowInChild(exe_path, options, key_name, bench.label, allocator, io);
                },
                .child => {
                    const ops = switch (bench.ops) {
                        .items => options.items,
                        .partial_range => partialRangeCount(options.items),
                        .copy_batch => copyBatchCount(options.items),
                    };
                    try runBenchmark(Ctx, options, bench.label, ops, bench.pre, bench.op, allocator, io, stdout);
                },
            }
        }
    }
    if (options.role == .parent) try stdout.print("\n", .{});
    return rows;
}

fn runRowInChild(
    exe_path: []const u8,
    options: Options,
    key_name: []const u8,
    label: []const u8,
    arena: Allocator,
    io: Io,
) !void {
    var child = try std.process.spawn(io, .{ .argv = &.{
        exe_path,
        "--child",
        "--items",
        try std.fmt.allocPrint(arena, "{d}", .{options.items}),
        "--runs",
        try std.fmt.allocPrint(arena, "{d}", .{options.runs}),
        "--allocator",
        @tagName(options.allocator),
        "--type",
        key_name,
        "--bench",
        label,
    } });
    const term = try child.wait(io);
    if (!term.success()) return error.BenchmarkChildFailed;
}

fn BenchContext(comptime K: type, comptime Map: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        prng: std.Random.DefaultPrng,
        items: usize,
        tree: Map,
        pending_removed: ?Map.DeleteRangeResult = null,
        copied_trees: []Map = &.{},
        keys: []K = &.{},
        indices: []usize = &.{},
        copy_batch_ops: usize,
        string_bytes: if (K == []const u8) []u8 else void = if (K == []const u8) &.{} else {},
        checksum: usize = 0,

        /// A context serves exactly one sample: one `pre` call, one timed `op` call, then `deinit`.
        fn init(allocator: Allocator, items: usize, seed: u64) Self {
            return .{
                .allocator = allocator,
                .prng = std.Random.DefaultPrng.init(seed),
                .items = items,
                .tree = Map.init(),
                .copy_batch_ops = copyBatchCount(items),
            };
        }

        fn deinit(self: *Self) void {
            if (self.pending_removed) |removed| removed.deinit(self.allocator);
            for (self.copied_trees) |*copied| copied.deinit(self.allocator);
            self.allocator.free(self.copied_trees);
            self.tree.deinit(self.allocator);
            self.allocator.free(self.keys);
            self.allocator.free(self.indices);
            if (K == []const u8) self.allocator.free(self.string_bytes);
        }

        fn makeKeys(self: *Self, random_order: bool) !void {
            self.keys = try makeKeySlice(K, self.allocator, self.items);
            if (random_order) self.prng.random().shuffle(K, self.keys);
        }

        fn makeStringKeys(self: *Self, random_order: bool) !void {
            self.keys = try self.allocator.alloc([]const u8, self.items);

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

        fn prepareIndices(self: *Self, random_order: bool) !void {
            self.indices = try self.allocator.alloc(usize, self.items);
            for (self.indices, 0..) |*index, i| index.* = i;
            if (random_order) self.prng.random().shuffle(usize, self.indices);
        }

        fn fillTree(self: *Self, random_order: bool) !void {
            try self.prepareKeys(random_order);
            try self.prepareIndices(random_order);
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.insert(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
        }

        pub fn preInsertSeq(self: *Self) !void {
            try self.prepareKeys(false);
        }

        pub fn preInsertRand(self: *Self) !void {
            try self.prepareKeys(true);
        }

        pub fn prePushBackSeq(self: *Self) !void {
            try self.preInsertSeq();
        }

        pub fn prePushFrontSeq(self: *Self) !void {
            try self.preInsertSeq();
            std.mem.reverse(K, self.keys);
        }

        pub fn preFullSeq(self: *Self) !void {
            try self.fillTree(false);
        }

        pub fn preFullRand(self: *Self) !void {
            try self.fillTree(true);
        }

        pub fn preReleaseCopies(self: *Self) !void {
            try self.fillTree(false);
            self.copied_trees = try self.allocator.alloc(Map, self.copy_batch_ops);
            for (self.copied_trees) |*copied| copied.* = self.tree.copy();
        }

        pub fn insertAll(self: *Self) !void {
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.insert(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
            self.record(self.tree.len());
        }

        pub fn pushBackAll(self: *Self) !void {
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.pushBack(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
            self.record(self.tree.len());
        }

        pub fn pushFrontAll(self: *Self) !void {
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.pushFront(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
            self.record(self.tree.len());
        }

        pub fn getAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const value = self.tree.get(key) orelse return error.BenchmarkMissingKey;
                digest +%= digestKey(key) ^ value;
            }
            self.record(digest);
        }

        pub fn getMutAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const value = (try self.tree.getMut(self.allocator, key)) orelse return error.BenchmarkMissingKey;
                digest +%= digestKey(key) ^ value.*;
            }
            self.record(digest);
        }

        pub fn setAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys, 0..) |key, i| {
                const new_value = valueForOrdinal(self.items + i);
                const old_value = try self.tree.set(self.allocator, key, new_value) orelse return error.BenchmarkMissingKey;
                digest +%= digestKey(key) ^ old_value ^ new_value;
            }
            self.record(digest +% self.tree.len());
        }

        pub fn replaceAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys, 0..) |key, i| {
                const new_value = valueForOrdinal(self.items * 2 + i);
                const old_value = try self.tree.replace(self.allocator, key, new_value) orelse return error.BenchmarkMissingKey;
                digest +%= digestKey(key) ^ old_value ^ new_value;
            }
            self.record(digest);
        }

        pub fn seekAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const entry = self.tree.seek(key) orelse return error.BenchmarkMissingKey;
                digest +%= entryDigest(entry);
            }
            self.record(digest);
        }

        pub fn seekNextAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                if (self.tree.seekNext(key)) |entry| digest +%= entryDigest(entry);
            }
            self.record(digest);
        }

        pub fn seekPrevAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                if (self.tree.seekPrev(key)) |entry| digest +%= entryDigest(entry);
            }
            self.record(digest);
        }

        pub fn indexOfAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const index = self.tree.indexOf(key) orelse return error.BenchmarkMissingKey;
                digest +%= digestKey(key) ^ index;
            }
            self.record(digest);
        }

        pub fn getAtAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.indices) |index| {
                const entry = self.tree.getAt(index) orelse return error.BenchmarkMissingKey;
                digest +%= entryDigest(entry) ^ index;
            }
            self.record(digest);
        }

        pub fn getAtMutAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.indices) |index| {
                const entry = (try self.tree.getAtMut(self.allocator, index)) orelse return error.BenchmarkMissingKey;
                digest +%= digestKey(entry.key) ^ entry.value.* ^ index;
            }
            self.record(digest);
        }

        pub fn ascentMutAll(self: *Self) !void {
            try self.tree.ascentMut(self.allocator, *Self, self, consumeMutEntry);
            self.record(self.tree.len());
        }

        pub fn descentMutAll(self: *Self) !void {
            try self.tree.descentMut(self.allocator, *Self, self, consumeMutEntry);
            self.record(self.tree.len());
        }

        pub fn deleteAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const value = try self.tree.delete(self.allocator, key) orelse return error.BenchmarkMissingKey;
                digest +%= digestKey(key) ^ value;
            }
            self.record(digest);
        }

        pub fn deleteAtFrontAll(self: *Self) !void {
            var digest: usize = 0;
            var deleted: usize = 0;
            while (try self.tree.deleteAt(self.allocator, 0)) |entry| {
                digest +%= entryDigest(entry);
                deleted += 1;
            }
            if (deleted != self.items) return error.BenchmarkMissingKey;
            self.record(digest);
        }

        pub fn popFrontAll(self: *Self) !void {
            var digest: usize = 0;
            var deleted: usize = 0;
            while (try self.tree.popFront(self.allocator)) |entry| {
                digest +%= entryDigest(entry);
                deleted += 1;
            }
            if (deleted != self.items) return error.BenchmarkMissingKey;
            self.record(digest);
        }

        pub fn popBackAll(self: *Self) !void {
            var digest: usize = 0;
            var deleted: usize = 0;
            while (try self.tree.popBack(self.allocator)) |entry| {
                digest +%= entryDigest(entry);
                deleted += 1;
            }
            if (deleted != self.items) return error.BenchmarkMissingKey;
            self.record(digest);
        }

        pub fn deleteRangeAtReturning(self: *Self) !void {
            const count = partialRangeCount(self.items);
            const start = partialRangeStart(self.items, count);
            const removed = try self.tree.deleteRangeAt(self.allocator, start, count, .{});
            if (removed.removed_count != count or removed.len() != count) {
                removed.deinit(self.allocator);
                return error.BenchmarkMissingKey;
            }
            try removed.ascent(*Self, self, consumeRemoved);
            self.pending_removed = removed;
            self.record(removed.removed_count);
        }

        pub fn deleteRangeReturning(self: *Self) !void {
            const bounds = self.partialRangeBounds() orelse return error.BenchmarkMissingKey;
            const count = partialRangeCount(self.items);
            const removed = try self.tree.deleteRange(self.allocator, bounds.first, bounds.last, .{ .max_inclusive = true });
            if (removed.removed_count != count or removed.len() != count) {
                removed.deinit(self.allocator);
                return error.BenchmarkMissingKey;
            }
            try removed.ascent(*Self, self, consumeRemoved);
            self.pending_removed = removed;
            self.record(removed.removed_count);
        }

        fn partialRangeBounds(self: *Self) ?struct { first: K, last: K } {
            const count = partialRangeCount(self.items);
            const start = partialRangeStart(self.items, count);
            const first = self.tree.getAt(start) orelse return null;
            const last = self.tree.getAt(start + count - 1) orelse return null;
            return .{ .first = first.key, .last = last.key };
        }

        pub fn releaseMany(self: *Self) !void {
            var digest: usize = 0;
            for (self.copied_trees) |*copied| {
                digest +%= copied.len();
                copied.deinit(self.allocator);
                copied.* = Map.init();
            }
            self.record(digest);
        }

        pub fn copyMany(self: *Self) !void {
            var digest: usize = 0;
            for (0..self.copy_batch_ops) |_| {
                var copied = self.tree.copy();
                digest +%= copied.len();
                copied.deinit(self.allocator);
            }
            self.record(digest);
        }

        fn consumeRemoved(self: *Self, key: K, value: usize) !void {
            self.checksum +%= digestKey(key) ^ value;
        }

        fn consumeMutEntry(self: *Self, key: K, value: *usize) !void {
            self.checksum +%= digestKey(key) ^ value.*;
        }

        fn entryDigest(entry: Map.Entry) usize {
            return digestKey(entry.key) ^ entry.value;
        }

        fn digestKey(key: K) usize {
            if (K == []const u8) {
                var hash: u64 = 1469598103934665603;
                for (key) |byte| {
                    hash ^= byte;
                    hash *%= 1099511628211;
                }
                return @truncate(hash);
            }
            const hash: u64 = @as(u64, @intCast(key)) *% 11400714819323198485;
            return @truncate(hash);
        }

        fn record(self: *Self, value: usize) void {
            self.checksum +%= value;
            std.mem.doNotOptimizeAway(self.checksum);
        }
    };
}

fn partialRangeCount(items: usize) usize {
    return @max(1, items / 10);
}

fn copyBatchCount(items: usize) usize {
    return @max(@as(usize, 1024), @min(items, 16_384));
}

fn valueForOrdinal(index: usize) usize {
    return index +% 1;
}

fn benchmarkSeed(type_name: []const u8, label: []const u8) u64 {
    var seed: u64 = 1469598103934665603;
    seed = mixSeed(seed, type_name);
    seed = mixSeed(seed, label);
    return seed;
}

fn mixSeed(seed: u64, bytes: []const u8) u64 {
    var value = seed;
    for (bytes) |byte| {
        value ^= byte;
        value *%= 1099511628211;
    }
    return value;
}

fn partialRangeStart(items: usize, count: usize) usize {
    return (items - count) / 2;
}

fn makeKeySlice(comptime K: type, allocator: Allocator, items: usize) ![]K {
    if (items > std.math.maxInt(K)) return error.TooManyBenchmarkItems;
    const keys = try allocator.alloc(K, items);
    for (keys, 0..) |*key, i| key.* = @intCast(i);
    return keys;
}

fn runBenchmark(
    comptime Ctx: type,
    options: Options,
    label: []const u8,
    ops: usize,
    comptime pre: fn (*Ctx) anyerror!void,
    comptime op: fn (*Ctx) anyerror!void,
    allocator: Allocator,
    io: Io,
    stdout: *Io.Writer,
) !void {
    const elapsed = try allocator.alloc(u64, options.runs);
    defer allocator.free(elapsed);

    const seed = benchmarkSeed(@typeName(Ctx), label);
    for (0..warmup_runs) |_| _ = try runBenchmarkSample(Ctx, options.allocator, options.items, seed, pre, op, io);

    for (elapsed) |*sample| sample.* = try runBenchmarkSample(Ctx, options.allocator, options.items, seed, pre, op, io);

    std.sort.pdq(u64, elapsed, {}, lessU64);
    const median = elapsed[options.runs / 2];
    try writeResult(stdout, label, ops, median);
}

fn runBenchmarkSample(
    comptime Ctx: type,
    allocator_choice: AllocatorChoice,
    items: usize,
    seed: u64,
    comptime pre: fn (*Ctx) anyerror!void,
    comptime op: fn (*Ctx) anyerror!void,
    io: Io,
) !u64 {
    // Declared before ctx so ctx.deinit runs first, then the arena (if used) is released.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const sample_allocator = switch (allocator_choice) {
        .smp => std.heap.smp_allocator,
        .arena => arena.allocator(),
    };

    var ctx = Ctx.init(sample_allocator, items, seed);
    defer ctx.deinit();

    try pre(&ctx);
    const start = benchTime(io);
    try op(&ctx);
    const end = benchTime(io);
    return @intCast(end - start);
}

fn benchTime(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn writeResult(stdout: *Io.Writer, label: []const u8, ops: usize, elapsed_ns: u64) !void {
    try stdout.print("{s}", .{label});
    var padding = if (label.len < 19) 19 - label.len else 1;
    while (padding > 0) : (padding -= 1) try stdout.writeAll(" ");

    const secs = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_s;
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ops));
    const ops_per_sec: usize = if (elapsed_ns == 0) 0 else @intFromFloat(@as(f64, @floatFromInt(ops)) / secs);

    try writeCommaized(stdout, ops);
    try stdout.print(" ops in {d:.3} secs {d:.1} ns/op ", .{ secs, ns_per_op });
    try writeCommaized(stdout, ops_per_sec);
    try stdout.print(" op/sec\n", .{});
}

fn writeCommaized(stdout: *Io.Writer, value: usize) !void {
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
