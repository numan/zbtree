const std = @import("std");
const mem = std.mem;

pub fn Tree(
    comptime K: type,
    comptime V: type,
    comptime compare: fn (K, V, K, V) i32,
) type {
    _ = compare;

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
    defer tree.deinit(std.testing.allocator);

    const leaf = try tree.newNode(std.testing.allocator, true);
    tree.destroyNode(std.testing.allocator, leaf);

    tree.root = try tree.newNode(std.testing.allocator, false);
}
