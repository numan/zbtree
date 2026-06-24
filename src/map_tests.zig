const std = @import("std");
const map = @import("map.zig");
const testing = std.testing;

const Pair = struct {
    key: i32,
    value: i32,
};

const CollectContext = struct {
    items: [128]Pair = undefined,
    len: usize = 0,
};

const DynamicCollectContext = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Pair) = .empty,

    fn deinit(ctx: *@This()) void {
        ctx.items.deinit(ctx.allocator);
    }
};

fn collect(ctx: *CollectContext, key: i32, value: i32) !void {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
}

fn collectUntil(ctx: *CollectContext, key: i32, value: i32) !bool {
    try collect(ctx, key, value);
    return ctx.len < 3;
}

fn collectDynamic(ctx: *DynamicCollectContext, key: i32, value: i32) !void {
    try ctx.items.append(ctx.allocator, .{ .key = key, .value = value });
}

test "map stores one value per key" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    try testing.expect(try m.insert(testing.allocator, 10, 100));
    try testing.expect(!try m.insert(testing.allocator, 10, 200));
    try testing.expectEqual(@as(usize, 1), m.len());
    try testing.expectEqual(@as(?i32, 100), m.get(10));

    try testing.expectEqual(@as(?i32, 100), try m.set(testing.allocator, 10, 200));
    try testing.expectEqual(@as(?i32, 200), m.get(10));
    try testing.expectEqual(@as(?i32, null), try m.set(testing.allocator, 20, 300));
    try testing.expectEqual(@as(usize, 2), m.len());

    try testing.expectEqual(@as(?i32, 200), try m.replace(testing.allocator, 10, 111));
    try testing.expectEqual(@as(?i32, null), try m.replace(testing.allocator, 30, 333));
    try testing.expectEqual(@as(?i32, 111), m.get(10));

    try testing.expectEqual(@as(?i32, 111), try m.delete(testing.allocator, 10));
    try testing.expectEqual(@as(?i32, null), m.get(10));
    try testing.expectEqual(@as(usize, 1), m.len());
    try m.checkInvariants();
}

test "map ordered access and traversal" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    for ([_]i32{ 5, 1, 3, 2, 4 }) |key| {
        try testing.expect(try m.insert(testing.allocator, key, key * 10));
    }

    try testing.expectEqual(@as(i32, 1), m.front().?.key);
    try testing.expectEqual(@as(i32, 5), m.back().?.key);
    try testing.expectEqual(@as(?usize, 2), m.indexOf(3));
    try testing.expectEqual(@as(i32, 4), m.seek(4).?.key);
    try testing.expectEqual(@as(i32, 4), m.seekNext(3).?.key);
    try testing.expectEqual(@as(i32, 2), m.seekPrev(3).?.key);
    try testing.expectEqual(@as(i32, 3), m.getAt(2).?.key);

    var ctx = CollectContext{};
    try m.ascent(*CollectContext, &ctx, collect);
    try testing.expectEqual(@as(usize, 5), ctx.len);
    for (0..ctx.len) |i| {
        const expected: i32 = @intCast(i + 1);
        try testing.expectEqual(expected, ctx.items[i].key);
        try testing.expectEqual(expected * 10, ctx.items[i].value);
    }

    var limited = CollectContext{};
    try m.ascendAt(*CollectContext, 1, &limited, collectUntil);
    try testing.expectEqual(@as(usize, 3), limited.len);
    try testing.expectEqual(@as(i32, 2), limited.items[0].key);
    try testing.expectEqual(@as(i32, 4), limited.items[2].key);
}

test "map edge push wrappers preserve order and reject duplicates" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    for ([_]i32{ 3, 2, 1 }) |key| {
        try testing.expect(try m.pushFront(testing.allocator, key, key * 10));
    }
    try testing.expect(!try m.pushFront(testing.allocator, 1, 10));
    try testing.expect(!try m.pushFront(testing.allocator, 2, 20));

    for ([_]i32{ 4, 5, 6 }) |key| {
        try testing.expect(try m.pushBack(testing.allocator, key, key * 10));
    }
    try testing.expect(!try m.pushBack(testing.allocator, 6, 60));
    try testing.expect(!try m.pushBack(testing.allocator, 5, 50));

    try testing.expectEqual(@as(usize, 6), m.len());
    for (0..6) |i| {
        const key: i32 = @intCast(i + 1);
        try expectMapEntry(m.getAt(i), key, key * 10);
    }
    try m.checkInvariants();
}

test "map deleteAt uses edge semantics for first and last items" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    for (0..200) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try m.insert(testing.allocator, key, -key));
    }

    try expectMapEntry(try m.deleteAt(testing.allocator, 0), 0, 0);
    try expectMapEntry(try m.deleteAt(testing.allocator, m.len() - 1), 199, -199);
    try testing.expectEqual(@as(usize, 198), m.len());
    try expectMapEntry(m.front(), 1, -1);
    try expectMapEntry(m.back(), 198, -198);
    try m.checkInvariants();
}

test "map copy-on-write isolates replacements and deletion" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var original = IntMap.init();
    defer original.deinit(testing.allocator);

    for (0..100) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, key * 10));
    }

    var copied = original.copy();
    defer copied.deinit(testing.allocator);

    try testing.expectEqual(@as(?i32, 100), try copied.replace(testing.allocator, 10, 111));
    try testing.expectEqual(@as(?i32, 200), try copied.set(testing.allocator, 20, 222));
    try testing.expectEqual(@as(?i32, 300), try copied.delete(testing.allocator, 30));

    try testing.expectEqual(@as(?i32, 100), original.get(10));
    try testing.expectEqual(@as(?i32, 200), original.get(20));
    try testing.expectEqual(@as(?i32, 300), original.get(30));
    try testing.expectEqual(@as(usize, 100), original.len());

    try testing.expectEqual(@as(?i32, 111), copied.get(10));
    try testing.expectEqual(@as(?i32, 222), copied.get(20));
    try testing.expectEqual(@as(?i32, null), copied.get(30));
    try testing.expectEqual(@as(usize, 99), copied.len());

    try original.checkInvariants();
    try copied.checkInvariants();
}

test "map range deletion returns removed entries" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    for (0..10) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try m.insert(testing.allocator, key, key * 10));
    }

    const removed = try m.deleteRange(testing.allocator, 3, 6, .{ .max_inclusive = true });
    defer removed.deinit(testing.allocator);

    var removed_items = DynamicCollectContext{ .allocator = testing.allocator };
    defer removed_items.deinit();
    try removed.ascent(*DynamicCollectContext, &removed_items, collectDynamic);

    try testing.expectEqual(@as(usize, 4), removed.removed_count);
    try testing.expectEqual(@as(usize, 4), removed_items.items.items.len);
    for (removed_items.items.items, 3..) |item, expected_usize| {
        const expected: i32 = @intCast(expected_usize);
        try testing.expectEqual(expected, item.key);
        try testing.expectEqual(expected * 10, item.value);
    }
    try testing.expectEqual(@as(?i32, null), m.get(3));
    try testing.expectEqual(@as(?i32, null), m.get(6));
    try testing.expectEqual(@as(usize, 6), m.len());
    try m.checkInvariants();
}

test "string map enables prefix routing by default" {
    const StringMap = map.Map([]const u8, usize, .{});
    var m = StringMap.init();
    defer m.deinit(testing.allocator);

    var buffers: [80][8]u8 = undefined;
    for (&buffers, 0..) |*buffer, i| {
        const key = try std.fmt.bufPrint(buffer, "key-{d:0>3}", .{i});
        try testing.expect(try m.insert(testing.allocator, key, i));
    }

    try testing.expectEqual(@as(?usize, 42), m.get("key-042"));
    try testing.expectEqualStrings("key-079", m.back().?.key);
    try m.checkInvariants();
}

fn fillPermutation(comptime N: usize, seed: u64) [N]i32 {
    var keys: [N]i32 = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle(i32, &keys);
    return keys;
}

fn expectMapEntry(entry: anytype, key: i32, value: i32) !void {
    try testing.expect(entry != null);
    try testing.expectEqual(key, entry.?.key);
    try testing.expectEqual(value, entry.?.value);
}

fn expectRemovedSorted(removed: anytype, first: i32, count: usize) !void {
    var removed_items = DynamicCollectContext{ .allocator = testing.allocator };
    defer removed_items.deinit();
    try removed.ascent(*DynamicCollectContext, &removed_items, collectDynamic);

    try testing.expectEqual(count, removed.removed_count);
    try testing.expectEqual(count, removed_items.items.items.len);
    for (removed_items.items.items, 0..) |item, i| {
        const key: i32 = first + @as(i32, @intCast(i));
        try testing.expectEqual(key, item.key);
        try testing.expectEqual(-key, item.value);
    }
}

fn refillIntMap(comptime IntMap: type, m: *IntMap, n: usize) !void {
    m.clear(testing.allocator);
    for (0..n) |i| {
        const key: i32 = @intCast(i);
        _ = try m.set(testing.allocator, key, key);
    }
}

fn copyBytes(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try gpa.dupe(u8, value);
}

fn releaseBytes(gpa: std.mem.Allocator, value: []const u8) void {
    gpa.free(value);
}

test "map randomized basics match btype operation sequence" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    const keys = fillPermutation(5000, 0x5eed_0001);
    for (keys, 0..) |permuted, i| {
        const key = permuted * 10;

        try testing.expectEqual(null, m.get(key));
        try testing.expectEqual(null, try m.delete(testing.allocator, key));
        try testing.expectEqual(null, try m.replace(testing.allocator, key, key));

        try testing.expectEqual(null, try m.set(testing.allocator, key, -key));
        try testing.expectEqual(-key, try m.delete(testing.allocator, key));
        try testing.expectEqual(null, try m.replace(testing.allocator, key, key));

        try testing.expect(try m.insert(testing.allocator, key, -key));
        try testing.expect(!try m.insert(testing.allocator, key, key));
        try testing.expectEqual(-key, try m.replace(testing.allocator, key, key));
        try testing.expectEqual(key, try m.replace(testing.allocator, key, -key));
        try testing.expectEqual(-key, m.get(key));

        try expectMapEntry(m.seek(key), key, -key);
        try expectMapEntry(m.seek(key - 5), key, -key);
        if (m.seekNext(key)) |next| {
            try testing.expect(next.key > key);
            try testing.expectEqual(-next.key, next.value);
        } else {
            try expectMapEntry(m.back(), key, -key);
        }

        if (i % 131 == 0) try m.checkInvariants();
    }
    try m.checkInvariants();
}

test "map randomized indexed access replace deleteAt and clear" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    const n = 2000;
    const keys = fillPermutation(n, 0x5eed_0002);
    for (keys, 0..) |key, i| {
        try testing.expectEqual(i, m.len());
        try testing.expectEqual(null, m.get(key));
        try testing.expect(try m.insert(testing.allocator, key, key));
        try testing.expectEqual(i + 1, m.len());
        try testing.expectEqual(key, m.get(key));

        try testing.expectEqual(key, try m.delete(testing.allocator, key));
        try testing.expectEqual(null, try m.delete(testing.allocator, key));
        try testing.expect(try m.insert(testing.allocator, key, key));

        const index = m.indexOf(key).?;
        try expectMapEntry(m.getAt(index), key, key);
        if (i % 257 == 0) try m.checkInvariants();
    }

    try testing.expect(m.getAt(n) == null);
    for (0..n) |i| {
        const key: i32 = @intCast(i);
        try expectMapEntry(m.getAt(i), key, key);
    }

    const replacement_order = fillPermutation(n, 0x5eed_0003);
    for (replacement_order, 0..) |key, i| {
        try testing.expect(!try m.insert(testing.allocator, key, -key));
        try testing.expectEqual(key, try m.replace(testing.allocator, key, -key));
        try testing.expectEqual(-key, m.get(key));
        if (i % 257 == 0) try m.checkInvariants();
    }

    for (0..n) |i| {
        const key: i32 = @intCast(i);
        try expectMapEntry(m.getAt(i), key, -key);
    }

    var expected: i32 = 0;
    while (try m.deleteAt(testing.allocator, 0)) |entry| : (expected += 1) {
        try testing.expectEqual(expected, entry.key);
        try testing.expectEqual(-expected, entry.value);
        if (@mod(expected, 257) == 0) try m.checkInvariants();
    }
    try testing.expectEqual(n, expected);
    try testing.expectEqual(0, m.len());

    try refillIntMap(IntMap, &m, n);
    m.clear(testing.allocator);
    try testing.expectEqual(0, m.len());
    try m.checkInvariants();
}

test "map property range deletion returns sorted removed entries" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    const cases = [_]struct {
        n: usize,
        min_key: i32,
        max_key: i32,
        opts: map.DeleteRangeOptions,
        first_removed: i32,
        removed_count: usize,
    }{
        .{ .n = 1, .min_key = 0, .max_key = 1, .opts = .{}, .first_removed = 0, .removed_count = 1 },
        .{ .n = 2, .min_key = 0, .max_key = 1, .opts = .{ .max_inclusive = true }, .first_removed = 0, .removed_count = 2 },
        .{ .n = 63, .min_key = 10, .max_key = 20, .opts = .{}, .first_removed = 10, .removed_count = 10 },
        .{ .n = 64, .min_key = 10, .max_key = 20, .opts = .{ .min_exclusive = true, .max_inclusive = true }, .first_removed = 11, .removed_count = 10 },
        .{ .n = 65, .min_key = -5, .max_key = 5, .opts = .{ .max_inclusive = true }, .first_removed = 0, .removed_count = 6 },
        .{ .n = 127, .min_key = 60, .max_key = 90, .opts = .{ .min_exclusive = true }, .first_removed = 61, .removed_count = 29 },
        .{ .n = 128, .min_key = 100, .max_key = 127, .opts = .{ .max_inclusive = true }, .first_removed = 100, .removed_count = 28 },
        .{ .n = 1000, .min_key = 250, .max_key = 750, .opts = .{}, .first_removed = 250, .removed_count = 500 },
    };

    inline for (cases, 0..) |case, case_index| {
        var m = IntMap.init();
        defer m.deinit(testing.allocator);

        var keys: [case.n]i32 = undefined;
        for (&keys, 0..) |*key, i| key.* = @intCast(i);
        var prng = std.Random.DefaultPrng.init(0x5eed_0004 + case_index);
        prng.random().shuffle(i32, &keys);
        for (keys) |key| try testing.expect(try m.insert(testing.allocator, key, -key));

        const removed = try m.deleteRange(testing.allocator, case.min_key, case.max_key, case.opts);
        defer removed.deinit(testing.allocator);
        try expectRemovedSorted(removed, case.first_removed, case.removed_count);
        try testing.expectEqual(case.n - case.removed_count, m.len());
        for (0..case.n) |i| {
            const key: i32 = @intCast(i);
            const removed_count: i32 = @intCast(case.removed_count);
            const was_removed = key >= case.first_removed and key < case.first_removed + removed_count;
            if (was_removed) {
                try testing.expectEqual(null, m.get(key));
            } else {
                try testing.expectEqual(-key, m.get(key));
            }
        }
        try m.checkInvariants();
    }

    var no_op = IntMap.init();
    defer no_op.deinit(testing.allocator);
    for (0..100) |i| {
        const key: i32 = @intCast(i);
        _ = try no_op.set(testing.allocator, key, key);
    }
    const removed = try no_op.deleteRange(testing.allocator, 99, 101, .{ .min_exclusive = true });
    defer removed.deinit(testing.allocator);
    try testing.expectEqual(0, removed.removed_count);
    try testing.expectEqual(100, no_op.len());
    try no_op.checkInvariants();
}

test "map deleteRangeAt honors bounds options and no_return" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    const n = 10000;
    try refillIntMap(IntMap, &m, n);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 3000, 1000, .{});
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(1000, removed.removed_count);
        try testing.expectEqual(9000, m.len());
        var removed_items = DynamicCollectContext{ .allocator = testing.allocator };
        defer removed_items.deinit();
        try removed.ascent(*DynamicCollectContext, &removed_items, collectDynamic);
        for (removed_items.items.items, 0..) |item, i| {
            const key: i32 = @intCast(i + 3000);
            try testing.expectEqual(key, item.key);
            try testing.expectEqual(key, item.value);
        }
    }

    try refillIntMap(IntMap, &m, n);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 3000, 1000, .{ .min_exclusive = true });
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(999, removed.removed_count);
        try testing.expectEqual(9001, m.len());
    }

    try refillIntMap(IntMap, &m, n);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 3000, 1000, .{ .min_exclusive = true, .max_inclusive = true });
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(1000, removed.removed_count);
        try testing.expectEqual(9000, m.len());
    }

    try refillIntMap(IntMap, &m, n);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 3000, 1000, .{ .max_inclusive = true });
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(1001, removed.removed_count);
        try testing.expectEqual(8999, m.len());
    }

    try refillIntMap(IntMap, &m, n);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 3000, 1000, .{ .max_inclusive = true, .no_return = true });
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(1001, removed.removed_count);
        try testing.expectEqual(0, removed.chunk_count);
        try testing.expectEqual(8999, m.len());
    }
    try m.checkInvariants();
}

test "map seek neighbors and indexed traversal across split tree" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    const n = 1000;
    for (0..n) |i| {
        const key: i32 = @intCast(i * 10);
        _ = try m.set(testing.allocator, key, @intCast(i));
    }

    for (0..n) |i| {
        const key: i32 = @intCast(i * 10);
        try expectMapEntry(m.seek(key), key, @intCast(i));
        try expectMapEntry(m.seek(key - 5), key, @intCast(i));
        if (i > 0) try expectMapEntry(m.seekPrev(key), key - 10, @intCast(i - 1));
        if (i + 1 < n) try expectMapEntry(m.seekNext(key), key + 10, @intCast(i + 1));

        var asc = CollectContext{};
        try m.ascendAt(*CollectContext, i, &asc, collectUntil);
        const asc_len = @min(3, n - i);
        try testing.expectEqual(asc_len, asc.len);
        for (0..asc.len) |j| {
            const expected_index = i + j;
            const expected_key: i32 = @intCast(expected_index * 10);
            const expected_value: i32 = @intCast(expected_index);
            try testing.expectEqual(expected_key, asc.items[j].key);
            try testing.expectEqual(expected_value, asc.items[j].value);
        }
    }
    try m.checkInvariants();
}

test "void map supports large random deletion" {
    const VoidMap = map.Map(i32, void, .{ .use_string_prefix = false });
    var m = VoidMap.init();
    defer m.deinit(testing.allocator);

    const keys = fillPermutation(10000, 0x5eed_0006);
    for (keys) |key| try testing.expect(try m.insert(testing.allocator, key, {}));
    try m.checkInvariants();

    for (keys, 0..) |key, i| {
        _ = try m.delete(testing.allocator, key) orelse return error.MissingBenchmarkKey;
        if (i % 251 == 0) try m.checkInvariants();
    }
    try testing.expectEqual(0, m.len());
    try m.checkInvariants();
}

test "map copy-on-write isolates value replacements across many entries" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var original = IntMap.init();
    defer original.deinit(testing.allocator);

    const n = 10000;
    for (0..n) |i| {
        const key: i32 = @intCast(i);
        _ = try original.set(testing.allocator, key, key);
    }
    try original.checkInvariants();

    var copied = original.copy();
    defer copied.deinit(testing.allocator);

    for (0..n) |i| {
        const key: i32 = @intCast(i);
        try testing.expectEqual(key, try copied.set(testing.allocator, key, -key));
        try testing.expectEqual(-key, copied.get(key));
    }

    for (0..n) |i| {
        const key: i32 = @intCast(i);
        try expectMapEntry(original.getAt(i), key, key);
        try expectMapEntry(copied.getAt(i), key, -key);
    }
    try original.checkInvariants();
    try copied.checkInvariants();
}

test "map owned values are copied and released through copy-on-write" {
    const ByteMap = map.Map(i32, []const u8, .{
        .use_string_prefix = false,
        .copy_value = copyBytes,
        .release_value = releaseBytes,
    });
    var original = ByteMap.init();
    defer original.deinit(testing.allocator);

    for (0..256) |i| {
        const key: i32 = @intCast(i);
        const value = try std.fmt.allocPrint(testing.allocator, "value-{d}", .{i});
        _ = try original.set(testing.allocator, key, value);
    }

    var copied = original.copy();
    defer copied.deinit(testing.allocator);

    const replacement = try testing.allocator.dupe(u8, "replacement");
    const old = (try copied.replace(testing.allocator, 42, replacement)).?;
    releaseBytes(testing.allocator, old);

    try testing.expectEqualStrings("value-42", original.get(42).?);
    try testing.expectEqualStrings("replacement", copied.get(42).?);
    try original.checkInvariants();
    try copied.checkInvariants();
}

test "string map stress covers prefix and no-prefix routing" {
    const PrefixMap = map.Map([]const u8, usize, .{});
    const NoPrefixMap = map.Map([]const u8, usize, .{ .use_string_prefix = false });

    inline for (.{ PrefixMap, NoPrefixMap }) |StringMap| {
        var m = StringMap.init();
        defer m.deinit(testing.allocator);

        var buffers: [2000][16]u8 = undefined;
        const keys = fillPermutation(2000, 0x5eed_0005);
        for (keys, 0..) |permuted, i| {
            const key = try std.fmt.bufPrint(&buffers[i], "{d}", .{permuted});
            try testing.expectEqual(null, m.get(key));
            try testing.expect(try m.insert(testing.allocator, key, @intCast(permuted)));
            const expected_value: usize = @intCast(permuted);
            try testing.expectEqual(expected_value, m.get(key));
            try testing.expect(!try m.insert(testing.allocator, key, 999_999));
            if (i % 301 == 0) try m.checkInvariants();
        }

        var copied = m.copy();
        defer copied.deinit(testing.allocator);

        for (keys, 0..) |permuted, i| {
            var missing_buffer: [20]u8 = undefined;
            const missing_key = try std.fmt.bufPrint(&missing_buffer, "{d}*", .{permuted});
            try testing.expectEqual(null, try copied.delete(testing.allocator, missing_key));
            if (i % 301 == 0) try copied.checkInvariants();
        }

        for (keys, 0..) |permuted, i| {
            const key = try std.fmt.bufPrint(&buffers[i], "{d}", .{permuted});
            const expected_value: usize = @intCast(permuted);
            try testing.expectEqual(expected_value, try m.delete(testing.allocator, key));
            try testing.expectEqual(null, try m.replace(testing.allocator, key, 100));
        }
        try testing.expectEqual(0, m.len());
        try testing.expectEqual(2000, copied.len());
        try m.checkInvariants();
        try copied.checkInvariants();
    }
}

test "string map handles long common-prefix keys" {
    const StringMap = map.Map([]const u8, i32, .{});
    var m = StringMap.init();
    defer m.deinit(testing.allocator);

    const prefix = "hfpqmrixjhshqoeuryfbal";
    var buffers: [5000][64]u8 = undefined;
    for (&buffers, 0..) |*buffer, i| {
        const key = try std.fmt.bufPrint(buffer, "{s}:{d}", .{ prefix, i });
        try testing.expectEqual(null, m.get(key));
        try testing.expectEqual(null, try m.delete(testing.allocator, key));
        const value: i32 = @intCast(i);
        _ = try m.set(testing.allocator, key, value);
        try testing.expectEqual(value, m.get(key));
        try testing.expectEqual(value, try m.set(testing.allocator, key, -value));
        try testing.expectEqual(-value, m.get(key));
        if (i % 301 == 0) try m.checkInvariants();
    }
    try m.checkInvariants();
}
