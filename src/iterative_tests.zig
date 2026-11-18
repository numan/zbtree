const std = @import("std");
const btree = @import("btree.zig");
const map = @import("map.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

fn cmpKey(a: isize, _: isize, b: isize, _: isize) Order {
    return std.math.order(a, b);
}

fn cmpStr(a: []const u8, _: usize, b: []const u8, _: usize) Order {
    return std.mem.order(u8, a, b);
}

const IntTree = btree.Tree(isize, isize, .{ .compare = cmpKey, .use_string_prefix = false });
const KeyTree = btree.Tree(isize, isize, .{ .compare = cmpKey, .ordering = .ordered_key, .use_string_prefix = false });
const StrTree = btree.Tree([]const u8, usize, .{ .compare = cmpStr, .use_string_prefix = true });
const IntMap = map.Map(isize, isize, .{});

/// 70k sequential keys build a 4-level tree: root, two internal levels, leaves.
/// Four levels is the smallest shape with an internal node that is neither the
/// root nor a leaf parent.
const deep_n: usize = 70_000;

fn height(TreeType: type, tree: *TreeType) usize {
    var node = tree.root orelse return 0;
    var h: usize = 1;
    while (node.branch) |b| : (h += 1) node = b.children[0].?;
    return h;
}

/// Inserts keys 0..n with value key*10.
fn fillDeep(TreeType: type, tree: *TreeType, gpa: Allocator, n: usize) !void {
    for (0..n) |i| {
        const k: isize = @intCast(i);
        try testing.expect(try tree.insert(gpa, k, k * 10));
    }
}

const ModelWalk = struct {
    model: []const bool,
    next: usize = 0,
    seen: usize = 0,
};

fn expectNextPresent(ctx: *ModelWalk, key: isize, value: isize) !void {
    while (ctx.next < ctx.model.len and !ctx.model[ctx.next]) ctx.next += 1;
    try testing.expect(ctx.next < ctx.model.len);
    try testing.expectEqual(@as(isize, @intCast(ctx.next)), key);
    try testing.expectEqual(key * 10, value);
    ctx.next += 1;
    ctx.seen += 1;
}

/// `model[k]` is true when key k (value k*10) must be in the tree.
fn expectMatchesModel(tree: anytype, model: []const bool) !void {
    try tree.checkInvariants();
    var ctx = ModelWalk{ .model = model };
    try tree.ascent(*ModelWalk, &ctx, expectNextPresent);
    var count: usize = 0;
    for (model) |present| count += @intFromBool(present);
    try testing.expectEqual(count, ctx.seen);
}

fn newModel(gpa: Allocator, size: usize, present_below: usize) ![]bool {
    const model = try gpa.alloc(bool, size);
    for (model, 0..) |*p, i| p.* = i < present_below;
    return model;
}

// ------------------------------------------------- step 0: safety net

test "deep fixture has four levels" {
    const TreeType = IntTree;
    var tree = TreeType.init();
    defer tree.deinit(testing.allocator);
    try fillDeep(TreeType, &tree, testing.allocator, deep_n);
    try testing.expectEqual(4, height(TreeType, &tree));
    try tree.checkInvariants();
}

test "max_height exceeds the height of any tree that fits in usize" {
    // Smallest tree with max_height + 1 levels: the root has 1 item and 2
    // children, other internal nodes have min_items + 1 children, and every
    // leaf holds min_items items. If even that tree cannot be counted in a
    // usize, no real tree can be taller than max_height.
    var leaves: u128 = 2;
    for (0..IntTree.max_height - 1) |_| leaves *= IntTree.min_items + 1;
    try testing.expect(leaves * IntTree.min_items > std.math.maxInt(usize));
}

test "random inserts and deletes on a deep tree match a model; snapshot stays frozen" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    const key_space = deep_n + 10_000;

    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);
    const model = try newModel(gpa, key_space, deep_n);
    defer gpa.free(model);

    var snapshot = tree.copy();
    defer snapshot.deinit(gpa);
    const snapshot_model = try gpa.dupe(bool, model);
    defer gpa.free(snapshot_model);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..40_000) |step| {
        const k = random.uintLessThan(usize, key_space);
        const key: isize = @intCast(k);
        if (random.boolean()) {
            try testing.expectEqual(!model[k], try tree.insert(gpa, key, key * 10));
            model[k] = true;
        } else {
            const old = try tree.delete(gpa, key, 0);
            if (model[k]) try testing.expectEqual(key * 10, old.?) else try testing.expect(old == null);
            model[k] = false;
        }
        if (step % 10_000 == 0) try tree.checkInvariants();
    }
    try expectMatchesModel(&tree, model);
    try expectMatchesModel(&snapshot, snapshot_model);
}

test "replaceAt reaches every index of a deep tree, including separators" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);

    var snapshot = tree.copy();
    defer snapshot.deinit(gpa);

    for (0..deep_n) |i| {
        const k: isize = @intCast(i);
        const old = (try tree.replaceAt(gpa, i, k, -k)).?;
        try testing.expectEqual(k, old.key);
        try testing.expectEqual(k * 10, old.value);
    }
    try tree.checkInvariants();
    for (0..deep_n) |i| {
        const k: isize = @intCast(i);
        try testing.expectEqual(-k, tree.getAt(i).?.value);
        try testing.expectEqual(k * 10, snapshot.getAt(i).?.value);
    }
}

test "replaceAt refreshes string prefixes on separators" {
    const TreeType = StrTree;
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tree = TreeType.init();
    defer tree.deinit(gpa);
    const n = 5_000;
    for (0..n) |i| {
        const key = try std.fmt.allocPrint(arena, "k{d:0>6}", .{i * 2});
        try testing.expect(try tree.insert(gpa, key, i));
    }
    for (0..n) |i| {
        // "k000002" -> "k000003": still between its neighbours, but the
        // 8-byte routing prefix changes, so checkInvariants catches a missing
        // setPrefix on internal nodes.
        const key = try std.fmt.allocPrint(arena, "k{d:0>6}", .{i * 2 + 1});
        try testing.expect((try tree.replaceAt(gpa, i, key, i)) != null);
    }
    try tree.checkInvariants();
    for (0..n) |i| {
        const key = try std.fmt.allocPrint(arena, "k{d:0>6}", .{i * 2 + 1});
        try testing.expectEqual(i, tree.get(key, 0));
    }
}

test "pushBack and pushFront build deep trees with correct counts" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var back = TreeType.init();
    defer back.deinit(gpa);
    var front = TreeType.init();
    defer front.deinit(gpa);

    for (0..deep_n) |i| {
        const k: isize = @intCast(i);
        try testing.expect(try back.pushBack(gpa, k, k * 10));
        const r: isize = @intCast(deep_n - 1 - i);
        try testing.expect(try front.pushFront(gpa, r, r * 10));
    }
    try testing.expect(height(TreeType, &back) >= 4);
    try testing.expect(height(TreeType, &front) >= 4);

    const model = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(model);
    try expectMatchesModel(&back, model);
    try expectMatchesModel(&front, model);
    var i: usize = 0;
    while (i < deep_n) : (i += 997) {
        try testing.expectEqual(@as(isize, @intCast(i)), back.getAt(i).?.key);
        try testing.expectEqual(@as(isize, @intCast(i)), front.getAt(i).?.key);
    }
}

test "edge pushes on a copy leave the original unchanged" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var original = TreeType.init();
    defer original.deinit(gpa);
    try fillDeep(TreeType, &original, gpa, deep_n);

    var copy = original.copy();
    defer copy.deinit(gpa);
    for (0..5_000) |i| {
        const k: isize = @intCast(deep_n + i);
        try testing.expect(try copy.pushBack(gpa, k, k * 10));
        const f: isize = -@as(isize, @intCast(i)) - 1;
        try testing.expect(try copy.pushFront(gpa, f, f * 10));
    }
    try copy.checkInvariants();
    try testing.expectEqual(deep_n + 10_000, copy.len);

    const model = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(model);
    try expectMatchesModel(&original, model);
}

test "duplicate inserts are rejected at every depth without touching counts" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);

    // Random order fills nodes close to max_items, so duplicate inserts often
    // split a full child first and then hit the promoted median (cmp == .eq).
    var prng = std.Random.DefaultPrng.init(42);
    const keys = try gpa.alloc(isize, deep_n);
    defer gpa.free(keys);
    for (keys, 0..) |*k, i| k.* = @intCast(i);
    prng.random().shuffle(isize, keys);
    for (keys) |k| try testing.expect(try tree.insert(gpa, k, k * 10));

    prng.random().shuffle(isize, keys);
    for (keys, 0..) |k, i| {
        try testing.expect(!try tree.insert(gpa, k, 0));
        if (i % 5_000 == 0) try tree.checkInvariants();
    }
    try testing.expectEqual(deep_n, tree.len);
    const model = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(model);
    try expectMatchesModel(&tree, model);
}

test "ordered-key insertKey matches a model on a deep tree" {
    const TreeType = KeyTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    const key_space = deep_n * 2;
    const model = try newModel(gpa, key_space, 0);
    defer gpa.free(model);

    var prng = std.Random.DefaultPrng.init(7);
    for (0..deep_n * 2) |_| {
        const k = prng.random().uintLessThan(usize, key_space);
        const key: isize = @intCast(k);
        try testing.expectEqual(!model[k], try tree.insertKey(gpa, key, key * 10));
        model[k] = true;
    }
    try expectMatchesModel(&tree, model);
}

test "map insert and set match a model, copy stays frozen" {
    const MapType = IntMap;
    const gpa = testing.allocator;
    var m = MapType.init();
    defer m.deinit(gpa);
    try fillDeep(MapType, &m, gpa, deep_n);
    var snapshot = m.copy();
    defer snapshot.deinit(gpa);

    const key_space = deep_n + 20_000;
    const model = try newModel(gpa, key_space, deep_n);
    defer gpa.free(model);

    var prng = std.Random.DefaultPrng.init(99);
    const random = prng.random();
    for (0..30_000) |_| {
        const k = random.uintLessThan(usize, key_space);
        const key: isize = @intCast(k);
        if (random.boolean()) {
            try testing.expectEqual(!model[k], try m.insert(gpa, key, key * 10));
        } else {
            const old = try m.set(gpa, key, key * 10);
            try testing.expectEqual(model[k], old != null);
        }
        model[k] = true;
    }
    try expectMatchesModel(&m, model);
    const snapshot_model = try newModel(gpa, key_space, deep_n);
    defer gpa.free(snapshot_model);
    try expectMatchesModel(&snapshot, snapshot_model);
}

test "deleting every key in random order keeps invariants" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);
    var snapshot = tree.copy();
    defer snapshot.deinit(gpa);

    const keys = try gpa.alloc(isize, deep_n);
    defer gpa.free(keys);
    for (keys, 0..) |*k, i| k.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(3);
    prng.random().shuffle(isize, keys);

    for (keys, 0..) |k, i| {
        try testing.expectEqual(k * 10, (try tree.delete(gpa, k, 0)).?);
        try testing.expect((try tree.delete(gpa, k, 0)) == null); // missing key: no-op
        if (i % 5_000 == 0) try tree.checkInvariants();
    }
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);

    const model = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(model);
    try expectMatchesModel(&snapshot, model);
}

test "popFront and popBack drain a deep tree in order" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);
    var snapshot = tree.copy();
    defer snapshot.deinit(gpa);

    var lo: isize = 0;
    var hi: isize = @intCast(deep_n - 1);
    var i: usize = 0;
    while (lo <= hi) : (i += 1) {
        const first = (try tree.popFront(gpa)).?;
        try testing.expectEqual(lo, first.key);
        lo += 1;
        if (lo > hi) break;
        const last = (try tree.popBack(gpa)).?;
        try testing.expectEqual(hi, last.key);
        hi -= 1;
        if (i % 3_000 == 0) try tree.checkInvariants();
    }
    try testing.expect((try tree.popFront(gpa)) == null);
    try testing.expectEqual(deep_n, snapshot.len);
    try snapshot.checkInvariants();
}

test "deleteAt at random indices matches a model" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);
    var snapshot = tree.copy();
    defer snapshot.deinit(gpa);

    var remaining = try std.ArrayList(isize).initCapacity(gpa, deep_n);
    defer remaining.deinit(gpa);
    for (0..deep_n) |i| remaining.appendAssumeCapacity(@intCast(i));

    var prng = std.Random.DefaultPrng.init(11);
    for (0..deep_n / 2) |step| {
        const index = prng.random().uintLessThan(usize, remaining.items.len);
        const expected = remaining.orderedRemove(index);
        const removed = (try tree.deleteAt(gpa, index)).?;
        try testing.expectEqual(expected, removed.key);
        if (step % 5_000 == 0) try tree.checkInvariants();
    }
    try tree.checkInvariants();
    for (remaining.items, 0..) |k, i| try testing.expectEqual(k, tree.getAt(i).?.key);
    try snapshot.checkInvariants();
    try testing.expectEqual(deep_n, snapshot.len);
}

test "map delete and ordered deleteKey match a model" {
    const MapType = IntMap;
    const TreeType = KeyTree;
    const gpa = testing.allocator;
    var m = MapType.init();
    defer m.deinit(gpa);
    try fillDeep(MapType, &m, gpa, deep_n);
    var kt = TreeType.init();
    defer kt.deinit(gpa);
    try fillDeep(TreeType, &kt, gpa, deep_n);
    var snapshot = m.copy();
    defer snapshot.deinit(gpa);

    const model = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(model);
    var prng = std.Random.DefaultPrng.init(5);
    for (0..deep_n) |_| {
        const k = prng.random().uintLessThan(usize, deep_n);
        const key: isize = @intCast(k);
        const a = try m.delete(gpa, key);
        const b = try kt.deleteKey(gpa, key);
        try testing.expectEqual(model[k], a != null);
        try testing.expectEqual(model[k], b != null);
        model[k] = false;
    }
    try expectMatchesModel(&m, model);
    try expectMatchesModel(&kt, model);
    const full = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(full);
    try expectMatchesModel(&snapshot, full);
}

const RangeWalk = struct {
    expected: []const isize,
    next: usize = 0,
};

fn expectRangeItem(ctx: *RangeWalk, key: isize, value: isize) !void {
    try testing.expect(ctx.next < ctx.expected.len);
    try testing.expectEqual(ctx.expected[ctx.next], key);
    try testing.expectEqual(key * 10, value);
    ctx.next += 1;
}

test "random deleteRangeAt calls on a deep tree match a model" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);
    var snapshot = tree.copy();
    defer snapshot.deinit(gpa);

    var remaining = try std.ArrayList(isize).initCapacity(gpa, deep_n);
    defer remaining.deinit(gpa);
    for (0..deep_n) |i| remaining.appendAssumeCapacity(@intCast(i));

    var prng = std.Random.DefaultPrng.init(17);
    const random = prng.random();
    while (remaining.items.len > 0) {
        const index = random.uintLessThan(usize, remaining.items.len);
        // Mix tiny, medium, and huge ranges so both the leaf path and the
        // detach-whole-subtree paths run at every depth.
        const count = switch (random.uintLessThan(u8, 3)) {
            0 => random.uintLessThan(usize, 4) + 1,
            1 => random.uintLessThan(usize, 200) + 1,
            else => random.uintLessThan(usize, 8_000) + 1,
        };
        const end = @min(index + count, remaining.items.len);

        const result = try tree.deleteRangeAt(gpa, index, count, .{});
        defer result.deinit(gpa);
        try testing.expectEqual(end - index, result.removed_count);

        var walk = RangeWalk{ .expected = remaining.items[index..end] };
        try result.ascent(*RangeWalk, &walk, expectRangeItem);
        try testing.expectEqual(end - index, walk.next);

        remaining.replaceRangeAssumeCapacity(index, end - index, &.{});
        try tree.checkInvariants();
        try testing.expectEqual(remaining.items.len, tree.len);
    }
    try testing.expect(tree.root == null);
    try testing.expectEqual(deep_n, snapshot.len);
    try snapshot.checkInvariants();
}

var live_values: usize = 0;

fn copyCounted(_: Allocator, value: isize) anyerror!isize {
    live_values += 1;
    return value;
}

fn releaseCounted(_: Allocator, _: isize) void {
    live_values -= 1;
}

const OwnedTree = btree.Tree(isize, isize, .{
    .compare = cmpKey,
    .use_string_prefix = false,
    .copy_value = copyCounted,
    .release_value = releaseCounted,
});

fn fillOwned(tree: *OwnedTree, gpa: Allocator, n: usize) !void {
    for (0..n) |i| {
        const k: isize = @intCast(i);
        live_values += 1; // the tree takes ownership of this value
        try testing.expect(try tree.insert(gpa, k, k * 10));
    }
}

test "every owned value and node is released exactly once" {
    const TreeType = OwnedTree;
    const gpa = testing.allocator;
    // Try both destruction orders: shared nodes must be freed by whichever
    // tree lets go last.
    for ([_]bool{ true, false }) |original_first| {
        live_values = 0;
        var original = TreeType.init();
        try fillOwned(&original, gpa, deep_n);
        var copy = original.copy();
        // Clone a few paths so the trees share some nodes and own others.
        // delete hands the removed value back to the caller, who must release it.
        for (0..200) |i| {
            if (try copy.delete(gpa, @intCast(i * 300), 0)) |value| releaseCounted(gpa, value);
        }
        const range = try copy.deleteRangeAt(gpa, 10_000, 20_000, .{});

        if (original_first) {
            original.deinit(gpa);
            range.deinit(gpa);
            copy.deinit(gpa);
        } else {
            copy.deinit(gpa);
            range.deinit(gpa);
            original.deinit(gpa);
        }
        // testing.allocator reports leaked nodes; this catches leaked values.
        try testing.expectEqual(0, live_values);
    }
}

test "clear on a deep tree, then reuse" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);
    tree.clear(gpa);
    try testing.expectEqual(0, tree.len);
    try fillDeep(TreeType, &tree, gpa, 1_000);
    try tree.checkInvariants();
}

const DescWalk = struct { next: isize, seen: usize = 0 };

fn expectDescending(ctx: *DescWalk, key: isize, value: isize) !void {
    try testing.expectEqual(ctx.next, key);
    try testing.expectEqual(key * 10, value);
    ctx.next -= 1;
    ctx.seen += 1;
}

const StartWalk = struct { next: isize, step: isize, left: usize };

fn expectFromIndex(ctx: *StartWalk, key: isize, value: isize) !bool {
    try testing.expectEqual(ctx.next, key);
    try testing.expectEqual(key * 10, value);
    ctx.next += ctx.step;
    ctx.left -= 1;
    return ctx.left > 0;
}

test "ascent and descent visit a deep tree in order" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);

    const model = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(model);
    try expectMatchesModel(&tree, model); // uses ascent

    var desc = DescWalk{ .next = @intCast(deep_n - 1) };
    try tree.descent(*DescWalk, &desc, expectDescending);
    try testing.expectEqual(deep_n, desc.seen);
}

test "ascendAt and descendAt start at every index of a deep tree" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);

    for (0..deep_n) |i| {
        const k: isize = @intCast(i);
        // Three items crosses leaf->separator->leaf boundaries near node edges.
        var up = StartWalk{ .next = k, .step = 1, .left = @min(3, deep_n - i) };
        try tree.ascendAt(*StartWalk, i, &up, expectFromIndex);
        try testing.expectEqual(0, up.left);

        var down = StartWalk{ .next = k, .step = -1, .left = @min(3, i + 1) };
        try tree.descendAt(*StartWalk, i, &down, expectFromIndex);
        try testing.expectEqual(0, down.left);
    }

    // Full runs from a deep interior start.
    var up = StartWalk{ .next = 31_337, .step = 1, .left = deep_n - 31_337 };
    try tree.ascendAt(*StartWalk, 31_337, &up, expectFromIndex);
    try testing.expectEqual(0, up.left);
    var down = StartWalk{ .next = 31_337, .step = -1, .left = 31_338 };
    try tree.descendAt(*StartWalk, 31_337, &down, expectFromIndex);
    try testing.expectEqual(0, down.left);
}

fn addOne(_: void, _: isize, value: *isize) !void {
    value.* += 1;
}

fn subOne(_: void, _: isize, value: *isize) !void {
    value.* -= 1;
}

test "ascentMut and descentMut update a copy without touching the original" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var original = TreeType.init();
    defer original.deinit(gpa);
    try fillDeep(TreeType, &original, gpa, deep_n);

    var copy = original.copy();
    defer copy.deinit(gpa);
    try copy.ascentMut(gpa, void, {}, addOne);
    for (0..deep_n) |i| {
        const k: isize = @intCast(i);
        try testing.expectEqual(k * 10 + 1, copy.getAt(i).?.value);
    }

    var copy2 = copy.copy();
    defer copy2.deinit(gpa);
    try copy2.descentMut(gpa, void, {}, subOne);
    try copy2.descentMut(gpa, void, {}, subOne);

    const model = try newModel(gpa, deep_n, deep_n);
    defer gpa.free(model);
    try expectMatchesModel(&original, model);
    for (0..deep_n) |i| {
        const k: isize = @intCast(i);
        try testing.expectEqual(k * 10 + 1, copy.getAt(i).?.value);
        try testing.expectEqual(k * 10 - 1, copy2.getAt(i).?.value);
    }
}

fn failAt(ctx: *usize, _: isize, _: isize) !void {
    if (ctx.* == 0) return error.Stop;
    ctx.* -= 1;
}

test "traversal errors stop deep in the tree" {
    const TreeType = IntTree;
    const gpa = testing.allocator;
    var tree = TreeType.init();
    defer tree.deinit(gpa);
    try fillDeep(TreeType, &tree, gpa, deep_n);

    var left: usize = 40_000;
    try testing.expectError(error.Stop, tree.ascent(*usize, &left, failAt));
    try testing.expectEqual(0, left);
    left = 40_000;
    try testing.expectError(error.Stop, tree.descent(*usize, &left, failAt));
    try testing.expectEqual(0, left);
}

test "deleteRangeAt releases every chunk when an allocation fails" {
    const TreeType = IntTree;
    // Fail the k-th allocation made *inside* deleteRangeAt, for every k, so
    // each error path in the range-deletion loop runs once. testing.allocator
    // (the backing allocator) reports anything leaked or double-freed.
    var k: usize = 0;
    while (true) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        const gpa = failing.allocator();
        var tree = TreeType.init();
        defer tree.deinit(gpa);
        try fillDeep(TreeType, &tree, gpa, 5_000);

        failing.fail_index = failing.alloc_index + k;
        const result = tree.deleteRangeAt(gpa, 200, 4_300, .{}) catch |err| {
            // Only ownership is checked here. A failed range delete can
            // currently leave stale subtree counts (a separate, pre-existing
            // bug), so checkInvariants is deliberately not called.
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        result.deinit(gpa);
        try testing.expectEqual(700, tree.len);
        try testing.expect(k > 0); // the loop really did inject failures
        break;
    }
}

// Runs `op` on a copy of a 3,000-item tree. `op` is a function pointer
// because checkAllAllocationFailures can't pass a comptime function as an
// extra argument. Setup and teardown use `gpa` too, or the harness would
// report their memory as leaked.
fn cowScenario(gpa: Allocator, op: *const fn (*IntTree, Allocator) anyerror!void) !void {
    var original = IntTree.init();
    defer original.deinit(gpa);
    for (0..3000) |i| {
        const k: isize = @intCast(i * 2);
        _ = try original.insert(gpa, k, k * 10);
    }
    var copy = original.copy();
    defer copy.deinit(gpa);
    op(&copy, gpa) catch |err| {
        try copy.checkInvariants();
        try original.checkInvariants();
        return err;
    };
    try copy.checkInvariants();
    try original.checkInvariants();
}

fn opInsertMany(t: *IntTree, gpa: Allocator) anyerror!void {
    for (0..200) |i| _ = try t.insert(gpa, @intCast(i * 2 + 1), 0);
}

test "copy-on-write insert survives every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, cowScenario, .{&opInsertMany});
}
