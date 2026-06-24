const std = @import("std");
const btree = @import("btree.zig");

const mem = std.mem;

pub const SearchMode = btree.SearchMode;
pub const DeleteRangeOptions = btree.DeleteRangeOptions;

pub fn MapConfig(comptime K: type, comptime V: type) type {
    return struct {
        /// Enables btype-style string-prefix routing. It is on by default for
        /// string keys and unavailable for non-string keys.
        use_string_prefix: bool = K == []const u8,
        search_mode: SearchMode = .auto,

        /// Optional value ownership hooks. Keys are borrowed by the map.
        copy_value: ?*const fn (mem.Allocator, V) anyerror!V = null,
        release_value: ?*const fn (mem.Allocator, V) void = null,
    };
}

fn ignoredCompare(comptime K: type, comptime V: type) fn (K, V, K, V) std.math.Order {
    return struct {
        fn compare(_: K, _: V, _: K, _: V) std.math.Order {
            unreachable;
        }
    }.compare;
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
    const Tree = btree.Tree(K, V, .{
        .compare = ignoredCompare(K, V),
        .use_string_prefix = config.use_string_prefix,
        .search_mode = config.search_mode,
        .key_only = true,
        .copy_value = config.copy_value,
        .release_value = config.release_value,
    });

    return struct {
        const Self = @This();

        pub const Entry = Tree.Entry;
        pub const DeleteRangeResult = Tree.DeleteRangeResult;
        pub const fanout = Tree.fanout;
        pub const max_items = Tree.max_items;
        pub const min_items = Tree.min_items;

        tree: Tree = Tree.init(),

        pub inline fn init() Self {
            return .{};
        }

        pub inline fn deinit(self: *Self, gpa: mem.Allocator) void {
            self.tree.deinit(gpa);
        }

        pub inline fn len(self: *const Self) usize {
            return self.tree.len;
        }

        pub inline fn isEmpty(self: *const Self) bool {
            return self.tree.len == 0;
        }

        pub inline fn insert(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            return self.tree.insertKeyOnly(gpa, key, value);
        }

        pub inline fn get(self: *const Self, key: K) ?V {
            return self.tree.getKeyOnly(key);
        }

        pub inline fn seek(self: *const Self, key: K) ?Entry {
            return self.tree.seek(key, undefined);
        }

        pub inline fn seekNext(self: *const Self, key: K) ?Entry {
            return self.tree.seekNext(key, undefined);
        }

        pub inline fn seekPrev(self: *const Self, key: K) ?Entry {
            return self.tree.seekPrev(key, undefined);
        }

        pub inline fn getAt(self: *const Self, index: usize) ?Entry {
            return self.tree.getAt(index);
        }

        pub inline fn indexOf(self: *const Self, key: K) ?usize {
            return self.tree.indexOf(key, undefined);
        }

        pub inline fn ascent(
            self: *const Self,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            return self.tree.ascent(CtxType, context, yield);
        }

        pub inline fn descent(
            self: *const Self,
            comptime CtxType: type,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!void,
        ) !void {
            return self.tree.descent(CtxType, context, yield);
        }

        pub inline fn ascendAt(
            self: *const Self,
            comptime CtxType: type,
            index: usize,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !void {
            return self.tree.ascendAt(CtxType, index, context, yield);
        }

        pub inline fn descendAt(
            self: *const Self,
            comptime CtxType: type,
            index: usize,
            context: CtxType,
            comptime yield: fn (CtxType, K, V) anyerror!bool,
        ) !void {
            return self.tree.descendAt(CtxType, index, context, yield);
        }

        pub inline fn replace(self: *Self, gpa: mem.Allocator, key: K, value: V) !?V {
            return self.tree.replace(gpa, key, value);
        }

        pub inline fn set(self: *Self, gpa: mem.Allocator, key: K, value: V) !?V {
            return self.tree.set(gpa, key, value);
        }

        pub inline fn delete(self: *Self, gpa: mem.Allocator, key: K) !?V {
            return self.tree.deleteKeyOnly(gpa, key);
        }

        pub inline fn front(self: *const Self) ?Entry {
            return self.tree.front();
        }

        pub inline fn back(self: *const Self) ?Entry {
            return self.tree.back();
        }

        pub inline fn popFront(self: *Self, gpa: mem.Allocator) !?Entry {
            return self.tree.popFront(gpa);
        }

        pub inline fn popBack(self: *Self, gpa: mem.Allocator) !?Entry {
            return self.tree.popBack(gpa);
        }

        pub inline fn pushFront(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            return self.tree.pushFront(gpa, key, value);
        }

        pub inline fn pushBack(self: *Self, gpa: mem.Allocator, key: K, value: V) !bool {
            return self.tree.pushBack(gpa, key, value);
        }

        pub inline fn deleteAt(self: *Self, gpa: mem.Allocator, index: usize) !?Entry {
            return self.tree.deleteAt(gpa, index);
        }

        pub inline fn deleteRangeAt(self: *Self, gpa: mem.Allocator, index: usize, count: usize, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.tree.deleteRangeAt(gpa, index, count, opts);
        }

        pub inline fn deleteRange(
            self: *Self,
            gpa: mem.Allocator,
            min_key: K,
            max_key: K,
            comptime opts: DeleteRangeOptions,
        ) !DeleteRangeResult {
            return self.tree.deleteRangeKeyOnly(gpa, min_key, max_key, opts);
        }

        pub inline fn deleteAllAt(self: *Self, gpa: mem.Allocator, index: usize, comptime opts: DeleteRangeOptions) !DeleteRangeResult {
            return self.tree.deleteAllAt(gpa, index, opts);
        }

        pub inline fn clear(self: *Self, gpa: mem.Allocator) void {
            self.tree.clear(gpa);
        }

        pub inline fn copy(self: *Self) Self {
            return .{ .tree = self.tree.copy() };
        }

        pub inline fn checkInvariants(self: *const Self) !void {
            return self.tree.checkInvariants();
        }
    };
}
