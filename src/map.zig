const std = @import("std");
const mem = std.mem;
const btree = @import("btree.zig");

pub const SearchMode = btree.SearchMode;
pub const DeleteRangeOptions = btree.DeleteRangeOptions;

pub fn MapConfig(comptime K: type, comptime V: type) type {
    return struct {
        use_string_prefix: bool = K == []const u8,
        search_mode: SearchMode = .auto,

        copy_value: ?*const fn (mem.Allocator, V) anyerror!V = null,
        release_value: ?*const fn (mem.Allocator, V) void = null,
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
        if (!btree.orderedKeySupported(K)) {
            @compileError("Map requires key type to be one of: int, float, bool, enum, []const u8 (string)");
        }
    }

    const OrderedCompare = struct {
        fn compare(a_key: K, _: V, b_key: K, _: V) std.math.Order {
            if (comptime K == []const u8) return mem.order(u8, a_key, b_key);
            return switch (@typeInfo(K)) {
                .bool => if (a_key == b_key) .eq else if (!a_key and b_key) .lt else .gt,
                .@"enum" => blk: {
                    const a = @intFromEnum(a_key);
                    const b = @intFromEnum(b_key);
                    break :blk if (a == b) .eq else if (a < b) .lt else .gt;
                },
                else => if (a_key < b_key) .lt else if (a_key > b_key) .gt else .eq,
            };
        }
    };

    const Base = btree.Tree(K, V, .{
        .compare = OrderedCompare.compare,
        .ordering = .ordered_key,
        .use_string_prefix = config.use_string_prefix,
        .search_mode = config.search_mode,
        .copy_value = config.copy_value,
        .release_value = config.release_value,
    });

    return struct {
        const Self = @This();
        const Node = Base.Node;

        const SearchResult = struct {
            index: usize,
            found: bool,

            fn init(index: usize, found: bool) @This() {
                return .{ .index = index, .found = found };
            }
        };

        const Slot = struct {
            node: *Node,
            index: usize,
        };

        const SetResult = struct {
            old: ?V,
            inserted: bool,
        };

        tree: Base = .init(),

        pub const fanout = Base.fanout;
        pub const max_items = Base.max_items;
        pub const min_items = Base.min_items;

        pub const Entry = Base.Entry;
        pub const EntryMut = Base.EntryMut;
        pub const DeleteRangeResult = Base.DeleteRangeResult;

        fn orderedKeyCompare(a: K, b: K) std.math.Order {
            if (comptime K == []const u8) return mem.order(u8, a, b);
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

        inline fn orderedKeyLess(a: K, b: K) bool {
            if (comptime K == []const u8) return mem.order(u8, a, b) == .lt;
            return switch (@typeInfo(K)) {
                .bool => !a and b,
                .@"enum" => @intFromEnum(a) < @intFromEnum(b),
                else => a < b,
            };
        }

        inline fn orderedKeyEqual(a: K, b: K) bool {
            if (comptime K == []const u8) return mem.eql(u8, a, b);
            return a == b;
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

        fn stringPrefix(key: []const u8) u64 {
            var bytes: [8]u8 = [_]u8{0} ** 8;
            const n = @min(bytes.len, key.len);
            @memcpy(bytes[0..n], key[0..n]);
            return mem.readInt(u64, &bytes, .big);
        }

        fn searchNodeWithPrefix(node: *const Node, key: K, prefix: u64) SearchResult {
            if (comptime config.use_string_prefix) {
                if (!node.isLeaf()) return searchBranchByKeyPrefix(node, key, prefix);
            }

            if (comptime K == []const u8) {
                if (comptime useBinarySearch()) return searchStringKeyBinary(node, key);
                return searchStringKeyLinear(node, key);
            }
            if (comptime useBinarySearch()) return searchOrderedKeyBinary(node, key);
            if (comptime usePrimitiveOrderedKeyFastSearch()) return searchPrimitiveOrderedKeyLinear(node, key);
            return searchOrderedKeyLinear(node, key);
        }

        fn searchBranchByKeyPrefix(node: *const Node, key: []const u8, wanted: u64) SearchResult {
            const branch = node.branch.?;
            if (wanted > branch.prefixes[node.len - 1]) return SearchResult.init(node.len, false);

            var i: usize = 0;
            while (i < node.len) : (i += 1) {
                const prefix = branch.prefixes[i];
                if (prefix < wanted) continue;
                if (prefix > wanted) return SearchResult.init(i, false);

                const c = mem.order(u8, node.keys[i], key);
                if (c == .gt or c == .eq) return SearchResult.init(i, c == .eq);
            }

            return SearchResult.init(i, false);
        }

        fn searchStringKeyLinear(node: *const Node, key: []const u8) SearchResult {
            if (node.len == 0) return SearchResult.init(0, false);

            const last = node.len - 1;
            switch (mem.order(u8, node.keys[last], key)) {
                .lt => return SearchResult.init(node.len, false),
                .eq => return SearchResult.init(last, true),
                .gt => {},
            }

            var i: usize = 0;
            while (true) : (i += 1) {
                switch (mem.order(u8, node.keys[i], key)) {
                    .lt => {},
                    .eq => return SearchResult.init(i, true),
                    .gt => return SearchResult.init(i, false),
                }
            }
        }

        fn searchStringKeyBinary(node: *const Node, key: []const u8) SearchResult {
            if (node.len == 0) return SearchResult.init(0, false);

            const last = node.len - 1;
            switch (mem.order(u8, node.keys[last], key)) {
                .lt => return SearchResult.init(node.len, false),
                .eq => return SearchResult.init(last, true),
                .gt => {},
            }

            var low: usize = 0;
            var high: usize = last;
            while (low < high) {
                const mid = low + (high - low) / 2;
                switch (mem.order(u8, node.keys[mid], key)) {
                    .lt => low = mid + 1,
                    .eq => return SearchResult.init(mid, true),
                    .gt => high = mid,
                }
            }

            return SearchResult.init(low, mem.order(u8, node.keys[low], key) == .eq);
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

        fn insertKeyOnlyIntoNonFull(self: *Self, gpa: mem.Allocator, node: *Node, key: K, value: V, prefix: u64) !bool {
            const found = searchNodeWithPrefix(node, key, prefix);
            if (found.found) return false;

            if (node.isLeaf()) {
                Base.insertItemAt(node, found.index, key, value);
                return true;
            }

            const branch = node.branch.?;
            var child_index = found.index;
            if (self.tree.copied) try self.tree.makeUniqueChild(gpa, node, child_index);
            if (branch.children[child_index].?.len == max_items) {
                try self.tree.splitChild(gpa, node, child_index);
                const cmp = orderedKeyCompare(node.keys[child_index], key);
                if (cmp == .eq) return false;
                if (cmp == .lt) child_index += 1;
            }

            const child = branch.children[child_index].?;
            if (child.isLeaf()) {
                const child_found = searchNodeWithPrefix(child, key, prefix);
                if (child_found.found) return false;
                Base.insertItemAt(child, child_found.index, key, value);
                branch.counts[child_index] += 1;
                return true;
            }

            const inserted = try self.insertKeyOnlyIntoNonFull(gpa, child, key, value, prefix);
            if (inserted) branch.counts[child_index] += 1;
            return inserted;
        }

        fn setKeyOnlyIntoNonFull(self: *Self, gpa: mem.Allocator, node: *Node, key: K, value: V, prefix: u64) !SetResult {
            const found = searchNodeWithPrefix(node, key, prefix);
            if (found.found) {
                const old = node.values[found.index];
                node.keys[found.index] = key;
                node.values[found.index] = value;
                Base.setPrefix(node, found.index);
                return .{ .old = old, .inserted = false };
            }

            if (node.isLeaf()) {
                Base.insertItemAt(node, found.index, key, value);
                return .{ .old = null, .inserted = true };
            }

            const branch = node.branch.?;
            var child_index = found.index;
            if (self.tree.copied) try self.tree.makeUniqueChild(gpa, node, child_index);
            if (branch.children[child_index].?.len == max_items) {
                try self.tree.splitChild(gpa, node, child_index);
                const cmp = orderedKeyCompare(node.keys[child_index], key);
                if (cmp == .eq) {
                    const old = node.values[child_index];
                    node.keys[child_index] = key;
                    node.values[child_index] = value;
                    Base.setPrefix(node, child_index);
                    return .{ .old = old, .inserted = false };
                }
                if (cmp == .lt) child_index += 1;
            }

            const child = branch.children[child_index].?;
            if (child.isLeaf()) {
                const child_found = searchNodeWithPrefix(child, key, prefix);
                if (child_found.found) {
                    const old = child.values[child_found.index];
                    child.keys[child_found.index] = key;
                    child.values[child_found.index] = value;
                    return .{ .old = old, .inserted = false };
                }
                Base.insertItemAt(child, child_found.index, key, value);
                branch.counts[child_index] += 1;
                return .{ .old = null, .inserted = true };
            }

            const result = try self.setKeyOnlyIntoNonFull(gpa, child, key, value, prefix);
            if (result.inserted) branch.counts[child_index] += 1;
            return result;
        }

        fn findKeySlotForWrite(self: *Self, gpa: mem.Allocator, key: K) !?Slot {
            if (self.tree.copied) try self.tree.makeUniqueRoot(gpa);
            var node = self.tree.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (found.found) return .{ .node = node, .index = found.index };
                if (node.branch) |branch| {
                    if (self.tree.copied) try self.tree.makeUniqueChild(gpa, node, found.index);
                    node = branch.children[found.index].?;
                } else return null;
            }
        }

        fn minEntry(node: *const Node) Entry {
            var current = node;
            while (current.branch) |branch| current = branch.children[0].?;
            return Entry{ .key = current.keys[0], .value = current.values[0] };
        }

        fn maxEntry(node: *const Node) Entry {
            var current = node;
            while (current.branch) |branch| current = branch.children[current.len].?;
            return Entry{ .key = current.keys[current.len - 1], .value = current.values[current.len - 1] };
        }

        fn deleteKeyOnlyFromNode(self: *Self, gpa: mem.Allocator, node: *Node, key: K, prefix: u64) anyerror!?V {
            const found = searchNodeWithPrefix(node, key, prefix);
            if (node.isLeaf()) return if (found.found) Base.removeItemAt(node, found.index).value else null;

            const branch = node.branch.?;
            if (found.found) {
                if (self.tree.copied) try self.tree.makeUniqueChild(gpa, node, found.index);
                const old = node.values[found.index];
                const replacement = try self.tree.deleteMaxFromNode(gpa, branch.children[found.index].?);
                node.keys[found.index] = replacement.key;
                node.values[found.index] = replacement.value;
                Base.setPrefix(node, found.index);
                branch.counts[found.index] -= 1;
                if (branch.children[found.index].?.len < min_items) try self.tree.rebalanceChild(gpa, node, found.index);
                return old;
            }

            if (self.tree.copied) try self.tree.makeUniqueChild(gpa, node, found.index);
            const old = try self.deleteKeyOnlyFromNode(gpa, branch.children[found.index].?, key, prefix);
            if (old != null) {
                branch.counts[found.index] -= 1;
                if (branch.children[found.index].?.len < min_items) try self.tree.rebalanceChild(gpa, node, found.index);
            }
            return old;
        }

        fn rankOf(self: *const Self, key: K) Base.RankResult {
            var node = self.tree.root orelse return .{ .index = 0, .found = false };
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var skipped: usize = 0;

            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (node.isLeaf()) return .{ .index = found.index + skipped, .found = found.found };

                const branch = node.branch.?;
                for (0..found.index) |i| skipped += branch.counts[i] + 1;
                if (found.found) return .{ .index = skipped + branch.counts[found.index], .found = true };
                node = branch.children[found.index].?;
            }
        }

        pub fn init() Self {
            return .{};
        }

        pub fn len(self: *const Self) usize {
            return self.tree.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.tree.len == 0;
        }

        pub fn insert(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            if (self.tree.copied) try self.tree.makeUniqueRoot(gpa);
            if (self.tree.root == null) {
                try self.tree.insertFirstItem(gpa, key, value);
                return true;
            }

            if (self.tree.root.?.len == max_items) try self.tree.splitRoot(gpa);
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            const root = self.tree.root.?;
            if (root.isLeaf()) {
                const found = searchNodeWithPrefix(root, key, prefix);
                if (found.found) return false;
                Base.insertItemAt(root, found.index, key, value);
                self.tree.len += 1;
                return true;
            }

            const inserted = try self.insertKeyOnlyIntoNonFull(gpa, root, key, value, prefix);
            if (inserted) self.tree.len += 1;
            return inserted;
        }

        pub fn get(self: *const Self, key: K) ?V {
            var node = self.tree.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (found.found) return node.values[found.index];
                if (node.branch) |branch| node = branch.children[found.index].? else return null;
            }
        }

        pub fn getMut(self: *Self, gpa: mem.Allocator, key: K) !?*V {
            if (self.tree.copied) try self.tree.makeUniqueRoot(gpa);
            var node = self.tree.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (found.found) return &node.values[found.index];
                if (node.branch) |branch| {
                    if (self.tree.copied) try self.tree.makeUniqueChild(gpa, node, found.index);
                    node = branch.children[found.index].?;
                } else return null;
            }
        }

        pub fn ascent(
            self: *const Self,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            return self.tree.ascent(CtxType, context, yield);
        }

        pub fn ascentMut(
            self: *Self,
            gpa: mem.Allocator,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, *V) anyerror!void,
        ) !void {
            return self.tree.ascentMut(gpa, CtxType, context, yield);
        }

        pub fn descent(
            self: *const Self,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            return self.tree.descent(CtxType, context, yield);
        }

        pub fn descentMut(
            self: *Self,
            gpa: mem.Allocator,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, *V) anyerror!void,
        ) !void {
            return self.tree.descentMut(gpa, CtxType, context, yield);
        }

        pub fn seek(self: *const Self, key: K) ?Entry {
            var node = self.tree.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;
            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (found.index < node.len) candidate = Entry{ .key = node.keys[found.index], .value = node.values[found.index] };
                if (found.found) return candidate;
                if (node.branch) |branch| node = branch.children[found.index].? else return candidate;
            }
        }

        pub fn seekNext(self: *const Self, key: K) ?Entry {
            var node = self.tree.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;
            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (!found.found and found.index < node.len) candidate = Entry{ .key = node.keys[found.index], .value = node.values[found.index] };

                if (found.found) {
                    if (node.branch) |branch| return minEntry(branch.children[found.index + 1].?);
                    return if (found.index + 1 < node.len) Entry{ .key = node.keys[found.index + 1], .value = node.values[found.index + 1] } else candidate;
                }

                if (node.branch) |branch| node = branch.children[found.index].? else return candidate;
            }
        }

        pub fn seekPrev(self: *const Self, key: K) ?Entry {
            var node = self.tree.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var candidate: ?Entry = null;
            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (found.found) {
                    if (node.branch) |branch| return maxEntry(branch.children[found.index].?);
                    return if (found.index == 0) candidate else Entry{ .key = node.keys[found.index - 1], .value = node.values[found.index - 1] };
                }
                if (found.index > 0) {
                    const candidate_index = found.index - 1;
                    candidate = Entry{ .key = node.keys[candidate_index], .value = node.values[candidate_index] };
                }
                if (node.branch) |branch| node = branch.children[found.index].? else return candidate;
            }
        }

        pub fn getAt(self: *const Self, index: usize) ?Entry {
            return self.tree.getAt(index);
        }

        pub fn getAtMut(self: *Self, gpa: mem.Allocator, index: usize) !?EntryMut {
            return self.tree.getAtMut(gpa, index);
        }

        pub fn indexOf(self: *const Self, key: K) ?usize {
            var node = self.tree.root orelse return null;
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            var skipped: usize = 0;
            while (true) {
                const found = searchNodeWithPrefix(node, key, prefix);
                if (node.isLeaf()) return if (found.found) skipped + found.index else null;

                const branch = node.branch.?;
                for (0..found.index) |i| skipped += branch.counts[i] + 1;
                if (found.found) return skipped + branch.counts[found.index];
                node = branch.children[found.index].?;
            }
        }

        pub fn ascendAt(
            self: *const Self,
            comptime CtxType: type,
            index: usize,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !void {
            return self.tree.ascendAt(CtxType, index, context, yield);
        }

        pub fn descendAt(
            self: *const Self,
            comptime CtxType: type,
            index: usize,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !void {
            return self.tree.descendAt(CtxType, index, context, yield);
        }

        pub fn replace(self: *Self, gpa: mem.Allocator, key: K, value: V) !?V {
            const slot = (try self.findKeySlotForWrite(gpa, key)) orelse return null;
            const old = slot.node.values[slot.index];
            slot.node.values[slot.index] = value;
            return old;
        }

        pub fn set(self: *Self, gpa: mem.Allocator, key: K, value: V) !?V {
            if (self.tree.copied) try self.tree.makeUniqueRoot(gpa);
            if (self.tree.root == null) {
                try self.tree.insertFirstItem(gpa, key, value);
                return null;
            }

            if (self.tree.root.?.len == max_items) try self.tree.splitRoot(gpa);
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            const root = self.tree.root.?;
            if (root.isLeaf()) {
                const found = searchNodeWithPrefix(root, key, prefix);
                if (found.found) {
                    const old = root.values[found.index];
                    root.keys[found.index] = key;
                    root.values[found.index] = value;
                    return old;
                }

                Base.insertItemAt(root, found.index, key, value);
                self.tree.len += 1;
                return null;
            }

            const result = try self.setKeyOnlyIntoNonFull(gpa, root, key, value, prefix);
            if (result.inserted) self.tree.len += 1;
            return result.old;
        }

        pub fn delete(self: *Self, gpa: mem.Allocator, key: K) !?V {
            if (self.tree.copied) try self.tree.makeUniqueRoot(gpa);
            const prefix = if (comptime config.use_string_prefix) stringPrefix(key) else 0;
            const old = if (self.tree.root) |root| try self.deleteKeyOnlyFromNode(gpa, root, key, prefix) else return null;
            if (old != null) {
                self.tree.len -= 1;
                self.tree.collapseEmptyRoot(gpa);
            }
            return old;
        }

        pub fn front(self: *const Self) ?Entry {
            return self.tree.front();
        }

        pub fn back(self: *const Self) ?Entry {
            return self.tree.back();
        }

        pub fn popFrontIf(self: *Self, gpa: mem.Allocator, cond: ?*const fn (K, V) bool) !?Entry {
            return self.tree.popFrontIf(gpa, cond);
        }

        pub fn popBackIf(self: *Self, gpa: mem.Allocator, cond: ?*const fn (K, V) bool) !?Entry {
            return self.tree.popBackIf(gpa, cond);
        }

        pub fn popFront(self: *Self, gpa: mem.Allocator) !?Entry {
            return self.tree.popFront(gpa);
        }

        pub fn popBack(self: *Self, gpa: mem.Allocator) !?Entry {
            return self.tree.popBack(gpa);
        }

        pub fn pushFront(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            return self.tree.pushFront(gpa, key, value);
        }

        pub fn pushBack(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            return self.tree.pushBack(gpa, key, value);
        }

        pub fn insertAt(self: *Self, gpa: mem.Allocator, index: usize, key: K, value: V) !bool {
            return self.tree.insertAt(gpa, index, key, value);
        }

        pub fn replaceAt(self: *Self, gpa: mem.Allocator, index: usize, key: K, value: V) !?Entry {
            return self.tree.replaceAt(gpa, index, key, value);
        }

        pub fn deleteAt(self: *Self, gpa: mem.Allocator, index: usize) !?Entry {
            return self.tree.deleteAt(gpa, index);
        }

        pub fn deleteRangeAt(self: *Self, gpa: mem.Allocator, index: usize, count: usize, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.tree.deleteRangeAt(gpa, index, count, opts);
        }

        pub fn deleteRange(self: *Self, gpa: mem.Allocator, min_key: K, max_key: K, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.tree.deleteRangeByRank(gpa, self.rankOf(min_key), self.rankOf(max_key), opts);
        }

        pub fn clear(self: *Self, gpa: mem.Allocator) void {
            self.tree.clear(gpa);
        }

        pub fn deleteAllAt(self: *Self, gpa: mem.Allocator, index: usize, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.tree.deleteAllAt(gpa, index, opts);
        }

        pub fn copy(self: *Self) Self {
            return .{ .tree = self.tree.copy() };
        }

        pub fn checkInvariants(self: *const Self) !void {
            return self.tree.checkInvariants();
        }

        pub fn deinit(self: *Self, gpa: mem.Allocator) void {
            self.tree.deinit(gpa);
        }
    };
}
