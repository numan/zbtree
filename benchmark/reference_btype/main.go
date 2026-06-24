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
	keyName := reflect.TypeFor[T]().Name()
	if keyName == "" {
		keyName = reflect.TypeFor[T]().String()
	}
	ctx := benchContext[T]{rng: rand.New(rand.NewPCG(0, uint64(time.Now().UnixNano()))), items: items}

	fmt.Printf("Benchmarking %d items, %s keys, %d times, using median\n", items, keyName, runs)
	runBench("insert(seq)", items, runs, ctx.preInsertSeq, ctx.insertAll)
	runBench("pushBack(seq)", items, runs, ctx.prePushBackSeq, ctx.pushBackAll)
	runBench("pushFront(seq)", items, runs, ctx.prePushFrontSeq, ctx.pushFrontAll)
	runBench("insert(rand)", items, runs, ctx.preInsertRand, ctx.insertAll)
	runBench("get(seq)", items, runs, ctx.preFullSeq, ctx.getAll)
	runBench("get(rand)", items, runs, ctx.preFullRand, ctx.getAll)
	runBench("set(existing)", items, runs, ctx.preFullRand, ctx.setAll)
	runBench("replace", items, runs, ctx.preFullRand, ctx.replaceAll)
	runBench("seek", items, runs, ctx.preFullRand, ctx.seekAll)
	runBench("seekNext", items, runs, ctx.preFullRand, ctx.seekNextAll)
	runBench("seekPrev", items, runs, ctx.preFullRand, ctx.seekPrevAll)
	runBench("indexOf", items, runs, ctx.preFullRand, ctx.indexOfAll)
	runBench("getAt", items, runs, ctx.preFullSeq, ctx.getAtAll)
	runBench("delete(rand)", items, runs, ctx.preFullRand, ctx.deleteAll)
	runBench("deleteAt(front)", items, runs, ctx.preFullSeq, ctx.deleteAtFrontAll)
	runBench("popFront", items, runs, ctx.preFullSeq, ctx.popFrontAll)
	runBench("popBack", items, runs, ctx.preFullSeq, ctx.popBackAll)
	rangeOps := partialRangeCount(items)
	runBench("deleteRangeAt(ret)", rangeOps, runs, ctx.preFullSeq, ctx.deleteRangeAtReturning)
	runBench("deleteRange(ret)", rangeOps, runs, ctx.preFullSeq, ctx.deleteRangeReturning)
	runBench("release", items, runs, ctx.preFullSeq, ctx.releaseAll)
	runBench("copy", 1, runs, ctx.preFullSeq, ctx.copyOnce)
	fmt.Println()
}

type benchContext[T keyType] struct {
	rng      *rand.Rand
	items    int
	tree     *btype.Map[T, struct{}]
	keys     []T
	checksum int
}

func (c *benchContext[T]) preInsertSeq() {
	c.tree = btype.NewMap[T, struct{}]()
	c.keys = randKeys[T](c.rng, c.items)
	slices.SortFunc(c.keys, cmp.Compare[T])
}

func (c *benchContext[T]) preInsertRand() {
	c.tree = btype.NewMap[T, struct{}]()
	c.keys = randKeys[T](c.rng, c.items)
	shuffle(c.rng, c.keys)
}

func (c *benchContext[T]) prePushBackSeq() {
	c.preInsertSeq()
}

func (c *benchContext[T]) prePushFrontSeq() {
	c.preInsertSeq()
	slices.Reverse(c.keys)
}

func (c *benchContext[T]) preFullSeq() {
	c.fillTree(false)
}

func (c *benchContext[T]) preFullRand() {
	c.fillTree(true)
}

func (c *benchContext[T]) fillTree(randomOrder bool) {
	if randomOrder {
		c.preInsertRand()
	} else {
		c.preInsertSeq()
	}
	c.insertAll()
}

func (c *benchContext[T]) insertAll() {
	for _, key := range c.keys {
		_, ok := c.tree.Insert(key, struct{}{})
		assert(ok)
	}
	runtime.KeepAlive(c.tree.Len())
}

func (c *benchContext[T]) pushBackAll() {
	for _, key := range c.keys {
		assert(c.tree.PushBack(key, struct{}{}))
	}
	runtime.KeepAlive(c.tree.Len())
}

func (c *benchContext[T]) pushFrontAll() {
	for _, key := range c.keys {
		assert(c.tree.PushFront(key, struct{}{}))
	}
	runtime.KeepAlive(c.tree.Len())
}

func (c *benchContext[T]) getAll() {
	found := 0
	for _, key := range c.keys {
		_, ok := c.tree.Get(key)
		assert(ok)
		found++
	}
	c.record(found)
}

func (c *benchContext[T]) setAll() {
	for _, key := range c.keys {
		c.tree.Set(key, struct{}{})
	}
	runtime.KeepAlive(c.tree.Len())
}

func (c *benchContext[T]) replaceAll() {
	found := 0
	for _, key := range c.keys {
		_, ok := c.tree.Replace(key, struct{}{})
		assert(ok)
		found++
	}
	c.record(found)
}

func (c *benchContext[T]) seekAll() {
	found := 0
	for _, key := range c.keys {
		_, _, ok := c.tree.Seek(key)
		assert(ok)
		found++
	}
	c.record(found)
}

func (c *benchContext[T]) seekNextAll() {
	found := 0
	for _, key := range c.keys {
		_, _, ok := c.tree.SeekNext(key)
		if ok {
			found++
		}
	}
	c.record(found)
}

func (c *benchContext[T]) seekPrevAll() {
	found := 0
	for _, key := range c.keys {
		_, _, ok := c.tree.SeekPrev(key)
		if ok {
			found++
		}
	}
	c.record(found)
}

func (c *benchContext[T]) indexOfAll() {
	found := 0
	for _, key := range c.keys {
		_, ok := c.tree.IndexOf(key)
		assert(ok)
		found++
	}
	c.record(found)
}

func (c *benchContext[T]) getAtAll() {
	found := 0
	for i := range c.items {
		_, _, ok := c.tree.GetAt(i)
		assert(ok)
		found++
	}
	c.record(found)
}

func (c *benchContext[T]) deleteAll() {
	deleted := 0
	for _, key := range c.keys {
		_, ok := c.tree.Delete(key)
		assert(ok)
		deleted++
	}
	c.record(deleted)
}

func (c *benchContext[T]) deleteAtFrontAll() {
	deleted := 0
	for {
		_, _, ok := c.tree.DeleteAt(0)
		if !ok {
			break
		}
		deleted++
	}
	assert(deleted == c.items)
	c.record(deleted)
}

func (c *benchContext[T]) popFrontAll() {
	deleted := 0
	for {
		_, _, ok := c.tree.PopFront()
		if !ok {
			break
		}
		deleted++
	}
	assert(deleted == c.items)
	c.record(deleted)
}

func (c *benchContext[T]) popBackAll() {
	deleted := 0
	for {
		_, _, ok := c.tree.PopBack()
		if !ok {
			break
		}
		deleted++
	}
	assert(deleted == c.items)
	c.record(deleted)
}

func (c *benchContext[T]) deleteRangeAtReturning() {
	count := partialRangeCount(c.items)
	start := partialRangeStart(c.items, count)
	removed := c.tree.DeleteRangeAt(start, count)
	assert(removed.Len() == count)
	assert(c.tree.Len() == c.items-count)
	c.record(count)
}

func (c *benchContext[T]) deleteRangeReturning() {
	first, last, ok := c.partialRangeBounds()
	assert(ok)
	count := partialRangeCount(c.items)
	removed := c.tree.DeleteRangeOptions(first, last, btype.DeleteRangeOptions{MaxInclusive: true})
	assert(removed.Len() == count)
	assert(c.tree.Len() == c.items-count)
	c.record(count)
}

func (c *benchContext[T]) partialRangeBounds() (T, T, bool) {
	count := partialRangeCount(c.items)
	start := partialRangeStart(c.items, count)
	first, _, ok := c.tree.GetAt(start)
	if !ok {
		var zero T
		return zero, zero, false
	}
	last, _, ok := c.tree.GetAt(start + count - 1)
	return first, last, ok
}

func (c *benchContext[T]) releaseAll() {
	c.tree.Release()
	c.record(c.items)
}

func (c *benchContext[T]) copyOnce() {
	copy := c.tree.Copy()
	copy.Release()
	c.record(1)
}

func (c *benchContext[T]) record(value int) {
	c.checksum += value
	runtime.KeepAlive(c.checksum)
}

func runBench(label string, ops, runs int, pre, op func()) {
	runtime.GC()
	elapsed := make([]time.Duration, 0, runs)
	for range runs {
		pre()
		start := time.Now()
		op()
		elapsed = append(elapsed, time.Since(start))
	}
	slices.Sort(elapsed)
	median := elapsed[runs/2]
	fmt.Printf("%-19s", label)
	writeOutput(ops, median)
}

func partialRangeCount(items int) int {
	return max(1, items/10)
}

func partialRangeStart(items, count int) int {
	return (items - count) / 2
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

func writeOutput(ops int, elapsed time.Duration) {
	fmt.Printf(" %s ops in %7.3f secs %7.1f ns/op %13s op/sec\n",
		commaize(ops), elapsed.Seconds(), float64(elapsed)/float64(ops), commaize(int(float64(ops)/elapsed.Seconds())))
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

func assert(ok bool) {
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
