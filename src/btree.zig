const std = @import("std");
const mem = std.mem;
const testing = std.testing;

/// Creates a B-tree type for the given key/value types.
///
/// `compare` defines the sort order. It receives both key and value for each
/// item, so the tree can be used as either a map-like structure or an ordered
/// collection where the value helps break ties.
pub fn Tree(
    comptime K: type,
    comptime V: type,
    comptime compare: fn (K, V, K, V) i32,
) type {
    return struct {
        const Self = @This();

        /// Maximum number of child pointers in an internal node.
        pub const fanout: usize = 64;
        /// Maximum number of key/value items stored directly in one node.
        pub const max_items: usize = fanout - 1;
        /// Minimum item count for non-root nodes after the tree has split.
        pub const min_items: usize = max_items / 2;

        // A node stores sorted key/value items. If `branch` is null it is a
        // leaf; otherwise `branch` stores the child pointers between items.
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

        // Extra data for internal nodes. `children[i]` contains items that sort
        // before `keys[i]`, and `children[len]` contains items after the last
        // key. `counts[i]` is the total number of items in `children[i]`.
        const Branch = struct {
            const BranchSelf = @This();

            children: [fanout]?*Node = [_]?*Node{null} ** fanout,
            counts: [fanout]usize = [_]usize{0} ** fanout,
            prefixes: ?*[max_items]u64 = null,

            fn init() BranchSelf {
                return .{};
            }
        };

        // Result of searching inside one node. `index` is either the matching
        // item index or the insertion/child-descent position.
        const SearchResult = struct {
            index: usize,
            found: bool,

            fn init(index: usize, found: bool) SearchResult {
                return .{ .index = index, .found = found };
            }
        };

        // Returned when a full node is split. The middle item moves up into the
        // parent, and `right` is the newly allocated right-hand sibling.
        const Split = struct {
            right: *Node,
            key: K,
            value: V,

            fn init(right: *Node, key: K, value: V) Split {
                return .{ .right = right, .key = key, .value = value };
            }
        };

        /// A key/value pair returned by ordered lookup and indexed access.
        const Bound = struct {
            key: K,
            value: V,

            pub fn init(key: K, value: V) Bound {
                return .{ .key = key, .value = value };
            }
        };

        const Entry = Bound;

        root: ?*Node = null,
        len: usize = 0,

        /// Returns an empty tree. The allocator is passed to operations that
        /// allocate or free nodes instead of being stored in the tree itself.
        pub fn init() Self {
            return .{};
        }

        // Allocates one node. Internal nodes also allocate their Branch data.
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

        // Recursively frees a node, all of its descendants, and branch data.
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

        // Splits a full node into left and right halves. The original node keeps
        // the left half; the returned Split contains the promoted middle item
        // and the new right half.
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

        // Splits a full root and creates a new root above it, increasing the
        // tree height by one.
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

        // Finds the first item in `node` that is greater than or equal to the
        // requested key/value pair.
        fn searchNode(node: *const Node, key: K, value: V) SearchResult {
            var i: usize = 0;
            while (i < node.len) : (i += 1) {
                const c = compare(node.keys[i], node.values[i], key, value);
                if (c >= 0) return SearchResult.init(i, c == 0);
            }
            return SearchResult.init(i, false);
        }

        // Inserts one item into a non-full node by shifting later items right.
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

        // Inserts a child pointer into an internal node and records that child's
        // current subtree size.
        fn insertChildAt(node: *Node, index: usize, child: *Node) void {
            const branch = node.branch.?;
            std.debug.assert(index <= node.len);

            var i = node.len;
            while (i > index) : (i -= 1) {
                branch.children[i] = branch.children[i - 1];
                branch.counts[i] = branch.counts[i - 1];
            }
            branch.children[index] = child;
            branch.counts[index] = subtreeCount(child);
        }

        // Counts all items reachable from a node. Hot insertion paths maintain
        // counts incrementally; this helper is used after structural changes and
        // by invariant checks.
        fn subtreeCount(node: ?*const Node) usize {
            const n = node orelse return 0;
            var total: usize = n.len;
            if (n.branch) |branch| {
                for (0..n.len + 1) |i| total += branch.counts[i];
            }
            return total;
        }

        // Splits a full child before descending into it. This keeps insertion
        // simple because recursion always enters a non-full node.
        fn splitChild(self: *Self, gpa: mem.Allocator, parent: *Node, child_index: usize) !void {
            const branch = parent.branch.?;
            const split = try self.splitNode(gpa, branch.children[child_index].?);

            insertItemAt(parent, child_index, split.key, split.value);
            insertChildAt(parent, child_index + 1, split.right);
            branch.counts[child_index] = subtreeCount(branch.children[child_index]);
        }

        // Inserts into a node that is known not to be full. Returns false when
        // the comparator says an equal item already exists.
        fn insertIntoNonFull(self: *Self, gpa: mem.Allocator, node: *Node, key: K, value: V) !bool {
            const found = searchNode(node, key, value);
            if (found.found) return false;

            if (node.isLeaf()) {
                insertItemAt(node, found.index, key, value);
                return true;
            }

            const branch = node.branch.?;
            var child_index = found.index;
            if (branch.children[child_index].?.len == max_items) {
                try self.splitChild(gpa, node, child_index);
                const cmp = compare(node.keys[child_index], node.values[child_index], key, value);
                if (cmp == 0) return false;
                if (cmp < 0) child_index += 1;
            }

            const inserted = try self.insertIntoNonFull(gpa, branch.children[child_index].?, key, value);
            if (inserted) branch.counts[child_index] += 1;
            return inserted;
        }

        /// Inserts `key`/`value` if an equal item is not already present.
        ///
        /// Returns `true` when a new item was inserted and `false` for a
        /// duplicate according to `compare`.
        pub fn insert(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            if (self.root == null) self.root = try self.newNode(gpa, true);
            if (self.root.?.len == max_items) try self.splitRoot(gpa);

            const inserted = try self.insertIntoNonFull(gpa, self.root.?, key, value);

            if (inserted) self.len += 1;
            return inserted;
        }

        /// Looks up an item equal to `key`/`value` and returns its stored value.
        /// Returns `null` when no equal item exists.
        pub fn get(self: *const Self, key: K, value: V) ?V {
            var node = self.root orelse return null;
            while (true) {
                const found = searchNode(node, key, value);
                if (found.found) return node.values[found.index];
                if (node.branch) |branch| node = branch.children[found.index].? else return null;
            }
        }

        /// Visits every item in ascending sort order.
        ///
        /// The callback receives `(context, key, value)`. Any callback error is
        /// returned to the caller and stops traversal.
        pub fn ascent(
            self: *const Self,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            if (self.root) |root| try visitAsc(CtxType, root, context, yield);
        }

        // Recursive implementation for ascending traversal.
        fn visitAsc(
            comptime CtxType: type,
            node: *const Node,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            if (node.isLeaf()) {
                for (0..node.len) |i| try yield(ctx, node.keys[i], node.values[i]);
                return;
            }

            const branch = node.branch.?;
            for (0..node.len) |i| {
                try visitAsc(CtxType, branch.children[i].?, ctx, yield);
                try yield(ctx, node.keys[i], node.values[i]);
            }

            try visitAsc(CtxType, branch.children[node.len].?, ctx, yield);
        }

        /// Visits every item in descending sort order.
        ///
        /// The callback receives `(context, key, value)`. Any callback error is
        /// returned to the caller and stops traversal.
        pub fn descent(
            self: *const Self,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            if (self.root) |root| try visitDesc(CtxType, root, context, yield);
        }

        // Recursive implementation for descending traversal.
        fn visitDesc(
            comptime CtxType: type,
            node: *const Node,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            if (node.isLeaf()) {
                var i = node.len;
                while (i > 0) {
                    i -= 1;
                    try yield(ctx, node.keys[i], node.values[i]);
                }
                return;
            }

            const branch = node.branch.?;
            try visitDesc(CtxType, branch.children[node.len].?, ctx, yield);

            var i = node.len;
            while (i > 0) {
                i -= 1;
                try yield(ctx, node.keys[i], node.values[i]);
                try visitDesc(CtxType, branch.children[i].?, ctx, yield);
            }
        }

        /// Returns the first item greater than or equal to `key`/`val`.
        ///
        /// This is a lower-bound search: `seek(15)` returns `20` in a tree that
        /// contains `10, 20, 30`. Returns `null` if all items are smaller.
        pub fn seek(self: *const Self, key: K, val: V) ?Entry {
            var node = self.root orelse return null;
            var candidate: ?Entry = null;
            while (true) {
                const found = searchNode(node, key, val);
                if (found.index < node.len) {
                    candidate = Entry.init(node.keys[found.index], node.values[found.index]);
                }
                if (found.found) return candidate;
                if (node.branch) |branch| node = branch.children[found.index].? else return candidate;
            }
        }

        /// Returns the item immediately after `key`/`val` in sort order.
        ///
        /// If `key`/`val` is not present, this behaves like `seek` and returns
        /// the first greater item.
        pub fn seekNext(self: *const Self, key: K, val: V) ?Entry {
            const index = self.indexOf(key, val) orelse return self.seek(key, val);
            return self.getAt(index + 1);
        }

        /// Returns the item immediately before `key`/`val` in sort order.
        ///
        /// If `key`/`val` is not present, this returns the greatest item smaller
        /// than it. Returns `null` when there is no smaller item.
        pub fn seekPrev(self: *const Self, key: K, val: V) ?Entry {
            var node = self.root orelse return null;
            var candidate: ?Entry = null;

            while (true) {
                const found = searchNode(node, key, val);
                if (found.found) {
                    const index = self.indexOf(key, val).?;
                    return if (index == 0) null else self.getAt(index - 1);
                }
                if (found.index > 0) {
                    const candidate_index = found.index - 1;
                    candidate = Entry.init(node.keys[candidate_index], node.values[candidate_index]);
                }
                if (node.branch) |branch| node = branch.children[found.index].? else return candidate;
            }
        }

        /// Returns the item at zero-based sorted position `index`.
        ///
        /// The per-child subtree counts let this skip whole child subtrees while
        /// descending, so access is logarithmic in the number of items. Returns
        /// `null` when `index` is out of range.
        pub fn getAt(self: *const Self, index: usize) ?Entry {
            if (index >= self.len) return null;

            var node = self.root.?;
            var remaining = index;

            while (true) {
                if (node.isLeaf()) return Entry.init(node.keys[remaining], node.values[remaining]);

                const branch = node.branch.?;
                for (0..node.len) |i| {
                    if (remaining < branch.counts[i]) {
                        node = branch.children[i].?;
                        break;
                    }
                    remaining -= branch.counts[i];
                    if (remaining == 0) return Entry.init(node.keys[i], node.values[i]);
                    remaining -= 1;
                } else {
                    node = branch.children[node.len].?;
                }
            }
        }

        /// Returns the zero-based sorted position of `key`/`val`.
        /// Returns `null` when no equal item exists.
        pub fn indexOf(self: *const Self, key: K, val: V) ?usize {
            var node = self.root orelse return null;
            var skipped: usize = 0;

            while (true) {
                const found = searchNode(node, key, val);
                if (node.isLeaf()) return if (found.found) skipped + found.index else null;

                const branch = node.branch.?;
                for (0..found.index) |i| skipped += branch.counts[i] + 1;
                if (found.found) return skipped + branch.counts[found.index];
                node = branch.children[found.index].?;
            }
        }

        /// Visits items in ascending order starting at sorted position `index`.
        ///
        /// The callback returns `true` to continue or `false` to stop early.
        /// Errors are returned to the caller.
        pub fn ascendAt(
            self: *const Self,
            comptime CtxType: type,
            index: usize,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !void {
            var i = index;
            while (i < self.len) : (i += 1) {
                const entry = self.getAt(i).?;
                if (!try yield(context, entry.key, entry.value)) return;
            }
        }

        /// Visits items in descending order starting at sorted position `index`.
        ///
        /// The callback returns `true` to continue or `false` to stop early.
        /// If the tree is empty or `index` is out of range, nothing is visited.
        pub fn descendAt(
            self: *const Self,
            comptime CtxType: type,
            index: usize,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !void {
            if (self.len == 0 or index >= self.len) return;
            var i = index;
            while (true) {
                const entry = self.getAt(i).?;
                if (!try yield(context, entry.key, entry.value)) return;
                if (i == 0) break;
                i -= 1;
            }
        }

        // Converts a failed internal consistency check into a testable error.
        fn expectInvariant(ok: bool) !void {
            if (!ok) return error.InvariantViolation;
        }

        // Recursively validates ordering, node sizes, leaf depth, and cached
        // subtree counts. Returns the actual number of items under `node`.
        fn checkNode(
            self: *const Self,
            node: *const Node,
            is_root: bool,
            depth: usize,
            leaf_depth: *?usize,
            lower: ?Bound,
            upper: ?Bound,
        ) !usize {
            try expectInvariant(node.len <= max_items);
            try expectInvariant(is_root or node.len >= min_items);

            for (0..node.len) |i| {
                const item = Bound{ .key = node.keys[i], .value = node.values[i] };
                if (i > 0) {
                    try expectInvariant(compare(node.keys[i - 1], node.values[i - 1], item.key, item.value) < 0);
                }
                if (lower) |bound| try expectInvariant(compare(bound.key, bound.value, item.key, item.value) < 0);
                if (upper) |bound| try expectInvariant(compare(item.key, item.value, bound.key, bound.value) < 0);
            }

            const branch = node.branch orelse {
                if (leaf_depth.*) |expected| {
                    try expectInvariant(depth == expected);
                } else {
                    leaf_depth.* = depth;
                }
                return node.len;
            };

            var total: usize = node.len;
            for (0..node.len + 1) |i| {
                const child = branch.children[i] orelse return error.InvariantViolation;
                const child_lower = if (i == 0) lower else Bound{ .key = node.keys[i - 1], .value = node.values[i - 1] };
                const child_upper = if (i == node.len) upper else Bound{ .key = node.keys[i], .value = node.values[i] };
                const count = try self.checkNode(child, false, depth + 1, leaf_depth, child_lower, child_upper);
                try expectInvariant(branch.counts[i] == count);
                total += count;
            }
            return total;
        }

        /// Verifies the tree's internal structure.
        ///
        /// Useful in tests and debug checks. It validates sorted order, B-tree
        /// node size rules, balanced leaf depth, and stored subtree counts.
        pub fn checkInvariants(self: *const Self) !void {
            const root = self.root orelse {
                try expectInvariant(self.len == 0);
                return;
            };

            var leaf_depth: ?usize = null;
            const count = try self.checkNode(root, true, 0, &leaf_depth, null, null);
            try expectInvariant(count == self.len);
        }

        /// Frees every node owned by the tree and resets it to empty.
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
