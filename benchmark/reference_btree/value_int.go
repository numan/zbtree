//go:build !keyonly

package main

// mapValue is what the benchmarked maps store per key.
type mapValue = int

const mapValueName = "int"

func valueForOrdinal(index int) mapValue {
	return index + 1
}

func valueDigest(value mapValue) int {
	return value
}
