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

//! Parsing shared by the tools that read benchmark harness output.
const std = @import("std");

pub const Section = struct {
    items: u64,
    key_name: []const u8,
    runs: u64,
};

/// Parses `Benchmarking N items, KEY keys, R times, using median`.
pub fn parseSectionHeader(line: []const u8) ?Section {
    const prefix = "Benchmarking ";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const items_marker = " items, ";
    const keys_marker = " keys, ";
    const times_marker = " times";
    const items_index = std.mem.indexOf(u8, line, items_marker) orelse return null;
    const items = parseCommaU64(line[prefix.len..items_index]) catch return null;
    const key_start = items_index + items_marker.len;
    const key_end = std.mem.indexOf(u8, line[key_start..], keys_marker) orelse return null;
    const runs_start = key_start + key_end + keys_marker.len;
    const runs_end = std.mem.indexOf(u8, line[runs_start..], times_marker) orelse return null;
    const runs = parseCommaU64(line[runs_start .. runs_start + runs_end]) catch return null;
    return .{ .items = items, .key_name = line[key_start .. key_start + key_end], .runs = runs };
}

pub fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

pub fn parseCommaU64(raw: []const u8) !u64 {
    var value: u64 = 0;
    for (raw) |byte| {
        if (byte == ',') continue;
        if (!isDigit(byte)) return error.InvalidBenchmarkNumber;
        value = try std.math.mul(u64, value, 10);
        value = try std.math.add(u64, value, byte - '0');
    }
    return value;
}

test "parseSectionHeader reads items, key type and runs" {
    const section = parseSectionHeader("Benchmarking 1,000,000 items, uint64 keys, 50 times, using median").?;
    try std.testing.expectEqual(@as(u64, 1_000_000), section.items);
    try std.testing.expectEqualStrings("uint64", section.key_name);
    try std.testing.expectEqual(@as(u64, 50), section.runs);

    try std.testing.expect(parseSectionHeader("insert(seq)        2,000 ops in 0.000 secs 10.0 ns/op 1 op/sec") == null);
}
