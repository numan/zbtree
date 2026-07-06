const std = @import("std");
const mem = std.mem;
const node_storage = @import("node_storage.zig");
const testing = std.testing;

pub const SearchMode = enum {
    linear,
    binary,
    auto,
};

pub const DeleteRangeOptions = struct {
    min_exclusive: bool = false,
    max_inclusive: bool = false,
};

pub fn TreeConfig(comptime K: type, comptime V: type) type {
    return struct {
        compare: fn (K, V, K, V) std.math.Order,
        use_string_prefix: bool = true,

        search_mode: SearchMode = .auto,

        copy_value: ?*const fn (mem.Allocator, V) anyerror!V = null,
        release_value: ?*const fn (mem.Allocator, V) void = null,
    };
}

/// Creates a B-tree type for the given key/value types.
///
/// `compare` defines the sort order. It receives both key and value for each
/// item, so the tree can be used as either a map-like structure or an ordered
/// collection where the value helps break ties.
pub fn Tree(
    comptime K: type,
    comptime V: type,
    comptime config: TreeConfig(K, V),
) type {
    comptime {
        if (config.use_string_prefix and K != []const u8) {
            @compileError("config.use_string_prefix requires key type to be []const u8 (string)");
        }
    }
    return struct {
        const Self = @This();

        const compare = config.compare;

        const storage = node_storage.NodeStorage(K, V, config.use_string_prefix);

        pub const fanout = storage.fanout;
        pub const max_items = storage.max_items;
        pub const min_items = storage.min_items;

        const Node = storage.Node;
        const Branch = storage.Branch;
        const InternalNode = storage.InternalNode;

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

            fn init(key: K, value: V) @This() {
                return .{ .key = key, .value = value };
            }
        };

        const RankResult = struct {
            index: usize,
            found: bool,

            fn init(index: usize, found: bool) RankResult {
                return .{ .index = index, .found = found };
            }
        };

        pub const Entry = struct {
            key: K,
            value: V,

            fn init(key: K, value: V) @This() {
                return .{ .key = key, .value = value };
            }
        };

        /// Owned result returned by range deletion operations.
        ///
        /// Returned entries are stored lazily as detached tree chunks plus small
        /// boundary item slices. Iterate with `ascent`; call `deinit` to release
        /// removed values and detached nodes.
        pub const DeleteRangeResult = struct {
            removed_count: usize,
            chunks: []Chunk,
            chunk_count: usize,

            const Chunk = struct {
                node: ?*Node = null,
                items: []Entry = &.{},
            };

            pub fn len(result: @This()) usize {
                return result.removed_count;
            }

            pub fn ascent(
                result: @This(),
                comptime CtxType: type,
                context: CtxType,
                comptime yield: fn (CtxType, K, V) anyerror!void,
            ) !void {
                for (result.chunks[0..result.chunk_count]) |chunk| {
                    if (chunk.node) |node| try visitAsc(CtxType, node, context, yield);
                    for (chunk.items) |item| try yield(context, item.key, item.value);
                }
            }

            pub fn deinit(result: @This(), gpa: mem.Allocator) void {
                var owner = Self{};
                for (result.chunks[0..result.chunk_count]) |chunk| {
                    if (chunk.node) |node| owner.releaseNode(gpa, node);
                    for (chunk.items) |item| releaseValue(gpa, item.value);
                    if (chunk.items.len != 0) gpa.free(chunk.items);
                }
                gpa.free(result.chunks);
            }
        };

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
        copied: bool = false,

        fn releaseValue(gpa: mem.Allocator, value: V) void {
            if (config.release_value) |release| release(gpa, value);
        }

        fn copyValue(gpa: mem.Allocator, value: V) !V {
            if (config.copy_value) |copyFn| return try copyFn(gpa, value);
            return value;
        }

        fn keyCompare(a_key: K, a_value: V, b_key: K, b_value: V) std.math.Order {
            return compare(a_key, a_value, b_key, b_value);
        }

        fn useBinarySearch() bool {
            return switch (config.search_mode) {
                .linear => false,
                .binary => true,
                .auto => K == []const u8 or @sizeOf(K) > @sizeOf(usize) * 2,
            };
        }

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

        // Allocates one node. Internal nodes colocate Branch data in the same
        // allocation as the Node.
        fn newNode(self: *Self, gpa: mem.Allocator, leaf: bool) !*Node {
            _ = self;

            if (leaf) {
                const node = try gpa.create(Node);
                node.* = Node.init();
                return node;
            }

            const internal = try gpa.create(InternalNode);
            internal.* = .{ .node = Node.init(), .branch = Branch.init() };
            internal.node.branch = &internal.branch;
            return &internal.node;
        }

        // Recursively frees a node, all of its descendants, and branch data.
        fn destroyNode(self: *Self, gpa: mem.Allocator, node: *Node) void {
            for (0..node.len) |i| releaseValue(gpa, node.values[i]);

            if (node.branch) |branch| {
                for (0..node.len + 1) |i| {
                    self.releaseNode(gpa, branch.children[i]);
                }
                const internal: *InternalNode = @fieldParentPtr("branch", branch);
                gpa.destroy(internal);
                return;
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
            const right_items_start = median + 1;
            @memcpy(right.keys[0..right.len], node.keys[right_items_start..max_items]);
            @memcpy(right.values[0..right.len], node.values[right_items_start..max_items]);

            if (config.use_string_prefix and right.branch != null) {
                for (0..right.len) |prefix_index| setPrefix(right, prefix_index);
            }

            if (node.branch) |left_branch| {
                const right_branch = right.branch.?;
                @memcpy(right_branch.children[0 .. right.len + 1], left_branch.children[right_items_start .. max_items + 1]);
                @memcpy(right_branch.counts[0 .. right.len + 1], left_branch.counts[right_items_start .. max_items + 1]);
                @memset(left_branch.children[right_items_start .. max_items + 1], null);
                @memset(left_branch.counts[right_items_start .. max_items + 1], 0);
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
        //TODO: Should we inline this?
        fn searchNode(node: *const Node, key: K, value: V) SearchResult {
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            return searchNodeWithPrefix(node, key, value, prefix);
        }

        //TODO: Should we inline this?
        fn searchNodeWithPrefix(node: *const Node, key: K, value: V, prefix: u64) SearchResult {
            if (comptime config.use_string_prefix) {
                if (!node.isLeaf()) return seachBranchWithPrefixes(node, key, value, prefix);
            }

            if (comptime useBinarySearch()) return searchNodeBinary(node, key, value);
            return searchNodeLinear(node, key, value);
        }

        fn seachBranchWithPrefixes(node: *const Node, key: []const u8, value: V, wanted: u64) SearchResult {
            const branch = node.branch.?;
            if (wanted > branch.prefixes[node.len - 1]) return SearchResult.init(node.len, false);

            var i: usize = 0;
            while (i < node.len) : (i += 1) {
                const prefix = branch.prefixes[i];
                if (prefix < wanted) continue;
                if (prefix > wanted) return SearchResult.init(i, false);

                const c = keyCompare(node.keys[i], node.values[i], key, value);
                if (c == .gt or c == .eq) return SearchResult.init(i, c == .eq);
            }

            return SearchResult.init(i, false);
        }

        fn searchNodeLinear(node: *const Node, key: K, value: V) SearchResult {
            if (node.len == 0) return SearchResult.init(0, false);

            const last = node.len - 1;
            const last_cmp = keyCompare(node.keys[last], node.values[last], key, value);

            if (last_cmp == .lt) return SearchResult.init(node.len, false);
            if (last_cmp == .eq) return SearchResult.init(last, true);

            var i: usize = 0;
            //TODO: Can we apply SIMD here?
            while (true) : (i += 1) {
                const c = keyCompare(node.keys[i], node.values[i], key, value);
                if (c == .gt or c == .eq) return SearchResult.init(i, c == .eq);
            }
        }

        fn searchNodeBinary(node: *const Node, key: K, value: V) SearchResult {
            if (node.len == 0) return SearchResult.init(0, false);

            const last = node.len - 1;
            const last_cmp = keyCompare(node.keys[last], node.values[last], key, value);
            if (last_cmp == .lt) return SearchResult.init(node.len, false);
            if (last_cmp == .eq) return SearchResult.init(last, true);

            var low: usize = 0;
            var high: usize = last;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (keyCompare(node.keys[mid], node.values[mid], key, value) == .lt) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            return SearchResult.init(low, keyCompare(node.keys[low], node.values[low], key, value) == .eq);
        }
        // Inserts one item into a non-full node by shifting later items right.
        fn insertItemAt(node: *Node, index: usize, key: K, value: V) void {
            std.debug.assert(node.len < max_items);

            if (index < node.len) {
                if (comptime @sizeOf(K) != 0) @memmove(node.keys[index + 1 .. node.len + 1], node.keys[index..node.len]);
                if (comptime @sizeOf(V) != 0) @memmove(node.values[index + 1 .. node.len + 1], node.values[index..node.len]);
                if (config.use_string_prefix) {
                    if (node.branch) |b| @memmove(b.prefixes[index + 1 .. node.len + 1], b.prefixes[index..node.len]);
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
            std.debug.assert(index <= node.len + 1);

            if (index < node.len + 1) {
                @memmove(branch.children[index + 1 .. node.len + 2], branch.children[index .. node.len + 1]);
                @memmove(branch.counts[index + 1 .. node.len + 2], branch.counts[index .. node.len + 1]);
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

            insertChildAt(parent, child_index + 1, split.right);
            insertItemAt(parent, child_index, split.key, split.value);
            branch.counts[child_index] = subtreeCount(branch.children[child_index]);
        }

        // Inserts into a node that is known not to be full. Returns false when
        // the comparator says an equal item already exists.
        fn insertIntoNonFull(self: *Self, gpa: mem.Allocator, node: *Node, key: K, value: V) !bool {
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            return self.insertIntoNonFullWithPrefix(gpa, node, key, value, prefix);
        }

        fn insertIntoNonFullWithPrefix(
            self: *Self,
            gpa: mem.Allocator,
            node: *Node,
            key: K,
            value: V,
            prefix: u64,
        ) !bool {
            const found = searchNodeWithPrefix(node, key, value, prefix);
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
                const cmp = keyCompare(node.keys[child_index], node.values[child_index], key, value);
                if (cmp == .eq) return false;
                if (cmp == .lt) child_index += 1;
            }

            const child = branch.children[child_index].?;
            if (child.isLeaf()) {
                const child_found = searchNodeWithPrefix(child, key, value, prefix);
                if (child_found.found) return false;
                insertItemAt(child, child_found.index, key, value);
                branch.counts[child_index] += 1;
                return true;
            }

            const inserted = try self.insertIntoNonFullWithPrefix(gpa, child, key, value, prefix);
            if (inserted) branch.counts[child_index] += 1;
            return inserted;
        }

        fn insertLeftEdgeIntoNonFull(self: *Self, gpa: mem.Allocator, node: *Node, key: K, value: V) !void {
            if (node.isLeaf()) {
                insertItemAt(node, 0, key, value);
                return;
            }

            const branch = node.branch.?;
            try self.makeUniqueChild(gpa, node, 0);
            if (branch.children[0].?.len == max_items) try self.splitChild(gpa, node, 0);

            try self.insertLeftEdgeIntoNonFull(gpa, branch.children[0].?, key, value);
            branch.counts[0] += 1;
        }

        fn insertRightEdgeIntoNonFull(self: *Self, gpa: mem.Allocator, node: *Node, key: K, value: V) !void {
            if (node.isLeaf()) {
                insertItemAt(node, node.len, key, value);
                return;
            }

            const branch = node.branch.?;
            var child_index: usize = node.len;
            try self.makeUniqueChild(gpa, node, child_index);
            if (branch.children[child_index].?.len == max_items) {
                try self.splitChild(gpa, node, child_index);
                child_index += 1;
            }

            try self.insertRightEdgeIntoNonFull(gpa, branch.children[child_index].?, key, value);
            branch.counts[child_index] += 1;
        }

        pub fn insert(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            try self.makeUniqueRoot(gpa);
            if (self.root == null) {
                self.root = try self.newNode(gpa, true);
                insertItemAt(self.root.?, 0, key, value);
                self.len = 1;
                return true;
            }

            if (self.root.?.len == max_items) try self.splitRoot(gpa);
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            const inserted = try self.insertIntoNonFullWithPrefix(gpa, self.root.?, key, value, prefix);
            if (inserted) self.len += 1;
            return inserted;
        }

        /// Looks up an item equal to `key`/`value` and returns its stored value.
        /// Returns `null` when no equal item exists.
        pub fn get(self: *const Self, key: K, value: V) ?V {
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            while (true) {
                const found = searchNodeWithPrefix(node, key, value, prefix);
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
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;
            while (true) {
                const found = searchNodeWithPrefix(node, key, val, prefix);
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
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;

            while (true) {
                const found = searchNodeWithPrefix(node, key, val, prefix);
                if (!found.found and found.index < node.len) candidate = Entry.init(node.keys[found.index], node.values[found.index]);

                if (found.found) {
                    if (node.branch) |branch| return minEntry(branch.children[found.index + 1].?);
                    return if (found.index + 1 < node.len) Entry.init(node.keys[found.index + 1], node.values[found.index + 1]) else candidate;
                }

                if (node.branch) |branch| node = branch.children[found.index].? else return candidate;
            }
        }

        /// Returns the item immediately before `key`/`val` in sort order.
        ///
        /// If `key`/`val` is not present, this returns the greatest item smaller
        /// than it. Returns `null` when there is no smaller item.
        pub fn seekPrev(self: *const Self, key: K, val: V) ?Entry {
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;

            while (true) {
                const found = searchNodeWithPrefix(node, key, val, prefix);
                if (found.found) {
                    if (node.branch) |branch| return maxEntry(branch.children[found.index].?);
                    return if (found.index == 0) candidate else Entry.init(node.keys[found.index - 1], node.values[found.index - 1]);
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
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var skipped: usize = 0;

            while (true) {
                const found = searchNodeWithPrefix(node, key, val, prefix);
                if (node.isLeaf()) return if (found.found) skipped + found.index else null;

                const branch = node.branch.?;
                for (0..found.index) |i| skipped += branch.counts[i] + 1;
                if (found.found) return skipped + branch.counts[found.index];
                node = branch.children[found.index].?;
            }
        }

        fn visitAscFrom(
            comptime CtxType: type,
            node: *const Node,
            index: usize,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !bool {
            if (node.isLeaf()) {
                for (index..node.len) |i| {
                    if (!try yield(ctx, node.keys[i], node.values[i])) return false;
                }
                return true;
            }

            const branch = node.branch.?;
            var remaining = index;
            var started = false;

            for (0..node.len) |i| {
                const child_count = branch.counts[i];
                if (!started) {
                    if (remaining < child_count) {
                        if (!try visitAscFrom(CtxType, branch.children[i].?, remaining, ctx, yield)) return false;
                        started = true;
                    } else {
                        remaining -= child_count;
                    }
                } else {
                    if (!try visitAscFrom(CtxType, branch.children[i].?, 0, ctx, yield)) return false;
                }

                if (!started) {
                    if (remaining == 0) {
                        started = true;
                    } else {
                        remaining -= 1;
                    }
                }

                if (started and !try yield(ctx, node.keys[i], node.values[i])) return false;
            }

            if (!started) {
                return visitAscFrom(CtxType, branch.children[node.len].?, remaining, ctx, yield);
            }

            return visitAscFrom(CtxType, branch.children[node.len].?, 0, ctx, yield);
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
            if (index >= self.len) return;
            _ = try visitAscFrom(CtxType, self.root.?, index, context, yield);
        }

        fn visitDescAllBool(
            comptime CtxType: type,
            node: *const Node,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !bool {
            if (node.isLeaf()) {
                var i = node.len;
                while (i > 0) {
                    i -= 1;
                    if (!try yield(ctx, node.keys[i], node.values[i])) return false;
                }
                return true;
            }

            const branch = node.branch.?;
            if (!try visitDescAllBool(CtxType, branch.children[node.len].?, ctx, yield)) return false;
            var i = node.len;
            while (i > 0) {
                i -= 1;
                if (!try yield(ctx, node.keys[i], node.values[i])) return false;
                if (!try visitDescAllBool(CtxType, branch.children[i].?, ctx, yield)) return false;
            }
            return true;
        }

        fn visitDescLowerChildren(
            comptime CtxType: type,
            node: *const Node,
            start_child: usize,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !bool {
            const branch = node.branch.?;
            var i = start_child;
            while (i > 0) {
                i -= 1;
                if (!try yield(ctx, node.keys[i], node.values[i])) return false;
                if (!try visitDescAllBool(CtxType, branch.children[i].?, ctx, yield)) return false;
            }
            return true;
        }

        fn visitDescFrom(
            comptime CtxType: type,
            node: *const Node,
            index: usize,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !bool {
            if (node.isLeaf()) {
                var i = index + 1;
                while (i > 0) {
                    i -= 1;
                    if (!try yield(ctx, node.keys[i], node.values[i])) return false;
                }
                return true;
            }

            const branch = node.branch.?;
            var remaining = index;
            for (0..node.len) |i| {
                const child_count = branch.counts[i];
                if (remaining < child_count) {
                    if (!try visitDescFrom(CtxType, branch.children[i].?, remaining, ctx, yield)) return false;
                    return visitDescLowerChildren(CtxType, node, i, ctx, yield);
                }
                remaining -= child_count;

                if (remaining == 0) {
                    if (!try yield(ctx, node.keys[i], node.values[i])) return false;
                    if (!try visitDescAllBool(CtxType, branch.children[i].?, ctx, yield)) return false;
                    return visitDescLowerChildren(CtxType, node, i, ctx, yield);
                }
                remaining -= 1;
            }

            if (!try visitDescFrom(CtxType, branch.children[node.len].?, remaining, ctx, yield)) return false;
            return visitDescLowerChildren(CtxType, node, node.len, ctx, yield);
        }

        /// Visits items in descending order starting at sorted position `index`.
        ///
        /// The callback returns `true` to continue or `false` to stop early.
        /// If the tree is empty, nothing is visited. If `index` is out of range,
        /// traversal starts from the last item.
        pub fn descendAt(
            self: *const Self,
            comptime CtxType: type,
            index: usize,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !void {
            if (self.len == 0) return;
            const start = if (index >= self.len) self.len - 1 else index;
            _ = try visitDescFrom(CtxType, self.root.?, start, context, yield);
        }

        // Finds a slot that may be mutated by cloning each shared node on the
        // search path before reaching it.
        fn findSlotForWrite(self: *Self, gpa: mem.Allocator, key: K, val: V) !?Slot {
            try self.makeUniqueRoot(gpa);
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            while (true) {
                const found = searchNodeWithPrefix(node, key, val, prefix);
                if (found.found) return Slot.init(node, found.index);
                if (node.branch) |branch| {
                    try self.makeUniqueChild(gpa, node, found.index);
                    node = branch.children[found.index].?;
                } else return null;
            }
        }

        /// Replaces the stored value for an item equal to `key`/`val`.
        ///
        /// Returns the old value when an equal item exists, or `null` when no
        /// matching item is present. The tree length and sort position are
        /// unchanged.
        pub fn replace(self: *Self, gpa: mem.Allocator, key: K, val: V) !?V {
            const slot = (try self.findSlotForWrite(gpa, key, val)) orelse return null;
            const old = slot.node.values[slot.index];
            slot.node.values[slot.index] = val;
            return old;
        }

        /// Inserts `key`/`val` or replaces the value of an equal existing item.
        ///
        /// Returns the old value when an item was replaced, or `null` when a new
        /// item was inserted.
        pub fn set(self: *Self, gpa: mem.Allocator, key: K, val: V) !?V {
            if (try self.findSlotForWrite(gpa, key, val)) |slot| {
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

            if (index + 1 < node.len) {
                if (comptime @sizeOf(K) != 0) @memmove(node.keys[index .. node.len - 1], node.keys[index + 1 .. node.len]);
                if (comptime @sizeOf(V) != 0) @memmove(node.values[index .. node.len - 1], node.values[index + 1 .. node.len]);
                if (config.use_string_prefix) {
                    if (node.branch) |b| @memmove(b.prefixes[index .. node.len - 1], b.prefixes[index + 1 .. node.len]);
                }
            }
            node.len -= 1;
            return removed;
        }

        // Returns the smallest item reachable from `node` by following the
        // leftmost child pointers down to a leaf.
        fn minEntry(node: *const Node) Entry {
            var current = node;
            while (current.branch) |branch| current = branch.children[0].?;
            return Entry.init(current.keys[0], current.values[0]);
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
            if (old != null) {
                self.len -= 1;
                self.collapseEmptyRoot(gpa);
            }
            return old;
        }

        fn collapseEmptyRoot(self: *Self, gpa: mem.Allocator) void {
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
        }

        // Recursive deletion implementation. It removes directly from leaves,
        // replaces internal matches with their left-subtree predecessor, and
        // rebalances any child that drops below the minimum size.
        fn deleteFromNode(self: *Self, gpa: mem.Allocator, node: *Node, key: K, val: V) anyerror!?V {
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            return self.deleteFromNodeWithPrefix(gpa, node, key, val, prefix);
        }

        fn deleteFromNodeWithPrefix(self: *Self, gpa: mem.Allocator, node: *Node, key: K, val: V, prefix: u64) anyerror!?V {
            const found = searchNodeWithPrefix(node, key, val, prefix);
            if (node.isLeaf()) return if (found.found) removeItemAt(node, found.index).value else null;

            const branch = node.branch.?;
            if (found.found) {
                try self.makeUniqueChild(gpa, node, found.index);
                const old = node.values[found.index];
                const replacement = try self.deleteMaxFromNode(gpa, branch.children[found.index].?);
                node.keys[found.index] = replacement.key;
                node.values[found.index] = replacement.value;
                setPrefix(node, found.index);
                branch.counts[found.index] -= 1;
                try self.rebalanceChild(gpa, node, found.index);
                return old;
            }

            try self.makeUniqueChild(gpa, node, found.index);
            const old = try self.deleteFromNodeWithPrefix(gpa, branch.children[found.index].?, key, val, prefix);
            if (old != null) {
                branch.counts[found.index] -= 1;
                try self.rebalanceChild(gpa, node, found.index);
            }

            return old;
        }

        // Restores the minimum size rule for `parent`'s child at `child_index`
        // by borrowing from a sibling when possible or merging siblings.
        fn rebalanceChild(self: *Self, gpa: mem.Allocator, parent: *Node, child_index: usize) !void {
            if (parent.len == 0) return;

            const branch = parent.branch.?;
            if (branch.children[child_index].?.len >= min_items) return;

            var i = child_index;
            if (i == parent.len) i -= 1;

            try self.makeUniqueChild(gpa, parent, i);
            try self.makeUniqueChild(gpa, parent, i + 1);

            const left = branch.children[i].?;
            const right = branch.children[i + 1].?;

            if (left.len + right.len < max_items) {
                self.mergeChildren(gpa, parent, i);
            } else if (left.len > right.len) {
                rotateFromLeft(parent, i + 1);
            } else {
                rotateFromRight(parent, i);
            }
        }

        // Borrows the left sibling's maximum item by moving it through the
        // parent separator into the front of the underfull child.
        fn rotateFromLeft(parent: *Node, child_index: usize) void {
            const branch = parent.branch.?;
            const left = branch.children[child_index - 1].?;
            const child = branch.children[child_index].?;
            const left_index = left.len - 1;
            const promoted_key = left.keys[left_index];
            const promoted_value = left.values[left_index];

            if (child.branch) |child_branch| {
                const left_branch = left.branch.?;
                insertChildAt(child, 0, left_branch.children[left.len].?);
                child_branch.counts[0] = left_branch.counts[left.len];
                left_branch.children[left.len] = null;
                left_branch.counts[left.len] = 0;
            }

            insertItemAt(child, 0, parent.keys[child_index - 1], parent.values[child_index - 1]);
            parent.keys[child_index - 1] = promoted_key;
            parent.values[child_index - 1] = promoted_value;
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

            if (child.branch) |child_branch| {
                const right_branch = right.branch.?;
                child_branch.children[child.len + 1] = right_branch.children[0];
                child_branch.counts[child.len + 1] = right_branch.counts[0];
                @memmove(right_branch.children[0..right.len], right_branch.children[1 .. right.len + 1]);
                @memmove(right_branch.counts[0..right.len], right_branch.counts[1 .. right.len + 1]);
                right_branch.children[right.len] = null;
                right_branch.counts[right.len] = 0;
            }

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
            while (i <= parent.len) : (i += 1) {
                branch.children[i] = branch.children[i + 1];
                branch.counts[i] = branch.counts[i + 1];
            }
            branch.children[parent.len + 1] = null;
            branch.counts[parent.len + 1] = 0;
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
            if (cond) |accept| {
                const item = self.front() orelse return null;
                if (!accept(item.key, item.value)) return null;
            } else if (self.root == null) return null;

            try self.makeUniqueRoot(gpa);
            const removed = try self.deleteMinFromNode(gpa, self.root.?);
            self.len -= 1;
            self.collapseRootIfNeeded(gpa);
            return removed;
        }

        /// Removes and returns the greatest item in sort order if accepted.
        ///
        /// Returns `null` when the tree is empty or when `cond` rejects the
        /// current last item. A `null` predicate pops unconditionally.
        pub fn popBackIf(self: *Self, gpa: mem.Allocator, cond: PopCond) !?Entry {
            if (cond) |accept| {
                const item = self.back() orelse return null;
                if (!accept(item.key, item.value)) return null;
            } else if (self.root == null) return null;

            try self.makeUniqueRoot(gpa);
            const removed = try self.deleteMaxFromNode(gpa, self.root.?);
            self.len -= 1;
            self.collapseRootIfNeeded(gpa);
            return removed;
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
            try self.makeUniqueRoot(gpa);
            if (self.root == null) {
                self.root = try self.newNode(gpa, true);
                insertItemAt(self.root.?, 0, key, value);
                self.len = 1;
                return true;
            }

            if (self.front()) |first| {
                if (keyCompare(key, value, first.key, first.value) != .lt) return false;
            }

            if (self.root.?.len == max_items) try self.splitRoot(gpa);
            try self.insertLeftEdgeIntoNonFull(gpa, self.root.?, key, value);
            self.len += 1;
            return true;
        }

        /// Inserts `key`/`value` after the current last item.
        ///
        /// Returns `false` if the item does not sort strictly after the
        /// current last item or if an equal item already exists.
        pub fn pushBack(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            try self.makeUniqueRoot(gpa);
            if (self.root == null) {
                self.root = try self.newNode(gpa, true);
                insertItemAt(self.root.?, 0, key, value);
                self.len = 1;
                return true;
            }

            if (self.back()) |last| {
                if (keyCompare(last.key, last.value, key, value) != .lt) return false;
            }

            if (self.root.?.len == max_items) try self.splitRoot(gpa);
            try self.insertRightEdgeIntoNonFull(gpa, self.root.?, key, value);
            self.len += 1;
            return true;
        }

        // Returns whether `key`/`value` can occupy sorted position `index`
        // without violating its neighboring items.
        fn fitsBetween(self: *const Self, index: usize, key: K, value: V) bool {
            if (index > 0) {
                const previous = self.getAt(index - 1).?;
                if (keyCompare(previous.key, previous.value, key, value) != .lt) return false;
            }
            if (index < self.len) {
                const next = self.getAt(index).?;
                if (keyCompare(key, value, next.key, next.value) != .lt) return false;
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

        fn fitsReplacementAt(self: *const Self, index: usize, key: K, value: V) bool {
            if (index > 0) {
                const previous = self.getAt(index - 1).?;
                const cmp = keyCompare(previous.key, previous.value, key, value);
                if (cmp == .eq or cmp == .gt) return false;
            }
            if (index + 1 < self.len) {
                const next = self.getAt(index + 1).?;
                const cmp = keyCompare(key, value, next.key, next.value);
                if (cmp == .eq or cmp == .gt) return false;
            }
            return true;
        }

        fn replaceAtInNode(self: *Self, gpa: mem.Allocator, node: *Node, index: usize, key: K, value: V) !Entry {
            if (node.isLeaf()) {
                const old = Entry.init(node.keys[index], node.values[index]);
                node.keys[index] = key;
                node.values[index] = value;
                return old;
            }

            const branch = node.branch.?;
            var remaining = index;
            for (0..node.len) |i| {
                const child_count = branch.counts[i];
                if (remaining < child_count) {
                    try self.makeUniqueChild(gpa, node, i);
                    return self.replaceAtInNode(gpa, branch.children[i].?, remaining, key, value);
                }
                remaining -= child_count;
                if (remaining == 0) {
                    const old = Entry.init(node.keys[i], node.values[i]);
                    node.keys[i] = key;
                    node.values[i] = value;
                    setPrefix(node, i);
                    return old;
                }
                remaining -= 1;
            }

            try self.makeUniqueChild(gpa, node, node.len);
            return self.replaceAtInNode(gpa, branch.children[node.len].?, remaining, key, value);
        }

        /// Replaces the item at sorted position `index`.
        ///
        /// Returns the old entry on success, or `null` if `index` is out of
        /// range or the replacement does not fit between its neighbors.
        pub fn replaceAt(self: *Self, gpa: mem.Allocator, index: usize, key: K, value: V) !?Entry {
            if (index >= self.len) return null;
            if (!self.fitsReplacementAt(index, key, value)) return null;
            try self.makeUniqueRoot(gpa);
            return try self.replaceAtInNode(gpa, self.root.?, index, key, value);
        }

        fn collapseRootIfNeeded(self: *Self, gpa: mem.Allocator) void {
            while (self.root) |root| {
                if (root.len != 0) return;

                if (root.branch) |branch| {
                    self.root = branch.children[0];
                    branch.children[0] = null;
                } else {
                    self.root = null;
                }
                self.destroyNode(gpa, root);
            }
        }

        fn deleteMinFromNode(self: *Self, gpa: mem.Allocator, node: *Node) !Entry {
            if (node.isLeaf()) return removeItemAt(node, 0);

            const branch = node.branch.?;
            try self.makeUniqueChild(gpa, node, 0);
            const removed = try self.deleteMinFromNode(gpa, branch.children[0].?);
            branch.counts[0] -= 1;
            try self.rebalanceChild(gpa, node, 0);
            return removed;
        }

        fn deleteMaxFromNode(self: *Self, gpa: mem.Allocator, node: *Node) !Entry {
            if (node.isLeaf()) return removeItemAt(node, node.len - 1);

            const branch = node.branch.?;
            const child_index = node.len;
            try self.makeUniqueChild(gpa, node, child_index);
            const removed = try self.deleteMaxFromNode(gpa, branch.children[child_index].?);
            branch.counts[child_index] -= 1;
            try self.rebalanceChild(gpa, node, child_index);
            return removed;
        }

        fn deleteAtFromNode(self: *Self, gpa: mem.Allocator, node: *Node, index: usize) !Entry {
            if (node.isLeaf()) return removeItemAt(node, index);

            const branch = node.branch.?;
            var remaining = index;
            for (0..node.len) |i| {
                const child_count = branch.counts[i];
                if (remaining < child_count) {
                    try self.makeUniqueChild(gpa, node, i);
                    const removed = try self.deleteAtFromNode(gpa, branch.children[i].?, remaining);
                    branch.counts[i] -= 1;
                    try self.rebalanceChild(gpa, node, i);
                    return removed;
                }

                remaining -= child_count;

                if (remaining == 0) {
                    try self.makeUniqueChild(gpa, node, i);
                    const old = Entry.init(node.keys[i], node.values[i]);
                    const replacement = try self.deleteMaxFromNode(gpa, branch.children[i].?);
                    branch.counts[i] -= 1;
                    node.keys[i] = replacement.key;
                    node.values[i] = replacement.value;
                    setPrefix(node, i);
                    try self.rebalanceChild(gpa, node, i);
                    return old;
                }
                remaining -= 1;
            }

            const child_index = node.len;
            try self.makeUniqueChild(gpa, node, child_index);
            const removed = try self.deleteAtFromNode(gpa, branch.children[child_index].?, remaining);
            branch.counts[child_index] -= 1;
            try self.rebalanceChild(gpa, node, child_index);
            return removed;
        }

        const RangeBuilder = struct {
            const Chunk = DeleteRangeResult.Chunk;

            chunks: std.ArrayList(Chunk),
            pending_items: std.ArrayList(Entry),

            fn init() @This() {
                return .{ .chunks = .empty, .pending_items = .empty };
            }

            fn appendEntry(builder: *@This(), gpa: mem.Allocator, entry: Entry) !void {
                try builder.pending_items.append(gpa, entry);
            }

            fn appendNode(builder: *@This(), gpa: mem.Allocator, node: *Node) !void {
                try builder.flushItems(gpa);
                try builder.chunks.append(gpa, .{ .node = node });
            }

            fn appendItems(builder: *@This(), gpa: mem.Allocator, items: []Entry) !void {
                if (items.len == 0) return;
                try builder.flushItems(gpa);
                try builder.chunks.append(gpa, .{ .items = items });
            }

            fn appendBuilder(builder: *@This(), gpa: mem.Allocator, other: *@This()) !void {
                try builder.flushItems(gpa);
                try other.flushItems(gpa);
                try builder.chunks.appendSlice(gpa, other.chunks.items);
                other.chunks.clearRetainingCapacity();
            }

            fn takePendingItems(builder: *@This(), gpa: mem.Allocator) ![]Entry {
                if (builder.pending_items.items.len == 0) return &.{};
                return try builder.pending_items.toOwnedSlice(gpa);
            }

            fn flushItems(builder: *@This(), gpa: mem.Allocator) !void {
                const items = try builder.takePendingItems(gpa);
                if (items.len == 0) return;
                errdefer gpa.free(items);
                try builder.chunks.append(gpa, .{ .items = items });
            }

            fn result(builder: *@This(), gpa: mem.Allocator, removed_count: usize) !DeleteRangeResult {
                try builder.flushItems(gpa);
                const chunks = try builder.chunks.toOwnedSlice(gpa);
                return .{ .removed_count = removed_count, .chunks = chunks, .chunk_count = chunks.len };
            }

            fn releaseOwned(builder: *@This(), tree: *Self, gpa: mem.Allocator) void {
                for (builder.chunks.items) |chunk| {
                    if (chunk.node) |node| tree.releaseNode(gpa, node);
                    for (chunk.items) |item| releaseValue(gpa, item.value);
                    if (chunk.items.len != 0) gpa.free(chunk.items);
                }
                for (builder.pending_items.items) |item| releaseValue(gpa, item.value);
                builder.deinit(gpa);
            }

            fn deinit(builder: *@This(), gpa: mem.Allocator) void {
                builder.pending_items.deinit(gpa);
                builder.chunks.deinit(gpa);
            }
        };

        const DeleteRangeChunk = struct {
            start: usize = 0,
            count: usize = 0,
        };

        fn allocEntryChunk(gpa: mem.Allocator, count: usize) ![]Entry {
            return try gpa.alloc(Entry, count);
        }

        fn deleteRangeFromLeafReturning(gpa: mem.Allocator, builder: *RangeBuilder, node: *Node, offset: usize, index: usize, count: usize, depth: usize) !DeleteRangeChunk {
            const floor = if (depth == 0) 0 else min_items - 1;
            const removable = if (node.len > floor) node.len - floor else 0;
            const removed = @min(count, node.len - index, removable);
            if (removed == 0) return .{ .start = offset + index, .count = 0 };

            const items = try allocEntryChunk(gpa, removed);
            errdefer gpa.free(items);
            for (items, 0..) |*item, i| item.* = Entry.init(node.keys[index + i], node.values[index + i]);
            try builder.appendItems(gpa, items);

            if (index + removed < node.len) {
                if (comptime @sizeOf(K) != 0) @memmove(node.keys[index .. node.len - removed], node.keys[index + removed .. node.len]);
                if (comptime @sizeOf(V) != 0) @memmove(node.values[index .. node.len - removed], node.values[index + removed .. node.len]);
            }
            node.len -= @intCast(removed);
            return .{ .start = offset + index, .count = removed };
        }

        fn detachChildAndItemAt(self: *Self, gpa: mem.Allocator, builder: *RangeBuilder, node: *Node, child_index: usize) !usize {
            _ = self;
            const branch = node.branch.?;
            const child = branch.children[child_index].?;
            const removed = branch.counts[child_index] + 1;

            try builder.appendNode(gpa, child);
            try builder.appendEntry(gpa, Entry.init(node.keys[child_index], node.values[child_index]));

            if (child_index + 1 < node.len) {
                if (comptime @sizeOf(K) != 0) @memmove(node.keys[child_index .. node.len - 1], node.keys[child_index + 1 .. node.len]);
                if (comptime @sizeOf(V) != 0) @memmove(node.values[child_index .. node.len - 1], node.values[child_index + 1 .. node.len]);
                if (config.use_string_prefix) {
                    @memmove(branch.prefixes[child_index .. node.len - 1], branch.prefixes[child_index + 1 .. node.len]);
                }
            }
            @memmove(branch.children[child_index..node.len], branch.children[child_index + 1 .. node.len + 1]);
            @memmove(branch.counts[child_index..node.len], branch.counts[child_index + 1 .. node.len + 1]);

            branch.children[node.len] = null;
            branch.counts[node.len] = 0;
            node.len -= 1;
            return removed;
        }

        fn detachItemAndRightChildAt(self: *Self, gpa: mem.Allocator, builder: *RangeBuilder, node: *Node, index: usize) !usize {
            _ = self;
            const branch = node.branch.?;
            const child_index = index + 1;
            const child = branch.children[child_index].?;
            const removed = branch.counts[child_index] + 1;

            try builder.appendEntry(gpa, Entry.init(node.keys[index], node.values[index]));
            try builder.appendNode(gpa, child);

            if (index + 1 < node.len) {
                if (comptime @sizeOf(K) != 0) @memmove(node.keys[index .. node.len - 1], node.keys[index + 1 .. node.len]);
                if (comptime @sizeOf(V) != 0) @memmove(node.values[index .. node.len - 1], node.values[index + 1 .. node.len]);
                if (config.use_string_prefix) {
                    @memmove(branch.prefixes[index .. node.len - 1], branch.prefixes[index + 1 .. node.len]);
                }
            }
            @memmove(branch.children[child_index..node.len], branch.children[child_index + 1 .. node.len + 1]);
            @memmove(branch.counts[child_index..node.len], branch.counts[child_index + 1 .. node.len + 1]);

            branch.children[node.len] = null;
            branch.counts[node.len] = 0;
            node.len -= 1;
            return removed;
        }

        fn deleteRangeChunkFromNode(self: *Self, gpa: mem.Allocator, builder: *RangeBuilder, node: *Node, offset: usize, index: usize, count: usize, depth: usize) anyerror!DeleteRangeChunk {
            if (node.isLeaf()) return deleteRangeFromLeafReturning(gpa, builder, node, offset, index, count, depth);

            const branch = node.branch.?;
            var i: usize = 0;
            var child_offset = offset;
            var child_index = index;
            var found_separator = false;

            while (i < node.len) : (i += 1) {
                const child_count = branch.counts[i];
                if (child_index <= child_count) {
                    if (child_index == child_count) {
                        child_offset += child_count;
                        found_separator = true;
                    }
                    break;
                }
                child_index -= child_count + 1;
                child_offset += child_count + 1;
            }

            if (found_separator and node.len > min_items and count > branch.counts[i + 1]) {
                return .{ .start = child_offset, .count = try self.detachItemAndRightChildAt(gpa, builder, node, i) };
            }

            if (found_separator) {
                const removed = try self.deleteAtFromNode(gpa, node, index);
                try builder.appendEntry(gpa, removed);
                return .{ .start = child_offset, .count = 1 };
            }

            var taken: usize = 0;
            var remaining_count = count;
            var chunk: DeleteRangeChunk = .{};
            while (child_index == 0 and i < node.len and node.len > min_items and remaining_count > branch.counts[i]) {
                if (taken == 0) chunk.start = child_offset;
                const removed = try self.detachChildAndItemAt(gpa, builder, node, i);
                chunk.count += removed;
                remaining_count -= removed;
                taken += 1;
            }
            if (taken > 0) return chunk;

            while (child_index > 0 and i < node.len and node.len > min_items and remaining_count > (branch.counts[i] - child_index) + branch.counts[i + 1] + 1) {
                if (taken == 0) chunk.start = child_offset + branch.counts[i];
                const removed = try self.detachItemAndRightChildAt(gpa, builder, node, i);
                chunk.count += removed;
                remaining_count -= removed;
                taken += 1;
            }
            if (taken > 0) return chunk;

            try self.makeUniqueChild(gpa, node, i);
            const deleted = try self.deleteRangeChunkFromNode(gpa, builder, branch.children[i].?, child_offset, child_index, count, depth + 1);
            branch.counts[i] -= deleted.count;
            if (branch.children[i].?.len < min_items) try self.rebalanceChild(gpa, node, i);
            return deleted;
        }

        fn deleteRangeChunkFromRoot(self: *Self, gpa: mem.Allocator, builder: *RangeBuilder, index: usize, count: usize) anyerror!DeleteRangeChunk {
            try self.makeUniqueRoot(gpa);
            const deleted = try self.deleteRangeChunkFromNode(gpa, builder, self.root.?, 0, index, count, 0);
            self.len -= deleted.count;
            self.collapseRootIfNeeded(gpa);
            return deleted;
        }

        fn deleteRangeRecursive(self: *Self, gpa: mem.Allocator, builder: *RangeBuilder, index: usize, count: usize) anyerror!usize {
            const end = index + count;
            var chunk_builder = RangeBuilder.init();
            var chunk_appended = false;
            errdefer if (!chunk_appended) chunk_builder.releaseOwned(self, gpa);

            const deleted = try self.deleteRangeChunkFromRoot(gpa, &chunk_builder, index, count);
            if (deleted.count == 0) {
                chunk_builder.deinit(gpa);
                return 0;
            }

            var removed: usize = deleted.count;
            if (deleted.start > index) {
                removed += try self.deleteRangeRecursive(gpa, builder, index, deleted.start - index);
            }

            try builder.appendBuilder(gpa, &chunk_builder);
            chunk_appended = true;
            chunk_builder.deinit(gpa);

            const deleted_end = deleted.start + deleted.count;
            if (deleted_end < end) {
                removed += try self.deleteRangeRecursive(gpa, builder, index, end - deleted_end);
            }
            return removed;
        }

        /// Removes and returns the item at sorted position `index`.
        ///
        /// Returns `null` when `index` is out of range.
        pub fn deleteAt(self: *Self, gpa: mem.Allocator, index: usize) !?Entry {
            if (index >= self.len) return null;
            if (index == 0) return self.popFront(gpa);
            if (index == self.len - 1) return self.popBack(gpa);

            try self.makeUniqueRoot(gpa);
            const removed = try self.deleteAtFromNode(gpa, self.root.?, index);
            self.len -= 1;
            self.collapseRootIfNeeded(gpa);
            return removed;
        }

        fn rankOf(self: *const Self, key: K, value: V) RankResult {
            var node = self.root orelse return RankResult.init(0, false);
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var skipped: usize = 0;

            while (true) {
                const found = searchNodeWithPrefix(node, key, value, prefix);
                if (node.isLeaf()) return RankResult.init(found.index + skipped, found.found);

                const branch = node.branch.?;
                for (0..found.index) |i| skipped += branch.counts[i] + 1;
                if (found.found) return RankResult.init(skipped + branch.counts[found.index], true);

                node = branch.children[found.index].?;
            }
        }

        /// Removes up to `count` items starting at sorted position `index`.
        ///
        /// Ranges past the end are clamped, and empty or out-of-range requests
        /// remove nothing. The returned result lazily owns the removed entries
        /// in sorted order; callers must call `DeleteRangeResult.deinit` unless
        /// they intentionally transfer ownership to a longer-lived allocator.
        pub fn deleteRangeAt(self: *Self, gpa: mem.Allocator, index: usize, count: usize, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            if (index >= self.len or count == 0) return .{ .removed_count = 0, .chunks = &.{}, .chunk_count = 0 };

            var start = index;
            var end = @min(index + count, self.len);
            if (comptime opts.min_exclusive) start += 1;
            if (comptime opts.max_inclusive) end = @min(end + 1, self.len);
            if (end <= start) return .{ .removed_count = 0, .chunks = &.{}, .chunk_count = 0 };

            const limit = end - start;
            var builder = RangeBuilder.init();
            errdefer builder.releaseOwned(self, gpa);

            if (start == 0 and limit == self.len) {
                if (self.root) |root| try builder.appendNode(gpa, root);
                self.root = null;
                self.len = 0;
                return builder.result(gpa, limit);
            }

            const removed = try self.deleteRangeRecursive(gpa, &builder, start, limit);
            return builder.result(gpa, removed);
        }

        fn deleteRangeByRank(self: *Self, gpa: mem.Allocator, min_rank: RankResult, max_rank: RankResult, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            var start = min_rank.index;
            if (opts.min_exclusive and min_rank.found) start += 1;

            var end = max_rank.index;
            if (opts.max_inclusive and max_rank.found) end += 1;

            if (end <= start) return .{ .removed_count = 0, .chunks = &.{}, .chunk_count = 0 };
            return self.deleteRangeAt(gpa, start, end - start, .{});
        }

        pub fn deleteRange(
            self: *Self,
            gpa: mem.Allocator,
            min_key: K,
            min_value: V,
            max_key: K,
            max_value: V,
            comptime opts: DeleteRangeOptions,
        ) !DeleteRangeResult {
            return self.deleteRangeByRank(gpa, self.rankOf(min_key, min_value), self.rankOf(max_key, max_value), opts);
        }

        /// Removes every item and releases all nodes owned by this tree.
        pub fn clear(self: *Self, gpa: mem.Allocator) void {
            self.releaseNode(gpa, self.root);
            self.root = null;
            self.len = 0;
        }

        /// Removes every item from sorted position `index` through the end.
        ///
        /// Returns an owned range deletion result.
        pub fn deleteAllAt(self: *Self, gpa: mem.Allocator, index: usize, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.deleteRangeAt(gpa, index, self.len - @min(index, self.len), opts);
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
                    try expectInvariant(keyCompare(node.keys[i - 1], node.values[i - 1], item.key, item.value) == .lt);
                }
                if (lower) |bound| try expectInvariant(keyCompare(bound.key, bound.value, item.key, item.value) == .lt);
                if (upper) |bound| try expectInvariant(keyCompare(item.key, item.value, bound.key, bound.value) == .lt);
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
            self.copied = true;
            return .{ .root = self.root, .len = self.len, .copied = true };
        }

        // Allocates a private copy of one node. Internal-node children remain
        // shared and have their reference counts incremented.
        fn cloneNode(self: *Self, gpa: mem.Allocator, node: *Node) !*Node {
            const clone = try self.newNode(gpa, node.isLeaf());
            errdefer self.destroyNode(gpa, clone);

            clone.len = 0;
            for (0..node.len) |i| {
                clone.values[i] = try copyValue(gpa, node.values[i]);
                clone.len += 1;
            }
            @memcpy(&clone.keys, &node.keys);

            if (node.branch) |branch| {
                const clone_branch = clone.branch.?;
                if (comptime config.use_string_prefix) @memcpy(&clone_branch.prefixes, &branch.prefixes);

                @memcpy(&clone_branch.counts, &branch.counts);
                @memcpy(&clone_branch.children, &branch.children);

                for (0..node.len + 1) |i| retainNode(branch.children[i]);
            }

            return clone;
        }

        // Clones the root when it is shared with another copy-on-write tree.
        fn makeUniqueRoot(self: *Self, gpa: mem.Allocator) !void {
            if (!self.copied) return;
            const root = self.root orelse return;
            if (root.rc.load(.monotonic) == 0) return;
            _ = root.rc.fetchSub(1, .acq_rel);
            self.root = try self.cloneNode(gpa, root);
        }

        // Clones an internal child when it is shared with another
        // copy-on-write tree.
        fn makeUniqueChild(self: *Self, gpa: mem.Allocator, parent: *Node, child_index: usize) !void {
            if (!self.copied) return;
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

fn compareTestIntKey(a_key: isize, _: isize, b_key: isize, _: isize) std.math.Order {
    return if (a_key < b_key) .lt else if (a_key > b_key) .gt else .eq;
}

fn compareTestStringKey(a_key: []const u8, _: usize, b_key: []const u8, _: usize) std.math.Order {
    return mem.order(u8, a_key, b_key);
}

fn compareTestIntKeyOwnedValue(a_key: isize, _: []const u8, b_key: isize, _: []const u8) std.math.Order {
    return if (a_key < b_key) .lt else if (a_key > b_key) .gt else .eq;
}

fn copyTestBytes(gpa: mem.Allocator, value: []const u8) ![]const u8 {
    return try gpa.dupe(u8, value);
}

fn releaseTestBytes(gpa: mem.Allocator, value: []const u8) void {
    gpa.free(value);
}

test "core nodes allocate and deallocate" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const leaf = try tree.newNode(std.testing.allocator, true);
    tree.destroyNode(testing.allocator, leaf);

    tree.root = try tree.newNode(std.testing.allocator, false);
}

test "internal nodes coallocate branch metadata" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();

    const node = try tree.newNode(testing.allocator, false);
    const internal: *IntTree.InternalNode = @fieldParentPtr("node", node);
    try testing.expectEqual(&internal.branch, node.branch.?);

    tree.destroyNode(testing.allocator, node);
}

test "destroyNode releases every value in a full leaf" {
    const ByteTree = Tree(isize, []const u8, .{
        .compare = compareTestIntKeyOwnedValue,
        .use_string_prefix = false,
        .copy_value = copyTestBytes,
        .release_value = releaseTestBytes,
    });
    var tree = ByteTree.init();

    const node = try tree.newNode(testing.allocator, true);
    for (0..ByteTree.max_items) |i| {
        node.keys[i] = @intCast(i);
        node.values[i] = try std.fmt.allocPrint(testing.allocator, "value-{d}", .{i});
    }
    node.len = ByteTree.max_items;

    tree.destroyNode(testing.allocator, node);
}

test "destroyNode releases the rightmost child of internal nodes" {
    const ByteTree = Tree(isize, []const u8, .{
        .compare = compareTestIntKeyOwnedValue,
        .use_string_prefix = false,
        .copy_value = copyTestBytes,
        .release_value = releaseTestBytes,
    });
    var tree = ByteTree.init();

    const parent = try tree.newNode(testing.allocator, false);
    const left = try tree.newNode(testing.allocator, true);
    const right = try tree.newNode(testing.allocator, true);

    left.keys[0] = 10;
    left.values[0] = try testing.allocator.dupe(u8, "left");
    left.len = 1;

    right.keys[0] = 30;
    right.values[0] = try testing.allocator.dupe(u8, "right");
    right.len = 1;

    parent.keys[0] = 20;
    parent.values[0] = try testing.allocator.dupe(u8, "parent");
    parent.len = 1;
    parent.branch.?.children[0] = left;
    parent.branch.?.children[1] = right;
    parent.branch.?.counts[0] = ByteTree.subtreeCount(left);
    parent.branch.?.counts[1] = ByteTree.subtreeCount(right);

    tree.destroyNode(testing.allocator, parent);
}

test "node local search returns lower bound" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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

test "linear and binary node searches return matching lower bounds" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(std.testing.allocator, true);
    defer tree.destroyNode(std.testing.allocator, node);

    for ([_]isize{ 10, 20, 30, 40 }, 0..) |key, i| {
        node.keys[i] = key;
        node.values[i] = -key;
    }
    node.len = 4;

    for ([_]struct { key: isize, index: usize, found: bool }{
        .{ .key = 5, .index = 0, .found = false },
        .{ .key = 10, .index = 0, .found = true },
        .{ .key = 15, .index = 1, .found = false },
        .{ .key = 20, .index = 1, .found = true },
        .{ .key = 35, .index = 3, .found = false },
        .{ .key = 40, .index = 3, .found = true },
        .{ .key = 45, .index = 4, .found = false },
    }) |case| {
        const linear = IntTree.searchNodeLinear(node, case.key, 0);
        const binary = IntTree.searchNodeBinary(node, case.key, 0);

        try testing.expectEqual(case.index, linear.index);
        try testing.expectEqual(case.found, linear.found);
        try testing.expectEqual(case.index, binary.index);
        try testing.expectEqual(case.found, binary.found);
    }
}

test "node searches handle empty nodes" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(std.testing.allocator, true);
    defer tree.destroyNode(std.testing.allocator, node);

    const linear = IntTree.searchNodeLinear(node, 10, 0);
    const binary = IntTree.searchNodeBinary(node, 10, 0);

    try testing.expectEqual(0, linear.index);
    try testing.expect(!linear.found);
    try testing.expectEqual(0, binary.index);
    try testing.expect(!binary.found);
}

test "search mode selects linear or binary node search" {
    const LinearTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false, .search_mode = .linear });
    const BinaryTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false, .search_mode = .binary });
    var linear_tree = LinearTree.init();
    var binary_tree = BinaryTree.init();
    defer linear_tree.deinit(testing.allocator);
    defer binary_tree.deinit(testing.allocator);

    const linear_node = try linear_tree.newNode(std.testing.allocator, true);
    const binary_node = try binary_tree.newNode(std.testing.allocator, true);
    defer linear_tree.destroyNode(std.testing.allocator, linear_node);
    defer binary_tree.destroyNode(std.testing.allocator, binary_node);

    for ([_]isize{ 10, 20, 30 }, 0..) |key, i| {
        linear_node.keys[i] = key;
        linear_node.values[i] = -key;
        binary_node.keys[i] = key;
        binary_node.values[i] = -key;
    }
    linear_node.len = 3;
    binary_node.len = 3;

    const linear = LinearTree.searchNode(linear_node, 25, 0);
    const binary = BinaryTree.searchNode(binary_node, 25, 0);

    try testing.expectEqual(2, linear.index);
    try testing.expect(!linear.found);
    try testing.expectEqual(2, binary.index);
    try testing.expect(!binary.found);
}

test "prefix branch search uses prefixes before full string compare" {
    const StringTree = Tree([]const u8, usize, .{ .compare = compareTestStringKey, .use_string_prefix = true });
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    const node = try tree.newNode(std.testing.allocator, false);
    defer tree.destroyNode(std.testing.allocator, node);

    node.keys[0] = "abcdefgh-010";
    node.values[0] = 10;
    node.keys[1] = "abcdefgh-020";
    node.values[1] = 20;
    node.keys[2] = "ijklmnop-000";
    node.values[2] = 30;
    node.len = 3;
    for (0..node.len) |i| StringTree.setPrefix(node, i);

    const before_collision = StringTree.searchNodeWithPrefix(node, "abcdefgh-005", 0, StringTree.stringPrefix("abcdefgh-005"));
    const collision_match = StringTree.searchNodeWithPrefix(node, "abcdefgh-020", 0, StringTree.stringPrefix("abcdefgh-020"));
    const between_prefixes = StringTree.searchNodeWithPrefix(node, "abcdefgi", 0, StringTree.stringPrefix("abcdefgi"));
    const after_all = StringTree.searchNodeWithPrefix(node, "zzzzzzzz", 0, StringTree.stringPrefix("zzzzzzzz"));

    try testing.expectEqual(0, before_collision.index);
    try testing.expect(!before_collision.found);
    try testing.expectEqual(1, collision_match.index);
    try testing.expect(collision_match.found);
    try testing.expectEqual(2, between_prefixes.index);
    try testing.expect(!between_prefixes.found);
    try testing.expectEqual(3, after_all.index);
    try testing.expect(!after_all.found);
}

test "insertItemAt shifts items inside a leaf" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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

test "right edge insert splits a full root and updates child counts" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..IntTree.max_items + 1) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const root = tree.root.?;
    const branch = root.branch.?;
    try testing.expectEqual(1, root.len);
    try testing.expectEqual(31, root.keys[0]);
    try testing.expectEqual(31, branch.counts[0]);
    try testing.expectEqual(32, branch.counts[1]);
    try testing.expectEqual(IntTree.max_items + 1, tree.len);
    try testing.expectEqual(@as(isize, @intCast(IntTree.max_items)), tree.back().?.key);
    try tree.checkInvariants();
}

test "right edge insert splits a full rightmost child" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    const parent = try tree.newNode(testing.allocator, false);
    const left = try tree.newNode(testing.allocator, true);
    const right = try tree.newNode(testing.allocator, true);
    tree.root = parent;

    for (0..31) |i| {
        left.keys[i] = @intCast(i);
        left.values[i] = -@as(isize, @intCast(i));
    }
    left.len = 31;

    for (0..IntTree.max_items) |i| {
        const key: isize = @intCast(32 + i);
        right.keys[i] = key;
        right.values[i] = -key;
    }
    right.len = IntTree.max_items;

    parent.keys[0] = 31;
    parent.values[0] = -31;
    parent.len = 1;
    parent.branch.?.children[0] = left;
    parent.branch.?.children[1] = right;
    parent.branch.?.counts[0] = IntTree.subtreeCount(left);
    parent.branch.?.counts[1] = IntTree.subtreeCount(right);
    tree.len = 95;

    try tree.insertRightEdgeIntoNonFull(testing.allocator, parent, 95, -95);
    tree.len += 1;

    const branch = parent.branch.?;
    try testing.expectEqual(2, parent.len);
    try testing.expectEqual(31, parent.keys[0]);
    try testing.expectEqual(63, parent.keys[1]);
    try testing.expectEqual(31, branch.counts[0]);
    try testing.expectEqual(31, branch.counts[1]);
    try testing.expectEqual(32, branch.counts[2]);
    try testing.expectEqual(95, branch.children[2].?.keys[31]);
    try tree.checkInvariants();
}

test "maxEntry returns greatest entry from leaf and internal nodes" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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

test "rebalanceChild merges siblings when their items fit" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
        child.keys[i] = @intCast(33 + i);
        child.values[i] = -@as(isize, @intCast(33 + i));
    }
    child.len = 30;
    parent.keys[0] = 32;
    parent.values[0] = -32;
    parent.len = 1;
    parent.branch.?.children[0] = left;
    parent.branch.?.children[1] = child;
    parent.branch.?.counts[0] = IntTree.subtreeCount(left);
    parent.branch.?.counts[1] = IntTree.subtreeCount(child);
    tree.len = 63;

    try tree.rebalanceChild(testing.allocator, parent, 1);

    try testing.expectEqual(0, parent.len);
    try testing.expectEqual(63, left.len);
    try testing.expect(parent.branch.?.children[1] == null);
    try testing.expectEqual(63, parent.branch.?.counts[0]);
}

test "fitsBetween validates index neighbors" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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

test "replaceAt updates leaf and internal positions without reordering" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i * 10);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const first = (try tree.replaceAt(testing.allocator, 0, -5, 5)).?;
    try testing.expectEqual(0, first.key);
    try testing.expectEqual(150, tree.len);
    try testing.expectEqual(-5, tree.getAt(0).?.key);

    const separator = (try tree.replaceAt(testing.allocator, 32, 315, -315)).?;
    try testing.expectEqual(320, separator.key);
    try testing.expectEqual(315, tree.getAt(32).?.key);
    try testing.expect(tree.indexOf(320, 0) == null);
    try testing.expectEqual(-315, tree.get(315, 0).?);

    const last_index = tree.len - 1;
    const last = (try tree.replaceAt(testing.allocator, last_index, 2000, -2000)).?;
    try testing.expectEqual(1490, last.key);
    try testing.expectEqual(2000, tree.getAt(last_index).?.key);

    try testing.expect((try tree.replaceAt(testing.allocator, 1, -5, 0)) == null);
    try testing.expect((try tree.replaceAt(testing.allocator, 1, 315, 0)) == null);
    try testing.expect((try tree.replaceAt(testing.allocator, tree.len, 3000, 0)) == null);
    try testing.expectEqual(150, tree.len);
    try tree.checkInvariants();
}

test "replaceAt refreshes prefixes for internal string keys" {
    const StringTree = Tree([]const u8, usize, .{ .compare = compareTestStringKey, .use_string_prefix = true });
    var tree = StringTree.init();
    defer tree.deinit(testing.allocator);

    var keys: [150][7]u8 = undefined;
    for (0..keys.len) |i| {
        const key = try std.fmt.bufPrint(&keys[i], "key-{d:0>3}", .{i});
        try testing.expect(try tree.insert(testing.allocator, key, i));
    }

    const replaced = (try tree.replaceAt(testing.allocator, 31, "key-031a", 3100)).?;
    try testing.expectEqualStrings("key-031", replaced.key);
    try testing.expectEqualStrings("key-031a", tree.getAt(31).?.key);
    try tree.checkInvariants();
}

test "deleteAt removes leaf separator and edge entries" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..200) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const separator = (try tree.deleteAt(testing.allocator, 31)).?;
    try testing.expectEqual(31, separator.key);
    try testing.expectEqual(-31, separator.value);
    try testing.expectEqual(199, tree.len);
    try testing.expect(tree.indexOf(31, 0) == null);
    try testing.expectEqual(32, tree.getAt(31).?.key);

    const first = (try tree.deleteAt(testing.allocator, 0)).?;
    try testing.expectEqual(0, first.key);
    try testing.expectEqual(1, tree.front().?.key);

    const last = (try tree.deleteAt(testing.allocator, tree.len - 1)).?;
    try testing.expectEqual(199, last.key);
    try testing.expectEqual(198, tree.back().?.key);

    var expected: isize = 1;
    for (0..tree.len) |i| {
        if (expected == 31) expected += 1;
        try testing.expectEqual(expected, tree.getAt(i).?.key);
        expected += 1;
    }
    try testing.expect((try tree.deleteAt(testing.allocator, tree.len)) == null);
    try tree.checkInvariants();
}

test "deleteAt collapses the root after removing every item" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..70) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    for (0..70) |i| {
        const removed = (try tree.deleteAt(testing.allocator, 0)).?;
        try testing.expectEqual(@as(isize, @intCast(i)), removed.key);
        try tree.checkInvariants();
    }

    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
    try testing.expect((try tree.deleteAt(testing.allocator, 0)) == null);
}

test "replaceAt and deleteAt clone copy-on-write paths" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i * 10);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    var copy = tree.copy();
    defer copy.deinit(testing.allocator);

    const replaced = (try copy.replaceAt(testing.allocator, 40, 405, -405)).?;
    try testing.expectEqual(400, replaced.key);
    try testing.expectEqual(400, tree.getAt(40).?.key);
    try testing.expectEqual(405, copy.getAt(40).?.key);

    const removed = (try copy.deleteAt(testing.allocator, 40)).?;
    try testing.expectEqual(405, removed.key);
    try testing.expectEqual(150, tree.len);
    try testing.expectEqual(149, copy.len);
    try testing.expectEqual(400, tree.getAt(40).?.key);
    try testing.expectEqual(410, copy.getAt(40).?.key);

    try tree.checkInvariants();
    try copy.checkInvariants();
}

test "copy retains the root until both trees release it" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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

test "makeUniqueRoot deep copies owned values" {
    const ByteTree = Tree(isize, []const u8, .{
        .compare = compareTestIntKeyOwnedValue,
        .use_string_prefix = false,
        .copy_value = copyTestBytes,
        .release_value = releaseTestBytes,
    });
    var tree = ByteTree.init();
    defer tree.deinit(testing.allocator);

    const value = try testing.allocator.dupe(u8, "owned value");
    try testing.expect(try tree.insert(testing.allocator, 10, value));

    var copy = tree.copy();
    defer copy.deinit(testing.allocator);

    try copy.makeUniqueRoot(testing.allocator);

    const original_value = tree.get(10, "").?;
    const copied_value = copy.get(10, "").?;
    try testing.expectEqualStrings("owned value", original_value);
    try testing.expectEqualStrings("owned value", copied_value);
    try testing.expect(original_value.ptr != copied_value.ptr);
}

test "makeUniqueRoot retains the rightmost child" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
    var tree = IntTree.init();
    defer tree.deinit(testing.allocator);

    for (0..150) |i| {
        const key: isize = @intCast(i);
        try testing.expect(try tree.insert(testing.allocator, key, -key));
    }

    const original_root = tree.root.?;
    const rightmost_index = original_root.len;
    const original_rightmost = original_root.branch.?.children[rightmost_index].?;

    var copy = tree.copy();
    defer copy.deinit(testing.allocator);
    try copy.makeUniqueRoot(testing.allocator);

    try testing.expectEqual(original_rightmost, copy.root.?.branch.?.children[rightmost_index].?);
    try testing.expect(original_rightmost.rc.load(.monotonic) > 0);
}

test "makeUniqueChild clones a retained child" {
    const IntTree = Tree(isize, isize, .{ .compare = compareTestIntKey, .use_string_prefix = false });
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
