// Seeded random VDP1/VDP2 scenes, reduced to a hash of the pixels they produce.
// Shared by tests/saturn/golden_test.odin (which pins the hashes, taken from the
// renderers before they were optimised, so any rasteriser or compositor change has
// to stay pixel-identical) and tools/saturn_scenes (timing, and regenerating the
// hashes). Scene i of a class depends only on the seed and i, so a run of N scenes
// is a prefix of a longer one.
package scenes

import sat "../../../cores/saturn"

Rng :: struct {s: u64}

next :: proc(r: ^Rng) -> u64 {
	r.s ~= r.s >> 12; r.s ~= r.s << 25; r.s ~= r.s >> 27
	return r.s * 0x2545F4914F6CDD1D
}
rnd :: proc(r: ^Rng, n: u32) -> u32 {return u32(next(r) >> 33) % n}
range :: proc(r: ^Rng, lo, hi: i32) -> i32 {return lo + i32(rnd(r, u32(hi - lo + 1)))}

fnv :: proc(h: u64, v: u64) -> u64 {return (h ~ v) * 0x100000001B3}

vw :: proc(s: ^sat.Saturn, a: u32, v: u16) {
	s.vdp1.vram[a & 0x7FFFF] = u8(v >> 8)
	s.vdp1.vram[(a + 1) & 0x7FFFF] = u8(v)
}

// ------------------------------------------------------------------- VDP1 ---

Class :: enum {Normal, Huge, Offscreen, Clipped, Lines}

vdp1_scene :: proc(s: ^sat.Saturn, r: ^Rng, class: Class) -> u64 {
	sat.vdp1_reset(&s.vdp1)
	for i in 0x20000 ..< 0x50000 { // texture / table area: plenty of 0 and 0xFF for transparent + end codes
		k := rnd(r, 4)
		s.vdp1.vram[i] = 0 if k == 0 else 0xFF if k == 1 else u8(next(r) >> 40)
	}
	for i in 0 ..< 0x20000 { s.vdp1.fb[0][i] = u16(next(r) >> 40) } // random backdrop (RGB + palette dots)
	at: u32
	n := 3 + int(rnd(r, 8))
	for _ in 0 ..< n {
		ctrl: u16
		lo, hi: i32 = -400, 720 // coordinate range; Huge/Offscreen widen it
		switch class {
		case .Huge:      lo, hi = -2500, 3000
		case .Offscreen: lo, hi = 400, 1600
		case .Normal, .Clipped, .Lines:
		}
		kind := rnd(r, 10)
		type: u16
		switch class {
		case .Lines: type = 5 if kind < 5 else 6
		case .Normal, .Huge, .Offscreen, .Clipped:
			type = [?]u16{0, 1, 1, 2, 2, 4, 4, 4, 8 if class == .Clipped else 4, 9 if class == .Clipped else 2}[kind]
		}
		ctrl = type | u16(rnd(r, 4)) << 4 // flips
		if type == 1 { ctrl |= u16(rnd(r, 16)) << 8 }
		pmod := u16(next(r) >> 48)
		pmod &= ~u16(0x7)
		pmod |= u16(rnd(r, 4)) // colour calc 0..3
		if rnd(r, 3) == 0 { pmod |= 4 } // Gouraud
		pmod = (pmod & ~u16(0x38)) | u16(rnd(r, 6)) << 3 // colour mode
		if class != .Clipped { pmod &= ~u16(0x600) }
		if rnd(r, 3) != 0 { pmod &= ~u16(0x100) } // mesh is rarer
		tw := u16(1 + rnd(r, 8)); th := u16(1 + rnd(r, 64))
		p: [8]i16
		for i in 0 ..< 8 { p[i] = i16(range(r, lo, hi)) }
		if type == 8 { // user clip: pa .. pc
			p[0], p[1] = i16(range(r, 0, 200)), i16(range(r, 0, 150))
			p[4], p[5] = i16(range(r, 100, 330)), i16(range(r, 80, 230))
		}
		if type == 9 { p[4], p[5] = i16(range(r, 100, 511)), i16(range(r, 80, 255)) }
		if type == 0 || (type == 1 && (ctrl >> 8) & 0xF != 0) { // keep sprite/zoom sizes plausible
			p[2], p[3] = i16(range(r, 0, 700 if class == .Huge else 200)), i16(range(r, 0, 700 if class == .Huge else 200))
		}
		vw(s, at, ctrl); vw(s, at + 2, 0); vw(s, at + 4, pmod)
		vw(s, at + 6, u16(next(r) >> 48))
		vw(s, at + 8, u16((0x20000 + rnd(r, 0x1000) * 8) >> 3))
		vw(s, at + 10, tw << 8 | th)
		for i in 0 ..< 8 { vw(s, at + 12 + u32(i) * 2, u16(p[i])) }
		vw(s, at + 28, u16((0x40000 + rnd(r, 0x400) * 8) >> 3))
		at += 32
	}
	vw(s, at, 0x8000)
	sat.mem_write16(s, 0x05D00004, 1) // PTMR: run now
	h: u64 = 0xCBF29CE484222325
	for i in 0 ..< 0x20000 { h = fnv(h, u64(s.vdp1.fb[s.vdp1.draw][i])) }
	return h
}

// ------------------------------------------------------------------- VDP2 ---

vdp2_scene :: proc(s: ^sat.Saturn, r: ^Rng, mode: int) -> u64 {
	v := &s.vdp2
	sat.vdp2_reset(v)
	for i in 0 ..< len(v.vram) { v.vram[i] = u8(next(r) >> 40) if rnd(r, 3) != 0 else 0 }
	for i in 0 ..< len(v.cram) { v.cram[i] = u8(next(r) >> 40) }
	for i in 0 ..< len(s.vdp1.fb[0]) { s.vdp1.fb[0][i] = u16(next(r) >> 40) if rnd(r, 2) == 0 else 0 }
	for i in u32(0) ..< 0x80 { sat.vdp2_reg_write(v, i * 2, u16(next(r) >> 48)) }
	tv := u16(0x8000) | u16(rnd(r, 2)) // 320/352 wide
	tv |= u16(rnd(r, 3)) << 4
	if mode == 1 { tv |= u16(rnd(r, 4)) << 6 | u16(rnd(r, 2)) << 1 } // interlace / hires on
	sat.vdp2_reg_write(v, 0x00, tv)
	bg := u16(next(r) >> 48) & 0x1F3F
	if mode == 2 { bg = 0x000F } // all four NBG, no rotation
	sat.vdp2_reg_write(v, 0x20, bg)
	if mode != 3 { // mode 3 keeps the fully random register file
		for i in u32(0x38) ..< 0x4C { sat.vdp2_reg_write(v, i, u16(next(r) >> 48) & 0x07FF) } // scroll/zoom sane
	}
	h: u64 = 0xCBF29CE484222325
	w, ht, _, _ := sat.vdp2_mode(v)
	v.width, v.height = w, ht
	for y in u32(0) ..< ht {
		sat.vdp2_draw_line(v, y, &s.vdp1.fb[0])
	}
	for y in u32(0) ..< ht { for x in u32(0) ..< w { h = fnv(h, u64(v.pix[y * sat.SCREEN_MAX_W + x])) } }
	return h
}


CLASS_SEED  :: 0x9E3779B97F4A7C15
MODE_SEED   :: 0xD1B54A32D192ED03
HASH_START  :: u64(0xCBF29CE484222325)

// Hash of `n` consecutive scenes of a VDP1 class.
vdp1_class_hash :: proc(s: ^sat.Saturn, class: Class, n: int) -> u64 {
	r := Rng{CLASS_SEED + u64(class)}
	h := HASH_START
	for _ in 0 ..< n { h = fnv(h, vdp1_scene(s, &r, class)) }
	return h
}

// Hash of `n` consecutive VDP2 scenes of a mode (0 plain, 1 hires, 2 four NBG, 3 chaos).
vdp2_mode_hash :: proc(s: ^sat.Saturn, mode, n: int) -> u64 {
	r := Rng{MODE_SEED + u64(mode)}
	h := HASH_START
	for _ in 0 ..< n { h = fnv(h, vdp2_scene(s, &r, mode)) }
	return h
}

// Scene counts used by the golden test: enough to cover every command type, clip
// mode and register combination while keeping the test around two seconds.
QUICK_VDP1 :: 60
QUICK_VDP2 :: 16
