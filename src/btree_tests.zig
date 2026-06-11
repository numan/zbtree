const std = @import("std");
const btree = @import("btree.zig");
const testing = std.testing;

fn compareIntKey(a_key: isize, _: isize, b_key: isize, _: isize) i32 {
    return if (a_key < b_key) -1 else if (a_key > b_key) 1 else 0;
}
test "empty btree has expected constants" {
    const IntTree = btree.Tree(isize, isize, compareIntKey);
    const tree = IntTree.init();

    try testing.expectEqual(64, IntTree.fanout);
    try testing.expectEqual(63, IntTree.max_items);
    try testing.expectEqual(31, IntTree.min_items);
    try testing.expectEqual(0, tree.len);
    try testing.expect(tree.root == null);
}
