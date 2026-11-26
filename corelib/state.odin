// Package corelib: pure helpers shared by emulation cores. No imports, no OS,
// no allocation, everything "contextless". Cores may import this; frontends
// never need to.
//
// SYMMETRIC SERIALISATION. A subsystem describes its fields ONCE, as a list of
// sync_* calls, and that single description serves three jobs:
//
//     Count : walk the fields, add up the size          (state_size)
//     Save  : write each field into the buffer          (save_state)
//     Load  : read each field back from the buffer      (load_state)
//
// Save and load can never disagree about field order or width, because there
// is only one list. Integers are always little-endian, so a state is portable
// across machines and independent of struct layout and padding.
package corelib

import "base:intrinsics"

State_Mode :: enum u8 { Count, Save, Load }

State :: struct {
	mode: State_Mode,
	buf:  []byte,
	pos:  int,
	ok:   bool, // becomes false on overrun; every later sync is then a no-op
}

state_count :: proc "contextless" () -> State { return {mode = .Count, ok = true} }
state_save  :: proc "contextless" (buf: []byte) -> State { return {mode = .Save, buf = buf, ok = true} }
state_load  :: proc "contextless" (buf: []byte) -> State { return {mode = .Load, buf = buf, ok = true} }

// Reserve n bytes. Returns the slice to read/write (nil when counting or failed).
@(private)
take :: proc "contextless" (s: ^State, n: int) -> []byte {
	if !s.ok { return nil }
	start := s.pos
	s.pos += n
	if s.mode == .Count { return nil }
	if s.pos > len(s.buf) {
		s.ok = false
		return nil
	}
	return s.buf[start:s.pos]
}

sync_int :: proc "contextless" (s: ^State, v: ^$T) where intrinsics.type_is_integer(T) {
	b := take(s, size_of(T))
	if b == nil { return }
	switch s.mode {
	case .Save:
		x := u64(v^)
		for i in 0 ..< size_of(T) { b[i] = u8(x >> (8 * uint(i))) }
	case .Load:
		x: u64
		for i in 0 ..< size_of(T) { x |= u64(b[i]) << (8 * uint(i)) }
		v^ = T(x)
	case .Count:
	}
}

sync_bool :: proc "contextless" (s: ^State, v: ^bool) {
	x: u8 = 1 if v^ else 0
	sync_int(s, &x)
	if s.mode == .Load { v^ = x != 0 }
}

// Floats travel as their IEEE-754 bit pattern, so the round trip is exact.
sync_f32 :: proc "contextless" (s: ^State, v: ^f32) {
	x := transmute(u32)v^
	sync_int(s, &x)
	if s.mode == .Load { v^ = transmute(f32)x }
}

// Doubles travel as their IEEE-754 bit pattern, like sync_f32.
sync_f64 :: proc "contextless" (s: ^State, v: ^f64) {
	x := transmute(u64)v^
	sync_int(s, &x)
	if s.mode == .Load { v^ = transmute(f64)x }
}

// A run of integers of any one width (each element little-endian). For byte
// arrays prefer sync_bytes, which copies in one go.
sync_ints :: proc "contextless" (s: ^State, a: []$T) where intrinsics.type_is_integer(T) {
	for &x in a { sync_int(s, &x) }
}

sync_bytes :: proc "contextless" (s: ^State, data: []byte) {
	b := take(s, len(data))
	if b == nil { return }
	switch s.mode {
	case .Save: copy(b, data)
	case .Load: copy(data, b)
	case .Count:
	}
}

// Loading must consume the buffer exactly: trailing bytes mean a state from a
// different version or core, which should be rejected, not half-applied.
state_finished :: proc "contextless" (s: ^State) -> bool {
	return s.ok && (s.mode == .Count || s.pos == len(s.buf))
}
