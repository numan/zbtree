const std = @import("std");

/// Ordering strategy for map-like collections where only the key participates
/// in sort order.
pub fn OrderedKey(comptime K: type, comptime V: type) type {
    return struct {
        pub const Key = K;
        pub const Value = V;
        pub const key_only = true;
        pub const use_string_prefix = K == []const u8;

        pub fn compare(a_key: K, _: V, b_key: K, _: V) i32 {
            return compareKeys(K, a_key, b_key);
        }

        pub fn less(a_key: K, b_key: K) bool {
            return compareKeys(K, a_key, b_key) < 0;
        }
    };
}

/// Ordering strategy for callers that need values to participate in sort order.
pub fn Custom(
    comptime K: type,
    comptime V: type,
    comptime compareFn: fn (K, V, K, V) i32,
) type {
    return struct {
        pub const Key = K;
        pub const Value = V;
        pub const key_only = false;
        pub const use_string_prefix = false;

        pub fn compare(a_key: K, a_value: V, b_key: K, b_value: V) i32 {
            return compareFn(a_key, a_value, b_key, b_value);
        }
    };
}

pub fn compareKeys(comptime K: type, a: K, b: K) i32 {
    if (comptime K == []const u8) {
        return switch (std.mem.order(u8, a, b)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    return if (a < b) -1 else if (a > b) 1 else 0;
}

test "ordered key compares primitive keys" {
    const IntOrder = OrderedKey(i32, void);

    try std.testing.expectEqual(@as(i32, -1), IntOrder.compare(1, {}, 2, {}));
    try std.testing.expectEqual(@as(i32, 0), IntOrder.compare(2, {}, 2, {}));
    try std.testing.expectEqual(@as(i32, 1), IntOrder.compare(3, {}, 2, {}));
}

test "ordered key compares string keys lexicographically" {
    const StringOrder = OrderedKey([]const u8, void);

    try std.testing.expect(StringOrder.use_string_prefix);
    try std.testing.expectEqual(@as(i32, -1), StringOrder.compare("10", {}, "2", {}));
    try std.testing.expectEqual(@as(i32, 0), StringOrder.compare("abc", {}, "abc", {}));
    try std.testing.expectEqual(@as(i32, 1), StringOrder.compare("abd", {}, "abc", {}));
}
