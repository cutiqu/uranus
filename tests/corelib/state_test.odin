package corelib_tests

import lib "../../corelib"

import "core:testing"

Sample :: struct {
	a: u8, b: u16, c: i32, d: u64, e: bool, f: f32, g: [4]u8, h: f64, i: [3]i16,
}

sync_sample :: proc "contextless" (s: ^lib.State, v: ^Sample) {
	lib.sync_int(s, &v.a); lib.sync_int(s, &v.b); lib.sync_int(s, &v.c); lib.sync_int(s, &v.d)
	lib.sync_bool(s, &v.e); lib.sync_f32(s, &v.f); lib.sync_bytes(s, v.g[:])
	lib.sync_f64(s, &v.h); lib.sync_ints(s, v.i[:])
}

@(test)
round_trip_is_exact :: proc(t: ^testing.T) {
	orig := Sample{a = 0xAB, b = 0xBEEF, c = -123456, d = 0xDEAD_BEEF_CAFE_F00D, e = true, f = -3.5, g = {1, 2, 3, 4}, h = -0.1234567890123, i = {-1, 32767, -32768}}

	counter := lib.state_count()
	sync_sample(&counter, &orig)

	buf: [128]byte
	w := lib.state_save(buf[:counter.pos])
	sync_sample(&w, &orig)
	testing.expect(t, lib.state_finished(&w))

	got: Sample
	r := lib.state_load(buf[:counter.pos])
	sync_sample(&r, &got)
	testing.expect(t, lib.state_finished(&r))
	testing.expect_value(t, got, orig)
}

@(test)
format_is_little_endian_and_layout_independent :: proc(t: ^testing.T) {
	v := Sample{b = 0x0102, c = -1}
	buf: [128]byte
	n := lib.state_count(); sync_sample(&n, &v)
	w := lib.state_save(buf[:n.pos]); sync_sample(&w, &v)
	testing.expect_value(t, buf[1], u8(0x02)) // b, low byte first (a is byte 0)
	testing.expect_value(t, buf[2], u8(0x01))
	testing.expect_value(t, n.pos, 1 + 2 + 4 + 8 + 1 + 4 + 4 + 8 + 6) // fixed wire size, no padding
}

@(test)
truncated_and_oversized_buffers_are_rejected :: proc(t: ^testing.T) {
	v: Sample
	buf: [128]byte
	n := lib.state_count(); sync_sample(&n, &v)

	short := lib.state_load(buf[:n.pos - 1])
	sync_sample(&short, &v)
	testing.expect(t, !short.ok)

	long := lib.state_load(buf[:n.pos + 1])
	sync_sample(&long, &v)
	testing.expect(t, !lib.state_finished(&long)) // parsed fine but left bytes over
}
