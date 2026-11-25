// Adapted from tidwall/btree-bench by Josh Baker:
//   https://github.com/tidwall/btree-bench/blob/main/google_btree/main.go
//   https://github.com/tidwall/btree-bench/blob/main/tools/support/support.go
// Modified for the zbtree benchmarks.

package main

import (
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"runtime"
	"slices"
	"strconv"
	"time"

	"github.com/google/btree"
)

const (
	warmupRuns = 2
	degree     = 32
)

type keyType interface {
	~int32 | ~uint64 | ~string
}

func main() {
	items := flag.Int("items", envInt("N", 1_000_000), "items per benchmark run")
	runs := flag.Int("runs", envInt("R", 50), "number of benchmark runs; median is reported")
	flag.IntVar(items, "n", *items, "items per benchmark run")
	flag.IntVar(runs, "r", *runs, "number of benchmark runs; median is reported")
	flag.Parse()
	if *items <= 0 || *runs <= 0 || flag.NArg() != 0 {
		fmt.Fprintln(os.Stderr, "usage: google_btree [--items N] [--runs R]")
		os.Exit(2)
	}

	fmt.Println("google/btree (Go, btree.BTreeG)")
	fmt.Printf("config: go=%s GOMAXPROCS=%d degree=%d warmups=%d\n", runtime.Version(), runtime.GOMAXPROCS(0), degree, warmupRuns)
	benchSet("int32", *items, *runs, func(i int) int32 { return int32(i) })
	benchSet("uint64", *items, *runs, func(i int) uint64 { return uint64(i) })
	benchSet("string", *items, *runs, strconv.Itoa)
}

type sample[T keyType] struct {
	tree *btree.BTreeG[T]
	keys []T
}

func benchSet[T keyType](keyName string, items, runs int, makeKey func(int) T) {
	fmt.Printf("Benchmarking %d items, %s keys, %d times, using median\n", items, keyName, runs)

	prepare := func(rng *rand.Rand, randomOrder, fill bool) *sample[T] {
		s := &sample[T]{tree: btree.NewOrderedG[T](degree), keys: make([]T, items)}
		for i := range s.keys {
			s.keys[i] = makeKey(i)
		}
		if randomOrder {
			rng.Shuffle(len(s.keys), func(i, j int) { s.keys[i], s.keys[j] = s.keys[j], s.keys[i] })
		} else {
			slices.Sort(s.keys)
		}
		if fill {
			s.insertAll()
		}
		return s
	}

	run := func(label string, randomOrder, fill bool, op func(*sample[T])) {
		seed := benchmarkSeed(keyName, label)
		rng := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
		runSample := func() time.Duration {
			s := prepare(rng, randomOrder, fill)
			runtime.GC()
			start := time.Now()
			op(s)
			return time.Since(start)
		}
		for range warmupRuns {
			runSample()
		}
		elapsed := make([]time.Duration, runs)
		for i := range elapsed {
			elapsed[i] = runSample()
		}
		slices.Sort(elapsed)
		fmt.Printf("%-19s", label)
		writeOutput(items, elapsed[runs/2])
	}

	run("insert(seq)", false, false, (*sample[T]).insertAll)
	run("insert(rand)", true, false, (*sample[T]).insertAll)
	run("get(seq)", false, true, (*sample[T]).getAll)
	run("get(rand)", true, true, (*sample[T]).getAll)
	fmt.Println()
}

func (s *sample[T]) insertAll() {
	for _, key := range s.keys {
		if _, replaced := s.tree.ReplaceOrInsert(key); replaced {
			panic("duplicate benchmark key")
		}
	}
}

func (s *sample[T]) getAll() {
	for _, key := range s.keys {
		if _, ok := s.tree.Get(key); !ok {
			panic("missing benchmark key")
		}
	}
}

func benchmarkSeed(keyName, label string) uint64 {
	seed := uint64(1469598103934665603)
	for _, text := range []string{keyName, label} {
		for i := 0; i < len(text); i++ {
			seed ^= uint64(text[i])
			seed *= 1099511628211
		}
	}
	return seed
}

func writeOutput(ops int, elapsed time.Duration) {
	fmt.Printf(" %s ops in %7.3f secs %7.1f ns/op %13s op/sec\n",
		commaize(ops), elapsed.Seconds(), float64(elapsed)/float64(ops), commaize(int(float64(ops)/elapsed.Seconds())))
}

func commaize(n int) string {
	s1, s2 := strconv.Itoa(n), ""
	for i, j := len(s1)-1, 0; i >= 0; i, j = i-1, j+1 {
		if j%3 == 0 && j != 0 {
			s2 = "," + s2
		}
		s2 = string(s1[i]) + s2
	}
	return s2
}

func envInt(name string, fallback int) int {
	value, ok := os.LookupEnv(name)
	if !ok {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil {
		panic(err)
	}
	return n
}
