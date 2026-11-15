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

const warmupRuns = 2

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

	fmt.Println("tidwall/btype (Go, btype.Map)")
	fmt.Printf("config: go=%s GOMAXPROCS=%d warmups=%d\n", runtime.Version(), runtime.GOMAXPROCS(0), warmupRuns)
	benchMap[int32](*items, *runs)
	benchMap[uint64](*items, *runs)
	benchMap[string](*items, *runs)
}

func benchMap[T keyType](items, runs int) {
	keyName := reflect.TypeFor[T]().Name()
	if keyName == "" {
		keyName = reflect.TypeFor[T]().String()
	}
	ctx := benchContext[T]{items: items, copyBatchOps: copyBatchCount(items)}
	run := func(label string, ops int, pre, op func()) {
		runBench(label, ops, runs, func() {
			seed := benchmarkSeed(keyName, label)
			ctx.rng = rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
		}, pre, op)
	}

	fmt.Printf("Benchmarking %d items, %s keys, %d times, using median\n", items, keyName, runs)
	run("insert(seq)", items, ctx.preInsertSeq, ctx.insertAll)
	run("pushBack(seq)", items, ctx.prePushBackSeq, ctx.pushBackAll)
	run("pushFront(seq)", items, ctx.prePushFrontSeq, ctx.pushFrontAll)
	run("insert(rand)", items, ctx.preInsertRand, ctx.insertAll)
	run("get(seq)", items, ctx.preFullSeq, ctx.getAll)
	run("get(rand)", items, ctx.preFullRand, ctx.getAll)
	run("getMut(rand)", items, ctx.preFullRand, ctx.getMutAll)
	run("set(existing)", items, ctx.preFullRand, ctx.setAll)
	run("replace", items, ctx.preFullRand, ctx.replaceAll)
	run("seek", items, ctx.preFullRand, ctx.seekAll)
	run("seekNext", items, ctx.preFullRand, ctx.seekNextAll)
	run("seekPrev", items, ctx.preFullRand, ctx.seekPrevAll)
	run("indexOf", items, ctx.preFullRand, ctx.indexOfAll)
	run("getAt", items, ctx.preFullRand, ctx.getAtAll)
	run("getAtMut", items, ctx.preFullRand, ctx.getAtMutAll)
	run("ascentMut", items, ctx.preFullRand, ctx.ascentMutAll)
	run("descentMut", items, ctx.preFullRand, ctx.descentMutAll)
	run("delete(rand)", items, ctx.preFullRand, ctx.deleteAll)
	run("deleteAt(front)", items, ctx.preFullSeq, ctx.deleteAtFrontAll)
	run("popFront", items, ctx.preFullSeq, ctx.popFrontAll)
	run("popBack", items, ctx.preFullSeq, ctx.popBackAll)
	rangeOps := partialRangeCount(items)
	run("deleteRangeAt(ret)", rangeOps, ctx.preFullSeq, ctx.deleteRangeAtReturning)
	run("deleteRange(ret)", rangeOps, ctx.preFullSeq, ctx.deleteRangeReturning)
	run("release", ctx.copyBatchOps, ctx.preReleaseCopies, ctx.releaseMany)
	run("copy", ctx.copyBatchOps, ctx.preFullSeq, ctx.copyMany)
	fmt.Println()
}

type benchContext[T keyType] struct {
	rng          *rand.Rand
	items        int
	tree         *btype.Map[T, int]
	keys         []T
	indices      []int
	copiedTrees  []*btype.Map[T, int]
	copyBatchOps int
	checksum     int
}

func (c *benchContext[T]) preInsertSeq() {
	c.tree = btype.NewMap[T, int]()
	c.keys = randKeys[T](c.rng, c.items)
	slices.SortFunc(c.keys, cmp.Compare[T])
}

func (c *benchContext[T]) preInsertRand() {
	c.tree = btype.NewMap[T, int]()
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

func (c *benchContext[T]) preReleaseCopies() {
	c.fillTree(false)
	c.copiedTrees = make([]*btype.Map[T, int], c.copyBatchOps)
	for i := range c.copiedTrees {
		c.copiedTrees[i] = c.tree.Copy()
	}
}

func (c *benchContext[T]) fillTree(randomOrder bool) {
	if randomOrder {
		c.preInsertRand()
	} else {
		c.preInsertSeq()
	}
	c.prepareIndices(randomOrder)
	c.insertAll()
}

func (c *benchContext[T]) prepareIndices(randomOrder bool) {
	c.indices = make([]int, c.items)
	for i := range c.indices {
		c.indices[i] = i
	}
	if randomOrder {
		shuffle(c.rng, c.indices)
	}
}

func (c *benchContext[T]) insertAll() {
	for i, key := range c.keys {
		_, ok := c.tree.Insert(key, valueForOrdinal(i))
		assert(ok)
	}
	c.record(c.tree.Len())
}

func (c *benchContext[T]) pushBackAll() {
	for i, key := range c.keys {
		assert(c.tree.PushBack(key, valueForOrdinal(i)))
	}
	c.record(c.tree.Len())
}

func (c *benchContext[T]) pushFrontAll() {
	for i, key := range c.keys {
		assert(c.tree.PushFront(key, valueForOrdinal(i)))
	}
	c.record(c.tree.Len())
}

func (c *benchContext[T]) getAll() {
	digest := 0
	for _, key := range c.keys {
		value, ok := c.tree.Get(key)
		assert(ok)
		digest += keyDigest(key) ^ value
	}
	c.record(digest)
}

func (c *benchContext[T]) getMutAll() {
	digest := 0
	for _, key := range c.keys {
		value, ok := c.tree.GetMut(key)
		assert(ok)
		digest += keyDigest(key) ^ value
	}
	c.record(digest)
}

func (c *benchContext[T]) setAll() {
	digest := 0
	for i, key := range c.keys {
		newValue := valueForOrdinal(c.items + i)
		oldValue, replaced := c.tree.Set(key, newValue)
		assert(replaced)
		digest += keyDigest(key) ^ oldValue ^ newValue
	}
	c.record(digest + c.tree.Len())
}

func (c *benchContext[T]) replaceAll() {
	digest := 0
	for i, key := range c.keys {
		newValue := valueForOrdinal(c.items*2 + i)
		oldValue, ok := c.tree.Replace(key, newValue)
		assert(ok)
		digest += keyDigest(key) ^ oldValue ^ newValue
	}
	c.record(digest)
}

func (c *benchContext[T]) seekAll() {
	digest := 0
	for _, key := range c.keys {
		foundKey, value, ok := c.tree.Seek(key)
		assert(ok)
		digest += keyDigest(foundKey) ^ value
	}
	c.record(digest)
}

func (c *benchContext[T]) seekNextAll() {
	digest := 0
	for _, key := range c.keys {
		foundKey, value, ok := c.tree.SeekNext(key)
		if ok {
			digest += keyDigest(foundKey) ^ value
		}
	}
	c.record(digest)
}

func (c *benchContext[T]) seekPrevAll() {
	digest := 0
	for _, key := range c.keys {
		foundKey, value, ok := c.tree.SeekPrev(key)
		if ok {
			digest += keyDigest(foundKey) ^ value
		}
	}
	c.record(digest)
}

func (c *benchContext[T]) indexOfAll() {
	digest := 0
	for _, key := range c.keys {
		index, ok := c.tree.IndexOf(key)
		assert(ok)
		digest += keyDigest(key) ^ index
	}
	c.record(digest)
}

func (c *benchContext[T]) getAtAll() {
	digest := 0
	for _, index := range c.indices {
		key, value, ok := c.tree.GetAt(index)
		assert(ok)
		digest += keyDigest(key) ^ value ^ index
	}
	c.record(digest)
}

func (c *benchContext[T]) getAtMutAll() {
	digest := 0
	for _, index := range c.indices {
		key, value, ok := c.tree.GetAtMut(index)
		assert(ok)
		digest += keyDigest(key) ^ value ^ index
	}
	c.record(digest)
}

func (c *benchContext[T]) ascentMutAll() {
	digest := 0
	for key, value := range c.tree.AllMut() {
		digest += keyDigest(key) ^ value
	}
	c.record(digest + c.tree.Len())
}

func (c *benchContext[T]) descentMutAll() {
	digest := 0
	for key, value := range c.tree.BackwardMut() {
		digest += keyDigest(key) ^ value
	}
	c.record(digest + c.tree.Len())
}

func (c *benchContext[T]) deleteAll() {
	digest := 0
	for _, key := range c.keys {
		value, ok := c.tree.Delete(key)
		assert(ok)
		digest += keyDigest(key) ^ value
	}
	c.record(digest)
}

func (c *benchContext[T]) deleteAtFrontAll() {
	digest := 0
	deleted := 0
	for {
		key, value, ok := c.tree.DeleteAt(0)
		if !ok {
			break
		}
		digest += keyDigest(key) ^ value
		deleted++
	}
	assert(deleted == c.items)
	c.record(digest)
}

func (c *benchContext[T]) popFrontAll() {
	digest := 0
	deleted := 0
	for {
		key, value, ok := c.tree.PopFront()
		if !ok {
			break
		}
		digest += keyDigest(key) ^ value
		deleted++
	}
	assert(deleted == c.items)
	c.record(digest)
}

func (c *benchContext[T]) popBackAll() {
	digest := 0
	deleted := 0
	for {
		key, value, ok := c.tree.PopBack()
		if !ok {
			break
		}
		digest += keyDigest(key) ^ value
		deleted++
	}
	assert(deleted == c.items)
	c.record(digest)
}

func (c *benchContext[T]) deleteRangeAtReturning() {
	count := partialRangeCount(c.items)
	start := partialRangeStart(c.items, count)
	removed := c.tree.DeleteRangeAt(start, count)
	assert(removed.Len() == count)
	assert(c.tree.Len() == c.items-count)
	digest := 0
	for key, value := range removed.All() {
		digest += keyDigest(key) ^ value
	}
	c.record(digest + count)
}

func (c *benchContext[T]) deleteRangeReturning() {
	first, last, ok := c.partialRangeBounds()
	assert(ok)
	count := partialRangeCount(c.items)
	removed := c.tree.DeleteRangeOptions(first, last, btype.DeleteRangeOptions{MaxInclusive: true})
	assert(removed.Len() == count)
	assert(c.tree.Len() == c.items-count)
	digest := 0
	for key, value := range removed.All() {
		digest += keyDigest(key) ^ value
	}
	c.record(digest + count)
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

func (c *benchContext[T]) releaseMany() {
	digest := 0
	for _, copied := range c.copiedTrees {
		digest += copied.Len()
		copied.Release()
	}
	c.copiedTrees = nil
	c.record(digest)
}

func (c *benchContext[T]) copyMany() {
	digest := 0
	for range c.copyBatchOps {
		copy := c.tree.Copy()
		digest += copy.Len()
		copy.Release()
	}
	c.record(digest)
}

func (c *benchContext[T]) record(value int) {
	c.checksum += value
	runtime.KeepAlive(c.checksum)
}

func runBench(label string, ops, runs int, reset, pre, op func()) {
	runSample := func() time.Duration {
		reset()
		pre()
		runtime.GC()
		start := time.Now()
		op()
		return time.Since(start)
	}

	for range warmupRuns {
		runSample()
	}

	elapsed := make([]time.Duration, 0, runs)
	for range runs {
		elapsed = append(elapsed, runSample())
	}
	slices.Sort(elapsed)
	median := elapsed[runs/2]
	fmt.Printf("%-19s", label)
	writeOutput(ops, median)
}

func benchmarkSeed(keyName, label string) uint64 {
	seed := uint64(1469598103934665603)
	seed = mixSeed(seed, keyName)
	seed = mixSeed(seed, label)
	return seed
}

func mixSeed(seed uint64, text string) uint64 {
	for i := 0; i < len(text); i++ {
		seed ^= uint64(text[i])
		seed *= 1099511628211
	}
	return seed
}

func partialRangeCount(items int) int {
	return max(1, items/10)
}

func valueForOrdinal(index int) int {
	return index + 1
}

func keyDigest[T keyType](key T) int {
	switch key := any(key).(type) {
	case int32:
		return int(uint64(uint32(key)) * 11400714819323198485)
	case uint64:
		return int(key * 11400714819323198485)
	case string:
		hash := uint64(1469598103934665603)
		for i := 0; i < len(key); i++ {
			hash ^= uint64(key[i])
			hash *= 1099511628211
		}
		return int(hash)
	default:
		panic("unsupported benchmark key type")
	}
}

func copyBatchCount(items int) int {
	return max(1024, min(items, 16_384))
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
