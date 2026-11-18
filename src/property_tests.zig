//! Property-based tests for the B-tree.
//!
//! Each test runs many random cases. A case applies a random sequence of
//! operations to one or more trees and to a sorted-array model of each tree,
//! and makes allocations fail at random points inside the operations. The
//! cases run against several tree configurations: integer and string keys,
//! string prefixes, linear and binary search, ordered-key mode, values that
//! break ties between equal keys, and `void` values.
//!
//! The properties:
//!
//! * Results: every operation and every lookup returns what the model
//!   predicts.
//! * Failures: an operation that runs out of memory leaves every tree with
//!   the contents it had before. A range delete is the one exception: it may
//!   already have removed part of its range, and nothing outside it. A
//!   mutable walk keeps the values it replaced before the failure.
//! * Allocations: removing items and updating values in place never
//!   allocate on a tree that shares no nodes, so they can't fail. A
//!   conditional pop that its predicate rejects never allocates.
//! * Structure: `checkInvariants` passes, also right after a failure.
//! * Ownership: every node and value a tree can reach is live, no value is
//!   stored in two places, each node's reference count matches the number of
//!   trees and parent nodes that point to it, nothing is live that no tree
//!   can reach, and nothing is freed twice.
//! * Copies: mutating one tree never changes another.
//!
//! The seed is `std.testing.random_seed`, which is random on every test run.
//! A failure prints it, and `zig build test --seed=0x<seed>` reruns the same
//! cases. `zig build test` caches a passing run until the code changes. To
//! run these tests again with a new seed, use
//! `zig test src/root.zig --test-filter property_tests`.

const std = @import("std");
const btree = @import("btree.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Allocator for the trees under test. It fails allocations on request and
/// records which allocations are live, so the ownership checks can tell a
/// dangling pointer from a valid one without dereferencing it.
const TrackingAllocator = struct {
    backing: Allocator,
    live: std.HashMapUnmanaged(usize, Allocation, AddressContext, std.hash_map.default_max_load_percentage) = .empty,
    /// Allocations that may still succeed before every allocation fails.
    /// Null means allocations never fail.
    budget: ?usize = null,
    /// Whether an allocation was refused because the budget ran out.
    refused: bool = false,
    /// Frees of memory that isn't live, such as a second free of the same
    /// allocation. These aren't passed on, so that the test can report them
    /// instead of crashing.
    bad_frees: usize = 0,

    /// The checks look up every node and value of every tree, and the
    /// default hash is slow in debug builds.
    const AddressContext = struct {
        pub fn hash(_: AddressContext, address: usize) u64 {
            const mixed = address *% 0x9E3779B97F4A7C15;
            return mixed ^ (mixed >> 32);
        }

        pub fn eql(_: AddressContext, a: usize, b: usize) bool {
            return a == b;
        }
    };

    const Allocation = struct {
        len: usize,
        alignment: Alignment,
        /// The ownership check that last reached this allocation, and the
        /// number of owners it has found so far.
        epoch: u32 = 0,
        owners: u32 = 0,
    };

    fn allocator(tracker: *TrackingAllocator) Allocator {
        // Growing in place would make the number of allocations an operation
        // needs depend on where its memory happens to be. Refusing keeps two
        // runs with the same seed identical.
        return .{ .ptr = tracker, .vtable = &.{
            .alloc = alloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const tracker: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (tracker.budget) |*budget| {
            if (budget.* == 0) {
                tracker.refused = true;
                return null;
            }
            budget.* -= 1;
        }
        tracker.live.ensureUnusedCapacity(tracker.backing, 1) catch return null;
        const ptr = tracker.backing.rawAlloc(len, alignment, return_address) orelse return null;
        tracker.live.putAssumeCapacity(@intFromPtr(ptr), .{ .len = len, .alignment = alignment });
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const tracker: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const address = @intFromPtr(memory.ptr);
        const allocation = tracker.live.get(address) orelse {
            tracker.bad_frees += 1;
            return;
        };
        if (allocation.len != memory.len) {
            tracker.bad_frees += 1;
            return;
        }
        _ = tracker.live.remove(address);
        tracker.backing.rawFree(memory, alignment, return_address);
    }

    /// Frees whatever is still live. After a failed property the trees can't
    /// be trusted to free their own memory.
    fn deinit(tracker: *TrackingAllocator) void {
        var entries = tracker.live.iterator();
        while (entries.next()) |entry| {
            const memory = @as([*]u8, @ptrFromInt(entry.key_ptr.*))[0..entry.value_ptr.len];
            tracker.backing.rawFree(memory, entry.value_ptr.alignment, @returnAddress());
        }
        tracker.live.deinit(tracker.backing);
    }
};

const Violation = error{PropertyViolated};

fn violation(comptime format: []const u8, args: anytype) Violation {
    std.debug.print("property violated: " ++ format ++ "\n", args);
    return error.PropertyViolated;
}

/// One entry of a tree's model. Model keys are integers in every
/// configuration; each configuration maps them to its own tree keys in an
/// order-preserving way.
const Item = struct {
    key: isize,
    tag: u64,
};

const Position = struct {
    index: usize,
    found: bool,
};

fn orderKeyToItem(key: isize, item: Item) std.math.Order {
    return std.math.order(key, item.key);
}

/// Where `key` is in the model, or where it would be inserted.
fn locate(items: []const Item, key: isize) Position {
    const index = std.sort.lowerBound(Item, items, key, orderKeyToItem);
    return .{ .index = index, .found = index < items.len and items[index].key == key };
}

/// The part of the model that a range delete removes.
const Span = struct {
    start: usize = 0,
    end: usize = 0,

    /// `deleteRangeAt(index, count, options)` on a tree of `len` items.
    fn at(len: usize, index: usize, count: usize, options: Op.Options) Span {
        if (index >= len or count == 0) return .{};
        const start = index + @intFromBool(options.min_exclusive);
        var end = index + @min(count, len - index);
        if (options.max_inclusive) end = @min(end + 1, len);
        return if (end <= start) .{} else .{ .start = start, .end = end };
    }

    /// `deleteRange(min, max, options)`: from the first item not below `min`
    /// to the first item not below `max`, with each end moved past an item
    /// equal to it when the options say so.
    fn between(items: []const Item, min: isize, max: isize, options: Op.Options) Span {
        const low = locate(items, min);
        const high = locate(items, max);
        const start = low.index + @intFromBool(options.min_exclusive and low.found);
        const end = high.index + @intFromBool(options.max_inclusive and high.found);
        return if (end <= start) .{} else .{ .start = start, .end = end };
    }
};

const Op = union(enum) {
    insert: isize,
    set: isize,
    replace: isize,
    delete: isize,
    get_mut: isize,
    push_front: isize,
    push_back: isize,
    pop_front,
    pop_back,
    pop_front_if,
    pop_back_if,
    insert_at: Slot,
    replace_at: Slot,
    delete_at: usize,
    get_at_mut: usize,
    ascent_mut,
    descent_mut,
    delete_range_at: Range,
    delete_range: KeyRange,
    delete_all_at: Tail,
    clear,
    copy,
    drop,
    // Only for trees in ordered-key mode.
    insert_key: isize,
    set_key: isize,
    replace_key: isize,
    delete_key: isize,
    get_key_mut: isize,
    delete_range_key: KeyRange,

    const Slot = struct { index: usize, key: isize };
    const Range = struct { index: usize, count: usize, options: Options };
    const KeyRange = struct { min: isize, max: isize, options: Options };
    const Tail = struct { index: usize, options: Options };
    const Options = btree.DeleteRangeOptions;
};

const Kind = std.meta.Tag(Op);

/// How often each kind of operation is picked, relative to the others.
const Mix = std.enums.EnumArray(Kind, u16);

fn pickKind(random: std.Random, mix: Mix) Kind {
    return Mix.Indexer.keyForIndex(random.weightedIndex(u16, &mix.values));
}

/// Ordered-key trees also get the key-only variants of the keyed
/// operations, about half as often as the variants that take a value.
fn withKeyOps(mix: Mix) Mix {
    var result = mix;
    result.set(.insert_key, mix.get(.insert) / 2);
    result.set(.set_key, mix.get(.set) / 2);
    result.set(.replace_key, mix.get(.replace) / 2);
    result.set(.delete_key, mix.get(.delete) / 2);
    result.set(.get_key_mut, mix.get(.get_mut) / 2);
    result.set(.delete_range_key, mix.get(.delete_range));
    return result;
}

/// Memory for the harness itself. Only the trees use the tracking allocator.
const aux = testing.allocator;

const max_trees = 4;

/// A tree configuration under test.
const Spec = struct {
    key: enum { int, string } = .int,
    /// Whether string keys keep their first 8 bytes in internal nodes.
    prefix: bool = false,
    value: enum {
        /// Each value is an allocation the tree owns, holding a unique tag.
        owned,
        /// Like `owned`, but the value also holds the low part of the model
        /// key, and the comparator breaks ties between equal tree keys with
        /// it, as an ordered collection with duplicate keys would.
        tie_break,
        /// `void`: there is nothing to own or tag.
        none,
    } = .owned,
    ordering: btree.Ordering = .compare,
    search_mode: btree.SearchMode = .auto,
};

const Profile = struct {
    cases: usize,
    max_items: usize,
    /// Whether building the first tree also runs with allocation failures.
    fill_faults: bool,
    /// Operations per case after the first tree is built.
    steps: usize,
    mix: Mix,
};

fn Suite(comptime spec: Spec) type {
    comptime {
        if (spec.value == .tie_break and (spec.key != .int or spec.ordering != .compare)) {
            @compileError("tie-break values need integer keys and a comparator");
        }
    }

    return struct {
        const K = switch (spec.key) {
            .int => isize,
            .string => []const u8,
        };
        const owns_values = spec.value != .none;
        const V = if (owns_values) []const u8 else void;
        const value_size: usize = switch (spec.value) {
            .owned => 8,
            .tie_break => 16,
            .none => 0,
        };
        const ordered = spec.ordering == .ordered_key;

        const Tree = btree.Tree(K, V, .{
            .compare = compare,
            .ordering = spec.ordering,
            .use_string_prefix = spec.prefix,
            .search_mode = spec.search_mode,
            .copy_value = if (owns_values) &copyValue else null,
            .release_value = if (owns_values) &releaseValue else null,
        });

        // ---------------------------------------------------- keys and values

        /// A tie-break tree keys model key `n` by `@divFloor(n, tie_span)`
        /// and keeps the remainder in the value.
        const tie_span = 4;

        fn compare(a: K, a_value: V, b: K, b_value: V) std.math.Order {
            const order = switch (spec.key) {
                .int => std.math.order(a, b),
                .string => std.mem.order(u8, a, b),
            };
            if (comptime spec.value != .tie_break) return order;
            if (order != .eq) return order;
            return std.math.order(minorOf(a_value), minorOf(b_value));
        }

        fn copyValue(gpa: Allocator, value: V) anyerror!V {
            return gpa.dupe(u8, value);
        }

        fn releaseValue(gpa: Allocator, value: V) void {
            gpa.free(value);
        }

        /// The tag of a value that is known to be live.
        fn tagOf(value: V) u64 {
            if (comptime !owns_values) return 0;
            return std.mem.readInt(u64, value[0..8], .little);
        }

        fn minorOf(value: []const u8) isize {
            return std.mem.readInt(i64, value[8..16], .little);
        }

        /// Model key `n` as a string key: `n / 16` as 8 big-endian bytes,
        /// with the sign bit flipped so that byte order matches numeric order,
        /// then a ninth byte for `n % 16` unless it is zero. Sixteen keys in a
        /// row share their first 8 bytes, so string prefixes both decide
        /// comparisons and tie.
        fn encode(buffer: *[9]u8, n: isize) []const u8 {
            const major: i64 = @divFloor(n, 16);
            std.mem.writeInt(u64, buffer[0..8], @as(u64, @bitCast(major)) ^ sign_bit, .big);
            buffer[8] = @intCast(@mod(n, 16));
            return if (buffer[8] == 0) buffer[0..8] else buffer;
        }

        fn decode(key: []const u8) isize {
            const major: i64 = @bitCast(std.mem.readInt(u64, key[0..8], .big) ^ sign_bit);
            const minor: i64 = if (key.len == 9) key[8] else 0;
            return @intCast(major * 16 + minor);
        }

        const sign_bit: u64 = 1 << 63;

        /// The model key of a tree item whose value is known to be live.
        fn modelKey(key: K, value: V) isize {
            const major: isize = switch (spec.key) {
                .int => key,
                .string => decode(key),
            };
            if (comptime spec.value != .tie_break) return major;
            return major * tie_span + minorOf(value);
        }

        fn itemOf(key: K, value: V) Item {
            return .{ .key = modelKey(key, value), .tag = tagOf(value) };
        }

        fn acceptEven(key: K, value: V) bool {
            return @mod(modelKey(key, value), 2) == 0;
        }

        /// A tree that holds model items.
        const Subject = struct {
            tree: Tree = .init(),
            model: std.ArrayList(Item) = .empty,
        };

        const NewValue = struct {
            bytes: if (owns_values) []u8 else void,
            tag: u64,
        };

        const Harness = struct {
            tracker: TrackingAllocator,
            prng: std.Random.DefaultPrng,
            /// Holds string keys and lookup values, which the trees borrow.
            keys: std.heap.ArenaAllocator,
            /// Whether operations run with allocation failures.
            faults: bool = false,
            key_space: isize = 16,
            subjects: std.ArrayList(Subject) = .empty,
            /// Values the harness has allocated and not yet handed to a tree.
            held: usize = 0,
            next_tag: u64 = 1,
            epoch: u32 = 0,
            visited: std.ArrayList(*Tree.Node) = .empty,
            // What was running, for the failure report.
            steps: usize = 0,
            current: ?Op = null,
            current_tree: usize = 0,
            current_budget: ?usize = null,

            fn init(backing: Allocator, seed: u64) Harness {
                return .{
                    .tracker = .{ .backing = backing },
                    .prng = .init(seed),
                    .keys = .init(std.heap.page_allocator),
                };
            }

            fn deinit(h: *Harness) void {
                for (h.subjects.items) |*subject| subject.model.deinit(aux);
                h.subjects.deinit(aux);
                h.visited.deinit(aux);
                h.tracker.deinit();
                h.keys.deinit();
            }

            fn gpa(h: *Harness) Allocator {
                return h.tracker.allocator();
            }

            /// Names the last operation. A check that doesn't run after every
            /// operation can also find what an earlier one broke.
            fn report(h: *const Harness) void {
                std.debug.print("  configuration: {any}\n", .{spec});
                if (h.current) |op| {
                    std.debug.print("  last operation: step {d}, {any} on tree {d} of {d}", .{ h.steps, op, h.current_tree + 1, h.subjects.items.len });
                } else {
                    std.debug.print("  last operation: step {d}, releasing the trees", .{h.steps});
                }
                if (h.current_budget) |budget| std.debug.print(", with its allocation {d} and every later one failing", .{budget + 1});
                std.debug.print("\n", .{});
            }

            /// The tree key for model key `n`.
            fn treeKey(h: *Harness, n: isize) Allocator.Error!K {
                switch (spec.key) {
                    .int => return if (spec.value == .tie_break) @divFloor(n, tie_span) else n,
                    .string => {
                        const buffer = try h.keys.allocator().create([9]u8);
                        return encode(buffer, n);
                    },
                }
            }

            /// The value to look up model key `n` with. Only a tie-break
            /// tree reads it.
            fn probe(h: *Harness, n: isize) Allocator.Error!V {
                switch (spec.value) {
                    .owned => return &.{},
                    .none => return {},
                    .tie_break => {
                        const bytes = try h.keys.allocator().alloc(u8, value_size);
                        std.mem.writeInt(u64, bytes[0..8], 0, .little);
                        std.mem.writeInt(i64, bytes[8..16], @mod(n, tie_span), .little);
                        return bytes;
                    },
                }
            }

            // ------------------------------------------------------------ checks

            fn audit(h: *Harness) !void {
                // Ownership first: it proves every pointer is safe to follow.
                try h.checkOwnership();
                try h.checkContents();
            }

            /// Walks every tree and counts who owns each node and value.
            fn checkOwnership(h: *Harness) !void {
                if (h.tracker.bad_frees != 0) {
                    return violation("{d} free(s) of memory that was not live, such as a double free", .{h.tracker.bad_frees});
                }

                h.epoch += 1;
                h.visited.clearRetainingCapacity();
                var values: usize = 0;
                for (h.subjects.items) |*subject| {
                    if (subject.tree.root) |root| try h.claim(root, &values);
                }

                for (h.visited.items) |node| {
                    const owners = h.nodeAllocation(node).?.owners;
                    const counted = node.rc.load(.monotonic) + 1;
                    if (counted != owners) {
                        return violation("a node has {d} owner(s) but its reference count says {d}", .{ owners, counted });
                    }
                }

                const reachable = h.visited.items.len + values + h.held;
                const live = h.tracker.live.count();
                if (live > reachable) return violation("{d} allocation(s) leaked: live but not reachable from any tree", .{live - reachable});
                // Every node and value in a tree was just found live, so what
                // is missing is a value that the caller still owns.
                if (live < reachable) return violation("{d} value(s) that no tree took were freed", .{reachable - live});
            }

            /// Records one owner of `node`. The first owner also claims the
            /// node's values and children.
            fn claim(h: *Harness, node: *Tree.Node, values: *usize) (Violation || Allocator.Error)!void {
                const allocation = h.nodeAllocation(node) orelse return violation("a tree points to a node that was freed", .{});
                if (allocation.epoch == h.epoch) {
                    allocation.owners += 1;
                    return;
                }
                allocation.epoch = h.epoch;
                allocation.owners = 1;
                try h.visited.append(aux, node);

                if (node.isLeaf() != (allocation.len == @sizeOf(Tree.Node)) or node.len > Tree.max_items) {
                    return violation("a node is corrupt: {d} items, leaf: {}", .{ node.len, node.isLeaf() });
                }
                if (comptime owns_values) {
                    for (node.values[0..node.len]) |value| {
                        const owned = h.tracker.live.getPtr(@intFromPtr(value.ptr)) orelse return violation("a node holds a value that was freed", .{});
                        if (owned.len != value_size or value.len != value_size) return violation("a node holds a corrupt value", .{});
                        if (owned.epoch == h.epoch) return violation("a value is stored in two places", .{});
                        owned.epoch = h.epoch;
                    }
                    values.* += node.len;
                }

                const branch = node.branch orelse return;
                for (branch.children[0 .. @as(usize, node.len) + 1]) |child| {
                    try h.claim(child orelse return violation("an internal node is missing a child", .{}), values);
                }
            }

            /// The live allocation that holds `node`, or null if it was
            /// freed. Leaves are allocated on their own; internal nodes sit
            /// inside an InternalNode.
            fn nodeAllocation(h: *Harness, node: *Tree.Node) ?*TrackingAllocator.Allocation {
                const address = @intFromPtr(node);
                if (h.tracker.live.getPtr(address)) |allocation| {
                    if (allocation.len == @sizeOf(Tree.Node)) return allocation;
                }
                const allocation = h.tracker.live.getPtr(address -% @offsetOf(Tree.InternalNode, "node")) orelse return null;
                return if (allocation.len == @sizeOf(Tree.InternalNode)) allocation else null;
            }

            fn checkContents(h: *Harness) !void {
                for (h.subjects.items, 0..) |*subject, index| {
                    errdefer std.debug.print("  in tree {d} of {d}\n", .{ index + 1, h.subjects.items.len });
                    const tree = &subject.tree;
                    tree.checkInvariants() catch return violation("tree {d} fails checkInvariants", .{index + 1});
                    const items = subject.model.items;
                    if (tree.len != items.len) {
                        return violation("tree {d} has len {d} but should hold {d} items", .{ index + 1, tree.len, items.len });
                    }
                    var forward: ModelWalk = .{ .expected = items };
                    try tree.ascent(*ModelWalk, &forward, ModelWalk.visit);
                    if (forward.next != items.len) return violation("ascent yields {d} items but should yield {d}", .{ forward.next, items.len });
                    var backward: ModelWalk = .{ .expected = items, .descending = true };
                    try tree.descent(*ModelWalk, &backward, ModelWalk.visit);
                    if (backward.next != items.len) return violation("descent yields {d} items but should yield {d}", .{ backward.next, items.len });
                    try h.checkReads(tree, items);
                }
            }

            /// Compares the lookups and bounded walks with the model, at
            /// random positions and keys.
            fn checkReads(h: *Harness, tree: *const Tree, items: []const Item) !void {
                const random = h.prng.random();
                try expectEntry("front", 0, tree.front(), if (items.len == 0) null else items[0]);
                try expectEntry("back", 0, tree.back(), if (items.len == 0) null else items[items.len - 1]);

                for (0..4) |_| {
                    const index = random.uintLessThan(usize, items.len + 2);
                    try expectEntry("getAt", index, tree.getAt(index), if (index < items.len) items[index] else null);

                    const n = random.intRangeLessThan(isize, -2, h.key_space + 2);
                    const at = locate(items, n);
                    const key = try h.treeKey(n);
                    const value = try h.probe(n);
                    const found: ?Item = if (at.found) items[at.index] else null;
                    const next = at.index + @intFromBool(at.found);
                    const want_seek: ?Item = if (at.index < items.len) items[at.index] else null;
                    const want_next: ?Item = if (next < items.len) items[next] else null;
                    const want_prev: ?Item = if (at.index > 0) items[at.index - 1] else null;
                    const want_index: ?usize = if (at.found) at.index else null;

                    try expectValue("get", n, tree.get(key, value), found);
                    try expectIndex("indexOf", n, tree.indexOf(key, value), want_index);
                    try expectEntry("seek", n, tree.seek(key, value), want_seek);
                    try expectEntry("seekNext", n, tree.seekNext(key, value), want_next);
                    try expectEntry("seekPrev", n, tree.seekPrev(key, value), want_prev);
                    if (comptime ordered) {
                        try expectValue("getKey", n, tree.getKey(key), found);
                        try expectIndex("indexOfKey", n, tree.indexOfKey(key), want_index);
                        try expectEntry("seekKey", n, tree.seekKey(key), want_seek);
                        try expectEntry("seekNextKey", n, tree.seekNextKey(key), want_next);
                        try expectEntry("seekPrevKey", n, tree.seekPrevKey(key), want_prev);
                    }

                    // Walks that stop early, so that the callback's result
                    // matters, and that start at separators as well as in
                    // leaves.
                    const limit = 1 + random.uintAtMost(usize, 80);
                    var up: BoundedWalk = .{ .expected = items, .next = index, .limit = limit };
                    try tree.ascendAt(*BoundedWalk, index, &up, BoundedWalk.visit);
                    const up_count = if (index >= items.len) 0 else @min(limit, items.len - index);
                    if (up.seen != up_count) return violation("ascendAt({d}) yields {d} items instead of {d}", .{ index, up.seen, up_count });

                    const last = if (items.len == 0) 0 else @min(index, items.len - 1);
                    var down: BoundedWalk = .{ .expected = items, .next = last, .limit = limit, .descending = true };
                    try tree.descendAt(*BoundedWalk, index, &down, BoundedWalk.visit);
                    const down_count = if (items.len == 0) 0 else @min(limit, last + 1);
                    if (down.seen != down_count) return violation("descendAt({d}) yields {d} items instead of {d}", .{ index, down.seen, down_count });
                }
            }

            fn expectEntry(comptime name: []const u8, arg: anytype, got: ?Tree.Entry, want: ?Item) !void {
                const entry = got orelse {
                    if (want) |item| return violation(name ++ "({d}) returned nothing instead of key {d}", .{ arg, item.key });
                    return;
                };
                const item = want orelse return violation(name ++ "({d}) returned key {d} instead of nothing", .{ arg, modelKey(entry.key, entry.value) });
                const actual = itemOf(entry.key, entry.value);
                if (!std.meta.eql(actual, item)) {
                    return violation(name ++ "({d}) returned key {d} with value #{d} instead of key {d} with value #{d}", .{ arg, actual.key, actual.tag, item.key, item.tag });
                }
            }

            fn expectValue(comptime name: []const u8, n: isize, got: ?V, want: ?Item) !void {
                const value = got orelse {
                    if (want != null) return violation(name ++ "({d}) found nothing", .{n});
                    return;
                };
                const item = want orelse return violation(name ++ "({d}) found a value for a key the tree does not hold", .{n});
                if (tagOf(value) != item.tag) return violation(name ++ "({d}) returned value #{d} instead of #{d}", .{ n, tagOf(value), item.tag });
            }

            fn expectIndex(comptime name: []const u8, n: isize, got: ?usize, want: ?usize) !void {
                if (!std.meta.eql(got, want)) return violation(name ++ "({d}) returned {any} instead of {any}", .{ n, got, want });
            }

            /// Cheap enough to run after every operation.
            fn checkLengths(h: *Harness) !void {
                if (h.tracker.bad_frees != 0) {
                    return violation("{d} free(s) of memory that was not live, such as a double free", .{h.tracker.bad_frees});
                }
                for (h.subjects.items, 0..) |*subject, index| {
                    if (subject.tree.len != subject.model.items.len) {
                        return violation("tree {d} has len {d} but should hold {d} items", .{ index + 1, subject.tree.len, subject.model.items.len });
                    }
                }
            }

            /// Checks that a value a tree handed back, which may be dangling,
            /// is live before reading it.
            fn readTag(h: *Harness, value: V) !u64 {
                if (comptime !owns_values) return 0;
                const allocation = h.tracker.live.get(@intFromPtr(value.ptr)) orelse return violation("a tree handed out a value that was freed", .{});
                if (value.len != value_size or allocation.len != value_size) return violation("a tree handed out a corrupt value", .{});
                return tagOf(value);
            }

            /// The model item for a key and value that a tree handed back.
            fn readItem(h: *Harness, key: K, value: V) !Item {
                _ = try h.readTag(value);
                return itemOf(key, value);
            }

            // --------------------------------------------------- calling the tree

            /// Decides whether the next call runs out of memory, and after how
            /// many allocations. `usual` is how many allocations such a call
            /// makes at most when it doesn't clone nodes. Cloning one node
            /// allocates up to 64 times, so much larger budgets must stay
            /// likely too.
            fn planFault(h: *Harness, usual: usize) ?usize {
                if (!h.faults) return null;
                const random = h.prng.random();
                return switch (random.uintLessThan(u8, 4)) {
                    0 => null,
                    1, 2 => random.uintLessThan(usize, usual),
                    else => random.uintLessThan(usize, @as(usize, 1) << random.uintLessThan(u6, 9)),
                };
            }

            /// Calls `func` with every allocation after the first `budget`
            /// failing. Returns null when that made the call fail.
            fn callWithFault(h: *Harness, comptime T: type, budget: usize, comptime func: anytype, args: anytype) !?T {
                h.current_budget = budget;
                h.tracker.budget = budget;
                h.tracker.refused = false;
                const result = @call(.auto, func, args);
                h.tracker.budget = null;

                if (result) |value| {
                    if (h.tracker.refused) return violation("the call succeeded although an allocation failed", .{});
                    h.current_budget = null;
                    return value;
                } else |err| {
                    if (err != error.OutOfMemory or !h.tracker.refused) return violation("the call failed with {t}", .{err});
                    return null;
                }
            }

            fn callWithoutFault(comptime T: type, comptime func: anytype, args: anytype) !T {
                return @call(.auto, func, args) catch |err| return violation("the call failed with {t} although no allocation failed", .{err});
            }

            /// Calls an operation that must leave the trees as they were if it
            /// fails. A failed call is checked and then repeated without a
            /// failure.
            fn call(h: *Harness, comptime T: type, comptime func: anytype, args: anytype) !T {
                // A point operation allocates once per node it splits.
                if (h.planFault(4)) |budget| {
                    if (try h.callWithFault(T, budget, func, args)) |value| return value;
                    try h.audit();
                    h.current_budget = null;
                }
                return callWithoutFault(T, func, args);
            }

            /// Whether a node may be shared with another tree. With one tree
            /// left, every reference count is back to zero.
            fn shared(h: *const Harness) bool {
                return h.subjects.items.len > 1;
            }

            /// Calls an operation that removes items or updates them in
            /// place. Those only allocate to clone shared nodes, so on a tree
            /// that shares none they must succeed without any allocation.
            fn callInPlace(h: *Harness, comptime T: type, comptime func: anytype, args: anytype) !T {
                if (h.shared()) return h.call(T, func, args);
                return try h.callWithFault(T, 0, func, args) orelse
                    violation("the call allocated although the tree shares no nodes", .{});
            }

            // ------------------------------------------------------------- values

            /// A new value for model key `n`.
            fn newValue(h: *Harness, n: isize) !NewValue {
                if (comptime !owns_values) return .{ .bytes = {}, .tag = 0 };
                const tag = h.next_tag;
                h.next_tag += 1;
                const bytes = try h.gpa().alloc(u8, value_size);
                std.mem.writeInt(u64, bytes[0..8], tag, .little);
                if (comptime spec.value == .tie_break) std.mem.writeInt(i64, bytes[8..16], @mod(n, tie_span), .little);
                h.held += 1;
                return .{ .bytes = bytes, .tag = tag };
            }

            /// The tree took `value` as a new item at `index`.
            fn keep(h: *Harness, subject: *Subject, index: usize, key: isize, value: NewValue) !void {
                try subject.model.insert(aux, index, .{ .key = key, .tag = value.tag });
                if (comptime owns_values) h.held -= 1;
            }

            /// The tree took `value` in place of the item at `index`.
            fn overwrite(h: *Harness, subject: *Subject, index: usize, key: isize, value: NewValue) void {
                subject.model.items[index] = .{ .key = key, .tag = value.tag };
                if (comptime owns_values) h.held -= 1;
            }

            /// The tree did not take `value`.
            fn discard(h: *Harness, value: NewValue) void {
                if (comptime !owns_values) return;
                h.gpa().free(value.bytes);
                h.held -= 1;
            }

            /// Checks a value that the tree removed and handed back, then
            /// frees it.
            fn reclaim(h: *Harness, returned: ?V, expected: ?Item) !void {
                const value = returned orelse {
                    if (expected) |item| return violation("nothing was returned for key {d}, which the tree holds", .{item.key});
                    return;
                };
                const item = expected orelse return violation("a value was returned for an item the tree does not hold", .{});
                const tag = try h.readTag(value);
                if (tag != item.tag) return violation("value #{d} was returned for key {d}, which holds #{d}", .{ tag, item.key, item.tag });
                if (comptime owns_values) h.gpa().free(value);
            }

            fn reclaimEntry(h: *Harness, returned: ?Tree.Entry, expected: ?Item) !void {
                if (returned) |entry| {
                    if (expected) |item| {
                        const actual = try h.readItem(entry.key, entry.value);
                        if (actual.key != item.key) return violation("key {d} was returned instead of key {d}", .{ actual.key, item.key });
                    }
                }
                try h.reclaim(if (returned) |entry| entry.value else null, expected);
            }

            // --------------------------------------------------------- operations

            fn apply(h: *Harness, index: usize, op: Op) !void {
                h.current = op;
                h.current_tree = index;
                h.current_budget = null;
                const subject = &h.subjects.items[index];
                switch (op) {
                    .insert => |n| try h.insert(subject, n, Tree.insert),
                    .set => |n| try h.set(subject, n, Tree.set),
                    .replace => |n| try h.replace(subject, n, Tree.replace),
                    .delete => |n| try h.delete(subject, n, Tree.delete),
                    .get_mut => |n| try h.getMut(subject, n, Tree.getMut),
                    .push_front => |n| try h.pushFront(subject, n),
                    .push_back => |n| try h.pushBack(subject, n),
                    .pop_front => try h.popFront(subject),
                    .pop_back => try h.popBack(subject),
                    .pop_front_if => try h.popIf(subject, true),
                    .pop_back_if => try h.popIf(subject, false),
                    .insert_at => |slot| try h.insertAt(subject, slot.index, slot.key),
                    .replace_at => |slot| try h.replaceAt(subject, slot.index, slot.key),
                    .delete_at => |at| try h.deleteAt(subject, at),
                    .get_at_mut => |at| try h.getAtMut(subject, at),
                    .ascent_mut => try h.walkMut(subject, false),
                    .descent_mut => try h.walkMut(subject, true),
                    .delete_range_at => |range| {
                        const span = Span.at(subject.model.items.len, range.index, range.count, range.options);
                        try h.deleteSpan(subject, span, deleteRangeAt, .{ &subject.tree, h.gpa(), range.index, range.count, range.options });
                    },
                    .delete_range => |range| {
                        const span = Span.between(subject.model.items, range.min, range.max, range.options);
                        const args = .{ &subject.tree, h.gpa(), try h.treeKey(range.min), try h.probe(range.min), try h.treeKey(range.max), try h.probe(range.max), range.options };
                        try h.deleteSpan(subject, span, deleteRange, args);
                    },
                    .delete_all_at => |tail| {
                        const len = subject.model.items.len;
                        const span = Span.at(len, tail.index, len - @min(tail.index, len), tail.options);
                        try h.deleteSpan(subject, span, deleteAllAt, .{ &subject.tree, h.gpa(), tail.index, tail.options });
                    },
                    .clear => {
                        subject.tree.clear(h.gpa());
                        subject.model.clearRetainingCapacity();
                    },
                    .copy => try h.copy(index),
                    .drop => try h.drop(index),
                    .insert_key => |n| if (comptime ordered) try h.insert(subject, n, Tree.insertKey) else unreachable,
                    .set_key => |n| if (comptime ordered) try h.set(subject, n, Tree.setKey) else unreachable,
                    .replace_key => |n| if (comptime ordered) try h.replace(subject, n, Tree.replaceKey) else unreachable,
                    .delete_key => |n| if (comptime ordered) try h.delete(subject, n, deleteKey) else unreachable,
                    .get_key_mut => |n| if (comptime ordered) try h.getMut(subject, n, getKeyMut) else unreachable,
                    .delete_range_key => |range| if (comptime ordered) {
                        const span = Span.between(subject.model.items, range.min, range.max, range.options);
                        const args = .{ &subject.tree, h.gpa(), try h.treeKey(range.min), try h.treeKey(range.max), range.options };
                        try h.deleteSpan(subject, span, deleteRangeKey, args);
                    } else unreachable,
                }
                h.steps += 1;
                try h.checkLengths();

                // A full audit costs as much as visiting every item, so run it
                // less often the more items there are. Range deletes are few
                // and restructure the most, and a later one can free the
                // nodes an earlier one broke, so check after each of them.
                const restructured = switch (op) {
                    .delete_range_at, .delete_range, .delete_range_key, .delete_all_at => true,
                    else => false,
                };
                var total: usize = 0;
                for (h.subjects.items) |*s| total += s.model.items.len;
                if (restructured or h.prng.random().uintLessThan(usize, 1 + total / 4) == 0) try h.audit();
            }

            /// `func` is `Tree.insert` or `Tree.insertKey`.
            fn insert(h: *Harness, subject: *Subject, n: isize, comptime func: anytype) !void {
                const at = locate(subject.model.items, n);
                const value = try h.newValue(n);
                const inserted = try h.call(bool, func, .{ &subject.tree, h.gpa(), try h.treeKey(n), value.bytes });
                if (inserted == at.found) return violation("insert returned {}", .{inserted});
                if (inserted) try h.keep(subject, at.index, n, value) else h.discard(value);
            }

            /// `func` is `Tree.set` or `Tree.setKey`.
            fn set(h: *Harness, subject: *Subject, n: isize, comptime func: anytype) !void {
                const at = locate(subject.model.items, n);
                const value = try h.newValue(n);
                const old = try h.call(?V, func, .{ &subject.tree, h.gpa(), try h.treeKey(n), value.bytes });
                if (at.found) {
                    try h.reclaim(old, subject.model.items[at.index]);
                    h.overwrite(subject, at.index, n, value);
                } else {
                    try h.reclaim(old, null);
                    try h.keep(subject, at.index, n, value);
                }
            }

            /// `func` is `Tree.replace` or `Tree.replaceKey`.
            fn replace(h: *Harness, subject: *Subject, n: isize, comptime func: anytype) !void {
                const at = locate(subject.model.items, n);
                const value = try h.newValue(n);
                const old = try h.callInPlace(?V, func, .{ &subject.tree, h.gpa(), try h.treeKey(n), value.bytes });
                if (at.found) {
                    try h.reclaim(old, subject.model.items[at.index]);
                    h.overwrite(subject, at.index, n, value);
                } else {
                    try h.reclaim(old, null);
                    h.discard(value);
                }
            }

            /// `func` is `Tree.delete` or `deleteKey`.
            fn delete(h: *Harness, subject: *Subject, n: isize, comptime func: anytype) !void {
                const at = locate(subject.model.items, n);
                const old = try h.callInPlace(?V, func, .{ &subject.tree, h.gpa(), try h.treeKey(n), try h.probe(n) });
                try h.reclaim(old, if (at.found) subject.model.items[at.index] else null);
                if (at.found) _ = subject.model.orderedRemove(at.index);
            }

            fn deleteKey(tree: *Tree, allocator: Allocator, key: K, _: V) !?V {
                return tree.deleteKey(allocator, key);
            }

            /// Swaps in a new value through the pointer that `func` returns.
            /// `func` is `Tree.getMut` or `getKeyMut`.
            fn getMut(h: *Harness, subject: *Subject, n: isize, comptime func: anytype) !void {
                const at = locate(subject.model.items, n);
                const slot = try h.callInPlace(?*V, func, .{ &subject.tree, h.gpa(), try h.treeKey(n), try h.probe(n) });
                const stored = slot orelse {
                    if (at.found) return violation("getMut did not find key {d}", .{n});
                    return;
                };
                if (!at.found) return violation("getMut found key {d}, which the tree does not hold", .{n});
                try h.swapValue(subject, at.index, stored);
            }

            fn getKeyMut(tree: *Tree, allocator: Allocator, key: K, _: V) !?*V {
                return tree.getKeyMut(allocator, key);
            }

            fn getAtMut(h: *Harness, subject: *Subject, index: usize) !void {
                const items = subject.model.items;
                const entry = try h.callInPlace(?Tree.EntryMut, Tree.getAtMut, .{ &subject.tree, h.gpa(), index });
                const slot = entry orelse {
                    if (index < items.len) return violation("getAtMut({d}) found nothing", .{index});
                    return;
                };
                if (index >= items.len) return violation("getAtMut({d}) found an item past the end", .{index});
                const actual = try h.readItem(slot.key, slot.value.*);
                if (!std.meta.eql(actual, items[index])) return violation("getAtMut({d}) found key {d} instead of key {d}", .{ index, actual.key, items[index].key });
                try h.swapValue(subject, index, slot.value);
            }

            /// Replaces the value of item `index` through `stored`.
            fn swapValue(h: *Harness, subject: *Subject, index: usize, stored: *V) !void {
                const n = subject.model.items[index].key;
                const value = try h.newValue(n);
                const old = stored.*;
                stored.* = value.bytes;
                try h.reclaim(old, subject.model.items[index]);
                h.overwrite(subject, index, n, value);
            }

            fn pushFront(h: *Harness, subject: *Subject, n: isize) !void {
                const items = subject.model.items;
                const fits = items.len == 0 or n < items[0].key;
                const value = try h.newValue(n);
                const pushed = try h.call(bool, Tree.pushFront, .{ &subject.tree, h.gpa(), try h.treeKey(n), value.bytes });
                if (pushed != fits) return violation("pushFront returned {}", .{pushed});
                if (pushed) try h.keep(subject, 0, n, value) else h.discard(value);
            }

            fn pushBack(h: *Harness, subject: *Subject, n: isize) !void {
                const items = subject.model.items;
                const fits = items.len == 0 or n > items[items.len - 1].key;
                const value = try h.newValue(n);
                const pushed = try h.call(bool, Tree.pushBack, .{ &subject.tree, h.gpa(), try h.treeKey(n), value.bytes });
                if (pushed != fits) return violation("pushBack returned {}", .{pushed});
                if (pushed) try h.keep(subject, items.len, n, value) else h.discard(value);
            }

            fn popFront(h: *Harness, subject: *Subject) !void {
                const entry = try h.callInPlace(?Tree.Entry, Tree.popFront, .{ &subject.tree, h.gpa() });
                try h.removedItem(subject, entry, if (subject.model.items.len == 0) null else 0);
            }

            fn popBack(h: *Harness, subject: *Subject) !void {
                const entry = try h.callInPlace(?Tree.Entry, Tree.popBack, .{ &subject.tree, h.gpa() });
                const len = subject.model.items.len;
                try h.removedItem(subject, entry, if (len == 0) null else len - 1);
            }

            /// Pops the first or last item if its model key is even.
            fn popIf(h: *Harness, subject: *Subject, comptime front: bool) !void {
                const items = subject.model.items;
                const target: ?usize = if (items.len == 0) null else if (front) 0 else items.len - 1;
                const accepted = if (target) |i| @mod(items[i].key, 2) == 0 else false;
                const func = if (front) Tree.popFrontIf else Tree.popBackIf;
                const args = .{ &subject.tree, h.gpa(), &acceptEven };
                if (accepted) {
                    const entry = try h.callInPlace(?Tree.Entry, func, args);
                    return h.removedItem(subject, entry, target);
                }
                // A rejected pop must not touch the tree, so it must not
                // clone anything either.
                const entry = try h.callWithFault(?Tree.Entry, 0, func, args) orelse
                    return violation("a pop that its predicate rejects allocated", .{});
                if (entry != null) return violation("a pop returned an item that its predicate rejects", .{});
            }

            fn deleteAt(h: *Harness, subject: *Subject, index: usize) !void {
                const entry = try h.callInPlace(?Tree.Entry, Tree.deleteAt, .{ &subject.tree, h.gpa(), index });
                try h.removedItem(subject, entry, if (index < subject.model.items.len) index else null);
            }

            /// The tree handed back `entry`, which must be the item at `index`.
            fn removedItem(h: *Harness, subject: *Subject, entry: ?Tree.Entry, index: ?usize) !void {
                try h.reclaimEntry(entry, if (index) |i| subject.model.items[i] else null);
                if (index) |i| _ = subject.model.orderedRemove(i);
            }

            fn insertAt(h: *Harness, subject: *Subject, index: usize, n: isize) !void {
                const items = subject.model.items;
                const fits = index <= items.len and
                    (index == 0 or items[index - 1].key < n) and
                    (index == items.len or n < items[index].key);
                const value = try h.newValue(n);
                const inserted = try h.call(bool, Tree.insertAt, .{ &subject.tree, h.gpa(), index, try h.treeKey(n), value.bytes });
                if (inserted != fits) return violation("insertAt returned {}", .{inserted});
                if (inserted) try h.keep(subject, index, n, value) else h.discard(value);
            }

            fn replaceAt(h: *Harness, subject: *Subject, index: usize, n: isize) !void {
                const items = subject.model.items;
                const fits = index < items.len and
                    (index == 0 or items[index - 1].key < n) and
                    (index + 1 == items.len or n < items[index + 1].key);
                const value = try h.newValue(n);
                const old = try h.callInPlace(?Tree.Entry, Tree.replaceAt, .{ &subject.tree, h.gpa(), index, try h.treeKey(n), value.bytes });
                try h.reclaimEntry(old, if (fits) items[index] else null);
                if (fits) h.overwrite(subject, index, n, value) else h.discard(value);
            }

            /// Walks the tree with `ascentMut` or `descentMut`, checking each
            /// item and replacing a few values on the way. A walk that fails
            /// partway keeps the values it already replaced, and leaves the
            /// tree otherwise as it was.
            fn walkMut(h: *Harness, subject: *Subject, comptime descending: bool) !void {
                var pool: [4]NewValue = undefined;
                const pool_len = if (owns_values) @min(pool.len, subject.model.items.len) else 0;
                for (pool[0..pool_len]) |*value| value.* = try h.newValue(0);
                var walk: MutWalk = .{ .h = h, .subject = subject, .descending = descending, .pool = pool[0..pool_len] };
                const func = if (descending) descentMut else ascentMut;
                const args = .{ &subject.tree, h.gpa(), &walk };

                const budget: ?usize = if (h.shared()) h.planFault(8) else 0;
                const finished = if (budget) |limit|
                    try h.callWithFault(void, limit, func, args) != null
                else finished: {
                    try callWithoutFault(void, func, args);
                    break :finished true;
                };
                if (finished) {
                    if (walk.visited != subject.model.items.len) {
                        return violation("a mutable walk visited {d} of {d} items", .{ walk.visited, subject.model.items.len });
                    }
                } else {
                    if (!h.shared()) return violation("the call allocated although the tree shares no nodes", .{});
                    try h.audit();
                    h.current_budget = null;
                }
                for (walk.pool[walk.used..]) |value| h.discard(value);
            }

            fn ascentMut(tree: *Tree, allocator: Allocator, walk: *MutWalk) !void {
                return tree.ascentMut(allocator, *MutWalk, walk, MutWalk.visit);
            }

            fn descentMut(tree: *Tree, allocator: Allocator, walk: *MutWalk) !void {
                return tree.descentMut(allocator, *MutWalk, walk, MutWalk.visit);
            }

            /// Runs a range delete that removes `span` of the model.
            fn deleteSpan(h: *Harness, subject: *Subject, span: Span, comptime func: anytype, args: anytype) !void {
                // A range delete allocates for every few nodes it detaches.
                if (h.planFault(32)) |budget| {
                    if (try h.callWithFault(Tree.DeleteRangeResult, budget, func, args)) |result| {
                        return h.removedRange(subject, result, span.start, span.end);
                    }
                    // A failed range delete doesn't put back what it already
                    // removed, so delete the rest by position.
                    try h.checkOwnership();
                    const end = try resync(subject, span.start, span.end);
                    try h.checkContents();
                    h.current_budget = null;
                    const rest = try callWithoutFault(Tree.DeleteRangeResult, deleteRangeAt, .{ &subject.tree, h.gpa(), span.start, end - span.start, Op.Options{} });
                    return h.removedRange(subject, rest, span.start, end);
                }
                const result = try callWithoutFault(Tree.DeleteRangeResult, func, args);
                try h.removedRange(subject, result, span.start, span.end);
            }

            // The tree takes range options at compile time.
            fn optionBits(options: Op.Options) u2 {
                return @as(u2, @intFromBool(options.min_exclusive)) << 1 | @intFromBool(options.max_inclusive);
            }

            fn optionsOf(comptime bits: u2) Op.Options {
                return .{ .min_exclusive = bits & 2 != 0, .max_inclusive = bits & 1 != 0 };
            }

            fn deleteRangeAt(tree: *Tree, allocator: Allocator, index: usize, count: usize, options: Op.Options) !Tree.DeleteRangeResult {
                switch (optionBits(options)) {
                    inline else => |bits| return tree.deleteRangeAt(allocator, index, count, comptime optionsOf(bits)),
                }
            }

            fn deleteRange(tree: *Tree, allocator: Allocator, min: K, min_value: V, max: K, max_value: V, options: Op.Options) !Tree.DeleteRangeResult {
                switch (optionBits(options)) {
                    inline else => |bits| return tree.deleteRange(allocator, min, min_value, max, max_value, comptime optionsOf(bits)),
                }
            }

            fn deleteRangeKey(tree: *Tree, allocator: Allocator, min: K, max: K, options: Op.Options) !Tree.DeleteRangeResult {
                switch (optionBits(options)) {
                    inline else => |bits| return tree.deleteRangeKey(allocator, min, max, comptime optionsOf(bits)),
                }
            }

            fn deleteAllAt(tree: *Tree, allocator: Allocator, index: usize, options: Op.Options) !Tree.DeleteRangeResult {
                switch (optionBits(options)) {
                    inline else => |bits| return tree.deleteAllAt(allocator, index, comptime optionsOf(bits)),
                }
            }

            /// `result` must hold exactly the model's items from `start` to
            /// `end`.
            fn removedRange(h: *Harness, subject: *Subject, result: Tree.DeleteRangeResult, start: usize, end: usize) !void {
                if (result.removed_count != end - start) {
                    return violation("a range delete reports {d} removed items instead of {d}", .{ result.removed_count, end - start });
                }
                var walk: ModelWalk = .{ .expected = subject.model.items[start..end], .unverified = h };
                try result.ascent(*ModelWalk, &walk, ModelWalk.visit);
                if (walk.next != end - start) return violation("a range delete returned {d} items instead of {d}", .{ walk.next, end - start });
                result.deinit(h.gpa());
                subject.model.replaceRangeAssumeCapacity(start, end - start, &.{});
            }

            /// Brings the model in line with a tree whose range delete
            /// failed. The tree may have lost items between `start` and `end`
            /// and nothing else. Returns the end of what is left of the range.
            fn resync(subject: *Subject, start: usize, end: usize) !usize {
                subject.tree.checkInvariants() catch return violation("the tree fails checkInvariants", .{});
                var left: std.ArrayList(Item) = .empty;
                errdefer left.deinit(aux);
                try subject.tree.ascent(*std.ArrayList(Item), &left, collectItem);

                var next: usize = 0;
                for (subject.model.items, 0..) |item, index| {
                    if (next < left.items.len and std.meta.eql(left.items[next], item)) {
                        next += 1;
                    } else if (index < start or index >= end) {
                        return violation("a failed range delete lost key {d}, which is outside its range", .{item.key});
                    }
                }
                if (next != left.items.len) return violation("a failed range delete left an item that the tree did not hold", .{});

                const gone = subject.model.items.len - left.items.len;
                subject.model.deinit(aux);
                subject.model = left;
                return end - gone;
            }

            fn copy(h: *Harness, index: usize) !void {
                if (h.subjects.items.len == max_trees) return;
                try h.subjects.ensureUnusedCapacity(aux, 1);
                const subject = &h.subjects.items[index];
                const model = try subject.model.clone(aux);
                h.subjects.appendAssumeCapacity(.{ .tree = subject.tree.copy(), .model = model });
            }

            fn drop(h: *Harness, index: usize) !void {
                if (h.subjects.items.len == 1) return;
                var subject = h.subjects.swapRemove(index);
                subject.tree.deinit(h.gpa());
                subject.model.deinit(aux);
                // The other trees must still own everything they shared with
                // it.
                try h.checkOwnership();
            }

            // --------------------------------------------------------- generation

            fn anyKey(h: *Harness) isize {
                return h.prng.random().intRangeLessThan(isize, 0, h.key_space);
            }

            /// A key that is in the tree about half of the time.
            fn someKey(h: *Harness, items: []const Item) isize {
                const random = h.prng.random();
                if (items.len == 0 or random.boolean()) return h.anyKey();
                return items[random.uintLessThan(usize, items.len)].key;
            }

            /// An index below `len`, or now and then one that is out of range.
            fn someIndex(h: *Harness, len: usize) usize {
                const random = h.prng.random();
                if (len == 0 or random.uintLessThan(u8, 16) == 0) return len + random.uintLessThan(usize, 3);
                return random.uintLessThan(usize, len);
            }

            /// A key that usually sorts after item `after - 1` and before item
            /// `before`, where those exist.
            fn keyBetween(h: *Harness, items: []const Item, after: usize, before: usize) isize {
                const random = h.prng.random();
                if (random.uintLessThan(u8, 8) == 0) return h.anyKey();
                const low: ?isize = if (after > 0 and after <= items.len) items[after - 1].key else null;
                const high: ?isize = if (before < items.len) items[before].key else null;
                const lowest = low orelse if (high) |key| key - 5 else 0;
                const highest = high orelse lowest + 5;
                // No room between the neighbors: the tree must refuse this key.
                if (highest - lowest < 2) return lowest;
                return random.intRangeLessThan(isize, lowest + 1, highest);
            }

            /// Half of the range deletes exclude their first item or include
            /// one past their end.
            fn someOptions(h: *Harness) Op.Options {
                const random = h.prng.random();
                if (random.boolean()) return .{};
                return .{ .min_exclusive = random.boolean(), .max_inclusive = random.boolean() };
            }

            /// A key range whose width ranges from reversed or empty to the
            /// whole key space.
            fn keyRange(h: *Harness, items: []const Item) Op.KeyRange {
                const random = h.prng.random();
                const min = h.someKey(items);
                const width: isize = switch (random.uintLessThan(u8, 4)) {
                    0 => random.intRangeAtMost(isize, -2, 4),
                    1 => random.intRangeAtMost(isize, 0, 40),
                    2 => random.intRangeAtMost(isize, 0, 800),
                    else => random.intRangeAtMost(isize, 0, h.key_space),
                };
                return .{ .min = min, .max = min + width, .options = h.someOptions() };
            }

            fn generate(h: *Harness, items: []const Item, kind: Kind) Op {
                const random = h.prng.random();
                switch (kind) {
                    .insert => return .{ .insert = h.anyKey() },
                    .set => return .{ .set = h.someKey(items) },
                    .replace => return .{ .replace = h.someKey(items) },
                    .delete => return .{ .delete = h.someKey(items) },
                    .get_mut => return .{ .get_mut = h.someKey(items) },
                    .insert_key => return .{ .insert_key = h.anyKey() },
                    .set_key => return .{ .set_key = h.someKey(items) },
                    .replace_key => return .{ .replace_key = h.someKey(items) },
                    .delete_key => return .{ .delete_key = h.someKey(items) },
                    .get_key_mut => return .{ .get_key_mut = h.someKey(items) },
                    .push_front => {
                        if (items.len == 0 or random.uintLessThan(u8, 8) == 0) return .{ .push_front = h.anyKey() };
                        return .{ .push_front = items[0].key - random.intRangeAtMost(isize, 1, 3) };
                    },
                    .push_back => {
                        if (items.len == 0 or random.uintLessThan(u8, 8) == 0) return .{ .push_back = h.anyKey() };
                        return .{ .push_back = items[items.len - 1].key + random.intRangeAtMost(isize, 1, 3) };
                    },
                    .pop_front => return .pop_front,
                    .pop_back => return .pop_back,
                    .pop_front_if => return .pop_front_if,
                    .pop_back_if => return .pop_back_if,
                    .insert_at => {
                        const index = h.someIndex(items.len + 1);
                        return .{ .insert_at = .{ .index = index, .key = h.keyBetween(items, index, index) } };
                    },
                    .replace_at => {
                        const index = h.someIndex(items.len);
                        return .{ .replace_at = .{ .index = index, .key = h.keyBetween(items, index, index + 1) } };
                    },
                    .delete_at => return .{ .delete_at = h.someIndex(items.len) },
                    .get_at_mut => return .{ .get_at_mut = h.someIndex(items.len) },
                    .ascent_mut => return .ascent_mut,
                    .descent_mut => return .descent_mut,
                    .delete_range_at => {
                        // Tiny ranges stay inside a leaf. Medium ranges detach
                        // a few whole leaves and leave most of the tree for
                        // the next one. Huge ranges detach subtrees at every
                        // level. Counts near the maximum would overflow
                        // `index + count`.
                        const count = switch (random.uintLessThan(u8, 8)) {
                            0, 1 => random.uintAtMost(usize, 4),
                            2 => random.uintAtMost(usize, items.len + 1),
                            3 => std.math.maxInt(usize) - random.uintAtMost(usize, 2),
                            else => random.uintAtMost(usize, 200),
                        };
                        return .{ .delete_range_at = .{ .index = h.someIndex(items.len), .count = count, .options = h.someOptions() } };
                    },
                    .delete_range => return .{ .delete_range = h.keyRange(items) },
                    .delete_range_key => return .{ .delete_range_key = h.keyRange(items) },
                    .delete_all_at => return .{ .delete_all_at = .{ .index = h.someIndex(items.len), .options = h.someOptions() } },
                    .clear => return .clear,
                    .copy => return .copy,
                    .drop => return .drop,
                }
            }

            // -------------------------------------------------------------- cases

            /// Mostly small trees, because they are cheap, and some with
            /// enough items for three levels.
            fn pickSize(h: *Harness, max_items: usize) usize {
                const random = h.prng.random();
                const limit: usize = switch (random.uintLessThan(u8, 4)) {
                    0 => 8,
                    1 => 150,
                    2 => 1_000,
                    else => max_items,
                };
                return random.uintAtMost(usize, @min(limit, max_items));
            }

            /// Builds the first tree with about `count` items. Ascending and
            /// descending keys leave every node half full, so that later
            /// deletes rebalance at once. Random keys leave nodes unevenly
            /// filled.
            fn fill(h: *Harness, count: usize) !void {
                const random = h.prng.random();
                h.key_space = @intCast(4 * count + 16);
                switch (random.uintLessThan(u8, 3)) {
                    0 => {
                        var key: isize = 0;
                        for (0..count) |_| {
                            key += random.intRangeAtMost(isize, 1, 4);
                            try h.apply(0, .{ .push_back = key });
                        }
                    },
                    1 => {
                        var key: isize = h.key_space;
                        for (0..count) |_| {
                            key -= random.intRangeAtMost(isize, 1, 4);
                            try h.apply(0, .{ .push_front = key });
                        }
                    },
                    else => for (0..count) |_| try h.apply(0, .{ .insert = h.anyKey() }),
                }
            }

            fn step(h: *Harness, mix: Mix) !void {
                const random = h.prng.random();
                const index = random.uintLessThan(usize, h.subjects.items.len);
                const op = h.generate(h.subjects.items[index].model.items, pickKind(random, mix));
                try h.apply(index, op);
            }

            /// Releases the trees one at a time. Each one must leave intact
            /// what the others still share with it, and the last must leave
            /// nothing behind.
            fn finish(h: *Harness) !void {
                h.current = null;
                h.current_budget = null;
                try h.audit();
                while (h.subjects.pop()) |popped| {
                    var subject = popped;
                    subject.tree.deinit(h.gpa());
                    subject.model.deinit(aux);
                    try h.checkOwnership();
                }
            }
        };

        /// Compares the items a walk yields with a slice of a model.
        const ModelWalk = struct {
            expected: []const Item,
            descending: bool = false,
            next: usize = 0,
            /// Set when the ownership check has not covered the values of
            /// this walk, so that each one is checked before it is read.
            unverified: ?*Harness = null,

            fn visit(walk: *ModelWalk, key: K, value: V) anyerror!void {
                if (walk.next == walk.expected.len) return violation("an item follows the last expected one", .{});
                const index = if (walk.descending) walk.expected.len - 1 - walk.next else walk.next;
                const want = walk.expected[index];
                const got = if (walk.unverified) |h| try h.readItem(key, value) else itemOf(key, value);
                if (!std.meta.eql(got, want)) {
                    return violation("item {d} is key {d} with value #{d} instead of key {d} with value #{d}", .{ index, got.key, got.tag, want.key, want.tag });
                }
                walk.next += 1;
            }
        };

        /// Compares a walk that starts at item `next` with the model, and
        /// stops it after `limit` items.
        const BoundedWalk = struct {
            expected: []const Item,
            next: usize,
            limit: usize,
            descending: bool = false,
            seen: usize = 0,

            fn visit(walk: *BoundedWalk, key: K, value: V) anyerror!bool {
                if (walk.next >= walk.expected.len) return violation("a walk went past the end", .{});
                const got = itemOf(key, value);
                const want = walk.expected[walk.next];
                if (!std.meta.eql(got, want)) {
                    return violation("a walk yields key {d} at item {d} instead of key {d}", .{ got.key, walk.next, want.key });
                }
                walk.seen += 1;
                if (walk.descending) {
                    walk.next = if (walk.next == 0) walk.expected.len else walk.next - 1;
                } else {
                    walk.next += 1;
                }
                return walk.seen < walk.limit;
            }
        };

        /// Checks each item of a mutable walk, and replaces the values of a
        /// few with ones from `pool`.
        const MutWalk = struct {
            h: *Harness,
            subject: *Subject,
            descending: bool,
            pool: []NewValue,
            used: usize = 0,
            visited: usize = 0,

            fn visit(walk: *MutWalk, key: K, value: *V) anyerror!void {
                const h = walk.h;
                const items = walk.subject.model.items;
                if (walk.visited == items.len) return violation("a mutable walk went past the last item", .{});
                const index = if (walk.descending) items.len - 1 - walk.visited else walk.visited;
                const got = try h.readItem(key, value.*);
                if (!std.meta.eql(got, items[index])) {
                    return violation("a mutable walk yields key {d} at item {d} instead of key {d}", .{ got.key, index, items[index].key });
                }
                walk.visited += 1;

                if (comptime !owns_values) return;
                if (walk.used == walk.pool.len or h.prng.random().uintLessThan(u8, 4) != 0) return;
                const fresh = walk.pool[walk.used];
                walk.used += 1;
                const n = items[index].key;
                if (comptime spec.value == .tie_break) std.mem.writeInt(i64, fresh.bytes[8..16], @mod(n, tie_span), .little);
                const old = value.*;
                value.* = fresh.bytes;
                h.overwrite(walk.subject, index, n, fresh);
                h.gpa().free(old);
            }
        };

        fn collectItem(items: *std.ArrayList(Item), key: K, value: V) anyerror!void {
            try items.append(aux, itemOf(key, value));
        }

        fn runCase(seed: u64, profile: Profile) !void {
            // `testing.allocator` records a stack trace for every allocation,
            // which is too slow for this many. The tracking allocator reports
            // leaks and double frees itself, so the trees only need the
            // checks for writes to freed memory.
            var memory: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
            defer _ = memory.deinit();
            var h: Harness = .init(memory.allocator(), seed);
            defer h.deinit();
            errdefer h.report();

            try h.subjects.append(aux, .{});
            h.faults = profile.fill_faults;
            try h.fill(h.pickSize(profile.max_items));
            h.faults = true;
            const mix = if (ordered) withKeyOps(profile.mix) else profile.mix;
            for (0..profile.steps) |_| try h.step(mix);
            try h.finish();
        }

        /// `salt` gives each test its own cases for the same seed.
        fn check(salt: u16, profile: Profile) !void {
            for (0..profile.cases) |case| {
                const seed = @as(u64, testing.random_seed) << 32 | @as(u64, salt) << 16 | case;
                runCase(seed, profile) catch |err| {
                    std.debug.print("  case {d}; rerun with: zig build test --seed=0x{x}\n", .{ case, testing.random_seed });
                    return err;
                };
            }
        }
    };
}

const point_mix: Mix = .initDefault(0, .{
    .insert = 80,
    .set = 40,
    .replace = 20,
    .delete = 60,
    .get_mut = 20,
    .push_front = 20,
    .push_back = 20,
    .pop_front = 20,
    .pop_back = 20,
    .pop_front_if = 10,
    .pop_back_if = 10,
    .insert_at = 20,
    .replace_at = 20,
    .delete_at = 40,
    .get_at_mut = 20,
    .ascent_mut = 2,
    .descent_mut = 2,
    .clear = 1,
});

const range_mix: Mix = .initDefault(0, .{
    .delete_range_at = 6,
    .delete_range = 3,
    .delete_all_at = 1,
});

const copy_point_mix: Mix = blk: {
    var mix = point_mix;
    mix.set(.copy, 12);
    mix.set(.drop, 10);
    break :blk mix;
};

const copy_range_mix: Mix = blk: {
    var mix = range_mix;
    mix.set(.copy, 2);
    mix.set(.drop, 1);
    break :blk mix;
};

const Default = Suite(.{});

test "point operations match a model and survive allocation failures" {
    try Default.check(1, .{ .cases = 120, .max_items = 4_000, .fill_faults = true, .steps = 400, .mix = point_mix });
}

test "range deletions match a model and survive allocation failures" {
    try Default.check(2, .{ .cases = 120, .max_items = 6_000, .fill_faults = false, .steps = 32, .mix = range_mix });
}

test "copies stay independent while point operations hit allocation failures" {
    try Default.check(3, .{ .cases = 80, .max_items = 4_000, .fill_faults = false, .steps = 300, .mix = copy_point_mix });
}

test "copies stay independent while range deletions hit allocation failures" {
    try Default.check(4, .{ .cases = 120, .max_items = 6_000, .fill_faults = false, .steps = 32, .mix = copy_range_mix });
}

/// The other configurations differ from the default in how they search,
/// compare, and store items, so they run fewer cases each, with copies
/// mixed in.
fn checkConfiguration(comptime spec: Spec, salt: u16) !void {
    const S = Suite(spec);
    try S.check(salt, .{ .cases = 32, .max_items = 4_000, .fill_faults = true, .steps = 300, .mix = copy_point_mix });
    try S.check(salt + 1, .{ .cases = 80, .max_items = 6_000, .fill_faults = false, .steps = 32, .mix = copy_range_mix });
}

test "trees with binary search match a model" {
    try checkConfiguration(.{ .search_mode = .binary }, 10);
}

test "string keys with prefixes match a model" {
    try checkConfiguration(.{ .key = .string, .prefix = true }, 20);
}

test "ordered-key trees match a model" {
    try checkConfiguration(.{ .ordering = .ordered_key }, 30);
    try checkConfiguration(.{ .ordering = .ordered_key, .search_mode = .binary }, 32);
    try checkConfiguration(.{ .key = .string, .prefix = true, .ordering = .ordered_key, .search_mode = .linear }, 34);
    try checkConfiguration(.{ .key = .string, .ordering = .ordered_key }, 36);
}

test "values that break ties between equal keys match a model" {
    try checkConfiguration(.{ .value = .tie_break }, 40);
}

test "void values match a model" {
    try checkConfiguration(.{ .value = .none }, 50);
}
