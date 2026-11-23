//go:build keyonly

package main

// mapValue is empty, so the benchmarked maps hold keys only, as the
// Map[K, struct{}] in upstream btree-bench does.
type mapValue = struct{}

const mapValueName = "struct{}"

func valueForOrdinal(int) mapValue {
	return mapValue{}
}

func valueDigest(mapValue) int {
	return 0
}
