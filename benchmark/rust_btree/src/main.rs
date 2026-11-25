// Adapted from tidwall/btree-bench by Josh Baker:
//   https://github.com/tidwall/btree-bench/blob/main/rust_btree/src/main.rs
// Modified for the zbtree benchmarks.

use std::collections::BTreeSet;
use std::process::exit;
use std::time::{Duration, Instant};

const WARMUP_RUNS: usize = 2;

trait Key: Ord + Clone {
    const NAME: &'static str;
    fn from_ordinal(i: usize) -> Self;
}

impl Key for i32 {
    const NAME: &'static str = "int32";
    fn from_ordinal(i: usize) -> Self {
        i as i32
    }
}

impl Key for u64 {
    const NAME: &'static str = "uint64";
    fn from_ordinal(i: usize) -> Self {
        i as u64
    }
}

impl Key for String {
    const NAME: &'static str = "string";
    fn from_ordinal(i: usize) -> Self {
        i.to_string()
    }
}

struct Options {
    items: usize,
    runs: usize,
}

struct Sample<T> {
    tree: BTreeSet<T>,
    keys: Vec<T>,
}

impl<T: Key> Sample<T> {
    fn prepare(rng: &mut SplitMix64, items: usize, random_order: bool, fill: bool) -> Self {
        let mut keys: Vec<T> = (0..items).map(T::from_ordinal).collect();
        if random_order {
            rng.shuffle(&mut keys);
        } else {
            keys.sort_unstable();
        }
        let mut sample = Sample {
            tree: BTreeSet::new(),
            keys,
        };
        if fill {
            for key in &sample.keys {
                assert_inserted(sample.tree.insert(key.clone()));
            }
        }
        sample
    }

    fn insert_all(&mut self) {
        for key in self.keys.drain(..) {
            assert_inserted(self.tree.insert(key));
        }
    }

    fn get_all(&mut self) {
        for key in &self.keys {
            if !self.tree.contains(key) {
                fail("missing benchmark key");
            }
        }
    }
}

fn assert_inserted(inserted: bool) {
    if !inserted {
        fail("duplicate benchmark key");
    }
}

fn bench<T: Key>(options: &Options) {
    println!(
        "Benchmarking {} items, {} keys, {} times, using median",
        options.items,
        T::NAME,
        options.runs
    );
    let run = |label: &str, random_order: bool, fill: bool, op: fn(&mut Sample<T>)| {
        let mut rng = SplitMix64(benchmark_seed(T::NAME, label));
        let mut run_sample = || {
            let mut sample = Sample::<T>::prepare(&mut rng, options.items, random_order, fill);
            let start = Instant::now();
            op(&mut sample);
            let elapsed = start.elapsed();
            drop(sample);
            elapsed
        };
        for _ in 0..WARMUP_RUNS {
            run_sample();
        }
        let mut elapsed: Vec<Duration> = (0..options.runs).map(|_| run_sample()).collect();
        elapsed.sort_unstable();
        write_result(label, options.items, elapsed[options.runs / 2]);
    };
    run("insert(seq)", false, false, Sample::insert_all);
    run("insert(rand)", true, false, Sample::insert_all);
    run("get(seq)", false, true, Sample::get_all);
    run("get(rand)", true, true, Sample::get_all);
    println!();
}

fn main() {
    let options = parse_options();
    println!("rust/btree (Rust, std::collections::BTreeSet)");
    println!(
        "config: rustc={} profile=release warmups={}",
        env!("BENCH_RUSTC_VERSION"),
        WARMUP_RUNS
    );
    bench::<i32>(&options);
    bench::<u64>(&options);
    bench::<String>(&options);
}

fn parse_options() -> Options {
    let mut options = Options {
        items: env_usize("N", 1_000_000),
        runs: env_usize("R", 50),
    };
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let arg = args[i].as_str();
        let (name, inline_value) = match arg.split_once('=') {
            Some((name, value)) => (name, Some(value.to_string())),
            None => (arg, None),
        };
        let value = match inline_value {
            Some(value) => value,
            None => {
                i += 1;
                args.get(i).cloned().unwrap_or_else(|| usage())
            }
        };
        let parsed: usize = value.parse().unwrap_or_else(|_| usage());
        match name {
            "--items" | "-n" => options.items = parsed,
            "--runs" | "-r" => options.runs = parsed,
            _ => usage(),
        }
        i += 1;
    }
    if options.items == 0 || options.runs == 0 {
        usage();
    }
    options
}

fn env_usize(name: &str, default: usize) -> usize {
    match std::env::var(name) {
        Ok(value) => value.parse().unwrap_or_else(|_| usage()),
        Err(_) => default,
    }
}

fn usage() -> ! {
    eprintln!("usage: rust-btree-bench [--items N] [--runs R]");
    exit(2);
}

fn fail(message: &str) -> ! {
    eprintln!("error: {message}");
    exit(1);
}

struct SplitMix64(u64);

impl SplitMix64 {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }

    fn shuffle<T>(&mut self, slice: &mut [T]) {
        for i in (1..slice.len()).rev() {
            let j = (self.next() % (i as u64 + 1)) as usize;
            slice.swap(i, j);
        }
    }
}

fn benchmark_seed(key_name: &str, label: &str) -> u64 {
    let mut seed: u64 = 1469598103934665603;
    for byte in key_name.bytes().chain(label.bytes()) {
        seed ^= byte as u64;
        seed = seed.wrapping_mul(1099511628211);
    }
    seed
}

fn write_result(label: &str, ops: usize, elapsed: Duration) {
    let secs = elapsed.as_secs_f64();
    println!(
        "{:<19}{} ops in {:7.3} secs {:7.1} ns/op {:>13} op/sec",
        label,
        commaize(ops as u64),
        secs,
        secs * 1e9 / ops as f64,
        commaize((ops as f64 / secs) as u64)
    );
}

fn commaize(n: u64) -> String {
    let digits = n.to_string();
    let mut out = String::with_capacity(digits.len() + digits.len() / 3);
    for (i, digit) in digits.chars().enumerate() {
        if i != 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}
