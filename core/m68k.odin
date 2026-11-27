// Motorola MC68EC000, the Saturn's sound CPU (11.29 MHz, half the SCSP clock).
//
// A plain interpreter written from the 68000 programmer's reference: one call to
// `m68k_step` runs one instruction or takes one interrupt. Memory goes through
// the `M68K_Bus` callbacks (values are big-endian, size 1/2/4), so the CPU knows
// nothing about the Saturn and can be tested against a flat memory.
//
// Timing is a bus-cycle model (4 clocks per fetch/read/write) plus fixed extras
// for long ALU ops, multiply/divide, shifts and exceptions; it is close to the
// real chip for ordinary code, not exact. An odd word/long access does not raise
// an address error: it is performed at the even address below it and counted in
// `odd_accesses` (no Saturn software relies on the trap).
package saturn_core

M68K_C :: 0x01
M68K_V :: 0x02
M68K_Z :: 0x04
M68K_N :: 0x08
M68K_X :: 0x10
M68K_S :: 0x2000
M68K_T :: 0x8000
M68K_SR_MASK :: 0xA71F

M68K_Bus :: struct {
	ctx:   rawptr,
	read:  proc "contextless" (ctx: rawptr, addr: u32, size: u32) -> u32,
	write: proc "contextless" (ctx: rawptr, addr: u32, size: u32, v: u32),
}

M68K :: struct {
	d:   [8]u32,
	a:   [8]u32, // a[7] is the active stack pointer
	usp: u32, // user stack pointer while in supervisor mode
	ssp: u32, // supervisor stack pointer while in user mode
	pc:  u32,
	sr:  u32,

	ipl:      u8, // interrupt priority level on the IPL pins (0 = none)
	stopped:  bool, // STOP executed; woken by an interrupt
	halted:   bool, // held in reset (SMPC SNDOFF)
	cycles:   i64, // clocks consumed, running total
	odd_accesses: u32,

	bus: M68K_Bus,
	ipc: u32, // address of the instruction being executed
}

// Reset: stack pointer and start address come from the first two longs.
m68k_reset :: proc "contextless" (m: ^M68K) {
	bus := m.bus
	m^ = {}
	m.bus = bus
	m.sr = M68K_S | 0x0700
	m.a[7] = rd(m, 0, 4)
	m.pc = rd(m, 4, 4)
	m.cycles = 0
}

// ------------------------------------------------------------ bus access ---

@(private = "file")
rd :: proc "contextless" (m: ^M68K, addr: u32, size: u32) -> u32 {
	a := addr & 0xFFFFFF
	if size > 1 && a & 1 != 0 { m.odd_accesses += 1; a &= ~u32(1) }
	m.cycles += 4 if size < 4 else 8
	return m.bus.read(m.bus.ctx, a, size)
}

@(private = "file")
wr :: proc "contextless" (m: ^M68K, addr: u32, size: u32, v: u32) {
	a := addr & 0xFFFFFF
	if size > 1 && a & 1 != 0 { m.odd_accesses += 1; a &= ~u32(1) }
	m.cycles += 4 if size < 4 else 8
	m.bus.write(m.bus.ctx, a, size, v)
}

@(private = "file")
fetch16 :: #force_inline proc "contextless" (m: ^M68K) -> u32 {
	v := rd(m, m.pc, 2)
	m.pc += 2
	return v
}

@(private = "file")
fetch32 :: proc "contextless" (m: ^M68K) -> u32 {
	hi := fetch16(m)
	return hi << 16 | fetch16(m)
}

@(private = "file")
mask_of :: #force_inline proc "contextless" (sz: u32) -> u32 {
	return 0xFF if sz == 1 else (0xFFFF if sz == 2 else 0xFFFFFFFF)
}

@(private = "file")
sign_of :: #force_inline proc "contextless" (sz: u32) -> u32 {
	return 0x80 if sz == 1 else (0x8000 if sz == 2 else 0x80000000)
}

@(private = "file")
sext :: #force_inline proc "contextless" (v: u32, sz: u32) -> u32 {
	if sz == 1 { return u32(i32(i8(v))) }
	if sz == 2 { return u32(i32(i16(v))) }
	return v
}

// -------------------------------------------------------- status register ---

@(private = "file")
set_sr :: proc "contextless" (m: ^M68K, v: u32) {
	nv := v & M68K_SR_MASK
	if (nv ~ m.sr) & M68K_S != 0 { // swap stack pointers
		if nv & M68K_S != 0 { m.usp = m.a[7]; m.a[7] = m.ssp } else { m.ssp = m.a[7]; m.a[7] = m.usp }
	}
	m.sr = nv
}

@(private = "file")
flag :: #force_inline proc "contextless" (m: ^M68K, f: u32) -> bool { return m.sr & f != 0 }

@(private = "file")
put_flag :: #force_inline proc "contextless" (m: ^M68K, f: u32, on: bool) {
	if on { m.sr |= f } else { m.sr &= ~f }
}

@(private = "file")
set_nz :: proc "contextless" (m: ^M68K, v: u32, sz: u32) {
	r := v & mask_of(sz)
	put_flag(m, M68K_N, r & sign_of(sz) != 0)
	put_flag(m, M68K_Z, r == 0)
}

@(private = "file")
cond :: proc "contextless" (m: ^M68K, c: u32) -> bool {
	n, z, v, cy := flag(m, M68K_N), flag(m, M68K_Z), flag(m, M68K_V), flag(m, M68K_C)
	switch c {
	case 0:  return true
	case 1:  return false
	case 2:  return !cy && !z
	case 3:  return cy || z
	case 4:  return !cy
	case 5:  return cy
	case 6:  return !z
	case 7:  return z
	case 8:  return !v
	case 9:  return v
	case 10: return !n
	case 11: return n
	case 12: return n == v
	case 13: return n != v
	case 14: return !z && n == v
	}
	return z || n != v
}

// ------------------------------------------------------------ exceptions ---

@(private = "file")
push16 :: proc "contextless" (m: ^M68K, v: u32) {
	m.a[7] -= 2
	wr(m, m.a[7], 2, v)
}

@(private = "file")
push32 :: proc "contextless" (m: ^M68K, v: u32) {
	m.a[7] -= 4
	wr(m, m.a[7], 4, v)
}

@(private = "file")
pop16 :: proc "contextless" (m: ^M68K) -> u32 {
	v := rd(m, m.a[7], 2)
	m.a[7] += 2
	return v
}

@(private = "file")
pop32 :: proc "contextless" (m: ^M68K) -> u32 {
	v := rd(m, m.a[7], 4)
	m.a[7] += 4
	return v
}

// Takes exception `vec`, stacking `ret_pc`. Enters supervisor mode, clears trace.
@(private = "file")
exception :: proc "contextless" (m: ^M68K, vec: u32, ret_pc: u32) {
	old := m.sr
	set_sr(m, (m.sr | M68K_S) & ~u32(M68K_T))
	push32(m, ret_pc)
	push16(m, old)
	m.pc = rd(m, vec * 4, 4)
	m.cycles += 8
}

// ------------------------------------------------------- effective address ---

@(private = "file")
Ea_Kind :: enum u8 { Dn, An, Mem, Imm }

@(private = "file")
Ea :: struct {
	kind: Ea_Kind,
	reg:  u32,
	addr: u32,
	imm:  u32,
}

// Bit n set = addressing mode n allowed. 0 Dn, 1 An, 2 (An), 3 (An)+, 4 -(An),
// 5 d16(An), 6 d8(An,Xn), 7 abs.W, 8 abs.L, 9 d16(PC), 10 d8(PC,Xn), 11 #imm.
@(private = "file")
EA_ALL      :: u32(0xFFF)
@(private = "file")
EA_DATA     :: u32(0xFFD)
@(private = "file")
EA_DATA_ALT :: u32(0x1FD)
@(private = "file")
EA_MEM_ALT  :: u32(0x1FC)
@(private = "file")
EA_CTRL     :: u32(0x7E4)
@(private = "file")
EA_CTRL_ALT :: u32(0x1E4)
@(private = "file")
EA_ALT      :: u32(0x1FF)

@(private = "file")
ea_ok :: proc "contextless" (allowed: u32, mode, reg: u32) -> bool {
	idx: u32 = mode
	if mode == 7 {
		if reg > 4 { return false }
		idx = 7 + reg
	}
	return allowed >> idx & 1 != 0
}

@(private = "file")
index_ext :: proc "contextless" (m: ^M68K, base: u32) -> u32 {
	ext := fetch16(m)
	xn: u32
	r := (ext >> 12) & 7
	xn = m.a[r] if ext & 0x8000 != 0 else m.d[r]
	if ext & 0x800 == 0 { xn = sext(xn, 2) }
	return base + xn + sext(ext & 0xFF, 1)
}

// Resolves an effective address, performing pre/post-increment and fetching
// extension words. The caller must have checked the mode with ea_ok.
@(private = "file")
ea_resolve :: proc "contextless" (m: ^M68K, mode, reg, sz: u32) -> Ea {
	e: Ea
	step := sz
	if sz == 1 && reg == 7 { step = 2 }
	switch mode {
	case 0: e = {kind = .Dn, reg = reg}
	case 1: e = {kind = .An, reg = reg}
	case 2: e = {kind = .Mem, addr = m.a[reg]}
	case 3:
		e = {kind = .Mem, addr = m.a[reg]}
		m.a[reg] += step
	case 4:
		m.a[reg] -= step
		e = {kind = .Mem, addr = m.a[reg]}
		m.cycles += 2
	case 5:
		d := sext(fetch16(m), 2)
		e = {kind = .Mem, addr = m.a[reg] + d}
	case 6:
		m.cycles += 2
		e = {kind = .Mem, addr = index_ext(m, m.a[reg])}
	case 7:
		switch reg {
		case 0: e = {kind = .Mem, addr = sext(fetch16(m), 2)}
		case 1: e = {kind = .Mem, addr = fetch32(m)}
		case 2:
			base := m.pc
			d := sext(fetch16(m), 2)
			e = {kind = .Mem, addr = base + d}
		case 3:
			m.cycles += 2
			base := m.pc
			e = {kind = .Mem, addr = index_ext(m, base)}
		case 4:
			if sz == 4 { e = {kind = .Imm, imm = fetch32(m)} } else { e = {kind = .Imm, imm = fetch16(m) & mask_of(sz)} }
		}
	}
	return e
}

@(private = "file")
ea_read :: proc "contextless" (m: ^M68K, e: Ea, sz: u32) -> u32 {
	switch e.kind {
	case .Dn:  return m.d[e.reg] & mask_of(sz)
	case .An:  return m.a[e.reg] & mask_of(sz)
	case .Imm: return e.imm
	case .Mem: return rd(m, e.addr, sz)
	}
	return 0
}

@(private = "file")
ea_write :: proc "contextless" (m: ^M68K, e: Ea, sz: u32, v: u32) {
	switch e.kind {
	case .Dn:
		mk := mask_of(sz)
		m.d[e.reg] = (m.d[e.reg] & ~mk) | (v & mk)
	case .An: m.a[e.reg] = sext(v, sz)
	case .Imm:
	case .Mem: wr(m, e.addr, sz, v)
	}
}

// ------------------------------------------------------------------ ALU ----

@(private = "file")
alu_add :: proc "contextless" (m: ^M68K, src, dst, x, sz: u32, extended: bool) -> u32 {
	mk, sg := mask_of(sz), sign_of(sz)
	s, d := src & mk, dst & mk
	r := u64(s) + u64(d) + u64(x)
	res := u32(r) & mk
	c := r > u64(mk)
	put_flag(m, M68K_C | M68K_X, c)
	put_flag(m, M68K_V, (s ~ res) & (d ~ res) & sg != 0)
	put_flag(m, M68K_N, res & sg != 0)
	if extended { if res != 0 { m.sr &= ~u32(M68K_Z) } } else { put_flag(m, M68K_Z, res == 0) }
	return res
}

// dst - src - x. `set_x` false for CMP.
@(private = "file")
alu_sub :: proc "contextless" (m: ^M68K, src, dst, x, sz: u32, extended, set_x: bool) -> u32 {
	mk, sg := mask_of(sz), sign_of(sz)
	s, d := src & mk, dst & mk
	res := u32(i64(d) - i64(s) - i64(x)) & mk
	c := u64(s) + u64(x) > u64(d)
	put_flag(m, M68K_C, c)
	if set_x { put_flag(m, M68K_X, c) }
	put_flag(m, M68K_V, (s ~ d) & (res ~ d) & sg != 0)
	put_flag(m, M68K_N, res & sg != 0)
	if extended { if res != 0 { m.sr &= ~u32(M68K_Z) } } else { put_flag(m, M68K_Z, res == 0) }
	return res
}

@(private = "file")
logic_flags :: proc "contextless" (m: ^M68K, v, sz: u32) {
	set_nz(m, v, sz)
	m.sr &= ~u32(M68K_V | M68K_C)
}

// --------------------------------------------------------------- shifts ----

// Shift/rotate of `v` by `count` (already reduced to 0..63). type: 0 AS,
// 1 LS, 2 ROX, 3 RO. left: direction. Sets all flags.
@(private = "file")
shift_op :: proc "contextless" (m: ^M68K, v, count, sz, type: u32, left: bool) -> u32 {
	mk, sg := mask_of(sz), sign_of(sz)
	r := v & mk
	c := false
	x := flag(m, M68K_X)
	vflag := false
	if count == 0 {
		put_flag(m, M68K_C, x if type == 2 else false)
		set_nz(m, r, sz)
		m.sr &= ~u32(M68K_V)
		return r
	}
	switch type {
	case 0: // arithmetic
		if left {
			// V is set if the MSB changes at any point during the shift.
			for _ in 0 ..< count {
				c = r & sg != 0
				nr := (r << 1) & mk
				if (nr ~ r) & sg != 0 { vflag = true }
				r = nr
			}
		} else {
			neg := r & sg != 0
			for _ in 0 ..< count {
				c = r & 1 != 0
				r = (r >> 1) | (sg if neg else 0)
			}
		}
		put_flag(m, M68K_X, c)
	case 1: // logical
		if left {
			for _ in 0 ..< count { c = r & sg != 0; r = (r << 1) & mk }
		} else {
			for _ in 0 ..< count { c = r & 1 != 0; r >>= 1 }
		}
		put_flag(m, M68K_X, c)
	case 2: // rotate through X
		for _ in 0 ..< count {
			if left {
				nc := r & sg != 0
				r = ((r << 1) | (1 if x else 0)) & mk
				x = nc
			} else {
				nc := r & 1 != 0
				r = (r >> 1) | (sg if x else 0)
				x = nc
			}
		}
		c = x
		put_flag(m, M68K_X, x)
	case 3: // rotate
		for _ in 0 ..< count {
			if left {
				c = r & sg != 0
				r = ((r << 1) | (1 if c else 0)) & mk
			} else {
				c = r & 1 != 0
				r = (r >> 1) | (sg if c else 0)
			}
		}
	}
	put_flag(m, M68K_C, c)
	put_flag(m, M68K_V, vflag)
	set_nz(m, r, sz)
	return r
}

// ------------------------------------------------------------------ BCD ----

// ABCD/SBCD/NBCD. N and V are undefined by the manual; they follow the values
// the real chip produces (the V formula is the one used by the common emulators).
@(private = "file")
bcd_add :: proc "contextless" (m: ^M68K, src, dst: u32) -> u32 {
	x: u32 = 1 if flag(m, M68K_X) else 0
	res := (src & 0xF) + (dst & 0xF) + x
	v := ~res
	if res > 9 { res += 6 }
	res += (src & 0xF0) + (dst & 0xF0)
	c := res > 0x99
	if c { res -= 0xA0 }
	put_flag(m, M68K_X | M68K_C, c)
	put_flag(m, M68K_V, v & res & 0x80 != 0)
	put_flag(m, M68K_N, res & 0x80 != 0)
	res &= 0xFF
	if res != 0 { m.sr &= ~u32(M68K_Z) }
	return res
}

@(private = "file")
bcd_sub_full :: proc "contextless" (m: ^M68K, src, dst: u32) -> u32 {
	x: u32 = 1 if flag(m, M68K_X) else 0
	res := (dst & 0xF) - (src & 0xF) - x
	v := ~res
	if res > 9 { res -= 6 }
	res += (dst & 0xF0) - (src & 0xF0)
	c := res > 0x99
	if c { res += 0xA0 }
	res &= 0xFF
	put_flag(m, M68K_X | M68K_C, c)
	put_flag(m, M68K_V, v & res & 0x80 != 0)
	put_flag(m, M68K_N, res & 0x80 != 0)
	if res != 0 { m.sr &= ~u32(M68K_Z) }
	return res
}

@(private = "file")
nbcd :: proc "contextless" (m: ^M68K, dst: u32) -> u32 {
	x: u32 = 1 if flag(m, M68K_X) else 0
	res := (0x9A - dst - x) & 0xFF
	if res == 0x9A {
		m.sr &= ~u32(M68K_V | M68K_C | M68K_X)
		put_flag(m, M68K_N, res & 0x80 != 0)
		return dst
	}
	v := ~res
	if res & 0xF == 0xA { res = (res & 0xF0) + 0x10 }
	res &= 0xFF
	put_flag(m, M68K_V, v & res & 0x80 != 0)
	put_flag(m, M68K_N, res & 0x80 != 0)
	if res != 0 { m.sr &= ~u32(M68K_Z) }
	m.sr |= M68K_C | M68K_X
	return res
}

// ------------------------------------------------------------- stepping ----

m68k_set_ipl :: proc "contextless" (m: ^M68K, level: u8) { m.ipl = level }

// Runs until `m.cycles` reaches `until`. A stopped CPU just burns time.
m68k_run :: proc "contextless" (m: ^M68K, until: i64) {
	if m.halted { m.cycles = max(m.cycles, until); return }
	for m.cycles < until { m68k_step(m) }
}

m68k_step :: proc "contextless" (m: ^M68K) {
	// Interrupts are taken between instructions.
	mask := u8((m.sr >> 8) & 7)
	if m.ipl > mask || m.ipl == 7 {
		m.stopped = false
		level := u32(m.ipl)
		old := m.sr
		set_sr(m, ((m.sr | M68K_S) & ~u32(M68K_T) & ~u32(0x0700)) | (level << 8))
		push32(m, m.pc)
		push16(m, old)
		m.pc = rd(m, (24 + level) * 4, 4)
		m.cycles += 18
		return
	}
	if m.stopped { m.cycles += 4; return }

	m.ipc = m.pc
	op := fetch16(m)
	execute(m, op)
}

@(private = "file")
illegal :: proc "contextless" (m: ^M68K, vec: u32 = 4) {
	exception(m, vec, m.ipc)
}

@(private = "file")
privileged :: proc "contextless" (m: ^M68K) -> bool {
	if m.sr & M68K_S != 0 { return true }
	exception(m, 8, m.ipc)
	return false
}

@(private = "file")
execute :: proc "contextless" (m: ^M68K, op: u32) {
	switch op >> 12 {
	case 0x0: group0(m, op)
	case 0x1, 0x2, 0x3: do_move(m, op)
	case 0x4: group4(m, op)
	case 0x5: group5(m, op)
	case 0x6: do_branch(m, op)
	case 0x7:
		if op & 0x100 != 0 { illegal(m); return }
		v := sext(op & 0xFF, 1)
		m.d[(op >> 9) & 7] = v
		logic_flags(m, v, 4)
	case 0x8: group8(m, op)
	case 0x9, 0xD: group_addsub(m, op)
	case 0xA: illegal(m, 10)
	case 0xB: groupB(m, op)
	case 0xC: groupC(m, op)
	case 0xE: groupE(m, op)
	case 0xF: illegal(m, 11)
	}
}

// ------------------------------------------------------------- group 0 -----

@(private = "file")
size_field :: #force_inline proc "contextless" (op: u32) -> u32 {
	return 1 << ((op >> 6) & 3) // 0 -> 1, 1 -> 2, 2 -> 4 (3 = invalid, gives 8)
}

@(private = "file")
group0 :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7

	if op & 0x138 == 0x108 { // MOVEP
		dn := (op >> 9) & 7
		disp := sext(fetch16(m), 2)
		addr := m.a[reg] + disp
		switch (op >> 6) & 3 {
		case 0: m.d[dn] = (m.d[dn] & 0xFFFF0000) | (rd(m, addr, 1) << 8) | rd(m, addr + 2, 1)
		case 1: m.d[dn] = (rd(m, addr, 1) << 24) | (rd(m, addr + 2, 1) << 16) | (rd(m, addr + 4, 1) << 8) | rd(m, addr + 6, 1)
		case 2:
			wr(m, addr, 1, m.d[dn] >> 8)
			wr(m, addr + 2, 1, m.d[dn])
		case 3:
			wr(m, addr, 1, m.d[dn] >> 24)
			wr(m, addr + 2, 1, m.d[dn] >> 16)
			wr(m, addr + 4, 1, m.d[dn] >> 8)
			wr(m, addr + 6, 1, m.d[dn])
		}
		return
	}

	if op & 0x100 != 0 || (op >> 9) & 7 == 4 { // bit operations
		bit_op(m, op)
		return
	}

	kind := (op >> 9) & 7
	if kind == 7 { illegal(m); return }

	// ORI/ANDI/EORI to CCR / SR
	if op & 0xBF == 0x3C && (kind == 0 || kind == 1 || kind == 5) {
		imm := fetch16(m)
		if op & 0x40 == 0 { // CCR
			ccr := m.sr & 0x1F
			switch kind {
			case 0: ccr |= imm
			case 1: ccr &= imm
			case 5: ccr ~= imm
			}
			m.sr = (m.sr & 0xFF00) | (ccr & 0x1F)
			m.cycles += 8
		} else {
			if !privileged(m) { return }
			sr := m.sr
			switch kind {
			case 0: sr |= imm
			case 1: sr &= imm
			case 5: sr ~= imm
			}
			set_sr(m, sr)
			m.cycles += 8
		}
		return
	}
	if op & 0xC0 == 0xC0 { illegal(m); return }

	sz := size_field(op)
	if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
	imm: u32
	if sz == 4 { imm = fetch32(m) } else { imm = fetch16(m) & mask_of(sz) }
	e := ea_resolve(m, mode, reg, sz)
	d := ea_read(m, e, sz)
	if sz == 4 && e.kind == .Dn { m.cycles += 4 }
	switch kind {
	case 0: r := d | imm; logic_flags(m, r, sz); ea_write(m, e, sz, r)
	case 1: r := d & imm; logic_flags(m, r, sz); ea_write(m, e, sz, r)
	case 2: r := alu_sub(m, imm, d, 0, sz, false, true); ea_write(m, e, sz, r)
	case 3: r := alu_add(m, imm, d, 0, sz, false); ea_write(m, e, sz, r)
	case 5: r := d ~ imm; logic_flags(m, r, sz); ea_write(m, e, sz, r)
	case 6: alu_sub(m, imm, d, 0, sz, false, false)
	}
}

@(private = "file")
bit_op :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	which := (op >> 6) & 3 // 0 BTST, 1 BCHG, 2 BCLR, 3 BSET
	var_bit: u32
	if op & 0x100 != 0 {
		var_bit = m.d[(op >> 9) & 7]
	} else {
		var_bit = fetch16(m) & 0xFF
	}
	allowed := EA_DATA_ALT
	if which == 0 { allowed = EA_DATA if op & 0x100 != 0 else (EA_DATA & ~u32(0x800)) }
	if !ea_ok(allowed, mode, reg) { illegal(m); return }
	if mode == 0 {
		bit := u32(1) << (var_bit & 31)
		v := m.d[reg]
		put_flag(m, M68K_Z, v & bit == 0)
		switch which {
		case 1: m.d[reg] = v ~ bit
		case 2: m.d[reg] = v & ~bit
		case 3: m.d[reg] = v | bit
		}
		if which == 2 || which == 0 { m.cycles += 2 }
		if which != 0 { m.cycles += 2 }
		return
	}
	e := ea_resolve(m, mode, reg, 1)
	v := ea_read(m, e, 1)
	bit := u32(1) << (var_bit & 7)
	put_flag(m, M68K_Z, v & bit == 0)
	switch which {
	case 1: ea_write(m, e, 1, v ~ bit)
	case 2: ea_write(m, e, 1, v & ~bit)
	case 3: ea_write(m, e, 1, v | bit)
	}
}

// ---------------------------------------------------------------- MOVE -----

@(private = "file")
do_move :: proc "contextless" (m: ^M68K, op: u32) {
	sz: u32 = 1 if op >> 12 == 1 else (4 if op >> 12 == 2 else 2)
	smode, sreg := (op >> 3) & 7, op & 7
	dmode, dreg := (op >> 6) & 7, (op >> 9) & 7
	if !ea_ok(EA_ALL, smode, sreg) || (smode == 1 && sz == 1) { illegal(m); return }
	if dmode == 1 { // MOVEA
		if sz == 1 { illegal(m); return }
		se := ea_resolve(m, smode, sreg, sz)
		v := ea_read(m, se, sz)
		m.a[dreg] = sext(v, sz)
		return
	}
	if !ea_ok(EA_DATA_ALT, dmode, dreg) { illegal(m); return }
	se := ea_resolve(m, smode, sreg, sz)
	v := ea_read(m, se, sz)
	de := ea_resolve(m, dmode, dreg, sz)
	logic_flags(m, v, sz)
	ea_write(m, de, sz, v)
}

// ------------------------------------------------------------- group 4 -----

@(private = "file")
group4 :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7

	switch {
	case op & 0x1C0 == 0x1C0: // LEA
		if !ea_ok(EA_CTRL, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, 4)
		m.a[(op >> 9) & 7] = e.addr
		return
	case op & 0x1C0 == 0x180: // CHK.W
		if !ea_ok(EA_DATA, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, 2)
		bound := i32(sext(ea_read(m, e, 2), 2))
		dn := i32(sext(m.d[(op >> 9) & 7], 2))
		// Z/V/C are formally undefined; these are the values the chip produces.
		put_flag(m, M68K_Z, dn == 0)
		m.sr &= ~u32(M68K_V | M68K_C)
		if dn >= 0 && dn <= bound { return }
		put_flag(m, M68K_N, dn < 0)
		exception(m, 6, m.pc)
		return
	}

	switch op & 0xFF00 {
	case 0x4000, 0x4200, 0x4400, 0x4600:
		if op & 0xC0 == 0xC0 { // MOVE from SR / to CCR / to SR
			switch op & 0xFF00 {
			case 0x4000:
				if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
				e := ea_resolve(m, mode, reg, 2)
				ea_read(m, e, 2) // the 68000 reads before writing
				ea_write(m, e, 2, m.sr)
			case 0x4400:
				if !ea_ok(EA_DATA, mode, reg) { illegal(m); return }
				e := ea_resolve(m, mode, reg, 2)
				v := ea_read(m, e, 2)
				m.sr = (m.sr & 0xFF00) | (v & 0x1F)
			case 0x4600:
				if !ea_ok(EA_DATA, mode, reg) { illegal(m); return }
				if !privileged(m) { return }
				e := ea_resolve(m, mode, reg, 2)
				set_sr(m, ea_read(m, e, 2))
			case: illegal(m)
			}
			return
		}
		sz := size_field(op)
		if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		d := ea_read(m, e, sz)
		if sz == 4 && e.kind == .Dn { m.cycles += 2 }
		switch op & 0xFF00 {
		case 0x4000: // NEGX
			r := alu_sub(m, d, 0, 1 if flag(m, M68K_X) else 0, sz, true, true)
			ea_write(m, e, sz, r)
		case 0x4200: // CLR
			m.sr = (m.sr & ~u32(M68K_N | M68K_V | M68K_C)) | M68K_Z
			ea_write(m, e, sz, 0)
		case 0x4400: // NEG
			r := alu_sub(m, d, 0, 0, sz, false, true)
			ea_write(m, e, sz, r)
		case 0x4600: // NOT
			r := ~d & mask_of(sz)
			logic_flags(m, r, sz)
			ea_write(m, e, sz, r)
		}
		return
	case 0x4800:
		switch {
		case op & 0xC0 == 0x00: // NBCD
			if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
			e := ea_resolve(m, mode, reg, 1)
			d := ea_read(m, e, 1)
			ea_write(m, e, 1, nbcd(m, d))
		case op & 0xF8 == 0x40: // SWAP
			v := m.d[reg]
			v = v << 16 | v >> 16
			m.d[reg] = v
			logic_flags(m, v, 4)
		case op & 0xC0 == 0x40: // PEA
			if !ea_ok(EA_CTRL, mode, reg) { illegal(m); return }
			e := ea_resolve(m, mode, reg, 4)
			push32(m, e.addr)
		case op & 0xB8 == 0x80: // EXT
			if op & 0x40 == 0 {
				v := (m.d[reg] & 0xFFFF0000) | (sext(m.d[reg], 1) & 0xFFFF)
				m.d[reg] = v
				logic_flags(m, v, 2)
			} else {
				v := sext(m.d[reg], 2)
				m.d[reg] = v
				logic_flags(m, v, 4)
			}
		case op & 0x80 == 0x80: // MOVEM registers to memory
			movem_to_mem(m, op)
		case: illegal(m)
		}
		return
	case 0x4A00:
		if op & 0xC0 == 0xC0 {
			if op == 0x4AFC { illegal(m); return } // ILLEGAL
			if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
			e := ea_resolve(m, mode, reg, 1) // TAS
			v := ea_read(m, e, 1)
			logic_flags(m, v, 1)
			ea_write(m, e, 1, v | 0x80)
			return
		}
		sz := size_field(op)
		if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		logic_flags(m, ea_read(m, e, sz), sz)
		return
	case 0x4C00:
		if op & 0x80 != 0 { movem_to_regs(m, op) } else { illegal(m) }
		return
	case 0x4E00:
		group4e(m, op)
		return
	}
	illegal(m)
}

@(private = "file")
group4e :: proc "contextless" (m: ^M68K, op: u32) {
	switch {
	case op & 0xFFF0 == 0x4E40: // TRAP
		exception(m, 32 + (op & 15), m.pc)
	case op & 0xFFF8 == 0x4E50: // LINK
		reg := op & 7
		disp := sext(fetch16(m), 2)
		// LINK A7 pushes the already-decremented stack pointer.
		push32(m, m.a[reg] if reg != 7 else m.a[7] - 4)
		m.a[reg] = m.a[7]
		m.a[7] += disp
	case op & 0xFFF8 == 0x4E58: // UNLK
		reg := op & 7
		m.a[7] = m.a[reg]
		m.a[reg] = pop32(m)
	case op & 0xFFF8 == 0x4E60: // MOVE An,USP
		if !privileged(m) { return }
		m.usp = m.a[op & 7]
	case op & 0xFFF8 == 0x4E68: // MOVE USP,An
		if !privileged(m) { return }
		m.a[op & 7] = m.usp
	case op == 0x4E70: // RESET
		if !privileged(m) { return }
		m.cycles += 124
	case op == 0x4E71: // NOP
	case op == 0x4E72: // STOP
		if !privileged(m) { return }
		set_sr(m, fetch16(m))
		m.stopped = true
	case op == 0x4E73: // RTE
		if !privileged(m) { return }
		sr := pop16(m)
		m.pc = pop32(m)
		set_sr(m, sr)
	case op == 0x4E75: // RTS
		m.pc = pop32(m)
	case op == 0x4E76: // TRAPV
		if flag(m, M68K_V) { exception(m, 7, m.pc) }
	case op == 0x4E77: // RTR
		ccr := pop16(m)
		m.sr = (m.sr & 0xFF00) | (ccr & 0x1F)
		m.pc = pop32(m)
	case op & 0xFFC0 == 0x4E80, op & 0xFFC0 == 0x4EC0: // JSR / JMP
		mode, reg := (op >> 3) & 7, op & 7
		if !ea_ok(EA_CTRL, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, 4)
		if op & 0x40 == 0 { push32(m, m.pc) }
		m.pc = e.addr
	case: illegal(m)
	}
}

@(private = "file")
movem_to_mem :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	sz: u32 = 4 if op & 0x40 != 0 else 2
	list := fetch16(m)
	allowed := EA_CTRL_ALT | 0x10 // plus -(An)
	if !ea_ok(allowed, mode, reg) { illegal(m); return }
	if mode == 4 {
		addr := m.a[reg]
		start := m.a[reg]
		for i in u32(0) ..< 16 {
			if list >> i & 1 == 0 { continue }
			// bit 0 = A7 ... bit 15 = D0
			r := 15 - i
			v := m.a[r - 8] if r >= 8 else m.d[r]
			if r - 8 == reg && r >= 8 { v = start }
			addr -= sz
			wr(m, addr, sz, v)
		}
		m.a[reg] = addr
	} else {
		e := ea_resolve(m, mode, reg, sz)
		addr := e.addr
		for i in u32(0) ..< 16 {
			if list >> i & 1 == 0 { continue }
			v := m.a[i - 8] if i >= 8 else m.d[i]
			wr(m, addr, sz, v)
			addr += sz
		}
	}
}

@(private = "file")
movem_to_regs :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	sz: u32 = 4 if op & 0x40 != 0 else 2
	list := fetch16(m)
	allowed := (EA_CTRL | 0x08) // plus (An)+
	if !ea_ok(allowed, mode, reg) { illegal(m); return }
	e := ea_resolve(m, mode, reg, sz)
	addr := e.addr
	for i in u32(0) ..< 16 {
		if list >> i & 1 == 0 { continue }
		v := rd(m, addr, sz)
		if sz == 2 { v = sext(v, 2) }
		if i >= 8 { m.a[i - 8] = v } else { m.d[i] = v }
		addr += sz
	}
	// The word after the last one is read and discarded on the real chip.
	rd(m, addr, 2)
	if mode == 3 { m.a[reg] = addr }
}

// ------------------------------------------------------------- group 5 -----

@(private = "file")
group5 :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	if op & 0xC0 == 0xC0 {
		c := (op >> 8) & 15
		if mode == 1 { // DBcc
			disp := sext(fetch16(m), 2)
			if cond(m, c) { m.cycles += 4; return }
			w := (m.d[reg] - 1) & 0xFFFF
			m.d[reg] = (m.d[reg] & 0xFFFF0000) | w
			if w != 0xFFFF {
				m.pc = m.ipc + 2 + disp
				m.cycles += 2
			} else { m.cycles += 6 }
			return
		}
		if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, 1)
		if e.kind == .Mem { ea_read(m, e, 1) }
		t := cond(m, c)
		ea_write(m, e, 1, 0xFF if t else 0)
		if e.kind == .Dn && t { m.cycles += 2 }
		return
	}
	sz := size_field(op)
	data := (op >> 9) & 7
	if data == 0 { data = 8 }
	sub := op & 0x100 != 0
	if mode == 1 { // address register: whole register, no flags
		if sz == 1 { illegal(m); return }
		if sub { m.a[reg] -= data } else { m.a[reg] += data }
		m.cycles += 4
		return
	}
	if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
	e := ea_resolve(m, mode, reg, sz)
	d := ea_read(m, e, sz)
	if sz == 4 && e.kind == .Dn { m.cycles += 4 }
	r: u32
	if sub { r = alu_sub(m, data, d, 0, sz, false, true) } else { r = alu_add(m, data, d, 0, sz, false) }
	ea_write(m, e, sz, r)
}

// ------------------------------------------------------------ branches -----

@(private = "file")
do_branch :: proc "contextless" (m: ^M68K, op: u32) {
	c := (op >> 8) & 15
	disp := op & 0xFF
	base := m.pc // address after the opcode word
	if disp == 0 { disp = sext(fetch16(m), 2) } else { disp = sext(disp, 1) }
	if c == 1 { // BSR
		push32(m, m.pc)
		m.pc = base + disp
		m.cycles += 4
		return
	}
	if cond(m, c) {
		m.pc = base + disp
		m.cycles += 2
	} else {
		m.cycles += 2 if op & 0xFF != 0 else 4
	}
}

// ------------------------------------------------------------- group 8 -----

@(private = "file")
group8 :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	dn := (op >> 9) & 7
	opm := (op >> 6) & 7
	switch {
	case opm == 3 || opm == 7: // DIVU / DIVS
		if !ea_ok(EA_DATA, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, 2)
		src := ea_read(m, e, 2)
		divide(m, dn, src, opm == 7)
	case opm == 4 && mode < 2: // SBCD
		bcd_reg_or_mem(m, op, false)
	case: // OR
		sz := size_field(op)
		if !ea_ok(EA_DATA if opm < 3 else EA_MEM_ALT, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		if opm < 3 {
			r := (m.d[dn] | ea_read(m, e, sz)) & mask_of(sz)
			logic_flags(m, r, sz)
			ea_write(m, Ea{kind = .Dn, reg = dn}, sz, r)
			if sz == 4 { m.cycles += 2 if e.kind == .Dn || e.kind == .Imm else 0 }
		} else {
			r := (m.d[dn] | ea_read(m, e, sz)) & mask_of(sz)
			logic_flags(m, r, sz)
			ea_write(m, e, sz, r)
		}
	}
}

@(private = "file")
divide :: proc "contextless" (m: ^M68K, dn, src: u32, signed: bool) {
	if src & 0xFFFF == 0 {
		exception(m, 5, m.pc)
		return
	}
	dividend := m.d[dn]
	if !signed {
		divisor := src & 0xFFFF
		q := dividend / divisor
		r := dividend % divisor
		m.cycles += 76
		if q > 0xFFFF {
			m.sr |= M68K_V
			m.sr &= ~u32(M68K_C)
			return
		}
		m.d[dn] = (r << 16) | (q & 0xFFFF)
		put_flag(m, M68K_Z, q & 0xFFFF == 0)
		put_flag(m, M68K_N, q & 0x8000 != 0)
		m.sr &= ~u32(M68K_V | M68K_C)
	} else {
		divisor := i32(i16(src))
		dd := i32(dividend)
		m.cycles += 100
		if dd == min(i32) && divisor == -1 {
			put_flag(m, M68K_V, true)
			m.sr &= ~u32(M68K_C)
			return
		}
		q := dd / divisor
		r := dd % divisor
		if q > 32767 || q < -32768 {
			m.sr |= M68K_V
			m.sr &= ~u32(M68K_C)
			return
		}
		m.d[dn] = (u32(r) << 16) | (u32(q) & 0xFFFF)
		put_flag(m, M68K_Z, u32(q) & 0xFFFF == 0)
		put_flag(m, M68K_N, u32(q) & 0x8000 != 0)
		m.sr &= ~u32(M68K_V | M68K_C)
	}
}

@(private = "file")
bcd_reg_or_mem :: proc "contextless" (m: ^M68K, op: u32, add: bool) {
	rx, ry := (op >> 9) & 7, op & 7
	if op & 8 == 0 {
		src := m.d[ry] & 0xFF
		dst := m.d[rx] & 0xFF
		r := bcd_add(m, src, dst) if add else bcd_sub_full(m, src, dst)
		m.d[rx] = (m.d[rx] & 0xFFFFFF00) | r
		m.cycles += 2
	} else {
		sy := 2 if ry == 7 else 1
		sx := 2 if rx == 7 else 1
		m.a[ry] -= u32(sy)
		src := rd(m, m.a[ry], 1)
		m.a[rx] -= u32(sx)
		dst := rd(m, m.a[rx], 1)
		r := bcd_add(m, src, dst) if add else bcd_sub_full(m, src, dst)
		wr(m, m.a[rx], 1, r)
	}
}

// ---------------------------------------------------- ADD / SUB / CMP ... ---

@(private = "file")
group_addsub :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	dn := (op >> 9) & 7
	opm := (op >> 6) & 7
	is_add := op >> 12 == 0xD

	if opm == 3 || opm == 7 { // ADDA / SUBA
		sz: u32 = 2 if opm == 3 else 4
		if !ea_ok(EA_ALL, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		v := sext(ea_read(m, e, sz), sz)
		if is_add { m.a[dn] += v } else { m.a[dn] -= v }
		m.cycles += 4 if sz == 2 || e.kind == .Dn || e.kind == .An || e.kind == .Imm else 0
		if sz == 4 { m.cycles += 0 }
		return
	}
	sz := size_field(op)
	if opm >= 4 && mode < 2 { // ADDX / SUBX
		x: u32 = 1 if flag(m, M68K_X) else 0
		if mode == 0 {
			src, dst := m.d[reg] & mask_of(sz), m.d[dn] & mask_of(sz)
			r := alu_add(m, src, dst, x, sz, true) if is_add else alu_sub(m, src, dst, x, sz, true, true)
			ea_write(m, Ea{kind = .Dn, reg = dn}, sz, r)
			if sz == 4 { m.cycles += 4 }
		} else {
			step := sz
			sy: u32 = 2 if sz == 1 && reg == 7 else step
			sx: u32 = 2 if sz == 1 && dn == 7 else step
			m.a[reg] -= sy
			src := rd(m, m.a[reg], sz)
			m.a[dn] -= sx
			dst := rd(m, m.a[dn], sz)
			r := alu_add(m, src, dst, x, sz, true) if is_add else alu_sub(m, src, dst, x, sz, true, true)
			wr(m, m.a[dn], sz, r)
		}
		return
	}
	if opm < 3 {
		if !ea_ok(EA_ALL, mode, reg) || (mode == 1 && sz == 1) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		src := ea_read(m, e, sz)
		dst := m.d[dn] & mask_of(sz)
		r := alu_add(m, src, dst, 0, sz, false) if is_add else alu_sub(m, src, dst, 0, sz, false, true)
		ea_write(m, Ea{kind = .Dn, reg = dn}, sz, r)
		if sz == 4 && (e.kind == .Dn || e.kind == .An || e.kind == .Imm) { m.cycles += 2 }
	} else {
		if !ea_ok(EA_MEM_ALT, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		dst := ea_read(m, e, sz)
		src := m.d[dn] & mask_of(sz)
		r := alu_add(m, src, dst, 0, sz, false) if is_add else alu_sub(m, src, dst, 0, sz, false, true)
		ea_write(m, e, sz, r)
	}
}

@(private = "file")
groupB :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	dn := (op >> 9) & 7
	opm := (op >> 6) & 7
	if opm == 3 || opm == 7 { // CMPA
		sz: u32 = 2 if opm == 3 else 4
		if !ea_ok(EA_ALL, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		v := sext(ea_read(m, e, sz), sz)
		alu_sub(m, v, m.a[dn], 0, 4, false, false)
		m.cycles += 2
		return
	}
	sz := size_field(op)
	if opm < 3 { // CMP
		if !ea_ok(EA_ALL, mode, reg) || (mode == 1 && sz == 1) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		src := ea_read(m, e, sz)
		alu_sub(m, src, m.d[dn], 0, sz, false, false)
		if sz == 4 { m.cycles += 2 }
		return
	}
	if mode == 1 { // CMPM (Ay)+,(Ax)+
		sy: u32 = 2 if sz == 1 && reg == 7 else sz
		sx: u32 = 2 if sz == 1 && dn == 7 else sz
		src := rd(m, m.a[reg], sz)
		m.a[reg] += sy
		dst := rd(m, m.a[dn], sz)
		m.a[dn] += sx
		alu_sub(m, src, dst, 0, sz, false, false)
		return
	}
	// EOR Dn,<ea>
	if !ea_ok(EA_DATA_ALT, mode, reg) { illegal(m); return }
	e := ea_resolve(m, mode, reg, sz)
	r := (ea_read(m, e, sz) ~ m.d[dn]) & mask_of(sz)
	logic_flags(m, r, sz)
	ea_write(m, e, sz, r)
	if sz == 4 && e.kind == .Dn { m.cycles += 4 }
}

@(private = "file")
groupC :: proc "contextless" (m: ^M68K, op: u32) {
	mode, reg := (op >> 3) & 7, op & 7
	dn := (op >> 9) & 7
	opm := (op >> 6) & 7
	switch {
	case opm == 3 || opm == 7: // MULU / MULS
		if !ea_ok(EA_DATA, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, 2)
		src := ea_read(m, e, 2)
		r: u32
		if opm == 3 {
			r = (m.d[dn] & 0xFFFF) * (src & 0xFFFF)
			ones := u32(0)
			for i in u32(0) ..< 16 { ones += src >> i & 1 }
			m.cycles += 34 + 2 * i64(ones)
		} else {
			r = u32(i32(i16(m.d[dn])) * i32(i16(src)))
			m.cycles += 34 + 36
		}
		m.d[dn] = r
		logic_flags(m, r, 4)
	case opm == 4 && mode < 2: // ABCD
		bcd_reg_or_mem(m, op, true)
	case op & 0x1F8 == 0x140: // EXG Dx,Dy
		m.d[dn], m.d[reg] = m.d[reg], m.d[dn]
		m.cycles += 2
	case op & 0x1F8 == 0x148: // EXG Ax,Ay
		m.a[dn], m.a[reg] = m.a[reg], m.a[dn]
		m.cycles += 2
	case op & 0x1F8 == 0x188: // EXG Dx,Ay
		m.d[dn], m.a[reg] = m.a[reg], m.d[dn]
		m.cycles += 2
	case: // AND
		sz := size_field(op)
		if !ea_ok(EA_DATA if opm < 3 else EA_MEM_ALT, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, sz)
		r := (m.d[dn] & ea_read(m, e, sz)) & mask_of(sz)
		logic_flags(m, r, sz)
		if opm < 3 {
			ea_write(m, Ea{kind = .Dn, reg = dn}, sz, r)
			if sz == 4 { m.cycles += 2 if e.kind == .Dn || e.kind == .Imm else 0 }
		} else {
			ea_write(m, e, sz, r)
		}
	}
}

// --------------------------------------------------------------- shifts ----

@(private = "file")
groupE :: proc "contextless" (m: ^M68K, op: u32) {
	left := op & 0x100 != 0
	if op & 0xC0 == 0xC0 { // memory shift: word, one bit
		if op & 0x800 != 0 { illegal(m); return } // bit-field ops are 68020+
		mode, reg := (op >> 3) & 7, op & 7
		if !ea_ok(EA_MEM_ALT, mode, reg) { illegal(m); return }
		e := ea_resolve(m, mode, reg, 2)
		v := ea_read(m, e, 2)
		r := shift_op(m, v, 1, 2, (op >> 9) & 3, left)
		ea_write(m, e, 2, r)
		return
	}
	sz := size_field(op)
	reg := op & 7
	count: u32
	if op & 0x20 != 0 { count = m.d[(op >> 9) & 7] & 63 } else {
		count = (op >> 9) & 7
		if count == 0 { count = 8 }
	}
	r := shift_op(m, m.d[reg], count, sz, (op >> 3) & 3, left)
	ea_write(m, Ea{kind = .Dn, reg = reg}, sz, r)
	m.cycles += (4 if sz == 4 else 2) + 2 * i64(count)
}
