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

const std = @import("std");
const btree = @import("btree.zig");
const testing = std.testing;

fn orderInt(a: isize, b: isize) std.math.Order {
    return std.math.order(a, b);
}

fn copyBytes(gpa: std.mem.Allocator, value: []const u8) ![]const u8 {
    return try gpa.dupe(u8, value);
}

fn releaseBytes(gpa: std.mem.Allocator, value: []const u8) void {
    gpa.free(value);
}

const Pair = struct {
    key: isize,
    value: isize,
};

const CollectContext = struct {
    items: [1200]Pair = undefined,
    len: usize = 0,
};

fn collectPair(ctx: *CollectContext, key: isize, value: isize) !void {
    ctx.items[ctx.len] = .{ .key = key, .value = value };
    ctx.len += 1;
}

fn expectRemovedCount(expected: usize, result: anytype) !void {
    defer result.deinit(testing.allocator);
    try testing.expectEqual(expected, result.removed_count);
}

fn expectIndexOf(index: usize, found: bool, result: anytype) !void {
    try testing.expectEqual(index, result.index);
    try testing.expectEqual(found, result.found);
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

const VerifyAscendingContext = struct {
    next: usize,
    end: usize,
    seen: usize = 0,
    limit: usize = std.math.maxInt(usize),
};

fn verifyAscending(ctx: *VerifyAscendingContext, key: isize, value: isize) !bool {
    const expected: isize = @intCast(ctx.next);
    try testing.expectEqual(expected, key);
    try testing.expectEqual(expected * 10, value);
    ctx.next += 1;
    ctx.seen += 1;
    return ctx.seen < ctx.limit and ctx.next < ctx.end;
}

const FailAscendingContext = struct {
    next: usize,
    seen: usize = 0,
    fail_after: usize,
};

fn failAscending(ctx: *FailAscendingContext, key: isize, value: isize) !bool {
    if (ctx.seen == ctx.fail_after) return error.StopTraversal;
    const expected: isize = @intCast(ctx.next);
    try testing.expectEqual(expected, key);
    try testing.expectEqual(expected * 10, value);
    ctx.next += 1;
    ctx.seen += 1;
    return true;
}

const VerifyDescendingContext = struct {
    next: usize,
    seen: usize = 0,
    limit: usize = std.math.maxInt(usize),
};

fn verifyDescending(ctx: *VerifyDescendingContext, key: isize, value: isize) !bool {
    const expected: isize = @intCast(ctx.next);
    try testing.expectEqual(expected, key);
    try testing.expectEqual(expected * 10, value);
    ctx.seen += 1;
    if (ctx.next == 0) return false;
    ctx.next -= 1;
    return ctx.seen < ctx.limit;
}

const FailDescendingContext = struct {
    next: usize,
    seen: usize = 0,
    fail_after: usize,
};

fn failDescending(ctx: *FailDescendingContext, key: isize, value: isize) !bool {
    if (ctx.seen == ctx.fail_after) return error.StopTraversal;
    const expected: isize = @intCast(ctx.next);
    try testing.expectEqual(expected, key);
    try testing.expectEqual(expected * 10, value);
    ctx.next -= 1;
    ctx.seen += 1;
    return true;
}

fn rejectKeyOne(key: isize, value: isize) bool {
    std.debug.assert(key == 1);
    std.debug.assert(value == -1);
    return false;
}

fn acceptKeyOne(key: isize, value: isize) bool {
    std.debug.assert(key == 1);
    std.debug.assert(value == -1);
    return true;
}

fn rejectKeyNinetyEight(key: isize, value: isize) bool {
    std.debug.assert(key == 98);
    std.debug.assert(value == -98);
    return false;
}

fn acceptKeyNinetyEight(key: isize, value: isize) bool {
    std.debug.assert(key == 98);
    std.debug.assert(value == -98);
    return true;
}

fn addKeyToValue(_: void, key: isize, value: *isize) !void {
    value.* += key;
}

fn subtractKeyFromValue(_: void, key: isize, value: *isize) !void {
    value.* -= key;
}

fn fillPermutation(comptime N: usize, seed: u64) [N]isize {
    var keys: [N]isize = undefined;
    for (&keys, 0..) |*key, i| key.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle(isize, &keys);
    return keys;
}

test "ordered-key btree ignores values for identity" {
    const OrderedTree = btree.Tree(isize, isize, .{});
    var tree = OrderedTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insertKey(testing.allocator, 10, 100));
    try testing.expect(!try tree.insertKey(testing.allocator, 10, 200));
    try testing.expectEqual(@as(usize, 1), tree.len);
    try testing.expectEqual(@as(?isize, 100), tree.getKey(10));

    try testing.expectEqual(@as(?isize, 100), try tree.setKey(testing.allocator, 10, 200));
    try testing.expectEqual(@as(?isize, 200), tree.getKey(10));
    try testing.expectEqual(@as(?isize, null), try tree.setKey(testing.allocator, 20, 300));
    try testing.expectEqual(@as(usize, 2), tree.len);

    try testing.expectEqual(@as(?isize, 200), try tree.replaceKey(testing.allocator, 10, 111));
    try testing.expectEqual(@as(?isize, null), try tree.replaceKey(testing.allocator, 30, 333));
    try testing.expectEqual(@as(?isize, 111), tree.getKey(10));

    try testing.expectEqual(@as(?isize, 111), try tree.deleteKey(testing.allocator, 10));
    try testing.expectEqual(@as(?isize, null), tree.getKey(10));
    try testing.expectEqual(@as(usize, 1), tree.len);
    try tree.checkInvariants();
}

test "ordered-key btree supports ordered access and key-bounded range deletion" {
    const OrderedTree = btree.Tree(isize, isize, .{});
    var tree = OrderedTree.init();
    defer tree.deinit(testing.allocator);

    for ([_]isize{ 5, 1, 3, 2, 4, 0, 6 }) |key| {
        try testing.expect(try tree.insertKey(testing.allocator, key, key * 10));
    }

    try testing.expectEqual(@as(isize, 0), tree.front().?.key);
    try testing.expectEqual(@as(isize, 6), tree.back().?.key);
    try expectIndexOf(3, true, tree.indexOfKey(3));
    try testing.expectEqual(@as(isize, 4), tree.seekKey(4).?.key);
    try testing.expectEqual(@as(isize, 4), tree.seekNextKey(3).?.key);
    try testing.expectEqual(@as(isize, 2), tree.seekPrevKey(3).?.key);
    try testing.expectEqual(@as(isize, 3), tree.getAt(3).?.key);

    const removed = try tree.deleteRangeKey(testing.allocator, 2, 5, .{ .max_inclusive = true });
    defer removed.deinit(testing.allocator);

    var removed_items = CollectContext{};
    try removed.ascent(*CollectContext, &removed_items, collectPair);
    try testing.expectEqual(@as(usize, 4), removed.removed_count);
    try testing.expectEqual(@as(usize, 4), removed_items.len);
    for (removed_items.items[0..removed_items.len], 2..) |item, expected_usize| {
        const expected: isize = @intCast(expected_usize);
        try testing.expectEqual(expected, item.key);
        try testing.expectEqual(expected * 10, item.value);
    }
    try testing.expectEqual(@as(?isize, null), tree.getKey(2));
    try testing.expectEqual(@as(?isize, null), tree.getKey(5));
    try testing.expectEqual(@as(usize, 3), tree.len);
    try tree.checkInvariants();
}

test "ordered-key btree mutable accessors clone copy-on-write paths" {
    const OrderedTree = btree.Tree(isize, isize, .{});
    var original = OrderedTree.init();
    defer original.deinit(testing.allocator);

    for (0..256) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try original.insertKey(testing.allocator, key, key));
    }

    var copied = original.copy();
    defer copied.deinit(testing.allocator);

    (try copied.getKeyMut(testing.allocator, 42)).?.* = -42;
    (try copied.getAtMut(testing.allocator, 100)).?.value.* = -100;
    try copied.ascentMut(testing.allocator, void, {}, addKeyToValue);
    try copied.descentMut(testing.allocator, void, {}, subtractKeyFromValue);

    try testing.expectEqual(@as(?isize, 42), original.getKey(42));
    try testing.expectEqual(@as(?isize, 100), original.getKey(100));
    try testing.expectEqual(@as(?isize, -42), copied.getKey(42));
    try testing.expectEqual(@as(?isize, -100), copied.getKey(100));

    for (0..256) |i| {
        const key: isize = @intCast(i);
        try testing.expectEqual(@as(?isize, key), original.getKey(key));
        if (key != 42 and key != 100) try testing.expectEqual(@as(?isize, key), copied.getKey(key));
    }
    try original.checkInvariants();
    try copied.checkInvariants();
}

test "ordered-key string btree uses prefix routing with key-only APIs" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [2000][16]u8 = undefined;
    const keys = fillPermutation(2000, 0x5eed_1001);
    for (keys, 0..) |permuted, i| {
        const key = try std.fmt.bufPrint(&buffers[i], "{d}", .{permuted});
        try testing.expectEqual(null, tree.getKey(key));
        try testing.expect(try tree.insertKey(testing.allocator, key, @intCast(permuted)));
        try testing.expect(!try tree.insertKey(testing.allocator, key, 999_999));
        try testing.expectEqual(@as(usize, @intCast(permuted)), tree.getKey(key));
        if (i % 301 == 0) try tree.checkInvariants();
    }

    try testing.expectEqual(@as(usize, 2000), tree.len);
    try testing.expect(tree.seekKey("1000") != null);
    try tree.checkInvariants();
}

test "a tree without an order sorts string keys by their bytes and keeps prefixes" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    try testing.expect(@FieldType(StringTree.Branch, "prefixes") != void);
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [500][8]u8 = undefined;
    for (fillPermutation(500, 0x5eed_2001), &buffers) |permuted, *buffer| {
        const n: usize = @intCast(permuted);
        const key = try std.fmt.bufPrint(buffer, "{d:0>4}", .{n});
        try testing.expect(try tree.insertKey(testing.allocator, key, n));
    }
    for (0..500) |n| {
        var buffer: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "{d:0>4}", .{n});
        try testing.expectEqual(@as(?usize, n), tree.getKey(key));
        try expectIndexOf(n, true, tree.indexOfKey(key));
    }
    try tree.checkInvariants();
}

fn orderIgnoreCase(a: []const u8, b: []const u8) std.math.Order {
    return std.ascii.orderIgnoreCase(a, b);
}

test "a custom key order works with the key-only methods" {
    const CaseTree = btree.Tree([]const u8, usize, .{ .order = .{ .compare = orderIgnoreCase } });
    // Byte prefixes can't route case-insensitive keys, so they stay off.
    try testing.expect(@FieldType(CaseTree.Branch, "prefixes") == void);
    var tree = CaseTree.init();
    defer tree.deinit(testing.allocator);

    // Every other key starts with a capital, so that the order differs from
    // byte order, which puts every "K" before every "k".
    var stored: [500][8]u8 = undefined;
    for (fillPermutation(500, 0x5eed_2002)) |permuted| {
        const n: usize = @intCast(permuted);
        const key = try std.fmt.bufPrint(&stored[n], "{s}{d:0>4}", .{ if (n % 2 == 0) "k" else "K", n });
        try testing.expect(try tree.insertKey(testing.allocator, key, n));
    }
    try testing.expectEqual(@as(usize, 500), tree.len);

    // Lookups with the other case find the same items.
    for (0..500) |n| {
        var buffer: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "{s}{d:0>4}", .{ if (n % 2 == 0) "K" else "k", n });
        try testing.expectEqual(@as(?usize, n), tree.getKey(key));
        try expectIndexOf(n, true, tree.indexOfKey(key));
        try testing.expectEqual(@as(usize, n), tree.seekKey(key).?.value);
        try testing.expect(!try tree.insertKey(testing.allocator, key, 999));
    }
    try testing.expectEqual(@as(usize, 7), tree.seekNextKey("K0006").?.value);
    try testing.expectEqual(@as(usize, 5), tree.seekPrevKey("K0006").?.value);

    try testing.expectEqual(@as(?usize, 7), try tree.setKey(testing.allocator, "k0007", 70));
    try testing.expectEqual(@as(?usize, 70), tree.getKey("K0007"));
    try testing.expectEqual(@as(?usize, 8), try tree.deleteKey(testing.allocator, "K0008"));
    try testing.expectEqual(@as(?usize, null), tree.getKey("k0008"));

    const removed = try tree.deleteRangeKey(testing.allocator, "K0100", "k0200", .{});
    defer removed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 100), removed.len());
    try testing.expectEqual(@as(usize, 399), tree.len);
    try tree.checkInvariants();
}

fn orderDescending(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, b, a);
}

test "a string order that isn't byte order works without a prefix" {
    const DescendingTree = btree.Tree([]const u8, usize, .{ .order = .{ .compare = orderDescending } });
    var tree = DescendingTree.init();
    defer tree.deinit(testing.allocator);

    var stored: [500][8]u8 = undefined;
    for (fillPermutation(500, 0x5eed_2003)) |permuted| {
        const n: usize = @intCast(permuted);
        const key = try std.fmt.bufPrint(&stored[n], "{d:0>4}", .{n});
        try testing.expect(try tree.insert(testing.allocator, key, n));
    }
    for (&stored, 0..) |*buffer, n| {
        try testing.expectEqual(@as(?usize, n), tree.get(buffer[0..4], 0));
        try expectIndexOf(499 - n, true, tree.indexOf(buffer[0..4], 0));
    }
    try tree.checkInvariants();
}

/// The first 8 bytes lowercased, so that it never puts two keys in the
/// opposite order from `orderIgnoreCase`.
fn lowerPrefix(key: []const u8) u64 {
    var bytes: [8]u8 = @splat(0);
    for (bytes[0..@min(bytes.len, key.len)], key[0..@min(bytes.len, key.len)]) |*byte, c| byte.* = std.ascii.toLower(c);
    return std.mem.readInt(u64, &bytes, .big);
}

test "a custom prefix keeps prefixes for a case-insensitive order" {
    const CaseTree = btree.Tree([]const u8, usize, .{ .order = .{ .compare = orderIgnoreCase, .prefix = lowerPrefix } });
    try testing.expect(@FieldType(CaseTree.Branch, "prefixes") != void);
    var tree = CaseTree.init();
    defer tree.deinit(testing.allocator);

    // Keys share their first 8 bytes in groups of ten, so that prefixes
    // both decide comparisons and tie.
    var stored: [500][12]u8 = undefined;
    for (fillPermutation(500, 0x5eed_2004)) |permuted| {
        const n: usize = @intCast(permuted);
        const key = try std.fmt.bufPrint(&stored[n], "{s}key{d:0>4}", .{ if (n % 2 == 0) "abcd" else "ABCD", n });
        try testing.expect(try tree.insertKey(testing.allocator, key, n));
    }
    for (0..500) |n| {
        var buffer: [12]u8 = undefined;
        const key = try std.fmt.bufPrint(&buffer, "{s}KEY{d:0>4}", .{ if (n % 2 == 0) "ABCD" else "abcd", n });
        try testing.expectEqual(@as(?usize, n), tree.getKey(key));
        try expectIndexOf(n, true, tree.indexOfKey(key));
    }
    try tree.checkInvariants();
}

fn descendingPrefix(key: []const u8) u64 {
    return ~btree.bytePrefix(key);
}

test "a custom prefix keeps prefixes for a descending order" {
    const DescendingTree = btree.Tree([]const u8, usize, .{ .order = .{ .compare = orderDescending, .prefix = descendingPrefix } });
    try testing.expect(@FieldType(DescendingTree.Branch, "prefixes") != void);
    var tree = DescendingTree.init();
    defer tree.deinit(testing.allocator);

    var stored: [500][8]u8 = undefined;
    for (fillPermutation(500, 0x5eed_2005)) |permuted| {
        const n: usize = @intCast(permuted);
        const key = try std.fmt.bufPrint(&stored[n], "{d:0>4}", .{n});
        try testing.expect(try tree.insert(testing.allocator, key, n));
    }
    for (&stored, 0..) |*buffer, n| {
        try testing.expectEqual(@as(?usize, n), tree.get(buffer[0..4], 0));
        try expectIndexOf(499 - n, true, tree.indexOf(buffer[0..4], 0));
    }
    try tree.checkInvariants();
}

const Point = struct { x: u32, y: u32 };

fn orderPoint(a: Point, b: Point) std.math.Order {
    return if (a.x != b.x) std.math.order(a.x, b.x) else std.math.order(a.y, b.y);
}

fn pointPrefix(point: Point) u64 {
    return point.x;
}

test "a prefix routes keys that aren't strings" {
    const PointTree = btree.Tree(Point, usize, .{ .order = .{ .compare = orderPoint, .prefix = pointPrefix } });
    try testing.expect(@FieldType(PointTree.Branch, "prefixes") != void);
    var tree = PointTree.init();
    defer tree.deinit(testing.allocator);

    // Ten points share each x, so that prefixes both decide comparisons and
    // tie.
    for (fillPermutation(500, 0x5eed_2006)) |permuted| {
        const n: usize = @intCast(permuted);
        try testing.expect(try tree.insertKey(testing.allocator, .{ .x = @intCast(n / 10), .y = @intCast(n % 10) }, n));
    }
    for (0..500) |n| {
        const point: Point = .{ .x = @intCast(n / 10), .y = @intCast(n % 10) };
        try testing.expectEqual(@as(?usize, n), tree.getKey(point));
        try expectIndexOf(n, true, tree.indexOfKey(point));
    }
    try tree.checkInvariants();
}

fn orderUsize(a: usize, b: usize) std.math.Order {
    return std.math.order(a, b);
}

test "a value order on string keys keeps prefixes and keeps equal keys apart" {
    const MultiTree = btree.Tree([]const u8, usize, .{ .value_order = orderUsize });
    try testing.expect(@FieldType(MultiTree.Branch, "prefixes") != void);
    var tree = MultiTree.init();
    defer tree.deinit(testing.allocator);

    // Four values per key, so that internal nodes hold keys whose prefixes
    // tie with the key a search asks for.
    var stored: [125][4]u8 = undefined;
    for (&stored, 0..) |*buffer, i| _ = try std.fmt.bufPrint(buffer, "{d:0>4}", .{i});
    for (fillPermutation(500, 0x5eed_2007)) |permuted| {
        const n: usize = @intCast(permuted);
        try testing.expect(try tree.insert(testing.allocator, &stored[n / 4], n % 4));
    }
    try testing.expectEqual(@as(usize, 500), tree.len);

    for (0..500) |n| {
        const key: []const u8 = &stored[n / 4];
        try testing.expectEqual(@as(?usize, n % 4), tree.get(key, n % 4));
        try expectIndexOf(n, true, tree.indexOf(key, n % 4));
        try testing.expect(!try tree.insert(testing.allocator, key, n % 4));
    }
    try testing.expectEqual(@as(?usize, null), tree.get("0007", 4));
    try tree.checkInvariants();
}

test "empty btree has expected constants" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    const tree = IntTree.init();

    try testing.expectEqual(64, IntTree.fanout);
    try testing.expectEqual(63, IntTree.max_items);
    try testing.expectEqual(31, IntTree.min_items);
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
}

test "string btree routes by prefixes" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [80][7]u8 = undefined;
    var keys: [80][]const u8 = undefined;
    for (&buffers, 0..) |*buffer, i| {
        buffer.* = .{ 'k', 'e', 'y', '-', @intCast('0' + i / 100), @intCast('0' + i / 10 % 10), @intCast('0' + i % 10) };
        keys[i] = buffer[0..];
        try testing.expect(try tree.insert(testing.allocator, keys[i], i));
    }

    try testing.expectEqual(keys.len, tree.len);
    try testing.expectEqual(42, tree.get("key-042", 0).?);
    try testing.expectEqualStrings("key-079", tree.back().?.key);
    try tree.checkInvariants();
}

fn fillKey(buffer: []u8, prefix: []const u8, i: usize) []const u8 {
    std.mem.copyForwards(u8, buffer[0..prefix.len], prefix);
    buffer[prefix.len] = '-';
    buffer[prefix.len + 1] = @intCast('0' + i / 100);
    buffer[prefix.len + 2] = @intCast('0' + i / 10 % 10);
    buffer[prefix.len + 3] = @intCast('0' + i % 10);
    return buffer[0 .. prefix.len + 4];
}

fn insertStringKeys(comptime count: usize, tree: anytype, buffers: *[count][12]u8, prefix: []const u8) !void {
    for (buffers, 0..) |*buffer, i| {
        try testing.expect(try tree.insert(testing.allocator, fillKey(buffer[0..], prefix, i), i));
    }
}

test "string prefixes route searches across split root" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [80][12]u8 = undefined;
    try insertStringKeys(80, &tree, &buffers, "key");

    try testing.expectEqual(0, tree.get("key-000", 0).?);
    try testing.expectEqual(30, tree.get("key-030", 0).?);
    try testing.expectEqual(31, tree.get("key-031", 0).?);
    try testing.expectEqual(32, tree.get("key-032", 0).?);
    try testing.expectEqual(79, tree.get("key-079", 0).?);
    try expectIndexOf(15, true, tree.indexOf("key-015", 0));
    try testing.expectEqualStrings("key-016", tree.seekNext("key-015", 0).?.key);
    try tree.checkInvariants();
}

test "string prefix search falls back to full key on prefix collision" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [90][12]u8 = undefined;
    try insertStringKeys(90, &tree, &buffers, "abcdefgh");

    try testing.expectEqual(0, tree.get("abcdefgh-000", 0).?);
    try testing.expectEqual(44, tree.get("abcdefgh-044", 0).?);
    try testing.expectEqual(89, tree.get("abcdefgh-089", 0).?);
    try testing.expectEqualStrings("abcdefgh-045", tree.seek("abcdefgh-045", 0).?.key);
    try testing.expect(tree.get("abcdefgh-999", 0) == null);
    try tree.checkInvariants();
}

test "binary string search works with prefix routing and collisions" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [128][12]u8 = undefined;
    try insertStringKeys(128, &tree, &buffers, "abcdefgh");

    try testing.expectEqual(0, tree.get("abcdefgh-000", 0).?);
    try testing.expectEqual(31, tree.get("abcdefgh-031", 0).?);
    try testing.expectEqual(32, tree.get("abcdefgh-032", 0).?);
    try testing.expectEqual(127, tree.get("abcdefgh-127", 0).?);
    try testing.expectEqualStrings("abcdefgh-064", tree.seek("abcdefgh-064", 0).?.key);
    try testing.expectEqualStrings("abcdefgh-065", tree.seekNext("abcdefgh-064", 0).?.key);
    try testing.expectEqualStrings("abcdefgh-063", tree.seekPrev("abcdefgh-064", 0).?.key);
    try expectIndexOf(64, true, tree.indexOf("abcdefgh-064", 0));
    try testing.expect(tree.get("abcdefgh-999", 0) == null);
    try tree.checkInvariants();
}

test "string prefixes survive copy on write cloning" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var original = StringTree.init();
    defer original.deinit(testing.allocator);

    var buffers: [81][12]u8 = undefined;
    try insertStringKeys(80, &original, buffers[0..80], "key");

    var snapshot = original.copy();
    defer snapshot.deinit(testing.allocator);

    try testing.expect(try snapshot.insert(testing.allocator, fillKey(buffers[80][0..], "key", 80), 80));

    try testing.expectEqual(0, snapshot.get("key-000", 0).?);
    try testing.expectEqual(79, original.get("key-079", 0).?);
    try testing.expect(original.get("key-080", 0) == null);
    try snapshot.checkInvariants();
    try original.checkInvariants();
}

test "append-only inserts preserve indexes after repeated right-edge splits" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..2000) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
        if (i % 127 == 0) try tree.checkInvariants();
    }

    try testing.expectEqual(2000, tree.len);
    try testing.expectEqual(0, tree.front().?.key);
    try testing.expectEqual(1999, tree.back().?.key);
    for (0..2000) |i| {
        const key: isize = @intCast(i);
        const entry = tree.getAt(i).?;
        try testing.expectEqual(key, entry.key);
        try testing.expectEqual(-key, entry.value);
        try expectIndexOf(i, true, tree.indexOf(key, 0));
    }
    try tree.checkInvariants();
}

test "append-only string inserts preserve prefix routing after splits" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [256][12]u8 = undefined;
    try insertStringKeys(256, &tree, &buffers, "key");

    try testing.expectEqual(256, tree.len);
    try testing.expectEqualStrings("key-000", tree.front().?.key);
    try testing.expectEqualStrings("key-255", tree.back().?.key);
    for (0..256) |i| {
        var expected_buffer: [12]u8 = undefined;
        const expected = fillKey(expected_buffer[0..], "key", i);
        try testing.expectEqualStrings(expected, tree.getAt(i).?.key);
        try expectIndexOf(i, true, tree.indexOf(expected, 0));
        try testing.expectEqual(i, tree.get(expected, 0).?);
    }
    try tree.checkInvariants();
}

test "right-edge duplicate insert is rejected after splits" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..80) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    try testing.expect(!try tree.insert(testing.allocator, 79, 7900));
    try testing.expectEqual(80, tree.len);
    try testing.expectEqual(790, tree.get(79, 0).?);
    try testing.expectEqual(79, tree.back().?.key);
    try tree.checkInvariants();
}

test "insert rejects duplicate keys" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insert(testing.allocator, 42, 100));
    try testing.expect(!try tree.insert(testing.allocator, 42, 200));

    try testing.expectEqual(1, tree.len);
    try testing.expectEqual(100, tree.get(42, 0).?);
}

test "a value order keeps items with equal keys apart" {
    const MultiTree = btree.Tree(isize, isize, .{ .value_order = orderInt });
    var tree = MultiTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    try testing.expect(try tree.insert(testing.allocator, 10, 200));
    try testing.expect(!try tree.insert(testing.allocator, 10, 200));

    try testing.expectEqual(2, tree.len);
    try testing.expectEqual(100, tree.getAt(0).?.value);
    try testing.expectEqual(200, tree.getAt(1).?.value);
    try expectIndexOf(1, true, tree.indexOf(10, 200));
    try tree.checkInvariants();
}

test "replace updates existing value without inserting" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.replace(testing.allocator, 42, 420) == null);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    try testing.expect(try tree.insert(testing.allocator, 20, 200));

    try testing.expectEqual(100, (try tree.replace(testing.allocator, 10, 111)).?);
    try testing.expectEqual(2, tree.len);
    try testing.expectEqual(111, tree.get(10, 0).?);
    try testing.expectEqual(200, tree.get(20, 0).?);

    try testing.expect(try tree.replace(testing.allocator, 30, 300) == null);
    try testing.expectEqual(2, tree.len);
    try tree.checkInvariants();
}

test "set inserts missing keys and replaces existing values" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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

test "copy-on-write replace does not mutate original" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var original = IntTree.init();
    defer original.deinit(testing.allocator);

    for (0..200) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, key * 10));
    }

    var copy = original.copy();
    defer copy.deinit(testing.allocator);

    try testing.expectEqual(100, (try copy.replace(testing.allocator, 10, 111)).?);
    try testing.expectEqual(100, original.get(10, 0).?);
    try testing.expectEqual(111, copy.get(10, 0).?);
    try original.checkInvariants();
    try copy.checkInvariants();
}

test "copy-on-write set existing key does not mutate original" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var original = IntTree.init();
    defer original.deinit(testing.allocator);

    for (0..200) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, key * 10));
    }

    var copy = original.copy();
    defer copy.deinit(testing.allocator);

    try testing.expectEqual(100, (try copy.set(testing.allocator, 10, 111)).?);
    try testing.expectEqual(100, original.get(10, 0).?);
    try testing.expectEqual(111, copy.get(10, 0).?);
    try testing.expectEqual(200, original.len);
    try testing.expectEqual(200, copy.len);
    try original.checkInvariants();
    try copy.checkInvariants();
}

test "set replaces values after node splits without changing counts" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
        try expectIndexOf(i, true, tree.indexOf(key, 0));
    }
    try tree.checkInvariants();
}

test "delete returns null for empty and missing keys" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
        try expectIndexOf(index, true, tree.indexOf(key, 0));
        index += 1;
    }
    try testing.expectEqual(tree.len, index);
    try tree.checkInvariants();
}

test "front and back return null for an empty tree" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(tree.front() == null);
    try testing.expect(tree.back() == null);
    try testing.expect(try tree.popFront(testing.allocator) == null);
    try testing.expect(try tree.popBack(testing.allocator) == null);
}

test "front and back find edge entries after splits" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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

test "conditional edge pops only remove accepted entries" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.popFrontIf(testing.allocator, null) == null);
    try testing.expect(try tree.popBackIf(testing.allocator, null) == null);

    for (0..100) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try testing.expectEqual(0, (try tree.popFrontIf(testing.allocator, null)).?.key);
    try testing.expectEqual(99, (try tree.popBackIf(testing.allocator, null)).?.key);
    try testing.expectEqual(98, tree.len);

    try testing.expect(try tree.popFrontIf(testing.allocator, &rejectKeyOne) == null);
    try testing.expectEqual(98, tree.len);
    try testing.expectEqual(1, tree.front().?.key);
    try testing.expectEqual(-1, tree.front().?.value);

    const front = (try tree.popFrontIf(testing.allocator, &acceptKeyOne)).?;
    try testing.expectEqual(1, front.key);
    try testing.expectEqual(-1, front.value);
    try testing.expectEqual(97, tree.len);
    try testing.expectEqual(2, tree.front().?.key);

    try testing.expect(try tree.popBackIf(testing.allocator, &rejectKeyNinetyEight) == null);
    try testing.expectEqual(97, tree.len);
    try testing.expectEqual(98, tree.back().?.key);
    try testing.expectEqual(-98, tree.back().?.value);

    const back = (try tree.popBackIf(testing.allocator, &acceptKeyNinetyEight)).?;
    try testing.expectEqual(98, back.key);
    try testing.expectEqual(-98, back.value);
    try testing.expectEqual(96, tree.len);
    try testing.expectEqual(97, tree.back().?.key);
    try tree.checkInvariants();
}

test "insertAt inserts only when the item fits at the index" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
        try expectIndexOf(index, true, tree.indexOf(key, 0));
    }
    try tree.checkInvariants();
}

test "replaceAt replaces only when the new item fits" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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

test "deleteRangeAt removes bounded index ranges" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..120) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try expectRemovedCount(0, try tree.deleteRangeAt(testing.allocator, 10, 0, .{}));
    try expectRemovedCount(0, try tree.deleteRangeAt(testing.allocator, 120, 5, .{}));
    try expectRemovedCount(10, try tree.deleteRangeAt(testing.allocator, 20, 10, .{}));
    try testing.expectEqual(110, tree.len);
    try testing.expectEqual(19, tree.getAt(19).?.key);
    try testing.expectEqual(30, tree.getAt(20).?.key);
    for (20..30) |i| {
        const key: isize = @intCast(i);
        try testing.expect(tree.get(key, 0) == null);
    }

    try expectRemovedCount(5, try tree.deleteRangeAt(testing.allocator, 105, 50, .{}));
    try testing.expectEqual(105, tree.len);
    try testing.expectEqual(114, tree.back().?.key);
    try tree.checkInvariants();
}

test "deleteRangeAt returns removed entries in sorted order" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..20) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const result = try tree.deleteRangeAt(testing.allocator, 5, 7, .{});
    defer result.deinit(testing.allocator);

    var removed_items = CollectContext{};
    try result.ascent(*CollectContext, &removed_items, collectPair);

    try testing.expectEqual(7, result.removed_count);
    try testing.expectEqual(7, removed_items.len);
    for (removed_items.items[0..removed_items.len], 5..) |item, expected| {
        const key: isize = @intCast(expected);
        try testing.expectEqual(key, item.key);
        try testing.expectEqual(-key, item.value);
    }
    try testing.expectEqual(13, tree.len);
    try testing.expectEqual(4, tree.getAt(4).?.key);
    try testing.expectEqual(12, tree.getAt(5).?.key);
    try tree.checkInvariants();
}

test "deleteRangeAt always returns removed entries" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..12) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    const result = try tree.deleteRangeAt(testing.allocator, 3, 5, .{});
    defer result.deinit(testing.allocator);

    var removed_items = CollectContext{};
    try result.ascent(*CollectContext, &removed_items, collectPair);

    try testing.expectEqual(5, result.removed_count);
    try testing.expectEqual(5, removed_items.len);
    try testing.expectEqual(3, removed_items.items[0].key);
    try testing.expectEqual(7, removed_items.items[4].key);
    try testing.expectEqual(7, tree.len);
    try testing.expectEqual(2, tree.getAt(2).?.key);
    try testing.expectEqual(8, tree.getAt(3).?.key);
    try tree.checkInvariants();
}

test "deleteRange groups boundary entries into result chunks" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..2000) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const result = try tree.deleteRangeAt(testing.allocator, 500, 1000, .{});
    defer result.deinit(testing.allocator);

    var removed_items = CollectContext{};
    try result.ascent(*CollectContext, &removed_items, collectPair);

    try testing.expectEqual(1000, result.removed_count);
    try testing.expect(result.chunk_count < result.removed_count);
    try testing.expectEqual(1000, removed_items.len);
    for (0..1000) |i| {
        const expected: isize = @intCast(500 + i);
        try testing.expectEqual(expected, removed_items.items[i].key);
        try testing.expectEqual(-expected, removed_items.items[i].value);
    }
    try testing.expectEqual(1000, tree.len);
    try tree.checkInvariants();
}

test "deleteRangeAt rebalances underfull child after zero-progress range step" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..500_000) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    const result = try tree.deleteRangeAt(testing.allocator, 225_000, 50_000, .{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(50_000, result.removed_count);
    try testing.expectEqual(450_000, tree.len);
    try testing.expectEqual(224_999, tree.getAt(224_999).?.key);
    try testing.expectEqual(275_000, tree.getAt(225_000).?.key);
    try tree.checkInvariants();
}

test "deleteRange result owns removed values" {
    const ByteTree = btree.Tree(isize, []const u8, .{
        .order = .{ .compare = orderInt },
        .copy_value = copyBytes,
        .release_value = releaseBytes,
    });
    var tree = ByteTree.init();
    defer tree.deinit(testing.allocator);

    for (0..8) |i| {
        const key: isize = @intCast(i);
        const value = try std.fmt.allocPrint(testing.allocator, "value-{d}", .{i});
        try testing.expect(try tree.insert(testing.allocator, key, value));
    }

    const result = try tree.deleteRange(testing.allocator, 2, "", 5, "", .{ .max_inclusive = true });
    defer result.deinit(testing.allocator);

    const ByteContext = struct {
        seen: usize = 0,

        fn verify(ctx: *@This(), key: isize, value: []const u8) !void {
            const expected_key: isize = @intCast(ctx.seen + 2);
            var buffer: [16]u8 = undefined;
            const expected_value = try std.fmt.bufPrint(&buffer, "value-{d}", .{expected_key});
            try testing.expectEqual(expected_key, key);
            try testing.expectEqualStrings(expected_value, value);
            ctx.seen += 1;
        }
    };
    var byte_context = ByteContext{};
    try result.ascent(*ByteContext, &byte_context, ByteContext.verify);

    try testing.expectEqual(4, result.removed_count);
    try testing.expectEqual(4, byte_context.seen);
    try testing.expectEqual(4, tree.len);
    try testing.expect(tree.get(2, "") == null);
    try testing.expectEqualStrings("value-6", tree.get(6, "").?);
    try tree.checkInvariants();
}

test "delete releases each owned value once when merging nodes" {
    const ByteTree = btree.Tree(isize, []const u8, .{
        .order = .{ .compare = orderInt },
        .release_value = releaseBytes,
    });
    var tree = ByteTree.init();
    defer tree.deinit(testing.allocator);

    for (0..200) |i| {
        try testing.expect(try tree.insert(testing.allocator, @intCast(i), try testing.allocator.dupe(u8, "value")));
    }
    for (0..150) |i| {
        testing.allocator.free((try tree.delete(testing.allocator, @intCast(i), "")).?);
    }
    try tree.checkInvariants();
}

test "deleteRange removes key-bounded ranges" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try expectRemovedCount(0, try tree.deleteRange(testing.allocator, 20, 0, 30, 0, .{}));

    for (0..120) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try expectRemovedCount(10, try tree.deleteRange(testing.allocator, 20, 0, 30, 0, .{}));
    try testing.expectEqual(110, tree.len);
    try testing.expectEqual(19, tree.getAt(19).?.key);
    try testing.expectEqual(30, tree.getAt(20).?.key);
    for (20..30) |i| {
        const key: isize = @intCast(i);
        try testing.expect(tree.get(key, 0) == null);
    }

    try expectRemovedCount(10, try tree.deleteRange(testing.allocator, 40, 0, 50, 0, .{ .min_exclusive = true, .max_inclusive = true }));
    try testing.expectEqual(100, tree.len);
    try testing.expectEqual(-40, tree.get(40, 0).?);
    try testing.expectEqual(-51, tree.get(51, 0).?);
    for (41..51) |i| {
        const key: isize = @intCast(i);
        try testing.expect(tree.get(key, 0) == null);
    }

    try expectRemovedCount(0, try tree.deleteRange(testing.allocator, 90, 0, 80, 0, .{}));
    try expectRemovedCount(0, try tree.deleteRange(testing.allocator, 200, 0, 300, 0, .{ .max_inclusive = true }));
    try testing.expectEqual(100, tree.len);
    try tree.checkInvariants();
}

test "deleteRange uses lower bounds for missing endpoints" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..100) |i| {
        const key: isize = @intCast(i * 2);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try expectRemovedCount(5, try tree.deleteRange(testing.allocator, 15, 0, 25, 0, .{ .min_exclusive = true, .max_inclusive = true }));
    for ([_]isize{ 16, 18, 20, 22, 24 }) |key| {
        try testing.expect(tree.get(key, 0) == null);
    }
    try testing.expectEqual(-14, tree.get(14, 0).?);
    try testing.expectEqual(-26, tree.get(26, 0).?);

    try expectRemovedCount(3, try tree.deleteRange(testing.allocator, -5, 0, 5, 0, .{ .max_inclusive = true }));
    for ([_]isize{ 0, 2, 4 }) |key| {
        try testing.expect(tree.get(key, 0) == null);
    }
    try testing.expectEqual(-6, tree.get(6, 0).?);

    try expectRemovedCount(2, try tree.deleteRange(testing.allocator, 195, 0, 250, 0, .{}));
    try testing.expect(tree.get(196, 0) == null);
    try testing.expect(tree.get(198, 0) == null);
    try testing.expectEqual(90, tree.len);
    try tree.checkInvariants();
}

test "deleteRange honors value tie breakers" {
    const MultiTree = btree.Tree(isize, isize, .{ .value_order = orderInt });
    var tree = MultiTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insert(testing.allocator, 9, 90));
    for (0..10) |i| {
        const value: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, 10, value));
    }
    try testing.expect(try tree.insert(testing.allocator, 11, 110));

    try expectRemovedCount(5, try tree.deleteRange(testing.allocator, 10, 2, 10, 7, .{}));
    for ([_]isize{ 2, 3, 4, 5, 6 }) |value| {
        try testing.expect(!tree.indexOf(10, value).found);
    }
    for ([_]isize{ 0, 1, 7, 8, 9 }, [_]usize{ 1, 2, 3, 4, 5 }) |value, index| {
        try expectIndexOf(index, true, tree.indexOf(10, value));
    }

    try expectRemovedCount(2, try tree.deleteRange(testing.allocator, 10, 7, 10, 8, .{ .max_inclusive = true }));
    try testing.expect(!tree.indexOf(10, 7).found);
    try testing.expect(!tree.indexOf(10, 8).found);
    try testing.expectEqual(5, tree.len);
    try testing.expectEqual(9, tree.front().?.key);
    try testing.expectEqual(11, tree.back().?.key);
    try tree.checkInvariants();
}

test "deleteRange works with string prefix routing" {
    const StringTree = btree.Tree([]const u8, usize, .{});
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var buffers: [128][12]u8 = undefined;
    try insertStringKeys(128, &tree, &buffers, "abcdefgh");

    try expectRemovedCount(66, try tree.deleteRange(testing.allocator, "abcdefgh-031", 0, "abcdefgh-096", 0, .{ .max_inclusive = true }));
    try testing.expectEqual(62, tree.len);
    try testing.expectEqualStrings("abcdefgh-030", tree.getAt(30).?.key);
    try testing.expectEqualStrings("abcdefgh-097", tree.getAt(31).?.key);
    for (31..97) |i| {
        var key_buffer: [12]u8 = undefined;
        const key = fillKey(key_buffer[0..], "abcdefgh", i);
        try testing.expect(tree.get(key, 0) == null);
    }
    try testing.expectEqual(30, tree.get("abcdefgh-030", 0).?);
    try testing.expectEqual(97, tree.get("abcdefgh-097", 0).?);
    try tree.checkInvariants();
}

test "deleteAllAt removes everything from an index" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..50) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try expectRemovedCount(25, try tree.deleteAllAt(testing.allocator, 25, .{}));
    try testing.expectEqual(25, tree.len);
    try testing.expectEqual(0, tree.front().?.key);
    try testing.expectEqual(24, tree.back().?.key);
    try expectRemovedCount(0, try tree.deleteAllAt(testing.allocator, 25, .{}));
    try tree.checkInvariants();
}

test "deleteRangeAt removes all entries after splits" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..2000) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    try expectRemovedCount(2000, try tree.deleteRangeAt(testing.allocator, 0, 2000, .{}));
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
    try tree.checkInvariants();

    try testing.expect(try tree.insert(testing.allocator, 7, 70));
    try testing.expectEqual(70, tree.get(7, 0).?);
}

test "deleteRange clones copy-on-write paths before removing subtrees" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var original = IntTree.init();
    defer original.deinit(testing.allocator);

    for (0..2000) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, -key));
    }

    var copy = original.copy();
    defer copy.deinit(testing.allocator);

    const result = try copy.deleteRange(testing.allocator, 500, 0, 1500, 0, .{});
    defer result.deinit(testing.allocator);

    var removed_items = CollectContext{};
    try result.ascent(*CollectContext, &removed_items, collectPair);

    try testing.expectEqual(1000, result.removed_count);
    try testing.expectEqual(1000, removed_items.len);
    try testing.expectEqual(500, removed_items.items[0].key);
    try testing.expectEqual(1499, removed_items.items[removed_items.len - 1].key);
    try testing.expectEqual(1000, copy.len);
    try testing.expectEqual(2000, original.len);

    for (0..2000) |i| {
        const key: isize = @intCast(i);
        try testing.expectEqual(-key, original.get(key, 0).?);
        if (i >= 500 and i < 1500) {
            try testing.expect(copy.get(key, 0) == null);
        }
    }
    try testing.expectEqual(-499, copy.get(499, 0).?);
    try testing.expectEqual(-1500, copy.get(1500, 0).?);
    try original.checkInvariants();
    try copy.checkInvariants();
}

test "clear removes all entries and permits reuse" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..100) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    tree.clear(testing.allocator);
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
    try tree.checkInvariants();

    try testing.expect(try tree.insert(testing.allocator, 7, 70));
    try testing.expectEqual(1, tree.len);
    try testing.expectEqual(70, tree.get(7, 0).?);
    try tree.checkInvariants();
}

test "copy shares reads and diverges after insert" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var original = IntTree.init();
    defer original.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, -key));
    }

    var copy = original.copy();
    defer copy.deinit(testing.allocator);

    try testing.expectEqual(original.len, copy.len);
    try testing.expectEqual(-42, copy.get(42, 0).?);

    try testing.expect(try copy.insert(testing.allocator, 200, -200));

    try testing.expectEqual(150, original.len);
    try testing.expectEqual(151, copy.len);
    try testing.expect(original.get(200, 0) == null);
    try testing.expectEqual(-200, copy.get(200, 0).?);
    try original.checkInvariants();
    try copy.checkInvariants();
}

test "copy diverges after delete without changing original" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var original = IntTree.init();
    defer original.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, key * 10));
    }

    var copy = original.copy();
    defer copy.deinit(testing.allocator);

    try testing.expectEqual(310, (try copy.delete(testing.allocator, 31, 0)).?);
    try testing.expectEqual(149, copy.len);
    try testing.expect(copy.get(31, 0) == null);

    try testing.expectEqual(150, original.len);
    try testing.expectEqual(310, original.get(31, 0).?);
    try testing.expectEqual(31, original.getAt(31).?.key);
    try original.checkInvariants();
    try copy.checkInvariants();
}

test "clearing one copy leaves the other usable" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var original = IntTree.init();
    defer original.deinit(testing.allocator);

    for (0..100) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try original.insert(testing.allocator, key, -key));
    }

    var copy = original.copy();
    defer copy.deinit(testing.allocator);

    copy.clear(testing.allocator);

    try testing.expectEqual(0, copy.len);
    try testing.expect(copy.root == null);
    try testing.expectEqual(100, original.len);
    try testing.expectEqual(0, original.front().?.key);
    try testing.expectEqual(99, original.back().?.key);
    try original.checkInvariants();
    try copy.checkInvariants();
}

test "insert and get random keys" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    const tree = IntTree.init();

    var seen = CollectContext{};

    try tree.ascent(*CollectContext, &seen, collectPair);

    try testing.expectEqual(0, seen.len);
}

test "ascent yields every item in sorted order" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    const tree = IntTree.init();

    var seen = CollectContext{};

    try tree.descent(*CollectContext, &seen, collectPair);

    try testing.expectEqual(0, seen.len);
}

test "descent yields every item in reverse sorted order" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
        try expectIndexOf(i, true, tree.indexOf(entry.key, entry.value));
    }

    try testing.expect(tree.getAt(8000) == null);
    try expectIndexOf(0, false, tree.indexOf(-2, 0));
    try expectIndexOf(1, false, tree.indexOf(1, 0));
    try expectIndexOf(8000, false, tree.indexOf(16_000, 0));
    try tree.checkInvariants();
}

test "ascendAt and descendAt start at an index and stop when yield returns false" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
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
    try testing.expectEqual(0, out_of_range.len);

    try tree.descendAt(*CollectLimitContext, 100, &out_of_range, collectPairUntilLimit);
    try testing.expectEqual(5, out_of_range.len);
    for (out_of_range.items[0..out_of_range.len], 0..) |pair, i| {
        const key: isize = @intCast(99 - i);
        try testing.expectEqual(key, pair.key);
        try testing.expectEqual(key * 10, pair.value);
    }
}

fn fillSequentialTree(comptime IntTree: type, tree: *IntTree, count: usize) !void {
    for (0..count) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }
}

test "ascendAt starts correctly at every index in a multi-level tree" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try fillSequentialTree(IntTree, &tree, 5000);
    try tree.checkInvariants();

    for (0..tree.len) |index| {
        var ctx = VerifyAscendingContext{ .next = index, .end = tree.len, .limit = 4 };
        try tree.ascendAt(*VerifyAscendingContext, index, &ctx, verifyAscending);
        try testing.expectEqual(@min(@as(usize, 4), tree.len - index), ctx.seen);
    }

    var out_of_range = VerifyAscendingContext{ .next = tree.len, .end = tree.len };
    try tree.ascendAt(*VerifyAscendingContext, tree.len, &out_of_range, verifyAscending);
    try testing.expectEqual(0, out_of_range.seen);
}

test "ascendAt continues across multi-level child boundaries" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try fillSequentialTree(IntTree, &tree, 5000);

    const starts = [_]usize{ 0, 1, 30, 31, 32, 62, 63, 64, 95, 96, 127, 128, 255, 256, 1023, 1024, 2047, 2048, 4095, 4096, 4999 };
    for (starts) |index| {
        var ctx = VerifyAscendingContext{ .next = index, .end = tree.len };
        try tree.ascendAt(*VerifyAscendingContext, index, &ctx, verifyAscending);
        try testing.expectEqual(tree.len - index, ctx.seen);
        try testing.expectEqual(tree.len, ctx.next);
    }
}

test "ascendAt propagates errors after starting inside a multi-level tree" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try fillSequentialTree(IntTree, &tree, 5000);

    var ctx = FailAscendingContext{ .next = 2048, .fail_after = 17 };
    try testing.expectError(error.StopTraversal, tree.ascendAt(*FailAscendingContext, 2048, &ctx, failAscending));
    try testing.expectEqual(17, ctx.seen);
    try testing.expectEqual(2065, ctx.next);
}

test "descendAt starts correctly at every index in a multi-level tree" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try fillSequentialTree(IntTree, &tree, 5000);
    try tree.checkInvariants();

    for (0..tree.len) |index| {
        var ctx = VerifyDescendingContext{ .next = index, .limit = 4 };
        try tree.descendAt(*VerifyDescendingContext, index, &ctx, verifyDescending);
        try testing.expectEqual(@min(@as(usize, 4), index + 1), ctx.seen);
    }

    var out_of_range = VerifyDescendingContext{ .next = tree.len - 1, .limit = 4 };
    try tree.descendAt(*VerifyDescendingContext, tree.len, &out_of_range, verifyDescending);
    try testing.expectEqual(4, out_of_range.seen);
}

test "descendAt continues across multi-level child boundaries" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try fillSequentialTree(IntTree, &tree, 5000);

    const starts = [_]usize{ 0, 1, 30, 31, 32, 62, 63, 64, 95, 96, 127, 128, 255, 256, 1023, 1024, 2047, 2048, 4095, 4096, 4999 };
    for (starts) |index| {
        var ctx = VerifyDescendingContext{ .next = index };
        try tree.descendAt(*VerifyDescendingContext, index, &ctx, verifyDescending);
        try testing.expectEqual(index + 1, ctx.seen);
    }
}

test "descendAt propagates errors after starting inside a multi-level tree" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try fillSequentialTree(IntTree, &tree, 5000);

    var ctx = FailDescendingContext{ .next = 2048, .fail_after = 17 };
    try testing.expectError(error.StopTraversal, tree.descendAt(*FailDescendingContext, 2048, &ctx, failDescending));
    try testing.expectEqual(17, ctx.seen);
    try testing.expectEqual(2031, ctx.next);
}

test "insert keeps every item when splitting the root runs out of memory" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var tree = IntTree.init();
    defer tree.deinit(gpa);

    // Fill the root leaf exactly, so the next insert has to split it.
    for (0..IntTree.max_items) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(gpa, key, key * 10));
    }
    try testing.expect(tree.root.?.isLeaf());

    // The split allocates two nodes: the right half and the new root. Fail the second.
    failing.fail_index = failing.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, tree.insert(gpa, IntTree.max_items, 0));
    failing.fail_index = std.math.maxInt(usize);

    try tree.checkInvariants();
    for (0..IntTree.max_items) |i| {
        const key: isize = @intCast(i);
        try testing.expectEqual(key * 10, tree.get(key, key * 10));
    }
}

fn fillEvenKeys(comptime IntTree: type, tree: *IntTree, gpa: std.mem.Allocator, count: usize) !void {
    for (0..count) |i| {
        const key: isize = @intCast(i * 2);
        try testing.expect(try tree.insert(gpa, key, key * 10));
    }
}

test "copy stays independent when cloning its shared root runs out of memory" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var original = IntTree.init();
    defer original.deinit(gpa);
    try fillEvenKeys(IntTree, &original, gpa, 3000);

    var copy = original.copy();
    defer copy.deinit(gpa);

    // The first allocation of a mutation on the copy clones the shared root.
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, copy.insert(gpa, 1, 10));
    failing.fail_index = std.math.maxInt(usize);

    // The root is still shared, so mutating the original must clone it.
    try testing.expect(try original.insert(gpa, 3, 30));
    const still_shared = copy.root == original.root;
    // Both trees now own the root, but its reference count says only one does.
    // Restore the missing reference so teardown doesn't double free and crash
    // the test run.
    if (still_shared) _ = copy.root.?.rc.fetchAdd(1, .monotonic);

    try testing.expect(!still_shared);
    try testing.expectEqual(null, copy.get(3, 30));
    try testing.expectEqual(3000, copy.len);
    try copy.checkInvariants();
    try original.checkInvariants();
}

test "copy stays independent when cloning a shared child runs out of memory" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    const gpa = failing.allocator();
    var original = IntTree.init();
    defer original.deinit(gpa);
    try fillEvenKeys(IntTree, &original, gpa, 3000);

    var copy = original.copy();
    defer copy.deinit(gpa);

    // Let the root clone succeed, then fail cloning its leftmost child.
    failing.fail_index = failing.alloc_index + 1;
    try testing.expectError(error.OutOfMemory, copy.insert(gpa, 1, 10));
    failing.fail_index = std.math.maxInt(usize);
    try testing.expect(copy.root != original.root);

    // The leftmost child is still shared, so mutating it through the original
    // must clone it.
    try testing.expect(try original.insert(gpa, 3, 30));
    const copy_child = copy.root.?.branch.?.children[0].?;
    const still_shared = copy_child == original.root.?.branch.?.children[0].?;
    // Both trees now own the child, but its reference count says only one
    // does. Restore the missing reference so teardown doesn't free it twice
    // and crash the test run.
    if (still_shared) _ = copy_child.rc.fetchAdd(1, .monotonic);

    try testing.expect(!still_shared);
    try testing.expectEqual(null, copy.get(3, 30));
    try testing.expectEqual(3000, copy.len);
    try copy.checkInvariants();
    try original.checkInvariants();
}

test "deleteRangeAt leaves a valid tree when an allocation fails" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    // Fail the k-th allocation inside deleteRangeAt, for every k until the
    // delete succeeds, and check the tree after each failure.
    var k: usize = 0;
    while (true) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var tree = IntTree.init();
        defer tree.deinit(gpa);
        for (0..5000) |i| {
            const key: isize = @intCast(i);
            try testing.expect(try tree.insert(gpa, key, key * 10));
        }

        failing.fail_index = failing.alloc_index + k;
        const result = tree.deleteRangeAt(gpa, 200, 4_300, .{}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try tree.checkInvariants();
            continue;
        };
        result.deinit(gpa);
        try testing.expect(k > 0);
        break;
    }
}

fn expectCopyRangeDeleteSurvivesFailures(start: usize, count: usize) !void {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    const n = 2000;
    // Fail the k-th allocation inside deleteRangeAt on a copy, for every k
    // until the delete succeeds. Rebalancing on the way back up clones shared
    // siblings, so some of these failures happen after items were removed.
    var k: usize = 0;
    while (true) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var original = IntTree.init();
        defer original.deinit(gpa);
        for (0..n) |i| {
            const key: isize = @intCast(i);
            try testing.expect(try original.insert(gpa, key, key * 10));
        }
        var copy = original.copy();
        defer copy.deinit(gpa);

        failing.fail_index = failing.alloc_index + k;
        const result = copy.deleteRangeAt(gpa, start, count, .{}) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try copy.checkInvariants();
            try original.checkInvariants();
            try testing.expectEqual(n, original.len);
            continue;
        };
        result.deinit(gpa);
        try testing.expectEqual(n - count, copy.len);
        try original.checkInvariants();
        try testing.expectEqual(n, original.len);
        try testing.expect(k > 0);
        return;
    }
}

test "deleteRangeAt on a copy leaves both trees valid when an allocation fails" {
    // Starting at 200, every chunk is detached or removed from a leaf.
    try expectCopyRangeDeleteSurvivesFailures(200, 1700);
    // Starting at 31, a chunk starts at a separator, which is removed through
    // deleteAtFromNode and its own walk down and back up.
    try expectCopyRangeDeleteSurvivesFailures(31, 1500);
}

test "deleteRangeAt clamps a count that would overflow" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);
    for (0..10) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }

    const result = try tree.deleteRangeAt(testing.allocator, 5, std.math.maxInt(usize), .{});
    defer result.deinit(testing.allocator);

    try testing.expectEqual(5, result.removed_count);
    try testing.expectEqual(5, tree.len);
    try tree.checkInvariants();
}

test "deleteRangeByRank handles ranks at the largest index" {
    const IntTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);
    for (0..10) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, key * 10));
    }
    const last: IntTree.RankResult = .{ .index = std.math.maxInt(usize), .found = true };

    const to_end = try tree.deleteRangeByRank(testing.allocator, .{ .index = 2, .found = true }, last, .{ .max_inclusive = true });
    defer to_end.deinit(testing.allocator);
    try testing.expectEqual(8, to_end.removed_count);
    try testing.expectEqual(2, tree.len);

    const reversed = try tree.deleteRangeByRank(testing.allocator, last, .{ .index = 1, .found = false }, .{ .min_exclusive = true });
    defer reversed.deinit(testing.allocator);
    try testing.expectEqual(0, reversed.removed_count);
    try testing.expectEqual(2, tree.len);
    try tree.checkInvariants();
}

// Counts live allocations made from any thread. It doesn't use
// `testing.allocator`, which would report every leaked node separately.
const CountingAllocator = struct {
    var live = std.atomic.Value(isize).init(0);
    const backing = std.heap.smp_allocator;
    const allocator: std.mem.Allocator = .{
        .ptr = undefined,
        .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
    };

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const ptr = backing.rawAlloc(len, alignment, return_address) orelse return null;
        _ = live.fetchAdd(1, .monotonic);
        return ptr;
    }

    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        return backing.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        return backing.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        backing.rawFree(memory, alignment, return_address);
        _ = live.fetchSub(1, .monotonic);
    }
};

const SharedTree = btree.Tree(isize, isize, .{ .order = .{ .compare = orderInt } });

var threads_may_start = std.atomic.Value(bool).init(false);

fn waitForStart() void {
    while (!threads_may_start.load(.acquire)) std.atomic.spinLoopHint();
}

// Runs `work` on two threads that start at the same moment.
fn runOnTwoThreads(comptime work: anytype, first: anytype, second: anytype) !void {
    threads_may_start.store(false, .release);
    const a = try std.Thread.spawn(.{}, work, first);
    const b = std.Thread.spawn(.{}, work, second) catch |err| {
        threads_may_start.store(true, .release);
        a.join();
        return err;
    };
    threads_may_start.store(true, .release);
    a.join();
    b.join();
}

fn releaseWhenStarted(tree: *SharedTree) void {
    waitForStart();
    tree.deinit(CountingAllocator.allocator);
}

fn insertWhenStarted(tree: *SharedTree, key: isize) void {
    waitForStart();
    _ = tree.insert(CountingAllocator.allocator, key, key * 10) catch return;
}

test "copies released on two threads at once free every node" {
    const gpa = CountingAllocator.allocator;
    CountingAllocator.live.store(0, .monotonic);
    // The two threads collide in fewer than one round in a thousand on some
    // runs, so repeat often.
    for (0..15_000) |_| {
        var original = SharedTree.init();
        try fillEvenKeys(SharedTree, &original, gpa, 200);
        var copy = original.copy();

        try runOnTwoThreads(releaseWhenStarted, .{&original}, .{&copy});

        try testing.expectEqual(0, CountingAllocator.live.load(.monotonic));
    }
}

test "copies mutated on two threads at once stay independent and free every node" {
    const gpa = CountingAllocator.allocator;
    CountingAllocator.live.store(0, .monotonic);
    for (0..500) |_| {
        var original = SharedTree.init();
        try fillEvenKeys(SharedTree, &original, gpa, 200);
        var copy = original.copy();

        // Both keys go into the same leaf, so both threads clone the root
        // and that leaf.
        try runOnTwoThreads(insertWhenStarted, .{ &original, 1 }, .{ &copy, 3 });

        try testing.expectEqual(201, original.len);
        try testing.expectEqual(201, copy.len);
        try testing.expectEqual(10, original.get(1, 0));
        try testing.expectEqual(null, original.get(3, 0));
        try testing.expectEqual(30, copy.get(3, 0));
        try testing.expectEqual(null, copy.get(1, 0));
        try original.checkInvariants();
        try copy.checkInvariants();

        original.deinit(gpa);
        copy.deinit(gpa);
        try testing.expectEqual(0, CountingAllocator.live.load(.monotonic));
    }
}
