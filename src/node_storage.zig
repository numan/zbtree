const std = @import("std");

/// Most items a node holds, whatever the key and value types.
const max_node_items: usize = 63;
/// Fewest items a node is cut down to so that it fills a smaller allocation.
const min_fitted_items: usize = 55;

/// Shared B-tree node storage layout used by comparator-backed trees and
/// ordered map-specialized trees.
pub fn NodeStorage(
    comptime K: type,
    comptime V: type,
    comptime use_prefix: bool,
) type {
    return SizedStorage(K, V, use_prefix, fittedMaxItems(K, V, use_prefix));
}

// How many items a node of these types holds.
//
// Allocators with power-of-two size classes, such as std.heap.smp_allocator,
// round a leaf up to the next power of two. A leaf of 63 u64 keys is 576
// bytes, so it gets a 1024-byte slot and leaves almost half of it unused.
// This hurts the amount of useful thigs we can have in cache lines.
//
// Giving up a few items lets the leaf fill the next smaller power of
// two instead, the node holds that many: 61 u64 keys are 512 bytes.
//
// The count stays odd, because a full node splits into its median and two
// halves of `min_items`.
fn fittedMaxItems(comptime K: type, comptime V: type, comptime use_prefix: bool) usize {
    const full_size = @sizeOf(SizedStorage(K, V, use_prefix, max_node_items).Node);
    const smaller_slot = std.math.ceilPowerOfTwoAssert(usize, full_size) / 2;

    var items = max_node_items;
    while (items >= min_fitted_items) : (items -= 2) {
        if (@sizeOf(SizedStorage(K, V, use_prefix, items).Node) <= smaller_slot) return items;
    }
    return max_node_items;
}

fn SizedStorage(
    comptime K: type,
    comptime V: type,
    comptime use_prefix: bool,
    comptime item_capacity: usize,
) type {
    return struct {
        /// Maximum number of key/value items stored directly in one node.
        pub const max_items: usize = item_capacity;
        /// Maximum number of child pointers in an internal node.
        pub const fanout: usize = max_items + 1;
        /// Minimum item count for non-root nodes after the tree has split.
        pub const min_items: usize = max_items / 2;
        /// Upper bound on tree height in levels. A tree taller than this would
        /// have to hold than maxInt(usize) items.
        pub const max_height: usize = 16;

        // A node stores sorted key/value items. If `branch` is null it is a
        // leaf; otherwise `branch` stores the child pointers between items.
        pub const Node = struct {
            const NodeSelf = @This();

            // Aligned so the SIMD read search in btree.zig compares chunks
            // that start on a 64-byte cache line, whatever field order the
            // compiler picks and whichever allocator made the node. Not 100%
            // sure it makes a different, but it seems to for some cases.
            keys: [max_items]K align(64) = undefined,
            values: [max_items]V = undefined,
            len: u8 = 0,
            branch: ?*Branch = null,
            rc: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

            pub fn init() NodeSelf {
                return .{};
            }

            pub fn isLeaf(node: *const Node) bool {
                return node.branch == null;
            }
        };

        // Extra data for internal nodes. `children[i]` contains items that sort
        // before `keys[i]`, and `children[len]` contains items after the last
        // key. `counts[i]` is the total number of items in `children[i]`.
        pub const Branch = struct {
            const BranchSelf = @This();

            children: [fanout]?*Node = @splat(null),
            counts: [fanout]usize = @splat(0),
            prefixes: if (use_prefix) [max_items]u64 else void = if (use_prefix) @splat(0) else {},

            pub fn init() BranchSelf {
                return .{};
            }
        };

        // Internal nodes are allocated as one object so the hot Node fields and
        // Branch metadata are colocated and require one allocator call.
        pub const InternalNode = struct {
            node: Node,
            branch: Branch,
        };
    };
}

test "word-sized nodes fit power-of-two allocation sizes" {
    // std.heap.smp_allocator rounds each allocation up to a power of two, so a
    // node one byte over the boundary occupies twice the memory.
    const Storage = NodeStorage(u64, u64, false);
    try std.testing.expect(@sizeOf(Storage.Node) <= 1024);
    try std.testing.expect(@sizeOf(Storage.InternalNode) <= 2048);
}

test "a leaf that would half-fill its allocation holds fewer items and fills a smaller one" {
    // 63 u64 keys make a 576-byte leaf, which a power-of-two allocator puts
    // in a 1024-byte slot. 61 keys fill a 512-byte slot.
    const Keys64 = NodeStorage(u64, void, false);
    try std.testing.expectEqual(61, Keys64.max_items);
    try std.testing.expectEqual(512, @sizeOf(Keys64.Node));

    const Keys32 = NodeStorage(i32, void, false);
    try std.testing.expectEqual(59, Keys32.max_items);
    try std.testing.expectEqual(256, @sizeOf(Keys32.Node));
}

test "a leaf keeps 63 items when it fills its allocation or would give up too many items to fit a smaller one" {
    try std.testing.expectEqual(63, NodeStorage(u64, u64, false).max_items);
    try std.testing.expectEqual(63, NodeStorage([]const u8, void, true).max_items);
    // These would have to drop to 41 items to fit the smaller slot.
    try std.testing.expectEqual(63, NodeStorage(i32, usize, false).max_items);
    try std.testing.expectEqual(63, NodeStorage([]const u8, usize, true).max_items);
}

test "every node size splits into two valid halves" {
    inline for (.{ u8, u16, i32, u64, [3]usize, []const u8 }) |K| {
        inline for (.{ void, u8, i32, usize }) |V| {
            const Storage = NodeStorage(K, V, false);
            // A full node splits into its median and two halves of
            // min_items, which only an odd item count allows.
            try std.testing.expectEqual(Storage.max_items, 2 * Storage.min_items + 1);
            try std.testing.expectEqual(Storage.max_items + 1, Storage.fanout);
        }
    }
}
