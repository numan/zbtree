// Copyright 2026 Numan (numan856@gmail.com)
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const mem = std.mem;
const btree = @import("btree.zig");

pub const SearchMode = btree.SearchMode;
pub const DeleteRangeOptions = btree.DeleteRangeOptions;
pub const Order = btree.Order;

pub fn MapConfig(comptime K: type, comptime V: type) type {
    return struct {
        /// Orders keys with a custom order, for example case-insensitive
        /// strings. Null uses the built-in order of the key type.
        order: ?Order(K) = null,
        search_mode: SearchMode = .auto,

        copy_value: ?*const fn (mem.Allocator, V) anyerror!V = null,
        release_value: ?*const fn (mem.Allocator, V) void = null,
    };
}

/// Items are ordered and identified by key only. Values never participate in
/// ordering, so inserting the same key with a different value still addresses
/// the same map entry. Keys are borrowed; use value hooks in MapConfig when the
/// map should own value storage.
pub fn Map(
    comptime K: type,
    comptime V: type,
    comptime config: MapConfig(K, V),
) type {
    const Base = btree.Tree(K, V, .{
        .order = config.order,
        .search_mode = config.search_mode,
        .copy_value = config.copy_value,
        .release_value = config.release_value,
    });

    return struct {
        const Self = @This();

        tree: Base = .init(),

        pub const fanout = Base.fanout;
        pub const max_items = Base.max_items;
        pub const min_items = Base.min_items;

        pub const Entry = Base.Entry;
        pub const EntryMut = Base.EntryMut;
        pub const DeleteRangeResult = Base.DeleteRangeResult;
        pub const RankResult = Base.RankResult;

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
            return self.tree.insertKey(gpa, key, value);
        }

        pub fn get(self: *const Self, key: K) ?V {
            return self.tree.getKey(key);
        }

        pub fn getMut(self: *Self, gpa: mem.Allocator, key: K) !?*V {
            return self.tree.getKeyMut(gpa, key);
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
            return self.tree.seekKey(key);
        }

        pub fn seekNext(self: *const Self, key: K) ?Entry {
            return self.tree.seekNextKey(key);
        }

        pub fn seekPrev(self: *const Self, key: K) ?Entry {
            return self.tree.seekPrevKey(key);
        }

        pub fn getAt(self: *const Self, index: usize) ?Entry {
            return self.tree.getAt(index);
        }

        pub fn getAtMut(self: *Self, gpa: mem.Allocator, index: usize) !?EntryMut {
            return self.tree.getAtMut(gpa, index);
        }

        /// Returns the zero-based sorted position of `key`.
        ///
        /// When the key is absent, `found` is false and `index` is the
        /// position at which it would be inserted.
        pub fn indexOf(self: *const Self, key: K) RankResult {
            return self.tree.indexOfKey(key);
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
            return self.tree.replaceKey(gpa, key, value);
        }

        pub fn set(self: *Self, gpa: mem.Allocator, key: K, value: V) !?V {
            return self.tree.setKey(gpa, key, value);
        }

        pub fn delete(self: *Self, gpa: mem.Allocator, key: K) !?V {
            return self.tree.deleteKey(gpa, key);
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
            return self.tree.deleteRangeKey(gpa, min_key, max_key, opts);
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
