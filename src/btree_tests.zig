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

const CollectLimitContext = struct {
    items: [300]Pair = undefined,
    len: usize = 0,
    limit: usize,
};

fn collectPairUntilLimit(ctx: *CollectLimitContext, key: isize, value: isize) !bool {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
    return ctx.len < ctx.limit;
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

test "replace updates existing value without inserting" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(tree.replace(42, 420) == null);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    try testing.expect(try tree.insert(testing.allocator, 20, 200));

    try testing.expectEqual(100, tree.replace(10, 111).?);
    try testing.expectEqual(2, tree.len);
    try testing.expectEqual(111, tree.get(10, 0).?);
    try testing.expectEqual(200, tree.get(20, 0).?);

    try testing.expect(tree.replace(30, 300) == null);
    try testing.expectEqual(2, tree.len);
    try tree.checkInvariants();
}

test "set inserts missing keys and replaces existing values" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.set(testing.allocator, 10, 100) == null);
    try testing.expect(try tree.set(testing.allocator, 20, 200) == null);
    try testing.expectEqual(2, tree.len);

    try testing.expectEqual(100, (try tree.set(testing.allocator, 10, 111)).?);
    try testing.expectEqual(2, tree.len);
    try testing.expectEqual(111, tree.get(10, 0).?);
    try testing.expectEqual(200, tree.get(20, 0).?);
    try tree.checkInvariants();
}

test "set replaces values after node splits without changing counts" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..500) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.set(testing.allocator, key, key * 10) == null);
    }
    try testing.expectEqual(500, tree.len);

    for (0..500) |i| {
        if (i % 3 == 0) {
            const key: isize = @intCast(i);
            try testing.expectEqual(key * 10, (try tree.set(testing.allocator, key, -key)).?);
        }
    }

    try testing.expectEqual(500, tree.len);
    for (0..500) |i| {
        const key: isize = @intCast(i);
        const expected = if (i % 3 == 0) -key else key * 10;
        try testing.expectEqual(expected, tree.get(key, 0).?);
        try testing.expectEqual(i, tree.indexOf(key, 0).?);
    }
    try tree.checkInvariants();
}

test "delete returns null for empty and missing keys" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.delete(testing.allocator, 10, 0) == null);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    try testing.expect(try tree.insert(testing.allocator, 20, 200));

    try testing.expect(try tree.delete(testing.allocator, 30, 0) == null);
    try testing.expectEqual(2, tree.len);
    try testing.expectEqual(100, tree.get(10, 0).?);
    try testing.expectEqual(200, tree.get(20, 0).?);
    try tree.checkInvariants();
}

test "delete removes leaf keys and resets an empty root" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    try testing.expect(try tree.insert(testing.allocator, 20, 200));
    try testing.expect(try tree.insert(testing.allocator, 30, 300));

    try testing.expectEqual(200, (try tree.delete(testing.allocator, 20, 0)).?);
    try testing.expectEqual(2, tree.len);
    try testing.expect(tree.get(20, 0) == null);
    try testing.expectEqual(100, tree.get(10, 0).?);
    try testing.expectEqual(300, tree.get(30, 0).?);
    try tree.checkInvariants();

    try testing.expectEqual(100, (try tree.delete(testing.allocator, 10, 0)).?);
    try testing.expectEqual(300, (try tree.delete(testing.allocator, 30, 0)).?);
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
    try tree.checkInvariants();
}

test "delete removes internal keys and preserves indexed order" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    try testing.expectEqual(310, (try tree.delete(testing.allocator, 31, 0)).?);
    try testing.expectEqual(640, (try tree.delete(testing.allocator, 64, 0)).?);
    try testing.expectEqual(0, (try tree.delete(testing.allocator, 0, 0)).?);
    try testing.expectEqual(147, tree.len);
    try testing.expect(tree.get(31, 0) == null);
    try testing.expect(tree.get(64, 0) == null);
    try testing.expect(tree.get(0, 0) == null);

    var expected: usize = 0;
    var index: usize = 0;
    while (expected < 150) : (expected += 1) {
        if (expected == 0 or expected == 31 or expected == 64) continue;
        const key: isize = @intCast(expected);
        const entry = tree.getAt(index).?;
        try testing.expectEqual(key, entry.key);
        try testing.expectEqual(key * 10, entry.value);
        try testing.expectEqual(index, tree.indexOf(key, 0).?);
        index += 1;
    }
    try testing.expectEqual(tree.len, index);
    try tree.checkInvariants();
}

test "front and back return null for an empty tree" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(tree.front() == null);
    try testing.expect(tree.back() == null);
    try testing.expect(try tree.popFront(testing.allocator) == null);
    try testing.expect(try tree.popBack(testing.allocator) == null);
}

test "front and back find edge entries after splits" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(2024);
    var keys: [300]isize = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    prng.random().shuffle(isize, &keys);

    for (keys) |key| {
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    try testing.expectEqual(0, tree.front().?.key);
    try testing.expectEqual(0, tree.front().?.value);
    try testing.expectEqual(299, tree.back().?.key);
    try testing.expectEqual(2990, tree.back().?.value);
    try tree.checkInvariants();
}

test "pushFront and pushBack enforce edge ordering" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.pushFront(testing.allocator, 10, 100));
    try testing.expect(try tree.pushFront(testing.allocator, 5, 50));
    try testing.expect(!try tree.pushFront(testing.allocator, 7, 70));
    try testing.expect(!try tree.pushFront(testing.allocator, 5, 500));

    try testing.expect(try tree.pushBack(testing.allocator, 20, 200));
    try testing.expect(try tree.pushBack(testing.allocator, 30, 300));
    try testing.expect(!try tree.pushBack(testing.allocator, 25, 250));
    try testing.expect(!try tree.pushBack(testing.allocator, 30, 3000));

    try testing.expectEqual(4, tree.len);
    try testing.expectEqual(5, tree.front().?.key);
    try testing.expectEqual(30, tree.back().?.key);
    try tree.checkInvariants();
}

test "popFront and popBack remove edge entries" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..100) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try testing.expectEqual(0, (try tree.popFront(testing.allocator)).?.key);
    try testing.expectEqual(99, (try tree.popBack(testing.allocator)).?.key);
    try testing.expectEqual(98, tree.len);
    try testing.expectEqual(1, tree.front().?.key);
    try testing.expectEqual(98, tree.back().?.key);
    try testing.expect(tree.get(0, 0) == null);
    try testing.expect(tree.get(99, 0) == null);
    try tree.checkInvariants();

    var expected_front: isize = 1;
    while (try tree.popFront(testing.allocator)) |entry| : (expected_front += 1) {
        try testing.expectEqual(expected_front, entry.key);
    }

    try testing.expectEqual(99, expected_front);
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
}

test "insertAt inserts only when the item fits at the index" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insertAt(testing.allocator, 0, 10, 100));
    try testing.expect(try tree.insertAt(testing.allocator, 0, 5, 50));
    try testing.expect(try tree.insertAt(testing.allocator, 2, 20, 200));
    try testing.expect(try tree.insertAt(testing.allocator, 2, 15, 150));

    try testing.expect(!try tree.insertAt(testing.allocator, 10, 30, 300));
    try testing.expect(!try tree.insertAt(testing.allocator, 1, 30, 300));
    try testing.expect(!try tree.insertAt(testing.allocator, 2, 5, 500));

    try testing.expectEqual(4, tree.len);
    for ([_]isize{ 5, 10, 15, 20 }, 0..) |key, index| {
        try testing.expectEqual(key, tree.getAt(index).?.key);
        try testing.expectEqual(index, tree.indexOf(key, 0).?);
    }
    try tree.checkInvariants();
}

test "replaceAt replaces only when the new item fits" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for ([_]isize{ 10, 20, 30, 40 }) |key| {
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    const old = (try tree.replaceAt(testing.allocator, 1, 25, 250)).?;
    try testing.expectEqual(20, old.key);
    try testing.expectEqual(200, old.value);
    try testing.expectEqual(4, tree.len);
    try testing.expect(tree.get(20, 0) == null);
    try testing.expectEqual(250, tree.get(25, 0).?);

    try testing.expect(try tree.replaceAt(testing.allocator, 1, 35, 350) == null);
    try testing.expectEqual(4, tree.len);
    try testing.expectEqual(250, tree.get(25, 0).?);
    try testing.expect(tree.get(35, 0) == null);

    try testing.expect(try tree.replaceAt(testing.allocator, 4, 50, 500) == null);
    try tree.checkInvariants();
}

test "deleteAt removes by sorted index" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..80) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try testing.expectEqual(0, (try tree.deleteAt(testing.allocator, 0)).?.key);
    try testing.expectEqual(40, (try tree.deleteAt(testing.allocator, 39)).?.key);
    try testing.expectEqual(79, (try tree.deleteAt(testing.allocator, tree.len - 1)).?.key);
    try testing.expect(try tree.deleteAt(testing.allocator, tree.len) == null);

    try testing.expectEqual(77, tree.len);
    try testing.expect(tree.get(0, 0) == null);
    try testing.expect(tree.get(40, 0) == null);
    try testing.expect(tree.get(79, 0) == null);
    try testing.expectEqual(1, tree.getAt(0).?.key);
    try testing.expectEqual(41, tree.getAt(39).?.key);
    try testing.expectEqual(78, tree.getAt(tree.len - 1).?.key);
    try tree.checkInvariants();
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

test "descent visits an empty tree without yielding" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    const tree = IntTree.init();

    var seen = CollectContext{};

    try tree.descent(*CollectContext, &seen, collectPair);

    try testing.expectEqual(0, seen.len);
}

test "descent yields every item in reverse sorted order" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(456);
    var keys: [256]isize = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    prng.random().shuffle(isize, &keys);

    for (keys) |key| {
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    var seen = CollectContext{};

    try tree.descent(*CollectContext, &seen, collectPair);

    try testing.expectEqual(keys.len, seen.len);
    for (seen.items[0..seen.len], 0..) |pair, i| {
        const key: isize = @intCast(keys.len - 1 - i);
        try testing.expectEqual(key, pair.key);
        try testing.expectEqual(key * 10, pair.value);
    }
}

test "descent propagates yield errors and stops traversal" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..100) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    var ctx = StopAfterContext{ .stop_after = 17 };

    try testing.expectError(error.StopTraversal, tree.descent(*StopAfterContext, &ctx, stopAfter));
    try testing.expectEqual(17, ctx.seen);
}

test "seek functions handle empty trees and edge positions" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(tree.seek(10, 0) == null);
    try testing.expect(tree.seekNext(10, 0) == null);
    try testing.expect(tree.seekPrev(10, 0) == null);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    try testing.expect(try tree.insert(testing.allocator, 20, 200));
    try testing.expect(try tree.insert(testing.allocator, 30, 300));

    try testing.expectEqual(10, tree.seek(5, 0).?.key);
    try testing.expectEqual(10, tree.seek(10, 0).?.key);
    try testing.expectEqual(20, tree.seek(15, 0).?.key);
    try testing.expectEqual(30, tree.seek(30, 0).?.key);
    try testing.expect(tree.seek(31, 0) == null);

    try testing.expectEqual(10, tree.seekNext(5, 0).?.key);
    try testing.expectEqual(20, tree.seekNext(10, 0).?.key);
    try testing.expectEqual(30, tree.seekNext(20, 0).?.key);
    try testing.expect(tree.seekNext(30, 0) == null);

    try testing.expect(tree.seekPrev(5, 0) == null);
    try testing.expect(tree.seekPrev(10, 0) == null);
    try testing.expectEqual(10, tree.seekPrev(15, 0).?.key);
    try testing.expectEqual(10, tree.seekPrev(20, 0).?.key);
    try testing.expectEqual(30, tree.seekPrev(31, 0).?.key);
}

test "getAt and indexOf use subtree counts" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(9876);
    var keys: [8000]isize = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i * 2);
    prng.random().shuffle(isize, &keys);

    for (keys) |key| {
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    for (0..8000) |i| {
        const key: isize = @intCast(i * 2);
        const entry = tree.getAt(i).?;
        try testing.expectEqual(key, entry.key);
        try testing.expectEqual(-key, entry.value);
        try testing.expectEqual(i, tree.indexOf(entry.key, entry.value).?);
    }

    try testing.expect(tree.getAt(8000) == null);
    try testing.expect(tree.indexOf(-2, 0) == null);
    try testing.expect(tree.indexOf(1, 0) == null);
    try testing.expect(tree.indexOf(16_000, 0) == null);
    try tree.checkInvariants();
}

test "ascendAt and descendAt start at an index and stop when yield returns false" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..100) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    var asc = CollectLimitContext{ .limit = 5 };
    try tree.ascendAt(*CollectLimitContext, 40, &asc, collectPairUntilLimit);
    try testing.expectEqual(5, asc.len);
    for (asc.items[0..asc.len], 0..) |pair, i| {
        const key: isize = @intCast(40 + i);
        try testing.expectEqual(key, pair.key);
        try testing.expectEqual(key * 10, pair.value);
    }

    var desc = CollectLimitContext{ .limit = 5 };
    try tree.descendAt(*CollectLimitContext, 40, &desc, collectPairUntilLimit);
    try testing.expectEqual(5, desc.len);
    for (desc.items[0..desc.len], 0..) |pair, i| {
        const key: isize = @intCast(40 - i);
        try testing.expectEqual(key, pair.key);
        try testing.expectEqual(key * 10, pair.value);
    }

    var out_of_range = CollectLimitContext{ .limit = 5 };
    try tree.ascendAt(*CollectLimitContext, 100, &out_of_range, collectPairUntilLimit);
    try tree.descendAt(*CollectLimitContext, 100, &out_of_range, collectPairUntilLimit);
    try testing.expectEqual(0, out_of_range.len);
}
