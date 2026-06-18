package main

import (
	"cmp"
	"flag"
	"fmt"
	"math/rand/v2"
	"os"
	"reflect"
	"runtime"
	"slices"
	"strconv"
	"time"
	"unsafe"

	"github.com/tidwall/btype"
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
	if *items <= 0 || *runs <= 0 {
		panic("items and runs must be greater than zero")
	}

	runtime.GOMAXPROCS(1)
	fmt.Println("tidwall/btype (Go, btype.Map)")
	benchMap[int32](*items, *runs)
	benchMap[uint64](*items, *runs)
	benchMap[string](*items, *runs)
}

func benchMap[T keyType](items, runs int) {
	var tree *btype.Map[T, struct{}]
	fmt.Printf("Benchmarking %d items, %s keys, %d times, using median\n", items, reflect.TypeFor[T]().Name(), runs)
	bench(
		func() { tree = btype.NewMap[T, struct{}]() },
		func(key T) { assert2(tree.Insert(key, struct{}{})) },
		func(key T) { assert2(tree.Get(key)) },
		runs,
		items,
	)
	fmt.Println()
}

func bench[T keyType](clear func(), insert func(key T), get func(key T), runs, items int) {
	seed := uint64(time.Now().UnixNano())
	rng := rand.New(rand.NewPCG(0, seed))
	var keys []T

	run("insert(seq)", runs, func() {
		clear()
		keys = randKeys[T](rng, items)
		slices.SortFunc(keys, cmp.Compare[T])
	}, func() {
		for i := range items {
			insert(keys[i])
		}
	}, func(elapsed float64) {
		writeOutput(items, time.Duration(elapsed*float64(time.Second)))
	})

	run("insert(rand)", runs, func() {
		clear()
		keys = randKeys[T](rng, items)
		shuffle(rng, keys)
	}, func() {
		for i := range items {
			insert(keys[i])
		}
	}, func(elapsed float64) {
		writeOutput(items, time.Duration(elapsed*float64(time.Second)))
	})

	run("get(seq)", runs, func() {
		keys = randKeys[T](rng, items)
		slices.SortFunc(keys, cmp.Compare[T])
	}, func() {
		for i := range items {
			get(keys[i])
		}
	}, func(elapsed float64) {
		writeOutput(items, time.Duration(elapsed*float64(time.Second)))
	})

	run("get(rand)", runs, func() {
		keys = randKeys[T](rng, items)
		shuffle(rng, keys)
	}, func() {
		for i := range items {
			get(keys[i])
		}
	}, func(elapsed float64) {
		writeOutput(items, time.Duration(elapsed*float64(time.Second)))
	})
}

func run(label string, runs int, pre, op func(), done func(float64)) {
	runtime.GC()
	elapsed := make([]float64, 0, runs)
	for range runs {
		if pre != nil {
			pre()
		}
		start := time.Now()
		op()
		elapsed = append(elapsed, time.Since(start).Seconds())
	}
	slices.Sort(elapsed)
	fmt.Printf("%-19s", label)
	done(elapsed[runs/2])
}

func randKeys[T keyType](rng *rand.Rand, items int) []T {
	var empty T
	switch any(empty).(type) {
	case int32:
		keys := make([]int32, items)
		for i, j := range rng.Perm(items) {
			keys[i] = int32(j)
		}
		return unsafe.Slice((*T)(unsafe.Pointer(unsafe.SliceData(keys))), len(keys))
	case uint64:
		keys := make([]uint64, items)
		for i, j := range rng.Perm(items) {
			keys[i] = uint64(j)
		}
		return unsafe.Slice((*T)(unsafe.Pointer(unsafe.SliceData(keys))), len(keys))
	case string:
		keys := make([]string, items)
		for i, j := range rng.Perm(items) {
			keys[i] = strconv.Itoa(j)
		}
		return unsafe.Slice((*T)(unsafe.Pointer(unsafe.SliceData(keys))), len(keys))
	default:
		panic("unsupported key type")
	}
}

func shuffle[T any](rng *rand.Rand, slice []T) {
	for i := range slice {
		j := rng.IntN(i + 1)
		slice[i], slice[j] = slice[j], slice[i]
	}
}

func writeOutput(items int, elapsed time.Duration) {
	fmt.Printf(" %s ops in %7.3f secs %7.1f ns/op %13s op/sec\n",
		commaize(items), elapsed.Seconds(), float64(elapsed)/float64(items), commaize(int(float64(items)/elapsed.Seconds())))
}

func commaize(n int) string {
	s1, s2 := fmt.Sprintf("%d", n), ""
	for i, j := len(s1)-1, 0; i >= 0; i, j = i-1, j+1 {
		if j%3 == 0 && j != 0 {
			s2 = "," + s2
		}
		s2 = string(s1[i]) + s2
	}
	return s2
}

func assert2(_ any, ok bool) {
	if !ok {
		panic("assertion failed")
	}
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
