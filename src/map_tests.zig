const std = @import("std");
const btree = @import("btree.zig");
const map = @import("map.zig");
const testing = std.testing;

const Pair = struct {
    key: i32,
    value: i32,
};

const CollectContext = struct {
    items: [16]Pair = undefined,
    len: usize = 0,
};

const OracleKeyCount = 256;

const OracleCollectContext = struct {
    items: [OracleKeyCount]Pair = undefined,
    len: usize = 0,

    fn collect(ctx: *@This(), key: i32, value: i32) !void {
        ctx.items[ctx.len] = .{ .key = key, .value = value };
        ctx.len += 1;
    }
};

const LargeCollectContext = struct {
    items: [512]Pair = undefined,
    len: usize = 0,
};

const TraversalLimitContext = struct {
    items: [8]Pair = undefined,
    len: usize = 0,
    limit: usize,
};

const TraversalFailContext = struct {
    seen: usize = 0,
    fail_after: usize,
};

var tracked_copy_count: usize = 0;
var tracked_release_count: usize = 0;

fn collect(ctx: *CollectContext, key: i32, value: i32) !void {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
}

fn collectLarge(ctx: *LargeCollectContext, key: i32, value: i32) !void {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
}

fn collectLargeContinue(ctx: *LargeCollectContext, key: i32, value: i32) !bool {
    try collectLarge(ctx, key, value);
    return true;
}

fn collectUntil(ctx: *CollectContext, key: i32, value: i32) !bool {
    try collect(ctx, key, value);
    return ctx.len < 3;
}

fn collectUntilLimit(ctx: *TraversalLimitContext, key: i32, value: i32) !bool {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
    return ctx.len < ctx.limit;
}

fn failAfterLimit(ctx: *TraversalFailContext, _: i32, _: i32) !bool {
    ctx.seen += 1;
    if (ctx.seen > ctx.fail_after) return error.StopTraversal;
    return true;
}

fn addKeyToValue(_: void, key: i32, value: *i32) !void {
    value.* += key;
}

fn copyBytes(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try gpa.dupe(u8, value);
}

fn releaseBytes(gpa: std.mem.Allocator, value: []const u8) void {
    gpa.free(value);
}

fn copyTrackedInt(_: std.mem.Allocator, value: i32) !i32 {
    tracked_copy_count += 1;
    return value;
}

fn releaseTrackedInt(_: std.mem.Allocator, _: i32) void {
    tracked_release_count += 1;
}

fn expectMapEntry(entry: anytype, key: i32, value: i32) !void {
    try testing.expect(entry != null);
    try testing.expectEqual(key, entry.?.key);
    try testing.expectEqual(value, entry.?.value);
}

fn expectOptionalMapEntry(entry: anytype, expected: ?Pair) !void {
    if (expected) |pair| {
        try expectMapEntry(entry, pair.key, pair.value);
    } else {
        try testing.expect(entry == null);
    }
}

fn expectedAtOrAfter(present: *const [OracleKeyCount]bool, values: *const [OracleKeyCount]i32, key_index: usize) ?Pair {
    var i = key_index;
    while (i < OracleKeyCount) : (i += 1) {
        if (present[i]) return .{ .key = @intCast(i), .value = values[i] };
    }
    return null;
}

fn expectedAfter(present: *const [OracleKeyCount]bool, values: *const [OracleKeyCount]i32, key_index: usize) ?Pair {
    var i = key_index + 1;
    while (i < OracleKeyCount) : (i += 1) {
        if (present[i]) return .{ .key = @intCast(i), .value = values[i] };
    }
    return null;
}

fn expectedBefore(present: *const [OracleKeyCount]bool, values: *const [OracleKeyCount]i32, key_index: usize) ?Pair {
    var i = key_index;
    while (i > 0) {
        i -= 1;
        if (present[i]) return .{ .key = @intCast(i), .value = values[i] };
    }
    return null;
}

fn refillIntMap(comptime IntMap: type, m: *IntMap, count: usize) !void {
    m.clear(testing.allocator);
    for (0..count) |i| {
        const key: i32 = @intCast(i);
        _ = try m.set(testing.allocator, key, key * 10);
    }
}

fn runRandomDeleteRangeCase(comptime opts: map.DeleteRangeOptions, seed: u64) !void {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    for (0..OracleKeyCount) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try m.insert(testing.allocator, key, key * 10));
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const a = random.intRangeLessThan(usize, 0, OracleKeyCount + 32);
    const b = random.intRangeLessThan(usize, 0, OracleKeyCount + 32);
    const min_key: i32 = @intCast(@min(a, b));
    const max_key: i32 = @intCast(@max(a, b));

    const removed = try m.deleteRange(testing.allocator, min_key, max_key, opts);
    defer removed.deinit(testing.allocator);

    var removed_items = OracleCollectContext{};
    try removed.ascent(*OracleCollectContext, &removed_items, OracleCollectContext.collect);

    var expected_removed: usize = 0;
    var remaining: usize = 0;
    for (0..OracleKeyCount) |i| {
        const key: i32 = @intCast(i);
        const above_min = if (comptime opts.min_exclusive) key > min_key else key >= min_key;
        const below_max = if (comptime opts.max_inclusive) key <= max_key else key < max_key;
        const in_range = above_min and below_max;

        if (in_range) {
            try testing.expectEqual(key, removed_items.items[expected_removed].key);
            try testing.expectEqual(key * 10, removed_items.items[expected_removed].value);
            try testing.expectEqual(null, m.get(key));
            expected_removed += 1;
        } else {
            try testing.expectEqual(key * 10, m.get(key));
            remaining += 1;
        }
    }

    try testing.expectEqual(expected_removed, removed.removed_count);
    try testing.expectEqual(expected_removed, removed_items.len);
    try testing.expectEqual(remaining, m.len());
    try m.checkInvariants();
}

fn expectMapMatchesOracle(comptime MapType: type, m: *const MapType, present: *const [OracleKeyCount]bool, values: *const [OracleKeyCount]i32) !void {
    var expected_len: usize = 0;
    var first: ?Pair = null;
    var last: ?Pair = null;

    for (0..OracleKeyCount) |i| {
        const key: i32 = @intCast(i);
        if (present[i]) {
            const expected = values[i];
            if (first == null) first = .{ .key = key, .value = expected };
            last = .{ .key = key, .value = expected };

            try testing.expectEqual(expected, m.get(key));
            try testing.expectEqual(expected_len, m.indexOf(key).?);
            try expectMapEntry(m.getAt(expected_len), key, expected);
            expected_len += 1;
        } else {
            try testing.expectEqual(null, m.get(key));
            try testing.expectEqual(null, m.indexOf(key));
        }

        try expectOptionalMapEntry(m.seek(key), expectedAtOrAfter(present, values, i));
        try expectOptionalMapEntry(m.seekNext(key), expectedAfter(present, values, i));
        try expectOptionalMapEntry(m.seekPrev(key), expectedBefore(present, values, i));
    }

    try testing.expectEqual(expected_len, m.len());
    try expectOptionalMapEntry(m.front(), first);
    try expectOptionalMapEntry(m.back(), last);
    try testing.expect(m.getAt(expected_len) == null);

    var ascending = OracleCollectContext{};
    try m.ascent(*OracleCollectContext, &ascending, OracleCollectContext.collect);
    try testing.expectEqual(expected_len, ascending.len);

    var expected_index: usize = 0;
    for (0..OracleKeyCount) |i| {
        if (!present[i]) continue;
        const expected_key: i32 = @intCast(i);
        try testing.expectEqual(expected_key, ascending.items[expected_index].key);
        try testing.expectEqual(values[i], ascending.items[expected_index].value);
        expected_index += 1;
    }

    var descending = OracleCollectContext{};
    try m.descent(*OracleCollectContext, &descending, OracleCollectContext.collect);
    try testing.expectEqual(expected_len, descending.len);

    var remaining = expected_len;
    for (0..OracleKeyCount) |offset| {
        const i = OracleKeyCount - 1 - offset;
        if (!present[i]) continue;
        remaining -= 1;
        const expected_key: i32 = @intCast(i);
        try testing.expectEqual(expected_key, descending.items[expected_len - 1 - remaining].key);
        try testing.expectEqual(values[i], descending.items[expected_len - 1 - remaining].value);
    }

    try m.checkInvariants();
}

test "map re-exports shared btree options and constants" {
    try testing.expectEqual(btree.SearchMode, map.SearchMode);
    try testing.expectEqual(btree.DeleteRangeOptions, map.DeleteRangeOptions);

    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false, .search_mode = .binary });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    try testing.expectEqual(64, IntMap.fanout);
    try testing.expectEqual(63, IntMap.max_items);
    try testing.expectEqual(31, IntMap.min_items);
    try testing.expect(m.isEmpty());

    try testing.expect(try m.insert(testing.allocator, 10, 100));
    const entry: IntMap.Entry = m.front().?;
    try testing.expectEqual(10, entry.key);
    try testing.expectEqual(100, entry.value);
}

test "map facade preserves key-only identity" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    try testing.expect(try m.insert(testing.allocator, 10, 100));
    try testing.expect(!try m.insert(testing.allocator, 10, 200));
    try testing.expectEqual(1, m.len());
    try testing.expectEqual(100, m.get(10));

    try testing.expectEqual(100, try m.set(testing.allocator, 10, 200));
    try testing.expectEqual(200, try m.replace(testing.allocator, 10, 300));
    try testing.expectEqual(300, try m.delete(testing.allocator, 10));
    try testing.expect(m.isEmpty());
    try m.checkInvariants();
}

test "map facade forwards ordered traversal and index APIs" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    for ([_]i32{ 5, 1, 3, 2, 4 }) |key| {
        try testing.expect(try m.insert(testing.allocator, key, key * 10));
    }

    try expectMapEntry(m.front(), 1, 10);
    try expectMapEntry(m.back(), 5, 50);
    try testing.expectEqual(2, m.indexOf(3));
    try expectMapEntry(m.seek(4), 4, 40);
    try expectMapEntry(m.seekNext(3), 4, 40);
    try expectMapEntry(m.seekPrev(3), 2, 20);
    try expectMapEntry(m.getAt(2), 3, 30);

    var ascending = CollectContext{};
    try m.ascent(*CollectContext, &ascending, collect);
    try testing.expectEqual(5, ascending.len);
    for (ascending.items[0..ascending.len], 1..) |item, expected_usize| {
        const expected: i32 = @intCast(expected_usize);
        try testing.expectEqual(expected, item.key);
        try testing.expectEqual(expected * 10, item.value);
    }

    var partial = CollectContext{};
    try m.ascendAt(*CollectContext, 1, &partial, collectUntil);
    try testing.expectEqual(3, partial.len);
    try testing.expectEqual(2, partial.items[0].key);
    try testing.expectEqual(4, partial.items[2].key);
}

test "map randomized operations match sorted oracle" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    var present: [OracleKeyCount]bool = @splat(false);
    var values: [OracleKeyCount]i32 = @splat(0);
    var prng = std.Random.DefaultPrng.init(0x5eed_cafe);
    const random = prng.random();

    for (0..2000) |step| {
        const key_index = random.intRangeLessThan(usize, 0, OracleKeyCount);
        const key: i32 = @intCast(key_index);
        const value: i32 = @as(i32, @intCast(step)) * 1000 + key;

        switch (random.intRangeLessThan(usize, 0, 7)) {
            0 => {
                const inserted = try m.insert(testing.allocator, key, value);
                try testing.expectEqual(!present[key_index], inserted);
                if (inserted) {
                    present[key_index] = true;
                    values[key_index] = value;
                }
            },
            1 => {
                const old = try m.set(testing.allocator, key, value);
                if (present[key_index]) {
                    try testing.expectEqual(values[key_index], old);
                } else {
                    try testing.expectEqual(null, old);
                    present[key_index] = true;
                }
                values[key_index] = value;
            },
            2 => {
                const old = try m.replace(testing.allocator, key, value);
                if (present[key_index]) {
                    try testing.expectEqual(values[key_index], old);
                    values[key_index] = value;
                } else {
                    try testing.expectEqual(null, old);
                }
            },
            3 => {
                const old = try m.delete(testing.allocator, key);
                if (present[key_index]) {
                    try testing.expectEqual(values[key_index], old);
                    present[key_index] = false;
                } else {
                    try testing.expectEqual(null, old);
                }
            },
            4 => {
                if (present[key_index]) {
                    try testing.expectEqual(values[key_index], m.get(key));
                } else {
                    try testing.expectEqual(null, m.get(key));
                }
            },
            5 => {
                try expectOptionalMapEntry(m.seek(key), expectedAtOrAfter(&present, &values, key_index));
                try expectOptionalMapEntry(m.seekNext(key), expectedAfter(&present, &values, key_index));
                try expectOptionalMapEntry(m.seekPrev(key), expectedBefore(&present, &values, key_index));
            },
            else => {
                var expected_len: usize = 0;
                for (present) |is_present| {
                    if (is_present) expected_len += 1;
                }
                if (expected_len == 0) {
                    try testing.expect(m.getAt(0) == null);
                } else {
                    const rank = random.intRangeLessThan(usize, 0, expected_len);
                    var seen: usize = 0;
                    for (0..OracleKeyCount) |i| {
                        if (!present[i]) continue;
                        if (seen == rank) {
                            try expectMapEntry(m.getAt(rank), @intCast(i), values[i]);
                            break;
                        }
                        seen += 1;
                    }
                }
            },
        }

        if (step % 25 == 0) try expectMapMatchesOracle(IntMap, &m, &present, &values);
    }

    try expectMapMatchesOracle(IntMap, &m, &present, &values);
}

test "map facade forwards mutable accessors and copy-on-write" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var original = IntMap.init();
    defer original.deinit(testing.allocator);

    for (0..128) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, key));
    }

    var copied = original.copy();
    defer copied.deinit(testing.allocator);

    (try copied.getMut(testing.allocator, 42)).?.* = -42;
    (try copied.getAtMut(testing.allocator, 100)).?.value.* = -100;
    try copied.ascentMut(testing.allocator, void, {}, addKeyToValue);

    try testing.expectEqual(42, original.get(42));
    try testing.expectEqual(100, original.get(100));
    try testing.expectEqual(0, copied.get(42));
    try testing.expectEqual(0, copied.get(100));
    try original.checkInvariants();
    try copied.checkInvariants();
}

test "map set inserts into copied tree without mutating original" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var original = IntMap.init();
    defer original.deinit(testing.allocator);

    for (0..256) |i| {
        const key: i32 = @intCast(i * 2);
        try testing.expect(try original.insert(testing.allocator, key, key));
    }

    var copied = original.copy();
    defer copied.deinit(testing.allocator);

    try testing.expectEqual(null, try copied.set(testing.allocator, 255, -255));
    try testing.expectEqual(42, try copied.set(testing.allocator, 42, -42));

    try testing.expectEqual(null, original.get(255));
    try testing.expectEqual(42, original.get(42));
    try testing.expectEqual(-255, copied.get(255));
    try testing.expectEqual(-42, copied.get(42));
    try testing.expectEqual(256, original.len());
    try testing.expectEqual(257, copied.len());
    try original.checkInvariants();
    try copied.checkInvariants();
}

test "map facade forwards range deletion result ownership" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    for (0..8) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try m.insert(testing.allocator, key, key * 10));
    }

    const removed = try m.deleteRange(testing.allocator, 2, 5, .{ .max_inclusive = true });
    defer removed.deinit(testing.allocator);

    var removed_items = CollectContext{};
    try removed.ascent(*CollectContext, &removed_items, collect);
    try testing.expectEqual(4, removed.removed_count);
    try testing.expectEqual(4, removed_items.len);
    for (removed_items.items[0..removed_items.len], 2..) |item, expected_usize| {
        const expected: i32 = @intCast(expected_usize);
        try testing.expectEqual(expected, item.key);
        try testing.expectEqual(expected * 10, item.value);
    }
    try testing.expectEqual(4, m.len());
    try m.checkInvariants();
}

test "map randomized range deletion matches sorted oracle" {
    for (0..64) |i| {
        switch (i % 4) {
            0 => try runRandomDeleteRangeCase(.{}, 0x7261_6e67_6500 + i),
            1 => try runRandomDeleteRangeCase(.{ .min_exclusive = true }, 0x7261_6e67_6500 + i),
            2 => try runRandomDeleteRangeCase(.{ .max_inclusive = true }, 0x7261_6e67_6500 + i),
            else => try runRandomDeleteRangeCase(.{ .min_exclusive = true, .max_inclusive = true }, 0x7261_6e67_6500 + i),
        }
    }
}

test "map deleteRangeAt covers empty clamped and full ranges" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    try refillIntMap(IntMap, &m, 32);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 32, 1, .{});
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(0, removed.removed_count);
        try testing.expectEqual(32, m.len());
    }
    {
        const removed = try m.deleteRangeAt(testing.allocator, 10, 0, .{});
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(0, removed.removed_count);
        try testing.expectEqual(32, m.len());
    }
    {
        const removed = try m.deleteRangeAt(testing.allocator, 28, 99, .{});
        defer removed.deinit(testing.allocator);
        var removed_items = CollectContext{};
        try removed.ascent(*CollectContext, &removed_items, collect);
        try testing.expectEqual(4, removed.removed_count);
        try testing.expectEqual(4, removed_items.len);
        for (removed_items.items[0..removed_items.len], 28..) |item, expected_usize| {
            const expected: i32 = @intCast(expected_usize);
            try testing.expectEqual(expected, item.key);
            try testing.expectEqual(expected * 10, item.value);
        }
        try testing.expectEqual(28, m.len());
    }

    try refillIntMap(IntMap, &m, 32);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 0, 32, .{});
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(32, removed.removed_count);
        try testing.expect(m.isEmpty());
    }

    try refillIntMap(IntMap, &m, 32);
    {
        const removed = try m.deleteRangeAt(testing.allocator, 8, 4, .{ .min_exclusive = true, .max_inclusive = true });
        defer removed.deinit(testing.allocator);
        var removed_items = CollectContext{};
        try removed.ascent(*CollectContext, &removed_items, collect);
        try testing.expectEqual(4, removed.removed_count);
        try testing.expectEqual(9, removed_items.items[0].key);
        try testing.expectEqual(12, removed_items.items[3].key);
        try testing.expectEqual(28, m.len());
    }
    try m.checkInvariants();
}

test "map indexed operations return null outside bounds" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    try testing.expect(m.getAt(0) == null);
    try testing.expect((try m.getAtMut(testing.allocator, 0)) == null);
    try testing.expect((try m.deleteAt(testing.allocator, 0)) == null);
    try testing.expect((try m.replaceAt(testing.allocator, 0, 1, 10)) == null);

    try refillIntMap(IntMap, &m, 8);
    try testing.expect(m.getAt(8) == null);
    try testing.expect(m.getAt(99) == null);
    try testing.expect((try m.getAtMut(testing.allocator, 8)) == null);
    try testing.expect((try m.deleteAt(testing.allocator, 8)) == null);
    try testing.expect((try m.replaceAt(testing.allocator, 8, 99, 990)) == null);
    try testing.expectEqual(8, m.len());
    try m.checkInvariants();
}

test "map facade preserves value ownership hooks" {
    const ByteMap = map.Map(i32, []const u8, .{
        .use_string_prefix = false,
        .copy_value = copyBytes,
        .release_value = releaseBytes,
    });
    var original = ByteMap.init();
    defer original.deinit(testing.allocator);

    const value = try testing.allocator.dupe(u8, "value-42");
    try testing.expect(try original.insert(testing.allocator, 42, value));

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

test "map copy-on-write stress isolates generations with value hooks" {
    tracked_copy_count = 0;
    tracked_release_count = 0;

    const IntMap = map.Map(i32, i32, .{
        .use_string_prefix = false,
        .copy_value = copyTrackedInt,
        .release_value = releaseTrackedInt,
    });
    var original = IntMap.init();
    defer original.deinit(testing.allocator);

    for (0..128) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, key));
    }

    var first_copy = original.copy();
    defer first_copy.deinit(testing.allocator);
    var second_copy = first_copy.copy();
    defer second_copy.deinit(testing.allocator);

    for (0..32) |i| {
        const key: i32 = @intCast(i);
        try testing.expectEqual(key, try first_copy.set(testing.allocator, key, -key));
    }
    for (32..64) |i| {
        const key: i32 = @intCast(i);
        try testing.expectEqual(key, try second_copy.delete(testing.allocator, key));
    }
    (try second_copy.getMut(testing.allocator, 100)).?.* = -100;

    for (0..128) |i| {
        const key: i32 = @intCast(i);
        try testing.expectEqual(key, original.get(key));
        const expected_first = if (i < 32) -key else key;
        try testing.expectEqual(expected_first, first_copy.get(key));
        const expected_second: ?i32 = if (i >= 32 and i < 64) null else if (i == 100) -100 else key;
        try testing.expectEqual(expected_second, second_copy.get(key));
    }

    try testing.expect(tracked_copy_count > 0);
    try original.checkInvariants();
    try first_copy.checkInvariants();
    try second_copy.checkInvariants();
}

test "string map defaults to prefix routing but can disable it" {
    const PrefixMap = map.Map([]const u8, usize, .{});
    const NoPrefixMap = map.Map([]const u8, usize, .{ .use_string_prefix = false });

    inline for (.{ PrefixMap, NoPrefixMap }) |StringMap| {
        var m = StringMap.init();
        defer m.deinit(testing.allocator);

        var buffers: [128][16]u8 = undefined;
        for (&buffers, 0..) |*buffer, i| {
            const key = try std.fmt.bufPrint(buffer, "key-{d:0>3}", .{i});
            try testing.expect(try m.insert(testing.allocator, key, i));
        }

        try testing.expectEqual(42, m.get("key-042"));
        try testing.expectEqualStrings("key-127", m.back().?.key);
        try testing.expectEqual(128, m.len());
        try m.checkInvariants();
    }
}

test "string map handles long common-prefix keys and copied deletions" {
    const PrefixMap = map.Map([]const u8, usize, .{});
    const NoPrefixMap = map.Map([]const u8, usize, .{ .use_string_prefix = false });

    inline for (.{ PrefixMap, NoPrefixMap }) |StringMap| {
        var m = StringMap.init();
        defer m.deinit(testing.allocator);

        var buffers: [192][80]u8 = undefined;
        for (&buffers, 0..) |*buffer, i| {
            const key = try std.fmt.bufPrint(buffer, "shared-prefix-beyond-eight-bytes:{d:0>4}", .{i});
            try testing.expect(try m.insert(testing.allocator, key, i));
        }

        var copied = m.copy();
        defer copied.deinit(testing.allocator);

        try testing.expectEqual(42, m.get("shared-prefix-beyond-eight-bytes:0042"));
        try testing.expectEqual(42, copied.get("shared-prefix-beyond-eight-bytes:0042"));
        try testing.expectEqual(null, m.get("shared-prefix-beyond-eight-bytes:0042-extra"));
        try testing.expectEqual(null, copied.get("shared-prefix-beyond-eight-bytes:0042-extra"));

        const removed = try copied.deleteRange(testing.allocator, "shared-prefix-beyond-eight-bytes:0040", "shared-prefix-beyond-eight-bytes:0045", .{ .max_inclusive = true });
        defer removed.deinit(testing.allocator);
        try testing.expectEqual(6, removed.removed_count);
        try testing.expectEqual(42, m.get("shared-prefix-beyond-eight-bytes:0042"));
        try testing.expectEqual(null, copied.get("shared-prefix-beyond-eight-bytes:0042"));
        try testing.expectEqual(192, m.len());
        try testing.expectEqual(186, copied.len());
        try testing.expectEqualStrings("shared-prefix-beyond-eight-bytes:0000", m.front().?.key);
        try testing.expectEqualStrings("shared-prefix-beyond-eight-bytes:0191", copied.back().?.key);
        try m.checkInvariants();
        try copied.checkInvariants();
    }
}

test "string map set replaces only the value and keeps the stored key" {
    const PrefixMap = map.Map([]const u8, usize, .{});
    const NoPrefixMap = map.Map([]const u8, usize, .{ .use_string_prefix = false });

    inline for (.{ PrefixMap, NoPrefixMap }) |StringMap| {
        var m = StringMap.init();
        defer m.deinit(testing.allocator);

        // 95 ascending inserts leave one separator in the root and a full
        // right leaf whose median is "k-063".
        var stored: [95][8]u8 = undefined;
        var aliases: [95][8]u8 = undefined;
        for (&stored, 0..) |*buffer, i| {
            const key = try std.fmt.bufPrint(buffer, "k-{d:0>3}", .{i});
            try testing.expect(try m.insert(testing.allocator, key, i));
            if (i == 0) {
                // Existing key in a root leaf.
                const same = try std.fmt.bufPrint(&aliases[i], "k-{d:0>3}", .{i});
                try testing.expectEqual(0, try m.set(testing.allocator, same, 1000));
            }
        }
        try testing.expectEqual(1, m.tree.root.?.len);

        // Existing key promoted by the split that set performs on the way down.
        const median = try std.fmt.bufPrint(&aliases[63], "k-{d:0>3}", .{63});
        try testing.expectEqual(63, try m.set(testing.allocator, median, 1063));
        try testing.expectEqual(2, m.tree.root.?.len);

        // Existing keys in branches and leaves.
        for (1..stored.len) |i| {
            if (i == 63) continue;
            const same = try std.fmt.bufPrint(&aliases[i], "k-{d:0>3}", .{i});
            try testing.expectEqual(i, try m.set(testing.allocator, same, i + 1000));
        }

        try testing.expectEqual(stored.len, m.len());
        for (&stored, 0..) |*buffer, i| {
            const entry = m.getAt(i).?;
            try testing.expectEqual(@as([*]const u8, buffer), entry.key.ptr);
            try testing.expectEqual(i + 1000, entry.value);
        }
        try m.checkInvariants();
    }
}

test "map traversal callbacks stop early and propagate errors" {
    const IntMap = map.Map(i32, i32, .{ .use_string_prefix = false });
    var m = IntMap.init();
    defer m.deinit(testing.allocator);

    try refillIntMap(IntMap, &m, 128);

    var asc = TraversalLimitContext{ .limit = 4 };
    try m.ascendAt(*TraversalLimitContext, 60, &asc, collectUntilLimit);
    try testing.expectEqual(4, asc.len);
    try testing.expectEqual(60, asc.items[0].key);
    try testing.expectEqual(63, asc.items[3].key);

    var desc = TraversalLimitContext{ .limit = 4 };
    try m.descendAt(*TraversalLimitContext, 60, &desc, collectUntilLimit);
    try testing.expectEqual(4, desc.len);
    try testing.expectEqual(60, desc.items[0].key);
    try testing.expectEqual(57, desc.items[3].key);

    var all_desc = LargeCollectContext{};
    try m.descendAt(*LargeCollectContext, m.len(), &all_desc, collectLargeContinue);
    try testing.expectEqual(128, all_desc.len);
    try testing.expectEqual(127, all_desc.items[0].key);
    try testing.expectEqual(0, all_desc.items[127].key);

    var fail_asc = TraversalFailContext{ .fail_after = 2 };
    try testing.expectError(error.StopTraversal, m.ascendAt(*TraversalFailContext, 10, &fail_asc, failAfterLimit));
    try testing.expectEqual(3, fail_asc.seen);

    var fail_desc = TraversalFailContext{ .fail_after = 2 };
    try testing.expectError(error.StopTraversal, m.descendAt(*TraversalFailContext, 10, &fail_desc, failAfterLimit));
    try testing.expectEqual(3, fail_desc.seen);
}

test "void map facade supports key-only deletion" {
    const VoidMap = map.Map(i32, void, .{ .use_string_prefix = false });
    var m = VoidMap.init();
    defer m.deinit(testing.allocator);

    for (0..128) |i| {
        const key: i32 = @intCast(i);
        try testing.expect(try m.insert(testing.allocator, key, {}));
    }

    for (0..128) |i| {
        const key: i32 = @intCast(i);
        try testing.expect((try m.delete(testing.allocator, key)) != null);
    }
    try testing.expect(m.isEmpty());
    try m.checkInvariants();
}
