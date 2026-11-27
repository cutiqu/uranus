package saturn_tests

// The sound CPU (MC68EC000) on a flat 64 KiB memory, with hand-assembled code.
// Instruction semantics are additionally checked against Musashi over millions
// of random single-instruction cases (see tools/m68k_oracle/); these tests keep
// the behaviours the sound drivers depend on readable and fast to run.

import sat "../../core"
import "core:testing"

Flat :: struct {
	mem: [0x10000]u8,
}

flat_read :: proc "contextless" (ctx: rawptr, addr: u32, size: u32) -> u32 {
	f := (^Flat)(ctx)
	v: u32
	for i in u32(0) ..< size { v = v << 8 | u32(f.mem[(addr + i) & 0xFFFF]) }
	return v
}

flat_write :: proc "contextless" (ctx: rawptr, addr: u32, size: u32, v: u32) {
	f := (^Flat)(ctx)
	for i in u32(0) ..< size { f.mem[(addr + i) & 0xFFFF] = u8(v >> (8 * (size - 1 - i))) }
}

put_words :: proc(f: ^Flat, at: u32, words: ..u16) {
	for w, i in words {
		f.mem[at + u32(i) * 2] = u8(w >> 8)
		f.mem[at + u32(i) * 2 + 1] = u8(w)
	}
}

put_long :: proc(f: ^Flat, at: u32, v: u32) {
	put_words(f, at, u16(v >> 16), u16(v))
}

get_word :: proc(f: ^Flat, at: u32) -> u16 {return u16(f.mem[at]) << 8 | u16(f.mem[at + 1])}
get_long :: proc(f: ^Flat, at: u32) -> u32 {return u32(get_word(f, at)) << 16 | u32(get_word(f, at + 2))}

// Starts a CPU at 0x400 with the stack at 0x8000, code placed by the caller
// before calling `boot`.
boot :: proc(f: ^Flat, m: ^sat.M68K) {
	put_long(f, 0, 0x8000)
	put_long(f, 4, 0x400)
	m^ = {}
	m.bus = {ctx = f, read = flat_read, write = flat_write}
	sat.m68k_reset(m)
}

run :: proc(m: ^sat.M68K, n: int) {
	for _ in 0 ..< n { sat.m68k_step(m) }
}

@(test)
m68k_reset_reads_the_vectors :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	boot(f, &m)
	testing.expect_value(t, m.a[7], 0x8000)
	testing.expect_value(t, m.pc, 0x400)
	testing.expect_value(t, m.sr, 0x2700)
}

@(test)
m68k_arithmetic_and_flags :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_words(
		f, 0x400,
		0x7005, // moveq #5,d0
		0x7207, // moveq #7,d1
		0xD081, // add.l d1,d0        -> 12
		0x0640, 0x7FF4, // addi.w #$7FF4,d0 -> 0x8000: N and V set
	)
	boot(f, &m)
	run(&m, 3)
	testing.expect_value(t, m.d[0], 12)
	testing.expect_value(t, m.sr & 0x1F, 0)
	run(&m, 1)
	testing.expect_value(t, m.d[0] & 0xFFFF, 0x8000)
	testing.expect_value(t, m.sr & (sat.M68K_N | sat.M68K_V | sat.M68K_Z | sat.M68K_C), sat.M68K_N | sat.M68K_V)
}

@(test)
m68k_dbra_loop_sums_one_to_ten :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_words(
		f, 0x400,
		0x7000, // moveq #0,d0
		0x7209, // moveq #9,d1
		0x5241 - 0x0200 + 0x0200, // (placeholder replaced below)
	)
	// loop: addq.w #1,d1 ; add.w d1,d0 ; dbra d2... use d1 as counter explicitly:
	put_words(
		f, 0x400,
		0x7000, // moveq #0,d0         sum
		0x720A, // moveq #10,d1        n
		0xD041, // loop: add.w d1,d0
		0x5341, //       subq.w #1,d1
		0x66FA, //       bne loop      (-6)
		0x60FE, //       bra.s *
	)
	boot(f, &m)
	run(&m, 2 + 3 * 10)
	testing.expect_value(t, m.d[0], 55)
}

@(test)
m68k_subroutines_and_stack_frames :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_words(
		f, 0x400,
		0x4EB9, 0x0000, 0x0500, // jsr $500
		0x7201, // moveq #1,d1   (after return)
		0x60FE,
	)
	put_words(
		f, 0x500,
		0x4E56, 0xFFF8, // link a6,#-8
		0x303C, 0x1234, // move.w #$1234,d0
		0x4E5E, // unlk a6
		0x4E75, // rts
	)
	boot(f, &m)
	run(&m, 1)
	testing.expect_value(t, m.pc, 0x500)
	testing.expect_value(t, get_long(f, 0x7FFC), 0x406) // return address
	run(&m, 4)
	testing.expect_value(t, m.d[0] & 0xFFFF, 0x1234)
	testing.expect_value(t, m.a[7], 0x8000)
	run(&m, 1)
	testing.expect_value(t, m.d[1], 1)
}

@(test)
m68k_movem_round_trip :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_words(
		f, 0x400,
		0x48E7, 0xC0C0, // movem.l d0-d1/a0-a1,-(a7)
		0x7000, 0x7200, 0x91C8, 0x93C9, // clear d0,d1,a0,a1
		0x4CDF, 0x0303, // movem.l (a7)+,d0-d1/a0-a1
	)
	boot(f, &m)
	m.d[0], m.d[1], m.a[0], m.a[1] = 0x11111111, 0x22222222, 0x33333333, 0x44444444
	run(&m, 6)
	testing.expect_value(t, m.d[0], 0x11111111)
	testing.expect_value(t, m.d[1], 0x22222222)
	testing.expect_value(t, m.a[0], 0x33333333)
	testing.expect_value(t, m.a[1], 0x44444444)
	testing.expect_value(t, m.a[7], 0x8000)
}

@(test)
m68k_multiply_and_divide :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_words(
		f, 0x400,
		0x80C1, // divu d1,d0
		0xC0C2, // mulu d2,d0
	)
	boot(f, &m)
	m.d[0], m.d[1], m.d[2] = 1000, 7, 3
	run(&m, 1)
	testing.expect_value(t, m.d[0], (6 << 16) | 142) // 1000 = 142*7 + 6
	m.d[0] = 20
	run(&m, 1)
	testing.expect_value(t, m.d[0], 60)
}

@(test)
m68k_traps_and_privilege :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_long(f, 32 * 4, 0x600) // TRAP #0 handler
	put_long(f, 8 * 4, 0x700) // privilege violation handler
	put_long(f, 5 * 4, 0x800) // divide by zero handler
	put_words(
		f, 0x400,
		0x4E40, // trap #0
		0x4E73, // (never reached directly) rte target check below
	)
	put_words(f, 0x600, 0x4E73) // handler: rte
	boot(f, &m)
	run(&m, 1)
	testing.expect_value(t, m.pc, 0x600)
	testing.expect_value(t, get_long(f, 0x7FFC), 0x402) // stacked PC = next instruction
	run(&m, 1) // rte
	testing.expect_value(t, m.pc, 0x402)

	// Privileged instruction from user mode.
	put_words(f, 0x402, 0x46FC, 0x0000, 0x4E72, 0x2000) // move #0,sr (drop to user) ; stop (privileged)
	run(&m, 2)
	testing.expect_value(t, m.pc, 0x700)

	// Divide by zero.
	boot(f, &m)
	put_words(f, 0x400, 0x80C1)
	m.d[0], m.d[1] = 5, 0
	run(&m, 1)
	testing.expect_value(t, m.pc, 0x800)
}

@(test)
m68k_interrupts_wake_stop_and_use_autovectors :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_long(f, (24 + 4) * 4, 0x500) // level 4 autovector
	put_words(
		f, 0x400,
		0x46FC, 0x2000, // move #$2000,sr   (supervisor, mask 0)
		0x4E72, 0x2000, // stop #$2000
		0x7201, // moveq #1,d1       (after the handler returns)
		0x60FE,
	)
	put_words(f, 0x500, 0x7407, 0x4E73) // handler: moveq #7,d2 ; rte
	boot(f, &m)
	run(&m, 2) // sr load, stop
	testing.expect(t, m.stopped)
	sat.m68k_set_ipl(&m, 3) // masked? no: mask is 0, level 3 is accepted
	sat.m68k_set_ipl(&m, 0)
	run(&m, 3)
	testing.expect(t, m.stopped) // nothing pending: still stopped
	sat.m68k_set_ipl(&m, 4)
	run(&m, 1)
	testing.expect(t, !m.stopped)
	testing.expect_value(t, m.pc, 0x500)
	testing.expect_value(t, (m.sr >> 8) & 7, 4) // mask raised to the level taken
	sat.m68k_set_ipl(&m, 0)
	run(&m, 2) // moveq, rte
	testing.expect_value(t, m.d[2], 7)
	testing.expect_value(t, (m.sr >> 8) & 7, 0)
	run(&m, 1)
	testing.expect_value(t, m.d[1], 1)

	// A level at or below the mask is ignored.
	boot(f, &m)
	put_words(f, 0x400, 0x7201, 0x60FE)
	sat.m68k_set_ipl(&m, 6) // mask is 7 after reset
	run(&m, 1)
	testing.expect_value(t, m.d[1], 1)
}

@(test)
m68k_shifts_and_bcd :: proc(t: ^testing.T) {
	f := new(Flat)
	defer free(f)
	m: sat.M68K
	put_words(
		f, 0x400,
		0xE348, // lsl.w #1,d0
		0xE248, // lsr.w #1,d0  (restores)
		0xE540, // asl.w #2,d0
		0xC300, // abcd d0,d1
	)
	boot(f, &m)
	m.d[0] = 0x4001
	run(&m, 1)
	testing.expect_value(t, m.d[0], 0x8002)
	run(&m, 1)
	testing.expect_value(t, m.d[0], 0x4001)
	run(&m, 1)
	testing.expect_value(t, m.d[0], 0x0004)
	testing.expect(t, m.sr & sat.M68K_X != 0) // the shifted-out bit
	m.d[0], m.d[1] = 0x19, 0x28
	m.sr &= ~u32(sat.M68K_X)
	run(&m, 1)
	testing.expect_value(t, m.d[1] & 0xFF, 0x47) // 28 + 19 in BCD
}
