// Host-speed check for the Saturn core: how much of a 60 fps frame (16.7 ms) do the
// expensive pieces cost on THIS machine? Needs no BIOS or disc.
//
//   odin build tools/saturn_bench -o:speed -out:build/saturn_bench && build/saturn_bench
//
// Each case is run several times and the fastest run is reported (the minimum is the
// least noisy estimate on a busy or thermally throttled laptop). A scenario that is
// well under budget on its own can still add up: a busy frame is roughly
// "both SH-2s + VDP1 + VDP2 + sound", so compare the sum of the rows you expect.
package saturn_bench

import "core:fmt"
import "core:time"
import sat "../../cores/saturn"

BUDGET_MS :: 1000.0 / 60.0
CYC_PER_FRAME :: 478_660 // 263 lines x 1820 SH-2 cycles
RUNS :: 5

row :: proc(name: string, ms: f64) {
	fmt.printfln("  %-50s %8.3f ms  %5.1f%% of a frame", name, ms, ms / BUDGET_MS * 100)
}

min_ms :: proc(f: proc(_: rawptr), data: rawptr, inner: int) -> f64 {
	best := max(f64)
	for _ in 0 ..< RUNS {
		t0 := time.tick_now()
		for _ in 0 ..< inner { f(data) }
		best = min(best, time.duration_milliseconds(time.tick_since(t0)) / f64(inner))
	}
	return best
}

// ---------------------------------------------------------------- SH-2 ------

Cpu_Case :: struct {
	s:    ^sat.Saturn,
	both: bool,
}

run_frame_cpus :: proc(p: rawptr) {
	c := (^Cpu_Case)(p)
	m, sl := &c.s.cpu[0], &c.s.cpu[1]
	end := m.cycles + CYC_PER_FRAME
	for m.cycles < end {
		t := min(m.cycles + 200, end)
		sat.sh2_run(m, t)
		sat.sh2_run(sl, t)
	}
}

load :: proc(s: ^sat.Saturn, base: u32, ops: []u16) {
	for op, i in ops { sat.mem_write16(s, base + u32(i * 2), op) }
}

cpu_case :: proc(name: string, ops: []u16, flag: u32, both: bool) {
	s := new(sat.Saturn)
	defer free(s)
	for i in 0 ..< 2 { sat.sh2_reset(&s.cpu[i], s, i == 1) }
	s.cpu[1].halted = !both
	sat.mem_write32(s, flag, 1)
	for i in 0 ..< 2 {
		base := u32(0x06000000 + i * 0x1000)
		load(s, base, ops)
		s.cpu[i].pc, s.cpu[i].sr, s.cpu[i].r[4] = base, 0xF0, flag
		s.cpu[i].r[15] = 0x060FF000 - u32(i * 0x1000)
	}
	c := Cpu_Case{s, both}
	row(name, min_ms(run_frame_cpus, &c, 20))
}

// ---------------------------------------------------------------- VDP1 ------

Vdp1_Case :: struct {s: ^sat.Saturn}

fire :: proc(p: rawptr) { sat.mem_write16((^Vdp1_Case)(p).s, 0x05D00004, 1) }

w16 :: proc(s: ^sat.Saturn, a: u32, v: u16) { sat.mem_write16(s, 0x05C00000 + a, v) }

cmd :: proc(s: ^sat.Saturn, at: u32, ctrl, pmod, colr, srca, size: u16, p: [8]i16, grda: u16 = 0) {
	w16(s, at, ctrl); w16(s, at + 2, 0); w16(s, at + 4, pmod); w16(s, at + 6, colr)
	w16(s, at + 8, srca); w16(s, at + 10, size)
	for i in 0 ..< 8 { w16(s, at + 12 + u32(i) * 2, u16(p[i])) }
	w16(s, at + 28, grda)
}

vdp1_case :: proc(name: string, build: proc(s: ^sat.Saturn), inner: int) {
	s := new(sat.Saturn)
	defer free(s)
	sat.vdp1_reset(&s.vdp1)
	for i in 0 ..< 64 * 64 { w16(s, 0x20000 + u32(i) * 2, u16(0x8000 | (i * 2654435761) & 0x7FFF)) }
	for i in 0 ..< 4 { w16(s, 0x30000 + u32(i) * 2, u16(0x4210 + i * 3)) }
	build(s)
	c := Vdp1_Case{s}
	row(name, min_ms(fire, &c, inner))
}

// ---------------------------------------------------------------- VDP2 ------

Vdp2_Case :: struct {s: ^sat.Saturn}

draw_frame2 :: proc(p: rawptr) {
	s := (^Vdp2_Case)(p).s
	for y in u32(0) ..< 224 { sat.vdp2_draw_line(&s.vdp2, y, &s.vdp1.fb[0]) }
}

vdp2_case :: proc(name: string, layers: u16) {
	s := new(sat.Saturn)
	defer free(s)
	sat.vdp2_reset(&s.vdp2)
	sat.vdp2_reg_write(&s.vdp2, 0x00, 0x8000)
	for n in u32(0) ..< 4 { sat.vdp2_reg_write(&s.vdp2, 0x30 + n * 2, 0x8000) }
	sat.vdp2_reg_write(&s.vdp2, 0xF8, 0x0201)
	sat.vdp2_reg_write(&s.vdp2, 0xFA, 0x0403)
	sat.vdp2_reg_write(&s.vdp2, 0x20, layers)
	c := Vdp2_Case{s}
	row(name, min_ms(draw_frame2, &c, 30))
}

main :: proc() {
	fmt.printfln("Saturn core host cost (fastest of %d runs; 100%% = one 60 fps frame, %.1f ms)\n", RUNS, BUDGET_MS)

	fmt.println("SH-2 interpreter, one frame of guest time:")
	spin := [?]u16{0x6042, 0x8801, 0x89FC, 0x0009} // while (*flag == 1) {}
	alu := [?]u16{0x7101, 0x7101, 0x7101, 0x7101, 0x7101, 0x7101, 0x7101, 0x7101, 0xAFF6, 0x0009}
	cpu_case("master spins on a flag (work RAM)", spin[:], 0x06080000, false)
	cpu_case("both CPUs spin on a flag (work RAM)", spin[:], 0x06080000, true)
	cpu_case("both CPUs, 1 instruction/cycle (worst case)", alu[:], 0x06080000, true)

	fmt.println("\nVDP1 drawing (one command list):")
	vdp1_case("full-screen flat polygon (320x224)", proc(s: ^sat.Saturn) {
		cmd(s, 0, 0x0004, 0, 0x7FFF, 0, 0, {0, 0, 319, 0, 319, 223, 0, 223}); w16(s, 32, 0x8000)
	}, 100)
	vdp1_case("full-screen textured sprite", proc(s: ^sat.Saturn) {
		cmd(s, 0, 0x0002, 0x0028, 0, 0x20000 >> 3, 8 << 8 | 64, {0, 0, 319, 0, 319, 223, 0, 223}); w16(s, 32, 0x8000)
	}, 100)
	vdp1_case("full-screen Gouraud polygon", proc(s: ^sat.Saturn) {
		cmd(s, 0, 0x0004, 0x0004, 0x7FFF, 0, 0, {0, 0, 319, 0, 319, 223, 0, 223}, 0x30000 >> 3); w16(s, 32, 0x8000)
	}, 100)
	vdp1_case("100 textured 32x32 sprites", proc(s: ^sat.Saturn) {
		for i in 0 ..< 100 {
			x, y := i16((i % 10) * 30), i16((i / 10) * 22)
			cmd(s, u32(i) * 32, 0x0002, 0x0028, 0, 0x20000 >> 3, 8 << 8 | 64, {x, y, x + 31, y, x + 31, y + 31, x, y + 31})
		}
		w16(s, 3200, 0x8000)
	}, 100)
	vdp1_case("polygon 2000x2000, mostly off screen", proc(s: ^sat.Saturn) {
		cmd(s, 0, 0x0004, 0, 0x7FFF, 0, 0, {-1000, -1000, 1000, -1000, 1000, 1000, -1000, 1000}); w16(s, 32, 0x8000)
	}, 3)
	vdp1_case("polygon 4000x4000, mostly off screen", proc(s: ^sat.Saturn) {
		cmd(s, 0, 0x0004, 0, 0x7FFF, 0, 0, {-2000, -2000, 2000, -2000, 2000, 2000, -2000, 2000}); w16(s, 32, 0x8000)
	}, 3)

	fmt.println("\nVDP2 compositing (one 320x224 frame, every layer transparent = no early-out):")
	vdp2_case("1 scroll layer", 0x0001)
	vdp2_case("2 scroll layers", 0x0003)
	vdp2_case("4 scroll layers", 0x000F)

	fmt.println("\nThe SH-2 rows are guest time per frame (both CPUs). Add the pieces a scene uses;")
	fmt.println("if their sum is near 100%, expect dropped frames. The window title shows live fps.")
}
