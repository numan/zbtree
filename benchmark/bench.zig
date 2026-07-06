const std = @import("std");
const zbtree_ds = @import("zbtree_ds");
const map = zbtree_ds.map;
const order = zbtree_ds.order;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const warmup_runs = 2;

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
    try benchType(order.OrderedKey(i32, void), "int32", options, allocator, init.io, stdout);
    try benchType(order.OrderedKey(u64, void), "uint64", options, allocator, init.io, stdout);
    try benchType(order.OrderedKey([]const u8, void), "string", options, allocator, init.io, stdout);
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
    const Map = map.Map(K, usize, .{ .use_string_prefix = Order.use_string_prefix });
    const Ctx = BenchContext(K, Map);

    var ctx = Ctx.init(allocator, options.items, benchmarkSeed(key_name, "type"));
    defer ctx.deinit();

    try stdout.print("Benchmarking {d} items, {s} keys, {d} times, using median\n", .{ options.items, key_name, options.runs });

    try runBenchmark(Ctx, &ctx, "insert(seq)", options.items, options.runs, Ctx.preInsertSeq, Ctx.insertAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "pushBack(seq)", options.items, options.runs, Ctx.prePushBackSeq, Ctx.pushBackAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "pushFront(seq)", options.items, options.runs, Ctx.prePushFrontSeq, Ctx.pushFrontAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "insert(rand)", options.items, options.runs, Ctx.preInsertRand, Ctx.insertAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "get(seq)", options.items, options.runs, Ctx.preFullSeq, Ctx.getAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "get(rand)", options.items, options.runs, Ctx.preFullRand, Ctx.getAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "getMut(rand)", options.items, options.runs, Ctx.preFullRand, Ctx.getMutAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "set(existing)", options.items, options.runs, Ctx.preFullRand, Ctx.setAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "replace", options.items, options.runs, Ctx.preFullRand, Ctx.replaceAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "seek", options.items, options.runs, Ctx.preFullRand, Ctx.seekAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "seekNext", options.items, options.runs, Ctx.preFullRand, Ctx.seekNextAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "seekPrev", options.items, options.runs, Ctx.preFullRand, Ctx.seekPrevAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "indexOf", options.items, options.runs, Ctx.preFullRand, Ctx.indexOfAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "getAt", options.items, options.runs, Ctx.preFullRand, Ctx.getAtAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "getAtMut", options.items, options.runs, Ctx.preFullRand, Ctx.getAtMutAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "ascentMut", options.items, options.runs, Ctx.preFullRand, Ctx.ascentMutAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "descentMut", options.items, options.runs, Ctx.preFullRand, Ctx.descentMutAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "delete(rand)", options.items, options.runs, Ctx.preFullRand, Ctx.deleteAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "deleteAt(front)", options.items, options.runs, Ctx.preFullSeq, Ctx.deleteAtFrontAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "popFront", options.items, options.runs, Ctx.preFullSeq, Ctx.popFrontAll, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "popBack", options.items, options.runs, Ctx.preFullSeq, Ctx.popBackAll, allocator, io, stdout);
    const range_ops = partialRangeCount(options.items);
    try runBenchmark(Ctx, &ctx, "deleteRangeAt(ret)", range_ops, options.runs, Ctx.preFullSeq, Ctx.deleteRangeAtReturning, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "deleteRange(ret)", range_ops, options.runs, Ctx.preFullSeq, Ctx.deleteRangeReturning, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "release", ctx.copy_batch_ops, options.runs, Ctx.preReleaseCopies, Ctx.releaseMany, allocator, io, stdout);
    try runBenchmark(Ctx, &ctx, "copy", ctx.copy_batch_ops, options.runs, Ctx.preFullSeq, Ctx.copyMany, allocator, io, stdout);
    try stdout.print("\n", .{});
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
        resident_string_bytes: if (K == []const u8) []u8 else void = if (K == []const u8) &.{} else {},

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
            self.cleanupUntimed();
            self.tree.deinit(self.allocator);
            self.freeKeys();
            self.freeIndices();
            self.freeResidentStringBytes();
        }

        fn cleanupUntimed(self: *Self) void {
            if (self.pending_removed) |removed| {
                removed.deinit(self.allocator);
                self.pending_removed = null;
            }
            self.freeCopiedTrees();
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

        fn freeIndices(self: *Self) void {
            if (self.indices.len != 0) self.allocator.free(self.indices);
            self.indices = &.{};
        }

        fn freeCopiedTrees(self: *Self) void {
            for (self.copied_trees) |*copied| copied.deinit(self.allocator);
            if (self.copied_trees.len != 0) self.allocator.free(self.copied_trees);
            self.copied_trees = &.{};
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

        fn prepareIndices(self: *Self, random_order: bool) !void {
            self.freeIndices();
            self.indices = try self.allocator.alloc(usize, self.items);
            for (self.indices, 0..) |*index, i| index.* = i;
            if (random_order) self.prng.random().shuffle(usize, self.indices);
        }

        fn retainPreparedStringBytes(self: *Self) void {
            if (K == []const u8) {
                self.freeResidentStringBytes();
                self.resident_string_bytes = self.string_bytes;
                self.string_bytes = &.{};
            }
        }

        fn fillTree(self: *Self, random_order: bool) !void {
            self.tree.clear(self.allocator);
            self.freeResidentStringBytes();
            try self.prepareKeys(random_order);
            try self.prepareIndices(random_order);
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.insert(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
            self.retainPreparedStringBytes();
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
            self.freeCopiedTrees();
            self.copied_trees = try self.allocator.alloc(Map, self.copy_batch_ops);
            for (self.copied_trees) |*copied| copied.* = self.tree.copy();
        }

        pub fn insertAll(self: *Self) !void {
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.insert(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
            self.retainPreparedStringBytes();
            self.record(self.tree.len());
        }

        pub fn pushBackAll(self: *Self) !void {
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.pushBack(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
            self.retainPreparedStringBytes();
            self.record(self.tree.len());
        }

        pub fn pushFrontAll(self: *Self) !void {
            for (self.keys, 0..) |key, i| {
                if (!try self.tree.pushFront(self.allocator, key, valueForOrdinal(i))) return error.BenchmarkDuplicateKey;
            }
            self.retainPreparedStringBytes();
            self.record(self.tree.len());
        }

        pub fn getAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const value = self.tree.get(key) orelse return error.BenchmarkMissingKey;
                digest +%= self.keyDigest(key) ^ value;
            }
            self.record(digest);
        }

        pub fn getMutAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const value = (try self.tree.getMut(self.allocator, key)) orelse return error.BenchmarkMissingKey;
                digest +%= self.keyDigest(key) ^ value.*;
            }
            self.record(digest);
        }

        pub fn setAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys, 0..) |key, i| {
                const new_value = valueForOrdinal(self.items + i);
                const old_value = try self.tree.set(self.allocator, key, new_value) orelse return error.BenchmarkMissingKey;
                digest +%= self.keyDigest(key) ^ old_value ^ new_value;
            }
            self.record(digest +% self.tree.len());
        }

        pub fn replaceAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys, 0..) |key, i| {
                const new_value = valueForOrdinal(self.items * 2 + i);
                const old_value = try self.tree.replace(self.allocator, key, new_value) orelse return error.BenchmarkMissingKey;
                digest +%= self.keyDigest(key) ^ old_value ^ new_value;
            }
            self.record(digest);
        }

        pub fn seekAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const entry = self.tree.seek(key) orelse return error.BenchmarkMissingKey;
                digest +%= self.entryDigest(entry);
            }
            self.record(digest);
        }

        pub fn seekNextAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                if (self.tree.seekNext(key)) |entry| digest +%= self.entryDigest(entry);
            }
            self.record(digest);
        }

        pub fn seekPrevAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                if (self.tree.seekPrev(key)) |entry| digest +%= self.entryDigest(entry);
            }
            self.record(digest);
        }

        pub fn indexOfAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.keys) |key| {
                const index = self.tree.indexOf(key) orelse return error.BenchmarkMissingKey;
                digest +%= self.keyDigest(key) ^ index;
            }
            self.record(digest);
        }

        pub fn getAtAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.indices) |index| {
                const entry = self.tree.getAt(index) orelse return error.BenchmarkMissingKey;
                digest +%= self.entryDigest(entry) ^ index;
            }
            self.record(digest);
        }

        pub fn getAtMutAll(self: *Self) !void {
            var digest: usize = 0;
            for (self.indices) |index| {
                const entry = (try self.tree.getAtMut(self.allocator, index)) orelse return error.BenchmarkMissingKey;
                digest +%= self.keyDigest(entry.key) ^ entry.value.* ^ index;
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
                digest +%= self.keyDigest(key) ^ value;
            }
            self.record(digest);
        }

        pub fn deleteAtFrontAll(self: *Self) !void {
            var digest: usize = 0;
            var deleted: usize = 0;
            while (try self.tree.deleteAt(self.allocator, 0)) |entry| {
                digest +%= self.entryDigest(entry);
                deleted += 1;
            }
            if (deleted != self.items) return error.BenchmarkMissingKey;
            self.record(digest);
        }

        pub fn popFrontAll(self: *Self) !void {
            var digest: usize = 0;
            var deleted: usize = 0;
            while (try self.tree.popFront(self.allocator)) |entry| {
                digest +%= self.entryDigest(entry);
                deleted += 1;
            }
            if (deleted != self.items) return error.BenchmarkMissingKey;
            self.record(digest);
        }

        pub fn popBackAll(self: *Self) !void {
            var digest: usize = 0;
            var deleted: usize = 0;
            while (try self.tree.popBack(self.allocator)) |entry| {
                digest +%= self.entryDigest(entry);
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

        fn entryDigest(self: *Self, entry: Map.Entry) usize {
            return self.keyDigest(entry.key) ^ entry.value;
        }

        fn keyDigest(_: *Self, key: K) usize {
            return digestKey(key);
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
    ctx: *Ctx,
    label: []const u8,
    ops: usize,
    runs: usize,
    comptime pre: fn (*Ctx) anyerror!void,
    comptime op: fn (*Ctx) anyerror!void,
    allocator: Allocator,
    io: Io,
    stdout: anytype,
) !void {
    const elapsed = try allocator.alloc(u64, runs);
    defer allocator.free(elapsed);

    const seed = benchmarkSeed(@typeName(Ctx), label);
    for (0..warmup_runs) |_| _ = try runBenchmarkSample(Ctx, ctx.items, seed, pre, op, io);

    for (elapsed) |*sample| sample.* = try runBenchmarkSample(Ctx, ctx.items, seed, pre, op, io);

    std.sort.pdq(u64, elapsed, {}, lessU64);
    const median = elapsed[runs / 2];
    try writeResult(stdout, label, ops, median);
}

fn runBenchmarkSample(
    comptime Ctx: type,
    items: usize,
    seed: u64,
    comptime pre: fn (*Ctx) anyerror!void,
    comptime op: fn (*Ctx) anyerror!void,
    io: Io,
) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var ctx = Ctx.init(arena.allocator(), items, seed);
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

fn writeResult(stdout: anytype, label: []const u8, ops: usize, elapsed_ns: u64) !void {
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
