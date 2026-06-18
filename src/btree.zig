const std = @import("std");
const mem = std.mem;
const testing = std.testing;

pub const TreeConfig = struct {
    use_string_prefix: bool = true,
};

/// Creates a B-tree type for the given key/value types.
///
/// `compare` defines the sort order. It receives both key and value for each
/// item, so the tree can be used as either a map-like structure or an ordered
/// collection where the value helps break ties.
pub fn Tree(
    comptime K: type,
    comptime V: type,
    comptime compare: fn (K, V, K, V) i32,
    comptime config: TreeConfig,
) type {
    comptime {
        if (config.use_string_prefix and K != []const u8) {
            @compileError("config.use_string_prefix requires key type to be []const u8 (string)");
        }
    }
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
            rc: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

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
            prefixes: if (config.use_string_prefix) [max_items]u64 else void = if (config.use_string_prefix) [_]u64{0} ** max_items else {},

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

            pub fn init(key: K, value: V) @This() {
                return .{ .key = key, .value = value };
            }
        };

        const Entry = Bound;

        /// Optional predicate used by conditional edge-pop operations.
        const PopCond = ?*const fn (K, V) bool;

        const Slot = struct {
            node: *Node,
            index: usize,

            fn init(node: *Node, index: usize) Slot {
                return .{ .node = node, .index = index };
            }
        };

        root: ?*Node = null,
        len: usize = 0,

        fn setPrefix(node: *Node, index: usize) void {
            if (config.use_string_prefix) {
                if (node.branch) |branch| branch.prefixes[index] = stringPrefix(node.keys[index]);
            }
        }

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
                    self.releaseNode(gpa, branch.children[i]);
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

            if (config.use_string_prefix and right.branch != null) {
                for (0..right.len) |prefix_index| setPrefix(right, prefix_index);
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
            setPrefix(new_root, 0);

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
            if (config.use_string_prefix and !node.isLeaf()) return seachBranchWithPrefixes(node, key, value);
            return searchNodeFull(node, key, value);
        }

        fn seachBranchWithPrefixes(node: *const Node, key: []const u8, value: V) SearchResult {
            const wanted = stringPrefix(key);
            const branch = node.branch.?;

            var i: usize = 0;
            while (i < node.len) : (i += 1) {
                const prefix = branch.prefixes[i];
                if (prefix < wanted) continue;
                if (prefix > wanted) return SearchResult.init(i, false);

                const c = compare(node.keys[i], node.values[i], key, value);
                if (c >= 0) return SearchResult.init(i, c == 0);
            }

            return SearchResult.init(i, false);
        }

        fn searchNodeFull(node: *const Node, key: K, value: V) SearchResult {
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
                if (config.use_string_prefix) {
                    if (node.branch) |b| b.prefixes[i] = b.prefixes[i - 1];
                }
            }

            node.keys[index] = key;
            node.values[index] = value;
            node.len += 1;
            setPrefix(node, index);
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
        // counts incrementally.
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
            try self.makeUniqueChild(gpa, node, child_index);
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
            try self.makeUniqueRoot(gpa);
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

        // Finds the node slot containing an item equal to `key`/`val`.
        fn findSlot(self: *Self, key: K, val: V) ?Slot {
            var node = self.root orelse return null;
            while (true) {
                const found = searchNode(node, key, val);
                if (found.found) return Slot.init(node, found.index);
                if (node.branch) |branch| node = branch.children[found.index].? else return null;
            }
        }

        /// Replaces the stored value for an item equal to `key`/`val`.
        ///
        /// Returns the old value when an equal item exists, or `null` when no
        /// matching item is present. The tree length and sort position are
        /// unchanged.
        pub fn replace(self: *Self, key: K, val: V) ?V {
            const slot = self.findSlot(key, val) orelse return null;
            const old = slot.node.values[slot.index];
            slot.node.values[slot.index] = val;
            return old;
        }

        /// Inserts `key`/`val` or replaces the value of an equal existing item.
        ///
        /// Returns the old value when an item was replaced, or `null` when a new
        /// item was inserted. Allocation is only needed when inserting.
        pub fn set(self: *Self, gpa: mem.Allocator, key: K, val: V) !?V {
            if (self.findSlot(key, val)) |slot| {
                const old = slot.node.values[slot.index];
                slot.node.keys[slot.index] = key;
                slot.node.values[slot.index] = val;
                setPrefix(slot.node, slot.index);
                return old;
            }

            _ = try self.insert(gpa, key, val);
            return null;
        }

        // Removes and returns the item at `index`, shifting later items left.
        fn removeItemAt(node: *Node, index: usize) Entry {
            const removed = Entry.init(node.keys[index], node.values[index]);
            var i = index;

            while (i + 1 < node.len) : (i += 1) {
                node.keys[i] = node.keys[i + 1];
                node.values[i] = node.values[i + 1];
                if (config.use_string_prefix) {
                    if (node.branch) |b| b.prefixes[i] = b.prefixes[i + 1];
                }
            }
            node.len -= 1;
            return removed;
        }

        // Returns the greatest item reachable from `node` by following the
        // rightmost child pointers down to a leaf.
        fn maxEntry(node: *const Node) Entry {
            var current = node;
            while (current.branch) |branch| current = branch.children[current.len].?;
            return Entry.init(current.keys[current.len - 1], current.values[current.len - 1]);
        }

        /// Removes an item equal to `key`/`val` and returns its stored value.
        ///
        /// Returns `null` when no equal item exists. Deletion may free merged
        /// nodes and may collapse an empty internal root back to its only child.
        pub fn delete(self: *Self, gpa: mem.Allocator, key: K, val: V) !?V {
            try self.makeUniqueRoot(gpa);
            return self.deleteUnique(gpa, key, val);
        }

        // Deletes from a tree whose root has already been made unique for a
        // copy-on-write mutation. Handles length updates and root collapse.
        fn deleteUnique(self: *Self, gpa: mem.Allocator, key: K, val: V) !?V {
            const old = if (self.root) |root| try self.deleteFromNode(gpa, root, key, val) else return null;
            if (old != null) self.len -= 1;

            if (self.root) |root| {
                if (root.len == 0) {
                    if (root.branch) |branch| {
                        self.root = branch.children[0];
                        branch.children[0] = null;
                        self.destroyNode(gpa, root);
                    } else {
                        self.destroyNode(gpa, root);
                        self.root = null;
                    }
                }
            }
            return old;
        }

        // Recursive deletion implementation. It removes directly from leaves,
        // replaces internal matches with their left-subtree predecessor, and
        // rebalances any child that drops below the minimum size.
        fn deleteFromNode(self: *Self, gpa: mem.Allocator, node: *Node, key: K, val: V) !?V {
            const found = searchNode(node, key, val);
            if (node.isLeaf()) return if (found.found) removeItemAt(node, found.index).value else null;

            const branch = node.branch.?;
            if (found.found) {
                try self.makeUniqueChild(gpa, node, found.index);
                const replacement = maxEntry(branch.children[found.index].?);
                const old = node.values[found.index];
                node.keys[found.index] = replacement.key;
                node.values[found.index] = replacement.value;
                setPrefix(node, found.index);
                _ = try self.deleteFromNode(gpa, branch.children[found.index].?, replacement.key, replacement.value);
                branch.counts[found.index] -= 1;
                try self.rebalanceChild(gpa, node, found.index);
                return old;
            }

            try self.makeUniqueChild(gpa, node, found.index);
            const old = try self.deleteFromNode(gpa, branch.children[found.index].?, key, val);
            if (old != null) {
                branch.counts[found.index] -= 1;
                try self.rebalanceChild(gpa, node, found.index);
            }

            return old;
        }

        // Restores the minimum size rule for `parent`'s child at `child_index`
        // by borrowing from a sibling when possible or merging siblings.
        fn rebalanceChild(self: *Self, gpa: mem.Allocator, parent: *Node, child_index: usize) !void {
            const branch = parent.branch.?;
            const child = branch.children[child_index].?;

            if (child.len >= min_items) return;

            if (child_index > 0 and branch.children[child_index - 1].?.len > min_items) {
                rotateFromLeft(parent, child_index);
            } else if (child_index < parent.len and branch.children[child_index + 1].?.len > min_items) {
                rotateFromRight(parent, child_index);
            } else if (child_index > 0) {
                self.mergeChildren(gpa, parent, child_index - 1);
            } else {
                self.mergeChildren(gpa, parent, child_index);
            }
        }

        // Borrows the left sibling's maximum item by moving it through the
        // parent separator into the front of the underfull child.
        fn rotateFromLeft(parent: *Node, child_index: usize) void {
            const branch = parent.branch.?;
            const left = branch.children[child_index - 1].?;
            const child = branch.children[child_index].?;

            insertItemAt(child, 0, parent.keys[child_index - 1], parent.values[child_index - 1]);
            parent.keys[child_index - 1] = left.keys[left.len - 1];
            parent.values[child_index - 1] = left.values[left.len - 1];
            setPrefix(parent, child_index - 1);
            left.len -= 1;
            branch.counts[child_index - 1] = subtreeCount(left);
            branch.counts[child_index] = subtreeCount(child);
        }

        // Borrows the right sibling's minimum item by moving it through the
        // parent separator into the end of the underfull child.
        fn rotateFromRight(parent: *Node, child_index: usize) void {
            const branch = parent.branch.?;
            const child = branch.children[child_index].?;
            const right = branch.children[child_index + 1].?;

            insertItemAt(child, child.len, parent.keys[child_index], parent.values[child_index]);
            parent.keys[child_index] = right.keys[0];
            parent.values[child_index] = right.values[0];
            setPrefix(parent, child_index);
            _ = removeItemAt(right, 0);
            branch.counts[child_index] = subtreeCount(child);
            branch.counts[child_index + 1] = subtreeCount(right);
        }

        // Merges the child at `left_index`, the parent separator, and the right
        // sibling into one left child, then removes the empty right sibling.
        fn mergeChildren(self: *Self, gpa: mem.Allocator, parent: *Node, left_index: usize) void {
            const branch = parent.branch.?;
            const left = branch.children[left_index].?;
            const right = branch.children[left_index + 1].?;

            insertItemAt(left, left.len, parent.keys[left_index], parent.values[left_index]);
            for (0..right.len) |i| insertItemAt(left, left.len, right.keys[i], right.values[i]);
            if (right.branch) |right_branch| {
                const left_branch = left.branch.?;
                for (0..right.len + 1) |i| {
                    left_branch.children[left.len - right.len + i] = right_branch.children[i];
                    left_branch.counts[left.len - right.len + i] = right_branch.counts[i];
                    right_branch.children[i] = null;
                }
            }

            _ = removeItemAt(parent, left_index);
            var i = left_index + 1;
            while (i <= parent.len + 1) : (i += 1) {
                branch.children[i] = branch.children[i + 1];
                branch.counts[i] = branch.counts[i + 1];
            }
            branch.counts[left_index] = subtreeCount(left);
            self.destroyNode(gpa, right);
        }

        /// Returns the smallest item in sort order.
        ///
        /// Returns `null` when the tree is empty.
        pub fn front(self: *const Self) ?Entry {
            var node = self.root orelse return null;
            while (node.branch) |branch| node = branch.children[0].?;
            return Entry.init(node.keys[0], node.values[0]);
        }

        /// Returns the greatest item in sort order.
        ///
        /// Returns `null` when the tree is empty.
        pub fn back(self: *const Self) ?Entry {
            var node = self.root orelse return null;
            while (node.branch) |branch| node = branch.children[node.len].?;
            return Entry.init(node.keys[node.len - 1], node.values[node.len - 1]);
        }

        /// Removes and returns the smallest item in sort order if accepted.
        ///
        /// Returns `null` when the tree is empty or when `cond` rejects the
        /// current first item. A `null` predicate pops unconditionally.
        pub fn popFrontIf(self: *Self, gpa: mem.Allocator, cond: PopCond) !?Entry {
            const item = self.front() orelse return null;
            if (cond) |accept| {
                if (!accept(item.key, item.value)) return null;
            }
            _ = try self.delete(gpa, item.key, item.value);
            return item;
        }

        /// Removes and returns the greatest item in sort order if accepted.
        ///
        /// Returns `null` when the tree is empty or when `cond` rejects the
        /// current last item. A `null` predicate pops unconditionally.
        pub fn popBackIf(self: *Self, gpa: mem.Allocator, cond: PopCond) !?Entry {
            const item = self.back() orelse return null;
            if (cond) |accept| {
                if (!accept(item.key, item.value)) return null;
            }
            _ = try self.delete(gpa, item.key, item.value);
            return item;
        }

        /// Removes and returns the smallest item in sort order.
        ///
        /// Returns `null` when the tree is empty.
        pub fn popFront(self: *Self, gpa: mem.Allocator) !?Entry {
            return self.popFrontIf(gpa, null);
        }

        /// Removes and returns the greatest item in sort order.
        ///
        /// Returns `null` when the tree is empty.
        pub fn popBack(self: *Self, gpa: mem.Allocator) !?Entry {
            return self.popBackIf(gpa, null);
        }

        /// Inserts `key`/`value` before the current first item.
        ///
        /// Returns `false` if the item does not sort strictly before the
        /// current first item or if an equal item already exists.
        pub fn pushFront(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            if (self.front()) |first| {
                if (compare(key, value, first.key, first.value) >= 0) return false;
            }
            return self.insert(gpa, key, value);
        }

        /// Inserts `key`/`value` after the current last item.
        ///
        /// Returns `false` if the item does not sort strictly after the
        /// current last item or if an equal item already exists.
        pub fn pushBack(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            if (self.back()) |last| {
                if (compare(last.key, last.value, key, value) >= 0) return false;
            }
            return self.insert(gpa, key, value);
        }

        // Returns whether `key`/`value` can occupy sorted position `index`
        // without violating its neighboring items.
        fn fitsBetween(self: *const Self, index: usize, key: K, value: V) bool {
            if (index > 0) {
                const previous = self.getAt(index - 1).?;
                if (compare(previous.key, previous.value, key, value) >= 0) return false;
            }
            if (index < self.len) {
                const next = self.getAt(index).?;
                if (compare(key, value, next.key, next.value) >= 0) return false;
            }
            return true;
        }

        /// Inserts `key`/`value` at sorted position `index`.
        ///
        /// Returns `false` when `index` is out of range, when the item does not
        /// fit between its neighbors, or when an equal item already exists.
        pub fn insertAt(self: *Self, gpa: mem.Allocator, index: usize, key: K, value: V) !bool {
            if (index > self.len) return false;
            if (!self.fitsBetween(index, key, value)) return false;
            return self.insert(gpa, key, value);
        }

        /// Replaces the item at sorted position `index`.
        ///
        /// Returns the old entry on success, or `null` if `index` is out of
        /// range or the replacement does not fit between its neighbors.
        pub fn replaceAt(self: *Self, gpa: mem.Allocator, index: usize, key: K, value: V) !?Entry {
            if (index >= self.len) return null;
            const old = self.getAt(index).?;
            _ = try self.delete(gpa, old.key, old.value);
            if (!self.fitsBetween(index, key, value)) {
                _ = try self.insert(gpa, old.key, old.value);
                return null;
            }

            _ = try self.insert(gpa, key, value);
            return old;
        }

        /// Removes and returns the item at sorted position `index`.
        ///
        /// Returns `null` when `index` is out of range.
        pub fn deleteAt(self: *Self, gpa: mem.Allocator, index: usize) !?Entry {
            const item = self.getAt(index) orelse return null;
            _ = try self.delete(gpa, item.key, item.value);
            return item;
        }

        /// Removes up to `count` items starting at sorted position `index`.
        ///
        /// Returns the number of items removed. Ranges past the end are
        /// clamped, and empty or out-of-range requests remove nothing.
        pub fn deleteRangeAt(self: *Self, gpa: mem.Allocator, index: usize, count: usize) !usize {
            if (index >= self.len or count == 0) return 0;

            var removed: usize = 0;
            const limit = @min(count, self.len - index);
            while (removed < limit) : (removed += 1) {
                _ = try self.deleteAt(gpa, index);
            }
            return removed;
        }

        /// Removes every item and releases all nodes owned by this tree.
        pub fn clear(self: *Self, gpa: mem.Allocator) void {
            self.releaseNode(gpa, self.root);
            self.root = null;
            self.len = 0;
        }

        /// Removes every item from sorted position `index` through the end.
        ///
        /// Returns the number of items removed.
        pub fn deleteAllAt(self: *Self, gpa: mem.Allocator, index: usize) !usize {
            return self.deleteRangeAt(gpa, index, self.len - @min(index, self.len));
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
                if (i < node.len and config.use_string_prefix) {
                    try expectInvariant(branch.prefixes[i] == stringPrefix(node.keys[i]));
                }
                const child = branch.children[i] orelse return error.InvariantViolation;
                const child_lower = if (i == 0) lower else Bound{ .key = node.keys[i - 1], .value = node.values[i - 1] };
                const child_upper = if (i == node.len) upper else Bound{ .key = node.keys[i], .value = node.values[i] };
                const count = try self.checkNode(child, false, depth + 1, leaf_depth, child_lower, child_upper);
                try expectInvariant(branch.counts[i] == count);
                total += count;
            }
            return total;
        }

        // Adds one shared owner reference to a node for copy-on-write sharing.
        fn retainNode(node: ?*Node) void {
            if (node) |n| _ = n.rc.fetchAdd(1, .monotonic);
        }

        // Releases one owner reference. If no shared owner remains, destroys
        // the node and recursively releases its children.
        fn releaseNode(self: *Self, gpa: mem.Allocator, node: ?*Node) void {
            const n = node orelse return;
            if (n.rc.load(.monotonic) > 0) {
                _ = n.rc.fetchSub(1, .acq_rel);
                return;
            }
            self.destroyNode(gpa, n);
        }

        /// Returns an O(1) copy-on-write snapshot of this tree.
        ///
        /// The copy shares nodes until either tree mutates, at which point the
        /// mutating path is cloned lazily.
        pub fn copy(self: *Self) Self {
            retainNode(self.root);
            return .{ .root = self.root, .len = self.len };
        }

        // Allocates a private copy of one node. Internal-node children remain
        // shared and have their reference counts incremented.
        fn cloneNode(self: *Self, gpa: mem.Allocator, node: *Node) !*Node {
            const clone = try self.newNode(gpa, node.isLeaf());
            clone.len = node.len;

            for (0..node.len) |i| {
                clone.keys[i] = node.keys[i];
                clone.values[i] = node.values[i];
            }

            if (node.branch) |branch| {
                const clone_branch = clone.branch.?;
                if (config.use_string_prefix) {
                    for (0..node.len) |i| clone_branch.prefixes[i] = branch.prefixes[i];
                }
                for (0..node.len + 1) |i| {
                    clone_branch.children[i] = branch.children[i];
                    clone_branch.counts[i] = branch.counts[i];
                    retainNode(branch.children[i]);
                }
            }

            return clone;
        }

        // Clones the root when it is shared with another copy-on-write tree.
        fn makeUniqueRoot(self: *Self, gpa: mem.Allocator) !void {
            const root = self.root orelse return;
            if (root.rc.load(.monotonic) == 0) return;
            _ = root.rc.fetchSub(1, .acq_rel);
            self.root = try self.cloneNode(gpa, root);
        }

        // Clones an internal child when it is shared with another
        // copy-on-write tree.
        fn makeUniqueChild(self: *Self, gpa: mem.Allocator, parent: *Node, child_index: usize) !void {
            const branch = parent.branch.?;
            const child = branch.children[child_index].?;
            if (child.rc.load(.monotonic) == 0) return;
            _ = child.rc.fetchSub(1, .acq_rel);
            branch.children[child_index] = try self.cloneNode(gpa, child);
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

        fn stringPrefix(key: []const u8) u64 {
            var bytes: [8]u8 = [_]u8{0} ** 8;
            const n = @min(bytes.len, key.len);
            @memcpy(bytes[0..n], key[0..n]);
            return mem.readInt(u64, &bytes, .big);
        }

        /// Frees every node owned by the tree and resets it to empty.
        pub fn deinit(self: *Self, gpa: mem.Allocator) void {
            self.releaseNode(gpa, self.root);
            self.root = null;
            self.len = 0;
        }
    };
}

fn compareTestIntKey(a_key: isize, _: isize, b_key: isize, _: isize) i32 {
    return if (a_key < b_key) -1 else if (a_key > b_key) 1 else 0;
}

test "core nodes allocate and deallocate" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const leaf = try tree.newNode(std.testing.allocator, true);
    tree.destroyNode(testing.allocator, leaf);

    tree.root = try tree.newNode(std.testing.allocator, false);
}

test "node local search returns lower bound" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
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

test "removeItemAt shifts later items left and returns removed entry" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(testing.allocator, true);
    defer tree.destroyNode(testing.allocator, node);

    node.keys[0] = 10;
    node.values[0] = -10;
    node.keys[1] = 20;
    node.values[1] = -20;
    node.keys[2] = 30;
    node.values[2] = -30;
    node.keys[3] = 40;
    node.values[3] = -40;
    node.len = 4;

    const removed = IntTree.removeItemAt(node, 1);

    try testing.expectEqual(20, removed.key);
    try testing.expectEqual(-20, removed.value);
    try testing.expectEqual(3, node.len);
    try testing.expectEqual(10, node.keys[0]);
    try testing.expectEqual(30, node.keys[1]);
    try testing.expectEqual(40, node.keys[2]);

    const tail = IntTree.removeItemAt(node, 2);

    try testing.expectEqual(40, tail.key);
    try testing.expectEqual(-40, tail.value);
    try testing.expectEqual(2, node.len);
    try testing.expectEqual(10, node.keys[0]);
    try testing.expectEqual(30, node.keys[1]);
}

test "splitNode promotes the median" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
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

test "maxEntry returns greatest entry from leaf and internal nodes" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const root = tree.root.?;
    const max_from_root = IntTree.maxEntry(root);
    try testing.expect(!root.isLeaf());
    try testing.expectEqual(149, max_from_root.key);
    try testing.expectEqual(-149, max_from_root.value);

    const leaf = root.branch.?.children[0].?;
    const max_from_leaf = IntTree.maxEntry(leaf);
    try testing.expect(leaf.isLeaf());
    try testing.expectEqual(30, max_from_leaf.key);
    try testing.expectEqual(-30, max_from_leaf.value);
}

test "deleteFromNode removes matching leaf entries" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(testing.allocator, true);
    tree.root = node;
    for (0..4) |i| {
        node.keys[i] = @intCast((i + 1) * 10);
        node.values[i] = -@as(isize, @intCast((i + 1) * 10));
    }
    node.len = 4;

    try testing.expectEqual(-20, (try tree.deleteFromNode(testing.allocator, node, 20, 0)).?);
    try testing.expectEqual(3, node.len);
    try testing.expectEqual(10, node.keys[0]);
    try testing.expectEqual(30, node.keys[1]);
    try testing.expectEqual(40, node.keys[2]);
    try testing.expect(try tree.deleteFromNode(testing.allocator, node, 50, 0) == null);
}

test "rotateFromLeft borrows the left sibling maximum through the parent" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const parent = try tree.newNode(testing.allocator, false);
    const left = try tree.newNode(testing.allocator, true);
    const child = try tree.newNode(testing.allocator, true);
    tree.root = parent;

    for (0..32) |i| {
        left.keys[i] = @intCast(i);
        left.values[i] = -@as(isize, @intCast(i));
    }
    left.len = 32;
    for (0..30) |i| {
        child.keys[i] = @intCast(40 + i);
        child.values[i] = -@as(isize, @intCast(40 + i));
    }
    child.len = 30;
    parent.keys[0] = 32;
    parent.values[0] = -32;
    parent.len = 1;
    parent.branch.?.children[0] = left;
    parent.branch.?.children[1] = child;
    parent.branch.?.counts[0] = IntTree.subtreeCount(left);
    parent.branch.?.counts[1] = IntTree.subtreeCount(child);

    IntTree.rotateFromLeft(parent, 1);

    try testing.expectEqual(31, left.len);
    try testing.expectEqual(31, parent.keys[0]);
    try testing.expectEqual(31, child.len);
    try testing.expectEqual(32, child.keys[0]);
    try testing.expectEqual(40, child.keys[1]);
    try testing.expectEqual(IntTree.subtreeCount(left), parent.branch.?.counts[0]);
    try testing.expectEqual(IntTree.subtreeCount(child), parent.branch.?.counts[1]);
}

test "rotateFromRight borrows the right sibling minimum through the parent" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const parent = try tree.newNode(testing.allocator, false);
    const child = try tree.newNode(testing.allocator, true);
    const right = try tree.newNode(testing.allocator, true);
    tree.root = parent;

    for (0..30) |i| {
        child.keys[i] = @intCast(i);
        child.values[i] = -@as(isize, @intCast(i));
    }
    child.len = 30;
    for (0..32) |i| {
        right.keys[i] = @intCast(31 + i);
        right.values[i] = -@as(isize, @intCast(31 + i));
    }
    right.len = 32;
    parent.keys[0] = 30;
    parent.values[0] = -30;
    parent.len = 1;
    parent.branch.?.children[0] = child;
    parent.branch.?.children[1] = right;
    parent.branch.?.counts[0] = IntTree.subtreeCount(child);
    parent.branch.?.counts[1] = IntTree.subtreeCount(right);

    IntTree.rotateFromRight(parent, 0);

    try testing.expectEqual(31, child.len);
    try testing.expectEqual(30, child.keys[30]);
    try testing.expectEqual(31, parent.keys[0]);
    try testing.expectEqual(31, right.len);
    try testing.expectEqual(32, right.keys[0]);
    try testing.expectEqual(IntTree.subtreeCount(child), parent.branch.?.counts[0]);
    try testing.expectEqual(IntTree.subtreeCount(right), parent.branch.?.counts[1]);
}

test "mergeChildren joins adjacent leaves and removes the separator" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const parent = try tree.newNode(testing.allocator, false);
    const left = try tree.newNode(testing.allocator, true);
    const right = try tree.newNode(testing.allocator, true);
    tree.root = parent;

    for (0..31) |i| {
        left.keys[i] = @intCast(i);
        left.values[i] = -@as(isize, @intCast(i));
        right.keys[i] = @intCast(32 + i);
        right.values[i] = -@as(isize, @intCast(32 + i));
    }
    left.len = 31;
    right.len = 31;
    parent.keys[0] = 31;
    parent.values[0] = -31;
    parent.len = 1;
    parent.branch.?.children[0] = left;
    parent.branch.?.children[1] = right;
    parent.branch.?.counts[0] = IntTree.subtreeCount(left);
    parent.branch.?.counts[1] = IntTree.subtreeCount(right);

    tree.mergeChildren(testing.allocator, parent, 0);

    try testing.expectEqual(0, parent.len);
    try testing.expectEqual(left, parent.branch.?.children[0].?);
    try testing.expect(parent.branch.?.children[1] == null);
    try testing.expectEqual(63, left.len);
    for (0..63) |i| {
        try testing.expectEqual(@as(isize, @intCast(i)), left.keys[i]);
        try testing.expectEqual(-@as(isize, @intCast(i)), left.values[i]);
    }
    try testing.expectEqual(63, parent.branch.?.counts[0]);
}

test "rebalanceChild borrows from a left sibling when possible" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const parent = try tree.newNode(testing.allocator, false);
    const left = try tree.newNode(testing.allocator, true);
    const child = try tree.newNode(testing.allocator, true);
    tree.root = parent;

    for (0..32) |i| {
        left.keys[i] = @intCast(i);
        left.values[i] = -@as(isize, @intCast(i));
    }
    left.len = 32;
    for (0..30) |i| {
        child.keys[i] = @intCast(40 + i);
        child.values[i] = -@as(isize, @intCast(40 + i));
    }
    child.len = 30;
    parent.keys[0] = 32;
    parent.values[0] = -32;
    parent.len = 1;
    parent.branch.?.children[0] = left;
    parent.branch.?.children[1] = child;
    parent.branch.?.counts[0] = IntTree.subtreeCount(left);
    parent.branch.?.counts[1] = IntTree.subtreeCount(child);

    try tree.rebalanceChild(testing.allocator, parent, 1);

    try testing.expectEqual(31, left.len);
    try testing.expectEqual(31, parent.keys[0]);
    try testing.expectEqual(31, child.len);
    try testing.expectEqual(32, child.keys[0]);
}

test "fitsBetween validates index neighbors" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(tree.fitsBetween(0, 10, 100));

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    try testing.expect(try tree.insert(testing.allocator, 20, 200));
    try testing.expect(try tree.insert(testing.allocator, 30, 300));

    try testing.expect(tree.fitsBetween(0, 5, 50));
    try testing.expect(!tree.fitsBetween(0, 10, 1000));
    try testing.expect(tree.fitsBetween(1, 15, 150));
    try testing.expect(!tree.fitsBetween(1, 5, 50));
    try testing.expect(!tree.fitsBetween(1, 30, 3000));
    try testing.expect(tree.fitsBetween(3, 40, 400));
    try testing.expect(!tree.fitsBetween(3, 25, 250));
}

test "copy retains the root until both trees release it" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    const root = tree.root.?;
    try testing.expectEqual(0, root.rc.load(.monotonic));

    var copy = tree.copy();
    defer copy.deinit(testing.allocator);

    try testing.expectEqual(root, copy.root.?);
    try testing.expectEqual(1, root.rc.load(.monotonic));

    copy.clear(testing.allocator);
    try testing.expectEqual(0, root.rc.load(.monotonic));
    try testing.expectEqual(100, tree.get(10, 0).?);
}

test "makeUniqueRoot clones a retained root" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    try testing.expect(try tree.insert(testing.allocator, 10, 100));
    const original_root = tree.root.?;

    var copy = tree.copy();
    defer copy.deinit(testing.allocator);

    try copy.makeUniqueRoot(testing.allocator);

    try testing.expectEqual(original_root, tree.root.?);
    try testing.expect(copy.root.? != original_root);
    try testing.expectEqual(0, original_root.rc.load(.monotonic));
    try testing.expectEqual(100, tree.get(10, 0).?);
    try testing.expectEqual(100, copy.get(10, 0).?);
}

test "makeUniqueChild clones a retained child" {
    const IntTree = Tree(isize, isize, compareTestIntKey, .{ .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const original_root = tree.root.?;
    const original_child = original_root.branch.?.children[0].?;

    var copy = tree.copy();
    defer copy.deinit(testing.allocator);
    try copy.makeUniqueRoot(testing.allocator);

    try testing.expectEqual(original_child, copy.root.?.branch.?.children[0].?);
    try testing.expect(original_child.rc.load(.monotonic) > 0);

    try copy.makeUniqueChild(testing.allocator, copy.root.?, 0);

    try testing.expectEqual(original_child, tree.root.?.branch.?.children[0].?);
    try testing.expect(copy.root.?.branch.?.children[0].? != original_child);
    try testing.expectEqual(0, original_child.rc.load(.monotonic));
}
