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

fn collect(ctx: *CollectContext, key: i32, value: i32) !void {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
}

fn collectUntil(ctx: *CollectContext, key: i32, value: i32) !bool {
    try collect(ctx, key, value);
    return ctx.len < 3;
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

    try testing.expectEqual(@as(usize, 4), removed.removed_count);
    try testing.expectEqual(@as(usize, 4), removed.items.len);
    for (removed.items, 3..) |item, expected_usize| {
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
