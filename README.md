# zbtree

An fast B-tree written in Zig.

Requires Zig 0.17.1 or later.

## Features

- O(log n) inserts, lookups, deletes, and seeks.
- O(1) copy-on-write snapshots with `copy()`. Copies share reference-counted
  nodes.
- O(log n) access by position (`getAt`, `indexOf`, `insertAt`, `deleteAt`).
- Fast with strings using prefixes.
- Optimized for high performance and low memory.
- Extensively tested using unit tests and fuzzing.

## Example

```zig
const std = @import("std");
const zbtree = @import("zbtree");

fn printUser(_: void, key: []const u8, name: []const u8) !void {
    std.debug.print("{s} {s}\n", .{ key, name });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    // Create a map
    const Users = zbtree.map.Map([]const u8, []const u8, .{});
    var users: Users = .init();
    defer users.deinit(gpa);

    // Add some users
    _ = try users.insert(gpa, "user:4", "Andrea");
    _ = try users.insert(gpa, "user:6", "Andy");
    _ = try users.insert(gpa, "user:2", "Andy");
    _ = try users.insert(gpa, "user:1", "Jane");
    _ = try users.insert(gpa, "user:5", "Janet");
    _ = try users.insert(gpa, "user:3", "Steve");

    // Iterate over the map in key order and print each user
    try users.ascent(void, {}, printUser);
    std.debug.print("\n", .{});

    // Delete a couple of users
    _ = try users.delete(gpa, "user:5");
    _ = try users.delete(gpa, "user:1");

    // Print the map again
    try users.ascent(void, {}, printUser);
}

// Output:
// user:1 Jane
// user:2 Andy
// user:3 Steve
// user:4 Andrea
// user:5 Janet
// user:6 Andy
//
// user:2 Andy
// user:3 Steve
// user:4 Andrea
// user:6 Andy
```

## Running the tests

```sh
zig build test
```

This runs the unit, iterative, and property tests.

To fuzz the property tests' operations and allocation failures, run
`zig build test --fuzz`.

For a bounded run, use `zig build test --fuzz=2K` (about 5 minutes) or
`zig build test --fuzz=10K` (about 20 minutes). Both run every fuzz test for
that many rounds, one after another, and show no progress until they finish.

## Running the benchmarks

The benchmarks need an explicit release mode: `-Doptimize=safe` or
`-Doptimize=fast`. By default each benchmark uses 1,000,000 items and reports
the median of 50 runs. Use `--items`/`-n` and `--runs`/`-r` after `--` to change
this, or set the `N` and `R` environment variables.

### zbtree against tidwall/btree

Requires Go.

```sh
zig build bench -Doptimize=safe
zig build bench -Doptimize=safe -- --items 100000 --runs 10
```

Runs every operation for `int32`, `uint64`, and string keys against the
[tidwall/btree](https://github.com/tidwall/btree).

To use linear search instead of the default node search, add
`-Dsearch-mode=linear`.

### zbtree against other B-trees

Requires Go and Cargo. The first run downloads [frozenca/BTree](https://github.com/frozenca/BTree).

```sh
zig build bench-all -Doptimize=safe
zig build bench-all -Doptimize=safe -- --items 100000 --runs 10
```

Compares zbtree with [tidwall/btree](https://github.com/tidwall/btree),
[google/btree](https://github.com/google/btree), Rust's [`BTreeSet`](https://github.com/rust-lang/rust/blob/main/library/alloc/src/collections/btree/set.rs),
and [frozenca/btree](https://github.com/frozenca/BTree) on `insert(seq)`, `insert(rand)`, `get(seq)`, and `get(rand)`,
using key-only collections.

### Filtering `zig build bench`

`zig build bench` also accepts these options after `--`:

- `--type=int32|uint64|string` runs one key type only.
- `--bench='get(rand),insert(seq)'` runs only the listed operations.

```sh
zig build bench -Doptimize=safe -- --type=uint64 --bench='get(rand),insert(seq)'
```

## Performance

All results below are from an Apple M3 Max (14 cores) with:

- Zig 0.17.1
- Go 1.27.4
- Rust 1.100.0 (release profile)
- C++: Clang 22.1.8 with `-std=c++20`, always built in ReleaseFast to match
  the `-O3` build in [tidwall/btree-bench](https://github.com/tidwall/btree-bench)

> [!NOTE]
> These benchmarks were run with `-Doptimize=safe`, which keeps Zig's runtime
> safety checks on. `-Doptimize=fast` gives faster results but turns those
> checks off.

### zbtree vs tidwall/btree

Results of `zig build bench`:

```text
❯ zig build bench -Doptimize=safe -- --items 200000 --runs 10
zbtree (Zig) vs tidwall/btree (Go)
200,000 items · median of 10 runs · 2 warmups
  Zig        ReleaseSafe · runtime safety ON · std.heap.smp_allocator · search mode auto
  Zig arena  same build · per-sample ArenaAllocator (reference only, not scored)
  Go         go1.27.4 · GOMAXPROCS=14 · bounds checks ON
ns/op = median time per operation, lower is better.
Result compares Zig vs Go; differences under 10% are ties.

int32 keys
operation             Zig ns/op     Go ns/op   result                Zig arena
insert(seq)                16.2         16.5   tie (1.6%)                 12.4
pushBack(seq)              10.1         16.5   Zig 1.64x faster           11.9
pushFront(seq)             20.4         30.1   Zig 1.48x faster           23.2
insert(rand)               66.1         77.2   Zig 1.17x faster           76.2
get(seq)                   11.7         29.6   Zig 2.54x faster           12.4
get(rand)                  49.4         66.1   Zig 1.34x faster           52.2
getMut(rand)               55.3         68.8   Zig 1.24x faster           53.6
set(existing)              55.6         59.7   tie (7.3%)                 53.2
replace                    57.2         59.9   tie (4.7%)                 54.7
seek                       51.6         72.2   Zig 1.40x faster           52.8
seekNext                   52.3         81.9   Zig 1.57x faster           53.4
seekPrev                   52.8         80.3   Zig 1.52x faster           52.2
indexOf                    72.8         80.6   Zig 1.11x faster           70.8
getAt                      46.4         61.9   Zig 1.33x faster           45.5
getAtMut                   48.3         61.9   Zig 1.28x faster           47.8
ascentMut                   0.9          2.0   Zig 2.34x faster            0.9
descentMut                  1.0          2.8   Zig 2.84x faster            1.0
delete(rand)               66.7         75.7   Zig 1.14x faster           69.6
deleteAt(front)            29.0         24.2   Go  1.20x faster           27.8
popFront                   28.7         24.6   Go  1.16x faster           27.4
popBack                    13.8         15.6   Zig 1.13x faster           13.7
deleteRangeAt(ret)          1.1          4.4   Zig 3.97x faster            1.1
deleteRange(ret)            1.1          4.8   Zig 4.36x faster            1.1
release                     1.9          4.0   Zig 2.06x faster            2.0
copy                        3.7          7.4   Zig 2.00x faster            3.7

uint64 keys
operation             Zig ns/op     Go ns/op   result                Zig arena
insert(seq)                10.3         20.2   Zig 1.96x faster           12.3
pushBack(seq)              10.2         20.2   Zig 1.97x faster           12.2
pushFront(seq)             22.8         38.8   Zig 1.70x faster           23.9
insert(rand)               62.3         71.1   Zig 1.14x faster           65.9
get(seq)                   16.8         31.7   Zig 1.89x faster           17.2
get(rand)                  58.8         59.2   tie (0.6%)                 61.1
getMut(rand)               61.2         64.5   tie (5.3%)                 70.2
set(existing)              53.9         61.9   Zig 1.15x faster           56.6
replace                    61.8         63.5   tie (2.7%)                 67.5
seek                       62.7         69.8   Zig 1.11x faster           67.7
seekNext                   59.8         84.3   Zig 1.41x faster           64.9
seekPrev                   60.6         82.0   Zig 1.35x faster           63.8
indexOf                    71.3         84.5   Zig 1.19x faster           71.5
getAt                      48.6         59.9   Zig 1.23x faster           49.1
getAtMut                   52.2         62.8   Zig 1.20x faster           48.8
ascentMut                   0.9          2.1   Zig 2.41x faster            0.9
descentMut                  0.9          2.2   Zig 2.46x faster            0.9
delete(rand)               69.9         78.2   Zig 1.12x faster           73.0
deleteAt(front)            28.6         26.6   tie (7.7%)                 26.0
popFront                   27.7         25.3   tie (9.4%)                 26.7
popBack                    14.7         14.4   tie (2.2%)                 13.6
deleteRangeAt(ret)          1.4          3.3   Zig 2.36x faster            1.0
deleteRange(ret)            1.3          3.9   Zig 3.06x faster            1.0
release                     1.9          3.2   Zig 1.63x faster            1.9
copy                        4.0          7.2   Zig 1.82x faster            3.7

string keys
operation             Zig ns/op     Go ns/op   result                Zig arena
insert(seq)                20.3         40.7   Zig 2.00x faster           22.2
pushBack(seq)              15.5         29.6   Zig 1.91x faster           24.6
pushFront(seq)             34.1         49.9   Zig 1.46x faster           35.8
insert(rand)              156.1        218.4   Zig 1.40x faster          143.3
get(seq)                   53.7         71.2   Zig 1.33x faster           49.5
get(rand)                 112.8        174.2   Zig 1.54x faster          132.4
getMut(rand)              101.7        187.8   Zig 1.85x faster          123.6
set(existing)             126.1        183.3   Zig 1.45x faster          118.2
replace                   113.9        175.3   Zig 1.54x faster          108.6
seek                      105.2        316.8   Zig 3.01x faster          115.8
seekNext                  103.5        281.5   Zig 2.72x faster          101.9
seekPrev                  112.2        269.4   Zig 2.40x faster          105.9
indexOf                   120.6        265.7   Zig 2.20x faster          125.9
getAt                      68.6         74.2   tie (8.1%)                 60.5
getAtMut                   64.5         71.9   Zig 1.12x faster           75.5
ascentMut                   2.4          5.4   Zig 2.21x faster            3.1
descentMut                  2.6          5.8   Zig 2.27x faster            3.0
delete(rand)              133.8        173.8   Zig 1.30x faster          139.5
deleteAt(front)            37.0         39.9   tie (7.9%)                 36.5
popFront                   36.9         42.3   Zig 1.15x faster           36.6
popBack                    16.8         22.3   Zig 1.33x faster           17.1
deleteRangeAt(ret)          3.7          9.6   Zig 2.58x faster            3.2
deleteRange(ret)            3.3         15.3   Zig 4.67x faster            3.4
release                     1.9          4.7   Zig 2.40x faster            1.9
copy                        3.7          7.3   Zig 1.97x faster            3.7

Summary (Zig vs Go; ties within 10%)
                 Zig faster   tie   Go faster
int32                    20     3           2
uint64                   19     6           0
string                   23     2           0
all                      62    11           2
```

### zbtree vs other B-trees

Results of `zig build bench-all`, using the operations and key-only collections
from the [tidwall/btree-bench](https://github.com/tidwall/btree-bench) comparison.

```text
❯ zig build bench-all -Doptimize=safe
Benchmarking 1,000,000 items, 50 runs, using the median

zbtree (Zig)
  optimize=ReleaseSafe safety=on allocator=smp search=auto values=void warmups=2
tidwall/btree/v2 (Go, btree.Map)
  go=go1.27.4 GOMAXPROCS=14 values=struct{} warmups=2
google/btree (Go, btree.BTreeG)
  go=go1.27.4 GOMAXPROCS=14 degree=32 warmups=2
rust/btree (Rust, std::collections::BTreeSet)
  rustc=1.100.0 profile=release warmups=2
frozenca/btree (C++, frozenca::BTreeSet)
  compiler=clang-22.1.8 std=c++20 fanout=64 warmups=2

### int32 keys

zbtree
insert(seq)        1,000,000 ops in   0.009 secs     8.6 ns/op   115,879,326 op/sec
insert(rand)       1,000,000 ops in   0.065 secs    65.3 ns/op    15,324,682 op/sec
get(seq)           1,000,000 ops in   0.012 secs    11.8 ns/op    84,431,826 op/sec
get(rand)          1,000,000 ops in   0.053 secs    53.2 ns/op    18,792,106 op/sec

tidwall/btree/v2
insert(seq)        1,000,000 ops in   0.012 secs    12.3 ns/op    81,320,376 op/sec
insert(rand)       1,000,000 ops in   0.070 secs    69.9 ns/op    14,296,973 op/sec
get(seq)           1,000,000 ops in   0.034 secs    34.3 ns/op    29,147,366 op/sec
get(rand)          1,000,000 ops in   0.066 secs    66.0 ns/op    15,144,688 op/sec

google/btree
insert(seq)        1,000,000 ops in   0.056 secs    55.9 ns/op    17,898,065 op/sec
insert(rand)       1,000,000 ops in   0.155 secs   155.3 ns/op     6,437,160 op/sec
get(seq)           1,000,000 ops in   0.071 secs    71.0 ns/op    14,094,350 op/sec
get(rand)          1,000,000 ops in   0.154 secs   154.4 ns/op     6,474,643 op/sec

rust/btree
insert(seq)        1,000,000 ops in   0.042 secs    41.8 ns/op    23,931,245 op/sec
insert(rand)       1,000,000 ops in   0.091 secs    90.7 ns/op    11,020,649 op/sec
get(seq)           1,000,000 ops in   0.032 secs    31.9 ns/op    31,355,293 op/sec
get(rand)          1,000,000 ops in   0.088 secs    87.6 ns/op    11,413,348 op/sec

frozenca/btree
insert(seq)        1,000,000 ops in   0.069 secs    69.3 ns/op    14,434,787 op/sec
insert(rand)       1,000,000 ops in   0.078 secs    78.1 ns/op    12,808,163 op/sec
get(seq)           1,000,000 ops in   0.034 secs    34.0 ns/op    29,377,239 op/sec
get(rand)          1,000,000 ops in   0.070 secs    70.2 ns/op    14,235,018 op/sec

### uint64 keys

zbtree
insert(seq)        1,000,000 ops in   0.009 secs     8.7 ns/op   114,551,368 op/sec
insert(rand)       1,000,000 ops in   0.064 secs    64.4 ns/op    15,537,319 op/sec
get(seq)           1,000,000 ops in   0.018 secs    17.6 ns/op    56,789,680 op/sec
get(rand)          1,000,000 ops in   0.062 secs    61.8 ns/op    16,178,961 op/sec

tidwall/btree/v2
insert(seq)        1,000,000 ops in   0.013 secs    13.2 ns/op    75,890,044 op/sec
insert(rand)       1,000,000 ops in   0.076 secs    75.9 ns/op    13,180,353 op/sec
get(seq)           1,000,000 ops in   0.035 secs    35.2 ns/op    28,428,878 op/sec
get(rand)          1,000,000 ops in   0.075 secs    74.5 ns/op    13,414,056 op/sec

google/btree
insert(seq)        1,000,000 ops in   0.057 secs    56.9 ns/op    17,561,099 op/sec
insert(rand)       1,000,000 ops in   0.164 secs   164.0 ns/op     6,097,911 op/sec
get(seq)           1,000,000 ops in   0.071 secs    71.0 ns/op    14,088,458 op/sec
get(rand)          1,000,000 ops in   0.162 secs   161.9 ns/op     6,174,775 op/sec

rust/btree
insert(seq)        1,000,000 ops in   0.042 secs    42.0 ns/op    23,782,909 op/sec
insert(rand)       1,000,000 ops in   0.093 secs    92.7 ns/op    10,785,067 op/sec
get(seq)           1,000,000 ops in   0.032 secs    31.7 ns/op    31,552,542 op/sec
get(rand)          1,000,000 ops in   0.093 secs    92.9 ns/op    10,768,633 op/sec

frozenca/btree
insert(seq)        1,000,000 ops in   0.072 secs    71.9 ns/op    13,917,650 op/sec
insert(rand)       1,000,000 ops in   0.085 secs    85.0 ns/op    11,766,320 op/sec
get(seq)           1,000,000 ops in   0.034 secs    34.0 ns/op    29,397,786 op/sec
get(rand)          1,000,000 ops in   0.075 secs    74.8 ns/op    13,369,691 op/sec

### string keys

zbtree
insert(seq)        1,000,000 ops in   0.021 secs    20.8 ns/op    48,017,286 op/sec
insert(rand)       1,000,000 ops in   0.166 secs   166.2 ns/op     6,015,783 op/sec
get(seq)           1,000,000 ops in   0.058 secs    58.4 ns/op    17,126,978 op/sec
get(rand)          1,000,000 ops in   0.154 secs   154.4 ns/op     6,475,691 op/sec

tidwall/btree/v2
insert(seq)        1,000,000 ops in   0.036 secs    36.1 ns/op    27,700,447 op/sec
insert(rand)       1,000,000 ops in   0.239 secs   239.0 ns/op     4,183,539 op/sec
get(seq)           1,000,000 ops in   0.075 secs    75.2 ns/op    13,290,891 op/sec
get(rand)          1,000,000 ops in   0.220 secs   220.3 ns/op     4,539,007 op/sec

google/btree
insert(seq)        1,000,000 ops in   0.116 secs   115.8 ns/op     8,639,147 op/sec
insert(rand)       1,000,000 ops in   0.320 secs   320.2 ns/op     3,123,161 op/sec
get(seq)           1,000,000 ops in   0.120 secs   120.4 ns/op     8,307,970 op/sec
get(rand)          1,000,000 ops in   0.303 secs   302.8 ns/op     3,302,483 op/sec

rust/btree
insert(seq)        1,000,000 ops in   0.137 secs   137.1 ns/op     7,293,416 op/sec
insert(rand)       1,000,000 ops in   0.256 secs   255.7 ns/op     3,911,444 op/sec
get(seq)           1,000,000 ops in   0.088 secs    88.1 ns/op    11,349,014 op/sec
get(rand)          1,000,000 ops in   0.360 secs   359.6 ns/op     2,780,750 op/sec

frozenca/btree
insert(seq)        1,000,000 ops in   0.134 secs   133.6 ns/op     7,484,929 op/sec
insert(rand)       1,000,000 ops in   0.286 secs   285.7 ns/op     3,499,753 op/sec
get(seq)           1,000,000 ops in   0.145 secs   144.8 ns/op     6,904,172 op/sec
get(rand)          1,000,000 ops in   0.300 secs   299.9 ns/op     3,334,168 op/sec

### ns/op by implementation (lower is better, * marks the fastest)

int32 keys
operation          zbtree    tidwall/btree/v2    google/btree    rust/btree    frozenca/btree
insert(seq)           8.6*               12.3            55.9          41.8              69.3
insert(rand)         65.3*               69.9           155.3          90.7              78.1
get(seq)             11.8*               34.3            71.0          31.9              34.0
get(rand)            53.2*               66.0           154.4          87.6              70.2

uint64 keys
operation          zbtree    tidwall/btree/v2    google/btree    rust/btree    frozenca/btree
insert(seq)           8.7*               13.2            56.9          42.0              71.9
insert(rand)         64.4*               75.9           164.0          92.7              85.0
get(seq)             17.6*               35.2            71.0          31.7              34.0
get(rand)            61.8*               74.5           161.9          92.9              74.8

string keys
operation          zbtree    tidwall/btree/v2    google/btree    rust/btree    frozenca/btree
insert(seq)          20.8*               36.1           115.8         137.1             133.6
insert(rand)        166.2*              239.0           320.2         255.7             285.7
get(seq)             58.4*               75.2           120.4          88.1             144.8
get(rand)           154.4*              220.3           302.8         359.6             299.9
```

### Why zbtree is fast

#### Data-oriented node layout

The node layout is built around what a lookup actually reads: keys, in order,
from as few cache lines as possible.

- **Keys and values in separate arrays.**
- **Leaves carry no branch data.** Leaves are the vast majority of nodes, and a
  leaf is only keys, values, a length, a reference count, and a null branch
  pointer.
- **One allocation per internal node.** An internal node and its branch data
  (children, counts, prefixes) are allocated together as one block, so they sit
  next to each other in memory and cost one allocator call.
- **Nodes sized for the allocator.** Power-of-two allocators round a node up to
  the next size class in Zig. Node capacity is tuned so a node fills its slot instead
  of wasting nearly half of it: 59 `i32` keys fit 256 bytes and 61 `u64` keys
  fit 512 bytes. More useful keys per cache line means fewer cache misses.
- **Cache-line aligned keys.**
- **Wide nodes.** Nodes hold up to 63 items, so a tree of 1M items is only
  about 4 levels deep, and most of a lookup happens in cache-friendly scans of
  one node.

#### Search

- **SIMD node search.** For integer keys, lookups compare a chunk of up to 16
  keys at once instead of one key at a time.
- **String prefixes.** Internal nodes keep the first 8 bytes of each string key
  as a number, stored inline in the branch. Most routing decisions are then one
  integer compare instead of a string compare.

#### Compile-time specialization with `comptime`

Decisions other libraries make at runtime, or pay for in every node, are
made once by the compiler:

- **Search strategy per key type and CPU.** SIMD, linear, binary, or prefix
  search is chosen at compile time, along with the SIMD chunk width for the
  target.
- **Inlined comparisons.** The built-in order and any custom `order.compare`
  are compile-time known functions, so they are inlined into the search loop.
- **Node capacity computed from the real types.** The compiler measures
  `@sizeOf` the node for each `K` and `V` and picks the item count that fills
  an allocator slot the best.
- **Unused features cost nothing.** The string prefix array is a zero-size
  `void` field for non-string keys.

#### Less work per operation

- **One walk per insert.** Inserts split full nodes on the way down and update
  the subtree counts during the same walk, instead of a second pass up the tree.
- **No recursion and no heap use for paths.**
- **Copy-on-write costs nothing until you copy.** Writes to a tree that was
  never copied skip the shared-node checks behind one predictable branch.
- **No garbage collector.** Unlike the two Go implementations, nodes are freed
  explicitly through the allocator you pass in, so there is no GC work during
  the benchmark.

## Acknowledgements

zbtree is heavily inspired by Josh Baker's [tidwall/btree](https://github.com/tidwall/btree)
for Go. Its API, design, and benchmarks follow [tidwall/btree](https://github.com/tidwall/btree)
and [tidwall/btree-bench](https://github.com/tidwall/btree-bench).

## License

Licensed under the [Apache License, Version 2.0](LICENSE).
