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
