package host

import "core:slice"

// Samples and percentile summaries for --frame-stats.

SERIES_MAX :: 1_000_000 // about 4.6 hours of frames

Series :: struct {
	values: [dynamic]f32,
}

series_add :: proc(s: ^Series, value: f64) {
	if len(s.values) < SERIES_MAX { append(&s.values, f32(value)) }
}

series_destroy :: proc(s: ^Series) {
	delete(s.values)
	s^ = {}
}

Summary :: struct {
	count:                        int,
	min, mean, p50, p99, p999, max: f64,
}

// Nearest-rank percentiles; an empty series gives zeros.
series_summary :: proc(s: ^Series) -> (sum: Summary) {
	n := len(s.values)
	if n == 0 { return }
	sorted := slice.clone(s.values[:], context.temp_allocator)
	slice.sort(sorted)

	total: f64
	for v in sorted { total += f64(v) }
	at :: proc(sorted: []f32, p: f64) -> f64 { return f64(sorted[min(int(f64(len(sorted)) * p), len(sorted) - 1)]) }

	sum.count = n
	sum.min, sum.max = f64(sorted[0]), f64(sorted[n - 1])
	sum.mean = total / f64(n)
	sum.p50, sum.p99, sum.p999 = at(sorted, 0.50), at(sorted, 0.99), at(sorted, 0.999)
	return
}

// Share of values further than `tolerance` from `ideal`.
series_share_off :: proc(s: ^Series, ideal, tolerance: f64) -> f64 {
	if len(s.values) == 0 { return 0 }
	off := 0
	for v in s.values {
		d := f64(v) - ideal
		if d > tolerance || d < -tolerance { off += 1 }
	}
	return f64(off) / f64(len(s.values))
}
