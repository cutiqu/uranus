package host_tests

import host "../../host"

import "core:testing"

@(test)
ring_fifo_order :: proc(t: ^testing.T) {
	r := host.ring_make(8)
	defer host.ring_destroy(&r)
	host.ring_push(&r, {1, 2, 3, 4})
	out: [4]i16
	testing.expect_value(t, host.ring_pop(&r, out[:]), 4)
	testing.expect_value(t, out, [4]i16{1, 2, 3, 4})
	testing.expect_value(t, r.count, 0)
}

@(test)
ring_wraps_around :: proc(t: ^testing.T) {
	r := host.ring_make(8)
	defer host.ring_destroy(&r)
	scratch: [8]i16
	host.ring_push(&r, {1, 2, 3, 4, 5, 6})
	host.ring_pop(&r, scratch[:5])           // read index now near the end
	host.ring_push(&r, {7, 8, 9, 10, 11})    // this write wraps past the end of the array
	out: [6]i16
	testing.expect_value(t, host.ring_pop(&r, out[:]), 6)
	testing.expect_value(t, out, [6]i16{6, 7, 8, 9, 10, 11})
}

@(test)
ring_overflow_drops_oldest :: proc(t: ^testing.T) {
	r := host.ring_make(4)
	defer host.ring_destroy(&r)
	host.ring_push(&r, {1, 2, 3})
	dropped := host.ring_push(&r, {4, 5, 6}) // 6 samples into capacity 4: oldest 2 must go
	testing.expect_value(t, dropped, 2)
	out: [4]i16
	testing.expect_value(t, host.ring_pop(&r, out[:]), 4)
	testing.expect_value(t, out, [4]i16{3, 4, 5, 6})
}

@(test)
ring_underrun_returns_short :: proc(t: ^testing.T) {
	r := host.ring_make(8)
	defer host.ring_destroy(&r)
	host.ring_push(&r, {9, 9})
	out: [5]i16
	testing.expect_value(t, host.ring_pop(&r, out[:]), 2) // caller zero-fills the rest
}

@(test)
ring_push_larger_than_capacity :: proc(t: ^testing.T) {
	r := host.ring_make(4)
	defer host.ring_destroy(&r)
	dropped := host.ring_push(&r, {1, 2, 3, 4, 5, 6, 7})
	testing.expect_value(t, dropped, 3)
	out: [4]i16
	host.ring_pop(&r, out[:])
	testing.expect_value(t, out, [4]i16{4, 5, 6, 7}) // newest survive
}
