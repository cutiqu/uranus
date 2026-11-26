package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sat "../../../cores/saturn"

W :: struct { addr, size, val: u32 }

Ctx :: struct {
	seed: u32,
	code: [12]u8,
	ova:  [256]u32,
	ovv:  [256]u8,
	nov:  int,
	wl:   [64]W,
	nw:   int,
}

hbyte :: proc "contextless" (a: u32, seed: u32) -> u8 {
	h := (a * 0x9E3779B1) ~ seed
	h ~= h >> 15
	h *= 0x85EBCA6B
	h ~= h >> 13
	return u8(h >> 11)
}

rb :: proc "contextless" (c: ^Ctx, a0: u32) -> u8 {
	a := a0 & 0xFFFFFF
	for i := c.nov - 1; i >= 0; i -= 1 { if c.ova[i] == a { return c.ovv[i] } }
	if a >= 0x1000 && a < 0x100C { return c.code[a - 0x1000] }
	if a < 0x400 {
		v := u32(0x00080000) + (a >> 2) * 0x10
		return u8(v >> (8 * (3 - (a & 3))))
	}
	return hbyte(a, c.seed)
}

wbyte :: proc "contextless" (c: ^Ctx, a: u32, v: u8) {
	if c.nov < 256 { c.ova[c.nov] = a & 0xFFFFFF; c.ovv[c.nov] = v; c.nov += 1 }
}

bus_read :: proc "contextless" (ctx: rawptr, addr: u32, size: u32) -> u32 {
	c := (^Ctx)(ctx)
	v: u32
	for i in u32(0) ..< size { v = v << 8 | u32(rb(c, addr + i)) }
	return v
}

bus_write :: proc "contextless" (ctx: rawptr, addr: u32, size: u32, v: u32) {
	c := (^Ctx)(ctx)
	mk := u32(0xFF) if size == 1 else (u32(0xFFFF) if size == 2 else u32(0xFFFFFFFF))
	if c.nw < 64 { c.wl[c.nw] = {addr & 0xFFFFFF, size, v & mk}; c.nw += 1 }
	for i in u32(0) ..< size { wbyte(c, addr + i, u8(v >> (8 * (size - 1 - i)))) }
}

main :: proc() {
	data: [dynamic]u8
	buf: [65536]u8
	for {
		n, err := os.read(os.stdin, buf[:])
		if n <= 0 || err != nil { break }
		append(&data, ..buf[:n])
	}
	out: strings.Builder
	text := string(data[:])
	for line in strings.split_lines_iterator(&text) {
		toks := strings.fields(line)
		if len(toks) < 25 { continue }
		v: [32]u32
		for t, i in toks { n, _ := strconv.parse_uint(t, 16); v[i] = u32(n) }
		c := Ctx{}
		c.seed = v[0]
		for i in 0 ..< 5 { c.code[2*i] = u8(v[20+i] >> 8); c.code[2*i+1] = u8(v[20+i]) }
		m: sat.M68K
		m.bus = {ctx = &c, read = bus_read, write = bus_write}
		for i in 0 ..< 8 { m.d[i] = v[1 + i] }
		for i in 0 ..< 7 { m.a[i] = v[9 + i] }
		usp, ssp := v[16], v[17]
		m.sr = v[19]
		m.pc = v[18]
		if m.sr & 0x2000 != 0 { m.a[7] = ssp; m.usp = usp } else { m.a[7] = usp; m.ssp = ssp }
		sat.m68k_step(&m)
		nusp, nssp := m.usp, m.a[7]
		if m.sr & 0x2000 == 0 { nusp, nssp = m.a[7], m.ssp }
		strings.builder_reset(&out)
		fmt.sbprintf(&out, "%x:", c.seed)
		for i in 0 ..< 8 { fmt.sbprintf(&out, " %08x", m.d[i]) }
		for i in 0 ..< 8 { fmt.sbprintf(&out, " %08x", m.a[i]) }
		fmt.sbprintf(&out, " %08x %08x %08x %04x |", nusp, nssp, m.pc, m.sr)
		for i in 0 ..< c.nw { fmt.sbprintf(&out, " %x/%x=%x", c.wl[i].addr, c.wl[i].size, c.wl[i].val) }
		fmt.sbprintf(&out, " | odd=%d cyc=%d\n", 1 if m.odd_accesses > 0 else 0, m.cycles)
		os.write_string(os.stdout, strings.to_string(out))
	}
}
