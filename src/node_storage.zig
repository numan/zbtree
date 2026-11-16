const std = @import("std");

/// Shared B-tree node storage layout used by comparator-backed trees and
/// ordered map-specialized trees.
pub fn NodeStorage(
    comptime K: type,
    comptime V: type,
    comptime use_string_prefix: bool,
) type {
    return struct {
        /// Maximum number of child pointers in an internal node.
        pub const fanout: usize = 64;
        /// Maximum number of key/value items stored directly in one node.
        pub const max_items: usize = fanout - 1;
        /// Minimum item count for non-root nodes after the tree has split.
        pub const min_items: usize = max_items / 2;
        /// Upper bound on tree height in levels. A tree taller than this would
        /// have to hold than maxInt(usize) items.
        pub const max_height: usize = 16;

        // A node stores sorted key/value items. If `branch` is null it is a
        // leaf; otherwise `branch` stores the child pointers between items.
        pub const Node = struct {
            const NodeSelf = @This();

            keys: [max_items]K = undefined,
            values: [max_items]V = undefined,
            len: u8 = 0,
            branch: ?*Branch = null,
            rc: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

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
            prefixes: if (use_string_prefix) [max_items]u64 else void = if (use_string_prefix) @splat(0) else {},

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
