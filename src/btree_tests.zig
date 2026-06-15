const std = @import("std");
const btree = @import("btree.zig");
const testing = std.testing;

fn compareIntKey(a_key: isize, _: isize, b_key: isize, _: isize) i32 {
    return if (a_key < b_key) -1 else if (a_key > b_key) 1 else 0;
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
