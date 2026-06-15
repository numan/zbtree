const std = @import("std");
const btree = @import("btree.zig");
const testing = std.testing;

fn compareIntKey(a_key: isize, _: isize, b_key: isize, _: isize) i32 {
    return if (a_key < b_key) -1 else if (a_key > b_key) 1 else 0;
}

const Pair = struct {
    key: isize,
    value: isize,
};

const CollectContext = struct {
    items: [300]Pair = undefined,
    len: usize = 0,
};

fn collectPair(ctx: *CollectContext, key: isize, value: isize) !void {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
}

const StopAfterContext = struct {
    seen: usize = 0,
    stop_after: usize,
};

fn stopAfter(ctx: *StopAfterContext, _: isize, _: isize) !void {
    if (ctx.seen == ctx.stop_after) return error.StopTraversal;
    ctx.seen += 1;
}
test "empty btree has expected constants" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    const tree = IntTree.init();

    try testing.expectEqual(64, IntTree.fanout);
    try testing.expectEqual(63, IntTree.max_items);
    try testing.expectEqual(31, IntTree.min_items);
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
}

test "insert rejects duplicate keys" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insert(testing.allocator, 42, 100));
    try testing.expect(!try tree.insert(testing.allocator, 42, 200));

    try testing.expectEqual(1, tree.len);
    try testing.expectEqual(100, tree.get(42, 0).?);
}

test "insert and get random keys" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(12345);
    var keys: [5000]isize = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    prng.random().shuffle(isize, &keys);

    for (keys) |key| {
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    for (0..5000) |i| {
        const key: isize = @intCast(i);
        try testing.expectEqual(-key, tree.get(key, -key).?);
    }

    try testing.expectEqual(5000, tree.len);
}

test "random insertion preserves invariants" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(7);
    var keys: [10_000]isize = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    prng.random().shuffle(isize, &keys);

    for (keys, 0..) |key, i| {
        try testing.expect(try tree.insert(testing.allocator, key, -key));
        if (i % 137 == 0) try tree.checkInvariants();
    }
    try tree.checkInvariants();
}

test "ascent visits an empty tree without yielding" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    const tree = IntTree.init();

    var seen = CollectContext{};

    try tree.ascent(*CollectContext, &seen, collectPair);

    try testing.expectEqual(0, seen.len);
}

test "ascent yields every item in sorted order" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(123);
    var keys: [256]isize = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    prng.random().shuffle(isize, &keys);

    for (keys) |key| {
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    var seen = CollectContext{};

    try tree.ascent(*CollectContext, &seen, collectPair);

    try testing.expectEqual(keys.len, seen.len);
    for (seen.items[0..seen.len], 0..) |pair, i| {
        const key: isize = @intCast(i);
        try testing.expectEqual(key, pair.key);
        try testing.expectEqual(key * 10, pair.value);
    }
}

test "ascent propagates yield errors and stops traversal" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..100) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    var ctx = StopAfterContext{ .stop_after = 17 };

    try testing.expectError(error.StopTraversal, tree.ascent(*StopAfterContext, &ctx, stopAfter));
    try testing.expectEqual(17, ctx.seen);
}
