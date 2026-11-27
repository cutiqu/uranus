// VDP1: the sprite/polygon chip. Software draws a command table into VRAM;
// VDP1 walks it and rasterizes into one of two 512x256 16-bit framebuffers
// while VDP2 displays the other.
//
// Drawing here is instantaneous: the whole command list runs the moment the
// game starts it (PTMR write, or at frame swap in auto mode). Real hardware
// takes time, and games poll EDSR for the end flag, which this sets at once.
//
// Implemented: sprites (normal/scaled/distorted), polygons, lines, polylines,
// clipping, local coordinates, flips, all six texture colour modes,
// transparency/end-code handling, mesh, replace/shadow/half-luminance/
// half-transparent, and Gouraud shading (CMDPMOD bit 2) on every drawing
// command. Not implemented: 8bpp framebuffer mode, rotation mode.
package saturn_core

import "base:intrinsics"

VDP1 :: struct {
	vram: [0x80000]u8,
	fb:   [2][0x20000]u16,
	draw: int, // buffer being drawn into (the one the CPU sees); 1-draw is displayed

	tvmr, fbcr, ptmr, ewdr, ewlr, ewrr: u16,
	edsr, lopr, copr:                   u16,
	manual_pending:                     bool,
	end_int_pending:                    bool,

	sys_x, sys_y:                 i32,
	uc_x0, uc_y0, uc_x1, uc_y1:   i32,
	loc_x, loc_y:                 i32,

	prof: u64, // cpu cycle-counter ticks spent drawing (core.odin reports them)
}

vdp1_reset :: proc "contextless" (v: ^VDP1) {
	v.tvmr, v.fbcr, v.ptmr = 0, 0, 0
	v.edsr, v.lopr, v.copr = 0, 0, 0
	v.manual_pending, v.end_int_pending = false, false
	v.sys_x, v.sys_y = 511, 255
	v.uc_x0, v.uc_y0, v.uc_x1, v.uc_y1 = 0, 0, 511, 255
	v.loc_x, v.loc_y = 0, 0
}

// ------------------------------------------------------------- CPU access ---

vdp1_reg_read :: proc "contextless" (v: ^VDP1, off: u32) -> u16 {
	switch (off & 0x1E) >> 1 {
	case 8:  return v.edsr
	case 9:  return v.lopr
	case 10: return v.copr
	case 11: return 1 << 12 | (v.ptmr & 2) << 7 | (v.fbcr & 0x1E) << 3 | v.tvmr
	}
	return 0
}

vdp1_reg_write :: proc "contextless" (s: ^Saturn, off: u32, val: u16) {
	v := &s.vdp1
	switch (off & 0x1E) >> 1 {
	case 0: v.tvmr = val & 0xF
	case 1: v.fbcr = val & 0x1F; if val & 2 != 0 { v.manual_pending = true }
	case 2:
		v.ptmr = val & 3
		if val & 1 != 0 { vdp1_run_list(v) }
	case 3: v.ewdr = val
	case 4: v.ewlr = val & 0x7FFF
	case 5: v.ewrr = val
	}
}

// The CPU's view of the framebuffer is the one being drawn into, big-endian.
vdp1_fb_read16 :: proc "contextless" (v: ^VDP1, off: u32) -> u16 {
	return v.fb[v.draw][(off >> 1) & 0x1FFFF]
}
vdp1_fb_write16 :: proc "contextless" (v: ^VDP1, off: u32, val: u16) {
	v.fb[v.draw][(off >> 1) & 0x1FFFF] = val
}

// ------------------------------------------------------------ frame flow ---

// Called when leaving VBlank: swap/erase framebuffers per FBCR and TVMR.
vdp1_frame_change :: proc "contextless" (v: ^VDP1) {
	t0 := intrinsics.read_cycle_counter()
	defer v.prof += u64(intrinsics.read_cycle_counter() - t0)
	manual := v.manual_pending
	// FBCR bit 0 is FCT (change trigger), bit 1 is FCM (manual mode); they were
	// swapped here, which broke every mode except 0 and 3.
	fct := v.fbcr & 1 != 0
	fcm := v.fbcr & 2 != 0
	swapped := false
	if !fcm || (manual && fct) {
		v.draw = 1 - v.draw
		v.edsr >>= 1 // CEF becomes BEF, CEF clears
		swapped = true
	}
	if (v.tvmr & 8 != 0) || !fcm || (manual && fct) { erase(v) }
	v.manual_pending = false
	if swapped && v.ptmr & 2 != 0 { vdp1_run_list(v) }
}

@(private = "file")
erase :: proc "contextless" (v: ^VDP1) {
	x0 := u32((v.ewlr >> 9) & 0x3F) * 8
	y0 := u32(v.ewlr & 0x1FF)
	x1 := u32((v.ewrr >> 9) & 0x7F) * 8
	y1 := u32(v.ewrr & 0x1FF)
	fb := &v.fb[v.draw]
	for y := y0; y <= y1 && y < 512; y += 1 {
		for x := x0; x < x1; x += 1 { fb[(y & 0xFF) * 512 + (x & 0x1FF)] = v.ewdr }
	}
}

// ----------------------------------------------------------- command list ---

@(private = "file")
cw :: #force_inline proc "contextless" (v: ^VDP1, cmd, i: u32) -> u32 {
	a := (cmd + i * 2) & 0x7FFFE
	return u32(v.vram[a]) << 8 | u32(v.vram[a + 1])
}

@(private = "file")
s16 :: #force_inline proc "contextless" (x: u32) -> i32 {return i32(i16(x))}

vdp1_run_list :: proc "contextless" (v: ^VDP1) {
	t0 := intrinsics.read_cycle_counter()
	defer v.prof += u64(intrinsics.read_cycle_counter() - t0)
	v.edsr &= ~u16(2)
	addr: u32 = 0
	ret: u32 = 0xFFFFFFFF
	for _ in 0 ..< 100000 {
		ctrl := cw(v, addr, 0)
		v.copr = u16(addr >> 2)
		if ctrl & 0x8000 != 0 { break }
		if ctrl & 0x4000 == 0 { exec_command(v, addr, ctrl) }
		link := cw(v, addr, 1) * 8
		switch (ctrl >> 12) & 3 {
		case 0: addr += 32
		case 1: addr = link
		case 2:
			if ret == 0xFFFFFFFF { ret = addr + 32 }
			addr = link
		case 3:
			if ret != 0xFFFFFFFF { addr, ret = ret, 0xFFFFFFFF } else { addr += 32 }
		}
		addr &= 0x7FFFF
	}
	v.edsr |= 2
	v.end_int_pending = true
}

@(private = "file")
Point :: struct {x, y: i32}

// Per-command Gouraud state: the four table entries (vertex A, B, C, D) as 5-bit
// R, G, B in 8.8 fixed point. 16 (0x10) is "no change"; below darkens, above lightens.
@(private = "file")
Shade :: struct {
	on: bool,
	c:  [4][3]i32,
}

@(private = "file")
shade_load :: proc "contextless" (v: ^VDP1, a, pmod: u32) -> (sh: Shade) {
	if pmod & 4 == 0 { return }
	sh.on = true
	table := cw(v, a, 14) * 8 // CMDGRDA
	for i in u32(0) ..< 4 {
		w := cw(v, table, i)
		sh.c[i] = {i32(w & 0x1F) << 8, i32((w >> 5) & 0x1F) << 8, i32((w >> 10) & 0x1F) << 8}
	}
	return
}

@(private = "file")
lerp3 :: #force_inline proc "contextless" (a, b: [3]i32, n, d: i32) -> [3]i32 {
	return {a[0] + (b[0] - a[0]) * n / d, a[1] + (b[1] - a[1]) * n / d, a[2] + (b[2] - a[2]) * n / d}
}

@(private = "file")
exec_command :: proc "contextless" (v: ^VDP1, a: u32, ctrl: u32) {
	pmod := cw(v, a, 2)
	colr := cw(v, a, 3)
	srca := cw(v, a, 4) * 8
	size := cw(v, a, 5)
	tw := i32((size >> 8) & 0x3F) * 8
	th := i32(size & 0xFF)
	P :: proc "contextless" (v: ^VDP1, a, i: u32) -> Point {return {s16(cw(v, a, 6 + i * 2)), s16(cw(v, a, 7 + i * 2))}}
	pa, pb, pc, pd := P(v, a, 0), P(v, a, 1), P(v, a, 2), P(v, a, 3)
	loc := Point{v.loc_x, v.loc_y}
	hflip, vflip := ctrl & 0x10 != 0, ctrl & 0x20 != 0
	sh := shade_load(v, a, pmod) // only the drawing commands (0-6) look at it

	switch ctrl & 0xF {
	case 0: // normal sprite
		w, h := tw, th
		q := [4]Point{{pa.x, pa.y}, {pa.x + w - 1, pa.y}, {pa.x + w - 1, pa.y + h - 1}, {pa.x, pa.y + h - 1}}
		draw_quad(v, q, loc, pmod, colr, srca, tw, th, hflip, vflip, true, sh)
	case 1: // scaled sprite
		q: [4]Point
		zp := (ctrl >> 8) & 0xF
		if zp == 0 {
			q = {{pa.x, pa.y}, {pc.x, pa.y}, {pc.x, pc.y}, {pa.x, pc.y}}
		} else {
			w, h := pb.x, pb.y
			x0, y0 := pa.x, pa.y
			switch zp & 3 {
			case 2: x0 -= w / 2
			case 3: x0 -= w
			}
			switch (zp >> 2) & 3 {
			case 2: y0 -= h / 2
			case 3: y0 -= h
			}
			q = {{x0, y0}, {x0 + w, y0}, {x0 + w, y0 + h}, {x0, y0 + h}}
		}
		draw_quad(v, q, loc, pmod, colr, srca, tw, th, hflip, vflip, true, sh)
	case 2: // distorted sprite
		draw_quad(v, {pa, pb, pc, pd}, loc, pmod, colr, srca, tw, th, hflip, vflip, true, sh)
	case 4: // polygon
		draw_quad(v, {pa, pb, pc, pd}, loc, pmod, colr, 0, 0, 0, false, false, false, sh)
	case 5: // polyline: each edge runs from one vertex's table entry to the next
		draw_line(v, pa, pb, loc, pmod, colr, sh, 0, 1)
		draw_line(v, pb, pc, loc, pmod, colr, sh, 1, 2)
		draw_line(v, pc, pd, loc, pmod, colr, sh, 2, 3)
		draw_line(v, pd, pa, loc, pmod, colr, sh, 3, 0)
	case 6: draw_line(v, pa, pb, loc, pmod, colr, sh, 0, 1)
	case 8: v.uc_x0, v.uc_y0, v.uc_x1, v.uc_y1 = pa.x, pa.y, pc.x, pc.y
	case 9: v.sys_x, v.sys_y = pc.x, pc.y
	case 0xA: v.loc_x, v.loc_y = pa.x, pa.y
	}
}

// Adds the Gouraud table value to each 5-bit colour channel (16 = unchanged).
// A palette code (MSB clear) with only the red entry moving is a colour-bank
// ramp: SGL shades 4/8bpp sprites that way, by nudging the code itself.
@(private = "file")
shade_dot :: proc "contextless" (c, pmod: u32, g: [3]i32) -> u32 {
	r, gg, b := clamp((g[0] + 128) >> 8, 0, 31), clamp((g[1] + 128) >> 8, 0, 31), clamp((g[2] + 128) >> 8, 0, 31)
	cm := (pmod >> 3) & 7
	if c & 0x8000 == 0 && cm != 1 && cm != 5 && gg == 16 && b == 16 {
		return u32(max(i32(c) + r - 16, 0)) & 0xFFFF
	}
	nr := clamp(i32(c & 0x1F) + r - 16, 0, 31)
	ng := clamp(i32((c >> 5) & 0x1F) + gg - 16, 0, 31)
	nb := clamp(i32((c >> 10) & 0x1F) + b - 16, 0, 31)
	return u32(nr | ng << 5 | nb << 10) | 0x8000
}

@(private = "file")
plot :: proc "contextless" (v: ^VDP1, x, y: i32, color: u32, pmod: u32, sh: ^Shade, g: [3]i32) {
	if x < 0 || y < 0 || x > v.sys_x || y > v.sys_y { return }
	if pmod & 0x400 != 0 { // user clip enabled
		inside := x >= v.uc_x0 && x <= v.uc_x1 && y >= v.uc_y0 && y <= v.uc_y1
		if inside == (pmod & 0x200 != 0) { return } // bit 9: draw outside instead
	}
	if pmod & 0x100 != 0 && (x ~ y) & 1 != 0 { return } // mesh
	idx := (u32(y) & 0xFF) * 512 + (u32(x) & 0x1FF)
	fb := &v.fb[v.draw]
	src := color
	if sh.on { src = shade_dot(src, pmod, g) }
	c := u16(src)
	// Colour calculation mode (bits 1-0); bit 2 is Gouraud, handled above.
	switch pmod & 3 {
	case 1: // shadow: halves what is already there, if it is an RGB dot
		d := fb[idx]
		if d & 0x8000 != 0 { c = (d >> 1) & 0x3DEF | 0x8000 } else { c = d }
	case 2: c = (c >> 1) & 0x3DEF | c & 0x8000 // half-luminance
	case 3: // half-transparent: average with an RGB dot already there
		d := fb[idx]
		if d & 0x8000 != 0 { c = (((c & 0x7BDE) >> 1) + ((d & 0x7BDE) >> 1)) | 0x8000 }
	}
	if pmod & 0x8000 != 0 { c |= 0x8000 }
	fb[idx] = c
}

// Samples the texture at column `u`, row `row`. Returns the framebuffer value
// and whether the dot should be skipped (transparent or end code).
@(private = "file")
texel :: proc "contextless" (v: ^VDP1, pmod, colr, srca: u32, tw, u, row: i32) -> (c: u32, skip: bool) {
	spd := pmod & 0x40 != 0 // transparent pixel disable
	ecd := pmod & 0x80 != 0 // end code disable
	cm := (pmod >> 3) & 7
	vr := proc "contextless" (v: ^VDP1, a: u32) -> u32 {return u32(v.vram[a & 0x7FFFF])}
	switch cm {
	case 0, 1: // 4 bpp: colour bank, or lookup table
		b := vr(v, srca + u32(row * (tw / 2) + u / 2))
		dot := (b >> 4) if u & 1 == 0 else (b & 0xF)
		if !ecd && dot == 0xF { return 0, true }
		if !spd && dot == 0 { return 0, true }
		if cm == 0 { return (colr & 0xFFF0) | dot, false }
		lut := colr * 8 + dot * 2
		return vr(v, lut) << 8 | vr(v, lut + 1), false
	case 2, 3, 4: // 8 bpp with a 64/128/256-colour bank
		raw := vr(v, srca + u32(row * tw + u))
		mask: u32 = 0x3F if cm == 2 else 0x7F if cm == 3 else 0xFF
		if !ecd && raw == 0xFF { return 0, true }
		dot := raw & mask
		if !spd && dot == 0 { return 0, true }
		return (colr & 0xFFFF & ~mask) | dot, false
	case 5: // 16 bpp RGB
		a := srca + u32(row * tw * 2 + u * 2)
		w := vr(v, a) << 8 | vr(v, a + 1)
		if !ecd && w == 0x7FFF { return 0, true }
		if !spd && w == 0 { return 0, true }
		return w, false
	}
	return 0, true
}

// ---------------------------------------------------------------- clipping ---
//
// The rasterisers below walk every point of a command's geometry. A polygon or
// scaled sprite that reaches far off screen (3D games produce these constantly:
// floors crossing the screen edge, sprites scaled up past it) used to cost time
// proportional to its whole area, visible or not: a 2000x2000 polygon took
// 32 ms, a 1000x1000 one entirely off screen 8 ms. So each line is first reduced to
// the run of points that can land inside the visible window, solved exactly in
// integer arithmetic, and the points in between are never generated. Output is
// bit-identical: plot() still applies every clip/mesh/colour rule to what remains.

// Inclusive window a command can draw into: the system clip, narrowed by the
// user clip when that is an "inside" clip. (An "outside" user clip is not a
// rectangle; plot() handles it per pixel.)
@(private = "file")
Window :: struct {x0, y0, x1, y1: i32}

@(private = "file")
window_for :: proc "contextless" (v: ^VDP1, pmod: u32) -> Window {
	w := Window{0, 0, v.sys_x, v.sys_y}
	if pmod & 0x400 != 0 && pmod & 0x200 == 0 {
		w.x0, w.y0 = max(w.x0, v.uc_x0), max(w.y0, v.uc_y0)
		w.x1, w.y1 = min(w.x1, v.uc_x1), min(w.y1, v.uc_y1)
	}
	return w
}

// The points of a line are l + trunc(d*j/den) for j in [0, m). Returns the
// inclusive span of j for which that lies in [lo, hi] (j0 > j1 when none does).
// trunc(d*j/den) is s*floor(|d|*j/den) with s = sign(d), which is monotonic in
// j, so the span is an interval with a closed form.
@(private = "file")
axis_span :: proc "contextless" (l, d, den, m, lo, hi: i32) -> (j0, j1: i32) {
	if l >= lo && l <= hi && i64(l) + i64(d) >= i64(lo) && i64(l) + i64(d) <= i64(hi) { return 0, m - 1 } // both ends inside: all of it
	a := i64(abs(d))
	qlo, qhi: i64 // allowed range of floor(a*j/den)
	if d >= 0 {
		qlo, qhi = i64(lo) - i64(l), i64(hi) - i64(l)
	} else {
		qlo, qhi = i64(l) - i64(hi), i64(l) - i64(lo)
	}
	if qhi < 0 || qlo > qhi { return 1, 0 }
	if a == 0 { // constant coordinate: all of the line or none of it
		if qlo <= 0 { return 0, m - 1 }
		return 1, 0
	}
	jmin := (max(qlo, 0) * i64(den) + a - 1) / a // smallest j with floor(a*j/den) >= qlo
	jmax := ((qhi + 1) * i64(den) - 1) / a //       largest  j with floor(a*j/den) <= qhi
	return i32(min(jmin, i64(m))), i32(clamp(jmax, -1, i64(m - 1)))
}

// Exact incremental form of  l + trunc(d*j/den)  for consecutive j, one add per
// step instead of a hardware divide (the original cost three to six per pixel).
@(private = "file")
Dda :: struct {
	v:             i32, // current value
	rem, den:      i32,
	qs, rs:        i32, // |d| / den and |d| % den
	neg:           bool,
}

@(private = "file")
dda_at :: #force_inline proc "contextless" (l, d, den, j: i32) -> (r: Dda) {
	a := abs(d)
	r.neg, r.den, r.v = d < 0, den, l
	switch a {
	case 0:   return
	case den: r.qs = 1 // one step per j (axis-aligned or 45 degrees): the common case
	case:     r.qs, r.rs = a / den, a % den
	}
	if j == 0 { return }
	p := i64(a) * i64(j)
	q, rem: i32
	if p <= 0x7FFFFFFF {
		q = i32(p) / den
		rem = i32(p) - q * den
	} else {
		q = i32(p / i64(den))
		rem = i32(p - i64(q) * i64(den))
	}
	r.rem = rem
	r.v = l - q if r.neg else l + q
	return
}

@(private = "file")
dda_next :: #force_inline proc "contextless" (r: ^Dda) {
	q := r.qs
	r.rem += r.rs
	if r.rem >= r.den { r.rem -= r.den; q += 1 }
	r.v += -q if r.neg else q
}

// One coordinate of a line. Most lines a game draws are axis-aligned or exactly
// diagonal, where the coordinate is constant or moves one pixel per step; those
// need no remainder tracking, so only the general case pays for a Dda.
@(private = "file")
Axis :: struct {
	v, step: i32,
	unit:    bool,
	dda:     Dda,
}

@(private = "file")
axis_init :: #force_inline proc "contextless" (a: ^Axis, l, d, den, j: i32) {
	if d == 0 || abs(d) == den {
		a.unit = true
		a.step = 0 if d == 0 else (1 if d > 0 else -1)
		a.v = l + a.step * j
	} else {
		a.dda = dda_at(l, d, den, j)
		a.v = a.dda.v
	}
}

@(private = "file")
axis_next :: #force_inline proc "contextless" (a: ^Axis) {
	if a.unit { a.v += a.step } else { dda_next(&a.dda); a.v = a.dda.v }
}

@(private = "file")
draw_line :: proc "contextless" (v: ^VDP1, p0, p1, loc: Point, pmod, color: u32, sh: Shade, ga, gb: int) {
	x0, y0, x1, y1 := p0.x + loc.x, p0.y + loc.y, p1.x + loc.x, p1.y + loc.y
	dx, dy := x1 - x0, y1 - y0
	n := max(abs(dx), abs(dy))
	den := max(n, 1)
	m := n + 1
	w := window_for(v, pmod)
	jx0, jx1 := axis_span(x0, dx, den, m, w.x0, w.x1)
	jy0, jy1 := axis_span(y0, dy, den, m, w.y0, w.y1)
	j0, j1 := max(jx0, jy0), min(jx1, jy1)
	if j0 > j1 { return }
	sh := sh
	ax, ay := Axis{}, Axis{}
	axis_init(&ax, x0, dx, den, j0)
	axis_init(&ay, y0, dy, den, j0)
	gd: [3]Dda
	if sh.on {
		for c in 0 ..< 3 { gd[c] = dda_at(sh.c[ga][c], sh.c[gb][c] - sh.c[ga][c], den, j0) }
	}
	for _ in j0 ..= j1 {
		g: [3]i32
		if sh.on { g = {gd[0].v, gd[1].v, gd[2].v} }
		plot(v, ax.v, ay.v, color, pmod, &sh, g)
		axis_next(&ax); axis_next(&ay)
		if sh.on { dda_next(&gd[0]); dda_next(&gd[1]); dda_next(&gd[2]) }
	}
}

// Fills (or textures) the quadrilateral A-B-C-D the way VDP1 does: step along
// the A-D and B-C edges, and for each step draw a line from the left point to
// the right point, sampling the texture across it. Gouraud values follow the
// same walk: A->D down the left edge, B->C down the right, then across.
@(private = "file")
draw_quad :: proc "contextless" (
	v: ^VDP1, q: [4]Point, loc: Point, pmod, colr, srca: u32, tw, th: i32, hflip, vflip, textured: bool, sh: Shade,
) {
	a := Point{q[0].x + loc.x, q[0].y + loc.y}
	b := Point{q[1].x + loc.x, q[1].y + loc.y}
	c := Point{q[2].x + loc.x, q[2].y + loc.y}
	d := Point{q[3].x + loc.x, q[3].y + loc.y}
	if textured && (tw <= 0 || th <= 0) { return }
	sh := sh
	w := window_for(v, pmod)
	steps := max(abs(d.x - a.x), abs(d.y - a.y), abs(c.x - b.x), abs(c.y - b.y)) + 1
	sden := max(steps - 1, 1)
	for i in 0 ..< steps {
		lx, ly := a.x + interp(d.x - a.x, i, sden), a.y + interp(d.y - a.y, i, sden)
		rx, ry := b.x + interp(c.x - b.x, i, sden), b.y + interp(c.y - b.y, i, sden)
		// Every point of this line lies inside the box spanned by its end points.
		if max(lx, rx) < w.x0 || min(lx, rx) > w.x1 || max(ly, ry) < w.y0 || min(ly, ry) > w.y1 { continue }
		m := max(abs(rx - lx), abs(ry - ly)) + 1
		mden := max(m - 1, 1)
		jx0, jx1 := axis_span(lx, rx - lx, mden, m, w.x0, w.x1)
		jy0, jy1 := axis_span(ly, ry - ly, mden, m, w.y0, w.y1)
		j0, j1 := max(jx0, jy0), min(jx1, jy1)
		if j0 > j1 { continue }
		row: i32
		if textured {
			row = i * th / steps
			if vflip { row = th - 1 - row }
		}
		gl, gr: [3]i32
		if sh.on {
			gl = lerp3(sh.c[0], sh.c[3], i, sden)
			gr = lerp3(sh.c[1], sh.c[2], i, sden)
		}
		ax, ay: Axis
		axis_init(&ax, lx, rx - lx, mden, j0)
		axis_init(&ay, ly, ry - ly, mden, j0)
		du: Dda
		if textured { du = dda_at(0, tw, m, j0) } // u = j * tw / m
		gd: [3]Dda
		if sh.on {
			for k in 0 ..< 3 { gd[k] = dda_at(gl[k], gr[k] - gl[k], mden, j0) }
		}
		for _ in j0 ..= j1 {
			g: [3]i32
			if sh.on { g = {gd[0].v, gd[1].v, gd[2].v} }
			if !textured {
				plot(v, ax.v, ay.v, colr, pmod, &sh, g)
			} else {
				u := du.v
				if hflip { u = tw - 1 - u }
				col, skip := texel(v, pmod, colr, srca, tw, u, row)
				if !skip { plot(v, ax.v, ay.v, col, pmod, &sh, g) }
			}
			axis_next(&ax); axis_next(&ay)
			if textured { dda_next(&du) }
			if sh.on { dda_next(&gd[0]); dda_next(&gd[1]); dda_next(&gd[2]) }
		}
	}
}

// d*n/den with a 64-bit product, so edges near the signed 16-bit limits cannot
// overflow; the divide stays 32-bit whenever the product fits (as it always does
// for anything a game draws on screen).
@(private = "file")
interp :: #force_inline proc "contextless" (d, n, den: i32) -> i32 {
	p := i64(d) * i64(n)
	if p >= -0x7FFFFFFF && p <= 0x7FFFFFFF { return i32(p) / den }
	return i32(p / i64(den))
}
