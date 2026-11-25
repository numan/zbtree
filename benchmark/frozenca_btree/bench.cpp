// Adapted from tidwall/btree-bench by Josh Baker:
//   https://github.com/tidwall/btree-bench/blob/main/frozenca_btree/bench.cpp
//   https://github.com/tidwall/btree-bench/blob/main/frozenca_btree/bench.h
// Modified for the zbtree benchmarks.

#include <fc/btree.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr int warmup_runs = 2;
constexpr std::size_t fanout = 64;

struct Options {
  std::size_t items = 1000000;
  std::size_t runs = 50;
};

struct CStrLess {
  bool operator()(const char *a, const char *b) const noexcept {
    return std::strcmp(a, b) < 0;
  }
};

struct Int32Keys {
  using Key = std::int32_t;
  using Tree = frozenca::BTreeSet<Key, fanout>;
  static constexpr const char *name = "int32";
};

struct UInt64Keys {
  using Key = std::uint64_t;
  using Tree = frozenca::BTreeSet<Key, fanout>;
  static constexpr const char *name = "uint64";
};

// Mirrors upstream btree-bench: string keys are C strings compared with strcmp.
struct StringKeys {
  using Key = const char *;
  using Tree = frozenca::BTreeSet<Key, fanout, CStrLess>;
  static constexpr const char *name = "string";
};

[[noreturn]] void fail(const char *message) {
  std::fprintf(stderr, "error: %s\n", message);
  std::exit(1);
}

[[noreturn]] void usage() {
  std::fprintf(stderr, "usage: frozenca-bench [--items N] [--runs R]\n");
  std::exit(2);
}

struct SplitMix64 {
  std::uint64_t state;

  std::uint64_t next() {
    state += 0x9e3779b97f4a7c15ULL;
    std::uint64_t z = state;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
  }

  template <typename T> void shuffle(std::vector<T> &values) {
    for (std::size_t i = values.size(); i > 1; i--) {
      std::size_t j = next() % i;
      std::swap(values[i - 1], values[j]);
    }
  }
};

template <typename Keys> struct Sample {
  typename Keys::Tree tree;
  std::vector<typename Keys::Key> keys;
  // Backing storage for string keys.
  std::vector<char> bytes;

  void prepare(SplitMix64 &rng, std::size_t items, bool random_order,
               bool fill) {
    keys.resize(items);
    if constexpr (std::is_same_v<Keys, StringKeys>) {
      std::size_t total = 0;
      for (std::size_t i = 0; i < items; i++) {
        total += std::to_string(i).size() + 1;
      }
      bytes.resize(total);
      std::size_t offset = 0;
      for (std::size_t i = 0; i < items; i++) {
        int written = std::snprintf(bytes.data() + offset, total - offset,
                                    "%zu", i);
        keys[i] = bytes.data() + offset;
        offset += static_cast<std::size_t>(written) + 1;
      }
    } else {
      for (std::size_t i = 0; i < items; i++) {
        keys[i] = static_cast<typename Keys::Key>(i);
      }
    }
    if (random_order) {
      rng.shuffle(keys);
    } else if constexpr (std::is_same_v<Keys, StringKeys>) {
      std::sort(keys.begin(), keys.end(), CStrLess{});
    }
    if (fill) {
      insert_all();
    }
  }

  void insert_all() {
    for (auto key : keys) {
      if (!tree.insert(key).second) {
        fail("duplicate benchmark key");
      }
    }
  }

  void get_all() {
    for (auto key : keys) {
      if (!tree.contains(key)) {
        fail("missing benchmark key");
      }
    }
  }
};

std::uint64_t benchmark_seed(const char *key_name, const char *label) {
  std::uint64_t seed = 1469598103934665603ULL;
  for (const char *text : {key_name, label}) {
    for (const char *p = text; *p != '\0'; p++) {
      seed ^= static_cast<unsigned char>(*p);
      seed *= 1099511628211ULL;
    }
  }
  return seed;
}

std::string commaize(std::uint64_t n) {
  std::string digits = std::to_string(n);
  std::string out;
  for (std::size_t i = 0; i < digits.size(); i++) {
    if (i != 0 && (digits.size() - i) % 3 == 0) {
      out.push_back(',');
    }
    out.push_back(digits[i]);
  }
  return out;
}

void write_result(const char *label, std::size_t ops, double secs) {
  std::printf("%-19s%s ops in %7.3f secs %7.1f ns/op %13s op/sec\n", label,
              commaize(ops).c_str(), secs, secs * 1e9 / static_cast<double>(ops),
              commaize(static_cast<std::uint64_t>(static_cast<double>(ops) / secs))
                  .c_str());
}

template <typename Keys>
void run(const Options &options, const char *label, bool random_order,
         bool fill, void (Sample<Keys>::*op)()) {
  SplitMix64 rng{benchmark_seed(Keys::name, label)};
  auto run_sample = [&]() {
    Sample<Keys> sample;
    sample.prepare(rng, options.items, random_order, fill);
    auto start = std::chrono::steady_clock::now();
    (sample.*op)();
    auto end = std::chrono::steady_clock::now();
    return std::chrono::duration<double>(end - start).count();
  };
  for (int i = 0; i < warmup_runs; i++) {
    run_sample();
  }
  std::vector<double> elapsed(options.runs);
  for (auto &sample : elapsed) {
    sample = run_sample();
  }
  std::sort(elapsed.begin(), elapsed.end());
  write_result(label, options.items, elapsed[options.runs / 2]);
}

template <typename Keys> void bench(const Options &options) {
  std::printf("Benchmarking %zu items, %s keys, %zu times, using median\n",
              options.items, Keys::name, options.runs);
  run<Keys>(options, "insert(seq)", false, false, &Sample<Keys>::insert_all);
  run<Keys>(options, "insert(rand)", true, false, &Sample<Keys>::insert_all);
  run<Keys>(options, "get(seq)", false, true, &Sample<Keys>::get_all);
  run<Keys>(options, "get(rand)", true, true, &Sample<Keys>::get_all);
  std::printf("\n");
}

std::size_t parse_count(const char *text) {
  char *end = nullptr;
  unsigned long long value = std::strtoull(text, &end, 10);
  if (end == text || *end != '\0' || value == 0) {
    usage();
  }
  return static_cast<std::size_t>(value);
}

Options parse_options(int argc, char **argv) {
  Options options;
  if (const char *n = std::getenv("N")) {
    options.items = parse_count(n);
  }
  if (const char *r = std::getenv("R")) {
    options.runs = parse_count(r);
  }
  for (int i = 1; i < argc; i++) {
    std::string arg = argv[i];
    std::string name = arg;
    std::string value;
    if (auto eq = arg.find('='); eq != std::string::npos) {
      name = arg.substr(0, eq);
      value = arg.substr(eq + 1);
    } else if (i + 1 < argc) {
      value = argv[++i];
    } else {
      usage();
    }
    if (name == "--items" || name == "-n") {
      options.items = parse_count(value.c_str());
    } else if (name == "--runs" || name == "-r") {
      options.runs = parse_count(value.c_str());
    } else {
      usage();
    }
  }
  return options;
}

} // namespace

int main(int argc, char **argv) {
  Options options = parse_options(argc, argv);
  std::printf("frozenca/btree (C++, frozenca::BTreeSet)\n");
  std::printf("config: compiler=clang-%d.%d.%d std=c++20 fanout=%zu warmups=%d\n",
              __clang_major__, __clang_minor__, __clang_patchlevel__, fanout,
              warmup_runs);
  bench<Int32Keys>(options);
  bench<UInt64Keys>(options);
  bench<StringKeys>(options);
  return 0;
}
