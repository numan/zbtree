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

pub fn MapConfig(comptime K: type, comptime V: type) type {
    return struct {
        use_string_prefix: bool = K == []const u8,
        search_mode: SearchMode = .auto,

        copy_value: ?*const fn (mem.Allocator, V) anyerror!V = null,
        release_value: ?*const fn (mem.Allocator, V) void = null,
    };
}

fn orderedKeySupported(comptime K: type) bool {
    if (K == []const u8) return true;
    return switch (@typeInfo(K)) {
        .int, .comptime_int, .float, .comptime_float, .bool, .@"enum" => true,
        else => false,
    };
}

/// btype.Map-like key/value collection.
///
/// Items are ordered and identified by key only. Values never participate in
/// ordering, so inserting the same key with a different value still addresses
/// the same map entry. Keys are borrowed; use value hooks in MapConfig when the
/// map should own value storage.
pub fn Map(
    comptime K: type,
    comptime V: type,
    comptime config: MapConfig(K, V),
) type {
    comptime {
        if (config.use_string_prefix and K != []const u8) {
            @compileError("config.use_string_prefix requires key type to be []const u8 (string)");
        }
        if (!orderedKeySupported(K)) {
            @compileError("Map requires key type to be one of: int, float, bool, enum, []const u8 (string)");
        }
    }
    return struct {
        const Self = @This();

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

        pub const EntryMut = struct {
            key: K,
            value: *V,

            fn init(key: K, value: *V) @This() {
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
        count: usize = 0,
        copied: bool = false,

        fn releaseValue(gpa: mem.Allocator, value: V) void {
            if (config.release_value) |release| release(gpa, value);
        }

        fn copyValue(gpa: mem.Allocator, value: V) !V {
            if (config.copy_value) |copyFn| return try copyFn(gpa, value);
            return value;
        }

        fn orderedKeyCompare(a: K, b: K) std.math.Order {
            if (comptime K == []const u8) {
                return mem.order(u8, a, b);
            }

            return switch (@typeInfo(K)) {
                .bool => if (a == b) .eq else if (!a and b) .lt else .gt,
                .@"enum" => blk: {
                    const a_ = @intFromEnum(a);
                    const b_ = @intFromEnum(b);
                    break :blk if (a_ == b_) .eq else if (a_ < b_) .lt else .gt;
                },
                else => if (a < b) .lt else if (a > b) .gt else .eq,
            };
        }

        fn orderedKeyLess(a: K, b: K) bool {
            if (comptime K == []const u8) return mem.order(u8, a, b) == .lt;
            return switch (@typeInfo(K)) {
                .bool => !a and b,
                .@"enum" => @intFromEnum(a) < @intFromEnum(b),
                else => a < b,
            };
        }

        fn orderedKeyEqual(a: K, b: K) bool {
            if (comptime K == []const u8) return mem.eql(u8, a, b);
            return a == b;
        }

        fn keyCompare(a_key: K, a_value: V, b_key: K, b_value: V) std.math.Order {
            _ = a_value;
            _ = b_value;
            return orderedKeyCompare(a_key, b_key);
        }

        fn useBinarySearch() bool {
            return switch (config.search_mode) {
                .linear => false,
                .binary => true,
                .auto => K == []const u8 or @sizeOf(K) > @sizeOf(usize) * 2,
            };
        }

        fn usePrimitiveOrderedKeyFastSearch() bool {
            if (K == []const u8) return false;
            return switch (@typeInfo(K)) {
                .int, .comptime_int, .float, .comptime_float => true,
                else => false,
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

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
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

            if (comptime K != []const u8) {
                if (comptime useBinarySearch()) return searchOrderedKeyBinary(node, key);
                if (comptime usePrimitiveOrderedKeyFastSearch()) return searchPrimitiveOrderedKeyLinear(node, key);
                return searchOrderedKeyLinear(node, key);
            }

            if (comptime useBinarySearch()) return searchNodeBinary(node, key, value);
            return searchNodeLinear(node, key, value);
        }

        fn searchKeyOnlyWithPrefix(node: *const Node, key: K, prefix: u64) SearchResult {
            if (comptime config.use_string_prefix) {
                if (!node.isLeaf()) return searchBranchByKeyPrefix(node, key, prefix);
            }

            if (comptime useBinarySearch()) return searchOrderedKeyBinary(node, key);
            if (comptime usePrimitiveOrderedKeyFastSearch()) return searchPrimitiveOrderedKeyLinear(node, key);
            return searchOrderedKeyLinear(node, key);
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

        fn searchBranchByKeyPrefix(node: *const Node, key: []const u8, wanted: u64) SearchResult {
            const branch = node.branch.?;
            if (wanted > branch.prefixes[node.len - 1]) return SearchResult.init(node.len, false);

            var i: usize = 0;
            while (i < node.len) : (i += 1) {
                const prefix = branch.prefixes[i];
                if (prefix < wanted) continue;
                if (prefix > wanted) return SearchResult.init(i, false);

                const c = orderedKeyCompare(node.keys[i], key);
                if (c == .gt or c == .eq) return SearchResult.init(i, c == .eq);
            }

            return SearchResult.init(i, false);
        }

        fn searchOrderedKeyLinear(node: *const Node, key: K) SearchResult {
            if (node.len == 0) return SearchResult.init(0, false);

            const last = node.len - 1;
            if (orderedKeyLess(node.keys[last], key)) return SearchResult.init(node.len, false);
            if (orderedKeyEqual(node.keys[last], key)) return SearchResult.init(last, true);

            var i: usize = 0;
            while (true) : (i += 1) {
                if (!orderedKeyLess(node.keys[i], key)) return SearchResult.init(i, orderedKeyEqual(node.keys[i], key));
            }
        }

        inline fn searchPrimitiveOrderedKeyLinear(node: *const Node, key: K) SearchResult {
            if (node.len == 0) return SearchResult.init(0, false);

            const last = node.len - 1;
            if (key > node.keys[last]) return SearchResult.init(node.len, false);
            if (key == node.keys[last]) return SearchResult.init(last, true);

            var i: usize = 0;
            while (key > node.keys[i]) : (i += 1) {}
            return SearchResult.init(i, key == node.keys[i]);
        }

        fn searchOrderedKeyBinary(node: *const Node, key: K) SearchResult {
            if (node.len == 0) return SearchResult.init(0, false);

            const last = node.len - 1;
            if (orderedKeyLess(node.keys[last], key)) return SearchResult.init(node.len, false);
            if (orderedKeyEqual(node.keys[last], key)) return SearchResult.init(last, true);

            var low: usize = 0;
            var high: usize = last;
            while (low < high) {
                const mid = low + (high - low) / 2;
                if (orderedKeyLess(node.keys[mid], key)) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }

            return SearchResult.init(low, orderedKeyEqual(node.keys[low], key));
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

        fn insertKeyOnlyIntoNonFull(self: *Self, gpa: mem.Allocator, node: *Node, key: K, value: V, prefix: u64) !bool {
            const found = searchKeyOnlyWithPrefix(node, key, prefix);
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
                const cmp = orderedKeyCompare(node.keys[child_index], key);
                if (cmp == .eq) return false;
                if (cmp == .lt) child_index += 1;
            }

            const child = branch.children[child_index].?;
            if (child.isLeaf()) {
                const child_found = searchKeyOnlyWithPrefix(child, key, prefix);
                if (child_found.found) return false;
                insertItemAt(child, child_found.index, key, value);
                branch.counts[child_index] += 1;
                return true;
            }

            const inserted = try self.insertKeyOnlyIntoNonFull(gpa, child, key, value, prefix);
            if (inserted) branch.counts[child_index] += 1;
            return inserted;
        }

        pub fn insert(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            try self.makeUniqueRoot(gpa);
            if (self.root == null) {
                self.root = try self.newNode(gpa, true);
                insertItemAt(self.root.?, 0, key, value);
                self.count = 1;
                return true;
            }

            if (self.root.?.len == max_items) try self.splitRoot(gpa);
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            const inserted = try self.insertKeyOnlyIntoNonFull(gpa, self.root.?, key, value, prefix);
            if (inserted) self.count += 1;
            return inserted;
        }

        /// Looks up an item by key and returns its stored value.
        /// Returns `null` when no equal key exists.
        pub fn get(self: *const Self, key: K) ?V {
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            while (true) {
                const found = searchKeyOnlyWithPrefix(node, key, prefix);
                if (found.found) return node.values[found.index];
                if (node.branch) |branch| node = branch.children[found.index].? else return null;
            }
        }

        /// Looks up an item by key and returns a mutable pointer to its stored value.
        ///
        /// Copy-on-write paths are cloned before the pointer is returned. The
        /// pointer is valid until the next structural mutation of this map.
        pub fn getMut(self: *Self, gpa: mem.Allocator, key: K) !?*V {
            try self.makeUniqueRoot(gpa);
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            while (true) {
                const found = searchKeyOnlyWithPrefix(node, key, prefix);
                if (found.found) return &node.values[found.index];
                if (node.branch) |branch| {
                    try self.makeUniqueChild(gpa, node, found.index);
                    node = branch.children[found.index].?;
                } else return null;
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

        /// Visits every item in ascending sort order and yields mutable values.
        ///
        /// Copy-on-write paths are cloned before values are yielded. Callbacks
        /// must not structurally mutate the map while iteration is active.
        pub fn ascentMut(
            self: *Self,
            gpa: mem.Allocator,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, *V) anyerror!void,
        ) !void {
            try self.makeUniqueRoot(gpa);
            if (self.root) |root| try self.visitAscMut(gpa, CtxType, root, context, yield);
        }

        fn visitAscMut(
            self: *Self,
            gpa: mem.Allocator,
            comptime CtxType: type,
            node: *Node,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, *V) anyerror!void,
        ) !void {
            if (node.isLeaf()) {
                for (0..node.len) |i| try yield(ctx, node.keys[i], &node.values[i]);
                return;
            }

            const branch = node.branch.?;
            for (0..node.len) |i| {
                try self.makeUniqueChild(gpa, node, i);
                try self.visitAscMut(gpa, CtxType, branch.children[i].?, ctx, yield);
                try yield(ctx, node.keys[i], &node.values[i]);
            }

            try self.makeUniqueChild(gpa, node, node.len);
            try self.visitAscMut(gpa, CtxType, branch.children[node.len].?, ctx, yield);
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

        /// Visits every item in descending sort order and yields mutable values.
        ///
        /// Copy-on-write paths are cloned before values are yielded. Callbacks
        /// must not structurally mutate the map while iteration is active.
        pub fn descentMut(
            self: *Self,
            gpa: mem.Allocator,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, *V) anyerror!void,
        ) !void {
            try self.makeUniqueRoot(gpa);
            if (self.root) |root| try self.visitDescMut(gpa, CtxType, root, context, yield);
        }

        fn visitDescMut(
            self: *Self,
            gpa: mem.Allocator,
            comptime CtxType: type,
            node: *Node,
            ctx: CtxType,
            comptime yield: fn (CtxType, K, *V) anyerror!void,
        ) !void {
            if (node.isLeaf()) {
                var i = node.len;
                while (i > 0) {
                    i -= 1;
                    try yield(ctx, node.keys[i], &node.values[i]);
                }
                return;
            }

            const branch = node.branch.?;
            try self.makeUniqueChild(gpa, node, node.len);
            try self.visitDescMut(gpa, CtxType, branch.children[node.len].?, ctx, yield);

            var i = node.len;
            while (i > 0) {
                i -= 1;
                try yield(ctx, node.keys[i], &node.values[i]);
                try self.makeUniqueChild(gpa, node, i);
                try self.visitDescMut(gpa, CtxType, branch.children[i].?, ctx, yield);
            }
        }

        /// Returns the first item greater than or equal to `key`/`val`.
        ///
        /// This is a lower-bound search: `seek(15)` returns `20` in a tree that
        /// contains `10, 20, 30`. Returns `null` if all items are smaller.
        pub fn seek(self: *const Self, key: K) ?Entry {
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;
            while (true) {
                const found = searchKeyOnlyWithPrefix(node, key, prefix);
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
        pub fn seekNext(self: *const Self, key: K) ?Entry {
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;

            while (true) {
                const found = searchKeyOnlyWithPrefix(node, key, prefix);
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
        pub fn seekPrev(self: *const Self, key: K) ?Entry {
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;

            while (true) {
                const found = searchKeyOnlyWithPrefix(node, key, prefix);
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
            if (index >= self.count) return null;

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

        /// Returns a mutable value pointer for the item at zero-based sorted position `index`.
        ///
        /// Copy-on-write paths are cloned before the pointer is returned. The
        /// pointer is valid until the next structural mutation of this map.
        pub fn getAtMut(self: *Self, gpa: mem.Allocator, index: usize) !?EntryMut {
            if (index >= self.count) return null;
            try self.makeUniqueRoot(gpa);

            var node = self.root.?;
            var remaining = index;

            while (true) {
                if (node.isLeaf()) return EntryMut.init(node.keys[remaining], &node.values[remaining]);

                const branch = node.branch.?;
                for (0..node.len) |i| {
                    if (remaining < branch.counts[i]) {
                        try self.makeUniqueChild(gpa, node, i);
                        node = branch.children[i].?;
                        break;
                    }
                    remaining -= branch.counts[i];
                    if (remaining == 0) return EntryMut.init(node.keys[i], &node.values[i]);
                    remaining -= 1;
                } else {
                    try self.makeUniqueChild(gpa, node, node.len);
                    node = branch.children[node.len].?;
                }
            }
        }

        /// Returns the zero-based sorted position of `key`/`val`.
        /// Returns `null` when no equal item exists.
        pub fn indexOf(self: *const Self, key: K) ?usize {
            var node = self.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var skipped: usize = 0;

            while (true) {
                const found = searchKeyOnlyWithPrefix(node, key, prefix);
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
            if (index >= self.count) return;
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
            if (self.count == 0) return;
            const start = if (index >= self.count) self.count - 1 else index;
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
        pub fn delete(self: *Self, gpa: mem.Allocator, key: K) !?V {
            try self.makeUniqueRoot(gpa);
            return self.deleteKeyOnlyUnique(gpa, key);
        }

        // Deletes from a tree whose root has already been made unique for a
        // copy-on-write mutation. Handles length updates and root collapse.
        fn deleteUnique(self: *Self, gpa: mem.Allocator, key: K, val: V) !?V {
            const old = if (self.root) |root| try self.deleteFromNode(gpa, root, key, val) else return null;
            if (old != null) {
                self.count -= 1;
                self.collapseEmptyRoot(gpa);
            }
            return old;
        }

        fn deleteKeyOnlyUnique(self: *Self, gpa: mem.Allocator, key: K) !?V {
            const old = if (self.root) |root| try self.deleteKeyOnlyFromNode(gpa, root, key) else return null;
            if (old != null) {
                self.count -= 1;
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
                if (branch.children[found.index].?.len < min_items) try self.rebalanceChild(gpa, node, found.index);
                return old;
            }

            try self.makeUniqueChild(gpa, node, found.index);
            const old = try self.deleteFromNodeWithPrefix(gpa, branch.children[found.index].?, key, val, prefix);
            if (old != null) {
                branch.counts[found.index] -= 1;
                if (branch.children[found.index].?.len < min_items) try self.rebalanceChild(gpa, node, found.index);
            }

            return old;
        }

        fn deleteKeyOnlyFromNode(self: *Self, gpa: mem.Allocator, node: *Node, key: K) anyerror!?V {
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            return self.deleteKeyOnlyFromNodeWithPrefix(gpa, node, key, prefix);
        }

        fn deleteKeyOnlyFromNodeWithPrefix(self: *Self, gpa: mem.Allocator, node: *Node, key: K, prefix: u64) anyerror!?V {
            const found = searchKeyOnlyWithPrefix(node, key, prefix);
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
                if (branch.children[found.index].?.len < min_items) try self.rebalanceChild(gpa, node, found.index);
                return old;
            }

            try self.makeUniqueChild(gpa, node, found.index);
            const old = try self.deleteKeyOnlyFromNodeWithPrefix(gpa, branch.children[found.index].?, key, prefix);
            if (old != null) {
                branch.counts[found.index] -= 1;
                if (branch.children[found.index].?.len < min_items) try self.rebalanceChild(gpa, node, found.index);
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

            const left_len = left.len;
            const right_len = right.len;
            const merged_len = left_len + 1 + right_len;

            left.keys[left_len] = parent.keys[left_index];
            left.values[left_len] = parent.values[left_index];
            @memcpy(left.keys[left_len + 1 .. merged_len], right.keys[0..right_len]);
            @memcpy(left.values[left_len + 1 .. merged_len], right.values[0..right_len]);
            left.len = @intCast(merged_len);

            if (right.branch) |right_branch| {
                const left_branch = left.branch.?;
                @memcpy(left_branch.children[left_len + 1 .. merged_len + 1], right_branch.children[0 .. right_len + 1]);
                @memcpy(left_branch.counts[left_len + 1 .. merged_len + 1], right_branch.counts[0 .. right_len + 1]);
                @memset(right_branch.children[0 .. right_len + 1], null);
                @memset(right_branch.counts[0 .. right_len + 1], 0);

                if (config.use_string_prefix) {
                    left_branch.prefixes[left_len] = stringPrefix(parent.keys[left_index]);
                    @memcpy(left_branch.prefixes[left_len + 1 .. merged_len], right_branch.prefixes[0..right_len]);
                }
            }
            right.len = 0;

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
            self.count -= 1;
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
            self.count -= 1;
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
                self.count = 1;
                return true;
            }

            if (self.front()) |first| {
                if (keyCompare(key, value, first.key, first.value) != .lt) return false;
            }

            if (self.root.?.len == max_items) try self.splitRoot(gpa);
            try self.insertLeftEdgeIntoNonFull(gpa, self.root.?, key, value);
            self.count += 1;
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
                self.count = 1;
                return true;
            }

            if (self.back()) |last| {
                if (keyCompare(last.key, last.value, key, value) != .lt) return false;
            }

            if (self.root.?.len == max_items) try self.splitRoot(gpa);
            try self.insertRightEdgeIntoNonFull(gpa, self.root.?, key, value);
            self.count += 1;
            return true;
        }

        // Returns whether `key`/`value` can occupy sorted position `index`
        // without violating its neighboring items.
        fn fitsBetween(self: *const Self, index: usize, key: K, value: V) bool {
            if (index > 0) {
                const previous = self.getAt(index - 1).?;
                if (keyCompare(previous.key, previous.value, key, value) != .lt) return false;
            }
            if (index < self.count) {
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
            if (index > self.count) return false;
            if (!self.fitsBetween(index, key, value)) return false;
            return self.insert(gpa, key, value);
        }

        fn fitsReplacementAt(self: *const Self, index: usize, key: K, value: V) bool {
            if (index > 0) {
                const previous = self.getAt(index - 1).?;
                const cmp = keyCompare(previous.key, previous.value, key, value);
                if (cmp == .eq or cmp == .gt) return false;
            }
            if (index + 1 < self.count) {
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
            if (index >= self.count) return null;
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
            if (branch.children[0].?.len < min_items) try self.rebalanceChild(gpa, node, 0);
            return removed;
        }

        fn deleteMaxFromNode(self: *Self, gpa: mem.Allocator, node: *Node) !Entry {
            if (node.isLeaf()) return removeItemAt(node, node.len - 1);

            const branch = node.branch.?;
            const child_index = node.len;
            try self.makeUniqueChild(gpa, node, child_index);
            const removed = try self.deleteMaxFromNode(gpa, branch.children[child_index].?);
            branch.counts[child_index] -= 1;
            if (branch.children[child_index].?.len < min_items) try self.rebalanceChild(gpa, node, child_index);
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
                    if (branch.children[i].?.len < min_items) try self.rebalanceChild(gpa, node, i);
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
                    if (branch.children[i].?.len < min_items) try self.rebalanceChild(gpa, node, i);
                    return old;
                }
                remaining -= 1;
            }

            const child_index = node.len;
            try self.makeUniqueChild(gpa, node, child_index);
            const removed = try self.deleteAtFromNode(gpa, branch.children[child_index].?, remaining);
            branch.counts[child_index] -= 1;
            if (branch.children[child_index].?.len < min_items) try self.rebalanceChild(gpa, node, child_index);
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
            self.count -= deleted.count;
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
            if (index >= self.count) return null;
            if (index == 0) return self.popFront(gpa);
            if (index == self.count - 1) return self.popBack(gpa);

            try self.makeUniqueRoot(gpa);
            const removed = try self.deleteAtFromNode(gpa, self.root.?, index);
            self.count -= 1;
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

        fn rankOfKeyOnly(self: *const Self, key: K) RankResult {
            var node = self.root orelse return RankResult.init(0, false);
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var skipped: usize = 0;

            while (true) {
                const found = searchKeyOnlyWithPrefix(node, key, prefix);
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
            if (index >= self.count or count == 0) return .{ .removed_count = 0, .chunks = &.{}, .chunk_count = 0 };

            var start = index;
            var end = @min(index + count, self.count);
            if (comptime opts.min_exclusive) start += 1;
            if (comptime opts.max_inclusive) end = @min(end + 1, self.count);
            if (end <= start) return .{ .removed_count = 0, .chunks = &.{}, .chunk_count = 0 };

            const limit = end - start;
            var builder = RangeBuilder.init();
            errdefer builder.releaseOwned(self, gpa);

            if (start == 0 and limit == self.count) {
                if (self.root) |root| try builder.appendNode(gpa, root);
                self.root = null;
                self.count = 0;
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

        pub fn deleteRange(self: *Self, gpa: mem.Allocator, min_key: K, max_key: K, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.deleteRangeByRank(gpa, self.rankOfKeyOnly(min_key), self.rankOfKeyOnly(max_key), opts);
        }

        /// Removes every item and releases all nodes owned by this tree.
        pub fn clear(self: *Self, gpa: mem.Allocator) void {
            self.releaseNode(gpa, self.root);
            self.root = null;
            self.count = 0;
        }

        /// Removes every item from sorted position `index` through the end.
        ///
        /// Returns an owned range deletion result.
        pub fn deleteAllAt(self: *Self, gpa: mem.Allocator, index: usize, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.deleteRangeAt(gpa, index, self.count - @min(index, self.count), opts);
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
            return .{ .root = self.root, .count = self.count, .copied = true };
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
                try expectInvariant(self.count == 0);
                return;
            };

            var leaf_depth: ?usize = null;
            const count = try self.checkNode(root, true, 0, &leaf_depth, null, null);
            try expectInvariant(count == self.count);
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
            self.count = 0;
        }
    };
}
