const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub fn Tree(
    comptime K: type,
    comptime V: type,
    comptime compare: fn (K, V, K, V) i32,
) type {
    return struct {
        const Self = @This();

        pub const fanout: usize = 64;
        pub const max_items: usize = fanout - 1;
        pub const min_items: usize = max_items / 2;

        const Node = struct {
            const NodeSelf = @This();

            keys: [max_items]K = undefined,
            values: [max_items]V = undefined,
            len: u8 = 0,
            branch: ?*Branch = null,

            fn init() NodeSelf {
                return .{};
            }

            fn isLeaf(node: *const Node) bool {
                return node.branch == null;
            }
        };

        const Branch = struct {
            const BranchSelf = @This();

            children: [fanout]?*Node = [_]?*Node{null} ** fanout,
            counts: [fanout]usize = [_]usize{0} ** fanout,
            prefixes: ?*[max_items]u64 = null,

            fn init() BranchSelf {
                return .{};
            }
        };

        const SearchResult = struct {
            index: usize,
            found: bool,

            fn init(index: usize, found: bool) SearchResult {
                return .{ .index = index, .found = found };
            }
        };

        const Split = struct {
            right: *Node,
            key: K,
            value: V,

            fn init(right: *Node, key: K, value: V) Split {
                return .{ .right = right, .key = key, .value = value };
            }
        };

        root: ?*Node = null,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        fn newNode(self: *Self, gpa: mem.Allocator, leaf: bool) !*Node {
            _ = self;

            const node = try gpa.create(Node);
            node.* = Node.init();

            if (!leaf) {
                const branch = try gpa.create(Branch);
                branch.* = Branch.init();
                node.branch = branch;
            }

            return node;
        }

        fn destroyNode(self: *Self, gpa: mem.Allocator, node: *Node) void {
            if (node.branch) |branch| {
                var i: usize = 0;
                while (i <= node.len) : (i += 1) {
                    if (branch.children[i]) |child| {
                        self.destroyNode(gpa, child);
                    }
                }

                if (branch.prefixes) |prefixes| {
                    gpa.destroy(prefixes);
                }
                gpa.destroy(branch);
            }
            gpa.destroy(node);
        }

        fn splitNode(self: *Self, gpa: mem.Allocator, node: *Node) !Split {
            const median: usize = max_items - min_items - 1;
            const right = try self.newNode(gpa, node.isLeaf());

            const middle_key = node.keys[median];
            const middle_value = node.values[median];

            right.len = @intCast(max_items - median - 1);
            var i: usize = 0;
            while (i < right.len) : (i += 1) {
                const idx = i + median + 1;
                right.keys[i] = node.keys[idx];
                right.values[i] = node.values[idx];
            }

            if (node.branch) |left_branch| {
                const right_branch = right.branch.?;
                i = 0;
                while (i <= right.len) : (i += 1) {
                    const from = median + i + 1;
                    right_branch.children[i] = left_branch.children[from];
                    right_branch.counts[i] = left_branch.counts[from];
                    left_branch.children[from] = null;
                    left_branch.counts[from] = 0;
                }
            }

            node.len = @intCast(median);
            return Split.init(right, middle_key, middle_value);
        }

        fn splitRoot(self: *Self, gpa: mem.Allocator) !void {
            const old_root = self.root.?;
            const split = try self.splitNode(gpa, old_root);
            const new_root = try self.newNode(gpa, false);

            new_root.keys[0] = split.key;
            new_root.values[0] = split.value;
            new_root.len = 1;

            const branch = new_root.branch.?;
            branch.children[0] = old_root;
            branch.counts[0] = subtreeCount(old_root);
            branch.children[1] = split.right;
            branch.counts[1] = subtreeCount(split.right);

            self.root = new_root;
        }

        fn searchNode(node: *const Node, key: K, value: V) SearchResult {
            var i: usize = 0;
            while (i < node.len) : (i += 1) {
                const c = compare(node.keys[i], node.values[i], key, value);
                if (c >= 0) return SearchResult.init(i, c == 0);
            }
            return SearchResult.init(i, false);
        }

        fn insertItemAt(node: *Node, index: usize, key: K, value: V) void {
            std.debug.assert(node.len < max_items);

            var i = node.len;
            while (i > index) : (i -= 1) {
                node.keys[i] = node.keys[i - 1];
                node.values[i] = node.values[i - 1];
            }

            node.keys[index] = key;
            node.values[index] = value;
            node.len += 1;
        }

        fn insertChildAt(node: *Node, index: u8, child: *Node) void {
            const branch = node.branch.?;
            var i = node.len;
            while (i > index) : (i -= 1) {
                branch.children[i + 1] = branch.children[i];
                branch.counts[i + 1] = branch.counts[i];
            }
            branch.children[index] = child;
            branch.counts[index] = subtreeCount(node);
        }

        fn subtreeCount(node: ?*const Node) usize {
            const n = node orelse return 0;
            var total: usize = n.len;
            if (n.branch) |branch| {
                for (0..n.len + 1) |i| total += branch.counts[i];
            }
            return total;
        }

        pub fn deinit(self: *Self, gpa: mem.Allocator) void {
            if (self.root) |root| self.destroyNode(gpa, root);
            self.root = null;
            self.len = 0;
        }
    };
}

fn compareTestIntKey(a_key: isize, _: isize, b_key: isize, _: isize) i32 {
    return if (a_key < b_key) -1 else if (a_key > b_key) 1 else 0;
}

test "core nodes allocate and deallocate" {
    const IntTree = Tree(isize, isize, compareTestIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const leaf = try tree.newNode(std.testing.allocator, true);
    tree.destroyNode(testing.allocator, leaf);

    tree.root = try tree.newNode(std.testing.allocator, false);
}

test "node local search returns lower bound" {
    const IntTree = Tree(isize, isize, compareTestIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(std.testing.allocator, true);
    defer tree.destroyNode(std.testing.allocator, node);

    node.keys[0] = 10;
    node.values[0] = -10;
    node.keys[1] = 20;
    node.values[1] = -20;
    node.keys[2] = 30;
    node.values[2] = -30;
    node.len = 3;

    try testing.expectEqual(0, IntTree.searchNode(node, 5, 0).index);
    try testing.expect(IntTree.searchNode(node, 10, 0).found);
    try testing.expectEqual(1, IntTree.searchNode(node, 15, 0).index);
    try testing.expectEqual(3, IntTree.searchNode(node, 40, 0).index);
}

test "insertItemAt shifts items inside a leaf" {
    const IntTree = Tree(isize, isize, compareTestIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(testing.allocator, true);
    defer tree.destroyNode(testing.allocator, node);

    IntTree.insertItemAt(node, 0, 20, -20);
    IntTree.insertItemAt(node, 0, 10, -10);
    IntTree.insertItemAt(node, 2, 30, -30);

    try std.testing.expectEqual(3, node.len);
    try std.testing.expectEqual(10, node.keys[0]);
    try std.testing.expectEqual(20, node.keys[1]);
    try std.testing.expectEqual(30, node.keys[2]);
}

test "splitNode promotes the median" {
    const IntTree = Tree(isize, isize, compareTestIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(testing.allocator, true);
    tree.root = node;
    for (0..IntTree.max_items) |i| {
        node.keys[i] = @intCast(i);
        node.values[i] = -@as(isize, @intCast(i));
    }
    node.len = IntTree.max_items;

    const split = try tree.splitNode(testing.allocator, node);
    defer tree.destroyNode(testing.allocator, split.right);

    try std.testing.expectEqual(31, node.len);
    try std.testing.expectEqual(31, split.key);
    try std.testing.expectEqual(31, split.right.len);
    try std.testing.expectEqual(32, split.right.keys[0]);
}

test "splitRoot promotes the median into a new root" {
    const IntTree = Tree(isize, isize, compareTestIntKey);
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(testing.allocator, true);
    tree.root = node;
    for (0..IntTree.max_items) |i| {
        node.keys[i] = @intCast(i);
        node.values[i] = -@as(isize, @intCast(i));
    }
    node.len = IntTree.max_items;

    try tree.splitRoot(testing.allocator);

    const root = tree.root.?;
    const branch = root.branch.?;
    try testing.expectEqual(1, root.len);
    try testing.expectEqual(31, root.keys[0]);
    try testing.expectEqual(node, branch.children[0].?);
    try testing.expectEqual(31, branch.counts[0]);
    try testing.expectEqual(32, branch.children[1].?.keys[0]);
    try testing.expectEqual(31, branch.counts[1]);
}
