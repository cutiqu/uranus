package saturn_tests

// VDP2 compositing: colour calculation (the water overlay in Mega Man 8 needs
// it: without it a semi-transparent layer is drawn opaque and hides the stage)
// and line scroll.

import "core:testing"
import sat "../../core"

@(private = "file")
Rig :: struct {
	v:  ^sat.VDP2,
	fb: ^[0x20000]u16,
}

@(private = "file")
rig_new :: proc() -> Rig {
	r := Rig{v = new(sat.VDP2), fb = new([0x20000]u16)}
	sat.vdp2_reset(r.v)
	return r
}

@(private = "file")
rig_free :: proc(r: Rig) {
	free(r.v)
	free(r.fb)
}

@(private = "file")
put16 :: proc(v: ^sat.VDP2, a: u32, w: u16) {
	v.vram[a], v.vram[a + 1] = u8(w >> 8), u8(w)
}

// Two 16 bpp RGB bitmap layers: NBG0 (bitmap at 0x00000) pure red, NBG1
// (bitmap at 0x20000) pure blue, both opaque (bit 15 set) at dot (0,0).
// NBG1 has the higher priority.
@(private = "file")
two_bitmaps :: proc(r: Rig) {
	v := r.v
	v.regs[0x00] = 0x8000 // display on, 320x224
	v.regs[0x10] = 0x0003 // BGON: NBG0, NBG1
	v.regs[0x14] = 0x3232 // CHCTLA: both bitmap, 16 bpp RGB, 512x256
	v.regs[0x1E] = 0x0010 // MPOFN: NBG1 bitmap at 0x20000
	v.regs[0x7C] = 0x0503 // PRINA: NBG0 priority 3, NBG1 priority 5
	for i in u32(0) ..< 8 {
		put16(v, i * 2, 0x801F)           // red
		put16(v, 0x20000 + i * 2, 0xFC00) // blue
	}
}

@(private = "file")
px :: proc(r: Rig, x, y: u32) -> u32 {
	sat.vdp2_draw_line(r.v, y, r.fb)
	return r.v.pix[y * sat.SCREEN_MAX_W + x] & 0xFFFFFF
}

// Nothing enabled for colour calculation: the higher priority layer wins, as before.
@(test)
cc_off_top_layer_opaque :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
}

// N1CCEN with a 50% ratio blends NBG1 (top) with NBG0 (second).
@(test)
cc_ratio_blend_with_layer_below :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x76] = 0x0002 // CCCTL: N1CCEN
	r.v.regs[0x84] = 0x1000 // CCRNA: NBG1 ratio 16
	testing.expect_value(t, px(r, 0, 0), 0x7F007F)
}

// The ratio is the weight of the layer *below*: ratio 0 shows (almost) only the top.
@(test)
cc_ratio_extremes :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x76] = 0x0002
	r.v.regs[0x84] = 0x0000 // ratio 0
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
	r.v.regs[0x84] = 0x1F00 // ratio 31: 31/32 of the layer below
	// R = 255*31>>5 = 247, B = 255*1>>5 = 7
	testing.expect_value(t, px(r, 0, 0), 0xF70007)
}

// The layer enabled for colour calculation must be the *top* one to blend.
@(test)
cc_only_applies_to_top_layer :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x76] = 0x0001 // only NBG0 (the lower layer) has CC enabled
	r.v.regs[0x84] = 0x0010
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
}

// CCMD = 1: add instead of blend.
@(test)
cc_additive :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x76] = 0x0102 // CCMD + N1CCEN
	testing.expect_value(t, px(r, 0, 0), 0xFF00FF)
}

// With nothing below, the layer is left alone (see CC_WITH_BACK_SCREEN).
@(test)
cc_without_layer_below_not_dimmed :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0002 // NBG1 only
	r.v.regs[0x56] = 0x0002 // BKTAU: back screen colour at 0x40000
	r.v.regs[0x57] = 0x0000
	put16(r.v, 0x40000, 0x03E0) // green
	r.v.regs[0x76] = 0x0002
	r.v.regs[0x84] = 0x1000
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
}

// CCRTMD = 1: the ratio comes from the second screen (NBG0: 8) not the top (NBG1: 16).
@(test)
cc_ratio_from_second_screen :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x76] = 0x0202 // CCRTMD + N1CCEN
	r.v.regs[0x84] = 0x1008 // NBG1 16, NBG0 8
	// R = 255*8>>5 = 63, B = 255*24>>5 = 191
	testing.expect_value(t, px(r, 0, 0), 0x3F00BF)
}

// A transparent dot on the top layer is skipped: the layer below shows through unblended.
@(test)
cc_transparent_top_dot :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	put16(r.v, 0x20000, 0x7C00) // NBG1 dot (0,0): MSB clear = transparent
	r.v.regs[0x76] = 0x0002
	r.v.regs[0x84] = 0x1000
	testing.expect_value(t, px(r, 0, 0), 0xFF0000)
}

// A sprite dot whose priority satisfies the SPCCCS condition blends with NBG0.
@(test)
cc_sprite_blend :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0001 // NBG0 only (red, priority 3)
	r.v.regs[0x70] = 0x0700 // SPCTL: type 0, SPCCCS = 0 (pr <= SPCCN), SPCCN = 7
	r.v.regs[0x76] = 0x0040 // SPCCEN
	r.v.regs[0x78] = 0x0006 // PRISA: sprite priority 6 for priority number 0
	r.v.regs[0x80] = 0x0010 // CCRSA: ratio number 0 = 16
	r.v.cram[2], r.v.cram[3] = 0x7C, 0x00 // palette entry 1 = blue
	r.fb[0] = 1                           // type 0 dot: pr 0, cc 0, colour 1
	testing.expect_value(t, px(r, 0, 0), 0x7F007F)
}

// Without SPCCEN the same sprite is opaque.
@(test)
cc_sprite_opaque_without_enable :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0001
	r.v.regs[0x70] = 0x0700
	r.v.regs[0x78] = 0x0006
	r.v.regs[0x80] = 0x0010
	r.v.cram[2], r.v.cram[3] = 0x7C, 0x00
	r.fb[0] = 1
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
}

// Colour offset still follows the layer that ends up on top.
@(test)
color_offset_uses_top_layer :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x88] = 0x0002 // CLOFEN: NBG1 only
	r.v.regs[0x89] = 0x0000 // offset bank A
	r.v.regs[0x8A] = 0x0010 // COAR +16
	testing.expect_value(t, px(r, 0, 0), 0x1000FF) // R = 0+16, B = 255
}

// Line scroll: each line gets its own horizontal offset from the table.
@(test)
line_scroll_x_per_line :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	v := r.v
	v.regs[0x00] = 0x8000
	v.regs[0x10] = 0x0001
	v.regs[0x14] = 0x0032
	v.regs[0x7C] = 0x0003
	// NBG0 bitmap rows 0 and 1: dot x has red = x (0..31), opaque.
	for row in u32(0) ..< 2 {
		for x in u32(0) ..< 32 {
			put16(v, (row * 512 + x) * 2, u16(0x8000 | x))
		}
	}
	v.regs[0x4D] = 0x0002 // SCRCTL: N0LSCX, one entry per line
	v.regs[0x50] = 0x0003 // LSTA0U/L: table at (0x30000) * 2 = 0x60000
	v.regs[0x51] = 0x0000
	put16(v, 0x60000, 0x0003) // line 0: +3.0 (integer part at bits 26:16)
	put16(v, 0x60002, 0x0000)
	put16(v, 0x60004, 0x0005) // line 1: +5.0
	put16(v, 0x60006, 0x0000)
	red5 :: proc(n: u32) -> u32 {
		c := n << 3
		return (c | c >> 5) << 16
	}
	testing.expect_value(t, px(r, 0, 0), red5(3))
	testing.expect_value(t, px(r, 0, 1), red5(5))
	testing.expect_value(t, px(r, 4, 0), red5(7))
}

// A vertical line-scroll value is added to the layer's scroll register, like the
// horizontal one: it replaces the per-line "y * zoom" term, not SCY. A table of plain
// line numbers is therefore ordinary scrolling by SCY. (Regression: the table used to
// replace SCY, which left Mega Man 8's water layer 9 lines low, detached from the pool
// painted in the layer behind it.)
@(test)
line_scroll_y_adds_to_scroll_register :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	v := r.v
	v.regs[0x00] = 0x8000
	v.regs[0x10] = 0x0001
	v.regs[0x14] = 0x0032
	v.regs[0x7C] = 0x0003
	for row in u32(0) ..< 16 { put16(v, row * 512 * 2, u16(0x8000 | row)) } // dot 0 of row n has red = n
	v.regs[0x4D] = 0x0004 // SCRCTL: N0LSCY, one entry per line
	v.regs[0x50] = 0x0003 // LSTA0: table at 0x60000
	v.regs[0x51] = 0x0000
	red5 :: proc(n: u32) -> u32 {
		c := n << 3
		return (c | c >> 5) << 16
	}
	// Table = line number, SCY = 9: line y shows row y + 9.
	v.regs[0x3A] = 9
	for y in u32(0) ..< 4 { put16(v, 0x60000 + y * 4, u16(y)) }
	for y in u32(0) ..< 4 { testing.expect_value(t, px(r, 0, y), red5(y + 9)) }
	// Table = 2 * line (a stretch), SCY = 1: line y shows row 1 + 2y.
	v.regs[0x3A] = 1
	for y in u32(0) ..< 4 { put16(v, 0x60000 + y * 4, u16(2 * y)) }
	for y in u32(0) ..< 4 { testing.expect_value(t, px(r, 0, y), red5(1 + 2 * y)) }
}

// Without SCRCTL bits set the table is ignored.
@(test)
line_scroll_disabled_ignored :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	v := r.v
	v.regs[0x00] = 0x8000
	v.regs[0x10] = 0x0001
	v.regs[0x14] = 0x0032
	v.regs[0x7C] = 0x0003
	put16(v, 2, 0x8001)
	v.regs[0x50] = 0x0003
	put16(v, 0x60000, 0x0003)
	testing.expect_value(t, px(r, 1, 0), 0x080000) // dot 1 = red 1 -> 8
}

// The row-pitch probe: a smooth 16 bpp image stored with a 320-dot row pitch but
// read by a 512-dot bitmap layer (what the garbled Mega Man 8 title screens look
// like) is reported as a 320 pitch; the same image stored at 512 is not flagged.
@(private = "file")
fill_image :: proc(v: ^sat.VDP2, pitch: u32, rows: u32) {
	for y in u32(0) ..< rows {
		for x in u32(0) ..< 320 {
			g := u16(((x / 10) + (y / 7)) & 0x1F)
			put16(v, (y * pitch + x) * 2, 0x8000 | g << 5)
		}
	}
}

@(test)
pitch_probe_finds_stored_pitch :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0001 // NBG0 only, bitmap at 0, 512 wide, 16 bpp
	for i in 0 ..< 0x40000 { r.v.vram[i] = 0 }
	fill_image(r.v, 320, 224)
	best, best_err, cfg_err, ok := sat.vdp2_pitch_probe(r.v, 0)
	testing.expect(t, ok)
	testing.expect_value(t, best, 320)
	testing.expect(t, best_err * 2 < cfg_err)
}

@(test)
pitch_probe_accepts_matching_pitch :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0001
	for i in 0 ..< 0x40000 { r.v.vram[i] = 0 }
	fill_image(r.v, 512, 224)
	best, _, _, ok := sat.vdp2_pitch_probe(r.v, 0)
	testing.expect(t, ok)
	testing.expect_value(t, best, 512)
}

@(test)
pitch_probe_ignores_empty_vram :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0001
	for i in 0 ..< 0x40000 { r.v.vram[i] = 0 }
	_, _, _, ok := sat.vdp2_pitch_probe(r.v, 0)
	testing.expect(t, !ok)
}

@(private = "file")
put32 :: proc(v: ^sat.VDP2, a: u32, w: u32) {
	put16(v, a, u16(w >> 16))
	put16(v, a + 2, u16(w))
}

// The Mega Man 8 movie layer, rebuilt from the values the game was observed to
// program: a 320x224 32 bpp frame stored packed (1280 bytes per row, contiguous)
// in a 512-wide bitmap, reassembled by
//   * a line-scroll table giving, per screen line, X = (320*row) mod 512 and the
//     bitmap row as an absolute Y with a fraction (row*320/512, but only on lines
//     whose 320 dots run past the end of a bitmap row),
//   * a vertical cell scroll ramp of 1/64 row per 8-dot column (two longs per
//     column, the ramp in the second, two VCS slots in the cycle patterns) so the
//     integer part of Y carries into the next bitmap row exactly where the line
//     wraps,
//   * window 0 limiting the picture to lines 8-231.
@(private = "file")
movie_rig :: proc(r: Rig) {
	v := r.v
	v.regs[0x00] = 0x8010 // display on, 320x240
	v.regs[0x10] = 0x0001 // BGON: NBG0
	v.regs[0x14] = 0x0042 // CHCTLA: bitmap, 32 bpp, 512x256
	v.regs[0x1E] = 0x0000 // MPOFN
	v.regs[0x7C] = 0x0002 // PRINA: NBG0 priority 2
	v.regs[0x0E], v.regs[0x0F] = 0xCCFF, 0xFFFF // CYCB1: two NBG0 vertical cell scroll slots
	v.regs[0x56], v.regs[0x57] = 0x0003, 0xF800 // back screen colour at 0x7F000 (black)
	v.regs[0x4D] = 0x0007 // SCRCTL: N0VCSC + N0LSCX + N0LSCY
	v.regs[0x50], v.regs[0x51] = 0x0003, 0x0000 // LSTA0 -> 0x60000
	v.regs[0x4E], v.regs[0x4F] = 0x0003, 0x8000 // VCSTA -> 0x70000
	v.regs[0x68] = 0x0003 // WCTLA: NBG0 window 0 enabled, inside
	v.regs[0x60], v.regs[0x61], v.regs[0x62], v.regs[0x63] = 0, 8, 0x27E, 0xE7

	for rho in u32(0) ..< 224 {
		for x in u32(0) ..< 320 {
			rr, g, b := (rho * 7 + x) & 0xFF, x & 0xFF, rho & 0xFF
			put32(v, (rho * 320 + x) * 4, 0x8000_0000 | b << 16 | g << 8 | rr)
		}
	}
	for y in u32(8) ..< 232 {
		a := (y - 8) * 320
		q, o := a / 512, a % 512
		frac := o / 2 if o + 320 > 512 else 0 // o/512 of a row, in 1/256ths
		put32(v, 0x60000 + y * 8, o << 16)
		put32(v, 0x60000 + y * 8 + 4, q << 16 | frac << 8)
	}
	for c in u32(0) ..< 40 {
		put32(v, 0x70000 + c * 8, 0)
		put32(v, 0x70000 + c * 8 + 4, c * 0x400)
	}
}

@(test)
movie_frame_reassembled_from_packed_layout :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	movie_rig(r)
	bad := 0
	for y in u32(0) ..< 240 {
		for x in u32(0) ..< 320 {
			want: u32
			if y >= 8 && y < 232 {
				rho := y - 8
				want = ((rho * 7 + x) & 0xFF) << 16 | (x & 0xFF) << 8 | (rho & 0xFF)
			}
			if px(r, x, y) != want { bad += 1 }
		}
	}
	testing.expect_value(t, bad, 0)
}

// Without the vertical cell scroll ramp the wrapped lines come out wrong, so the
// test above really depends on it.
@(test)
movie_frame_needs_vertical_cell_scroll :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	movie_rig(r)
	r.v.regs[0x4D] = 0x0006 // line scroll only
	bad := 0
	for y in u32(8) ..< 232 {
		rho := y - 8
		for x in u32(0) ..< 320 {
			want := ((rho * 7 + x) & 0xFF) << 16 | (x & 0xFF) << 8 | (rho & 0xFF)
			if px(r, x, y) != want { bad += 1 }
		}
	}
	testing.expect(t, bad > 0)
}

// A single VCS slot means a plain consecutive table: column c reads long c.
@(test)
vertical_cell_scroll_single_slot :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	v := r.v
	v.regs[0x00] = 0x8000
	v.regs[0x10] = 0x0001
	v.regs[0x14] = 0x0032 // 16 bpp RGB bitmap
	v.regs[0x7C] = 0x0003
	v.regs[0x4D] = 0x0001 // N0VCSC
	v.regs[0x0E], v.regs[0x0F] = 0xCFFF, 0xFFFF // one slot
	v.regs[0x4E], v.regs[0x4F] = 0x0003, 0x8000 // table at 0x70000
	for row in u32(0) ..< 4 {
		for x in u32(0) ..< 32 {
			put16(v, (row * 512 + x) * 2, u16(0x8000 | row * 4)) // 5-bit red = row*4
		}
	}
	put32(v, 0x70000 + 0 * 4, 0)           // column 0: row 0
	put32(v, 0x70000 + 1 * 4, 2 << 16)     // column 1: +2 rows
	red :: proc(row: u32) -> u32 {
		c := (row * 4) << 3
		return (c | c >> 5) << 16
	}
	testing.expect_value(t, px(r, 0, 0), red(0))
	testing.expect_value(t, px(r, 8, 0), red(2))
	testing.expect_value(t, px(r, 8, 1), red(3))
}

// Windows: inside/outside, and a layer is hidden (back screen shows) where it is clipped.
@(test)
window_clips_layer :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0002 // NBG1 only (blue)
	r.v.regs[0x56], r.v.regs[0x57] = 0x0003, 0xF800 // black back screen
	r.v.regs[0x68] = 0x0200 // NBG1: window 0 enabled (bit 1), area bit (bit 0) clear = shown outside it
	r.v.regs[0x60], r.v.regs[0x61], r.v.regs[0x62], r.v.regs[0x63] = 0, 0, 0x0F, 0x0F // x 0-7, y 0-15
	testing.expect_value(t, px(r, 0, 0), 0x000000) // inside the window, layer hidden
	put16(r.v, 0x20000 + 10 * 2, 0xFC00)
	testing.expect_value(t, px(r, 10, 0), 0x0000FF) // outside, layer shows
	r.v.regs[0x68] = 0x0300 // window 0 enabled, area bit set = inside
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
}

// WCTL bit 0 is the area (inside/outside) select and bit 1 the enable. A byte with
// only the area bit set leaves the window disabled and the layer fully visible.
@(test)
window_area_bit_alone_does_not_enable :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	r.v.regs[0x10] = 0x0002 // NBG1 only (blue)
	r.v.regs[0x56], r.v.regs[0x57] = 0x0003, 0xF800
	r.v.regs[0x68] = 0x0100 // N1W0A set, N1W0E clear
	r.v.regs[0x60], r.v.regs[0x61], r.v.regs[0x62], r.v.regs[0x63] = 0, 0, 0x0F, 0x0F
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
}

// ---------------------------------------------------- special colour calc ---

// NBG0 = red 16 bpp bitmap (below). NBG1 = 8 bpp palette bitmap (above), dot 1
// at (0,0), whose colour-RAM entry 1 is pure blue with the given MSB. NBG1 has
// CCEN set at ratio 16, so wherever it blends the result is 0x7F007F.
@(private = "file")
palette_over_red :: proc(r: Rig, cram_msb: bool) {
	two_bitmaps(r)
	v := r.v
	v.regs[0x14] = 0x1232 // NBG0 16 bpp RGB bitmap, NBG1 8 bpp palette bitmap
	v.vram[0x20000] = 1
	v.regs[0x76] = 0x0002 // N1CCEN
	v.regs[0x84] = 0x1000 // NBG1 ratio 16
	v.cram[2], v.cram[3] = 0x7C | (0x80 if cram_msb else 0), 0x00
}

// SFCCMD mode 3: only colours whose colour-RAM MSB is set are blended.
@(test)
special_cc_msb_mode :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	palette_over_red(r, false)
	testing.expect_value(t, px(r, 0, 0), 0x7F007F) // mode 0: always blends
	r.v.regs[0x77] = 0x000C // N1SCCM = 3
	testing.expect_value(t, px(r, 0, 0), 0x0000FF) // MSB clear: opaque
	palette_over_red(r, true)
	r.v.regs[0x77] = 0x000C
	testing.expect_value(t, px(r, 0, 0), 0x7F007F) // MSB set: blends
}

// SFCCMD mode 1 on a bitmap layer: the SCC bit in BMPNA (bit 12 for NBG1).
@(test)
special_cc_bitmap_scc_bit :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	palette_over_red(r, false)
	r.v.regs[0x77] = 0x0004 // N1SCCM = 1
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
	r.v.regs[0x16] = 0x1000 // N1BMSCC
	testing.expect_value(t, px(r, 0, 0), 0x7F007F)
}

// SFCCMD mode 2: the dot's colour code is matched against SFCODE (bit n covers
// codes 2n and 2n+1), the code byte chosen by SFSEL.
@(test)
special_cc_code_mode :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	palette_over_red(r, false)
	r.v.regs[0x77] = 0x0008 // N1SCCM = 2
	r.v.regs[0x13] = 0x0002 // code A matches codes 2,3 only; dot is 1
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
	r.v.regs[0x13] = 0x0001 // code A matches codes 0,1
	testing.expect_value(t, px(r, 0, 0), 0x7F007F)
	r.v.regs[0x13] = 0x0100 // only code B matches, and NBG1 selects A
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
	r.v.regs[0x12] = 0x0002 // SFSEL: NBG1 uses code B
	r.v.regs[0x13] = 0x0100
	testing.expect_value(t, px(r, 0, 0), 0x7F007F)
}

// Cell layers: the SCC bit of a two-word pattern name (bit 12 of the first word).
@(test)
special_cc_cell_scc_bit :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	palette_over_red(r, false)
	v := r.v
	v.regs[0x14] = 0x1032 // NBG1 now cells: 8x8, 8 bpp (bit 5-4 = 1), not bitmap
	v.regs[0x18 + 1] = 0x0000 // PNCN1: two-word names
	v.regs[0x1E] = 0x0000 // MPOFN
	v.regs[0x22] = 0x0004 // MPABN1: plane A = map 4 -> 4 << 14 = 0x10000 (two-word 8x8 names)
	// Pattern name at plane 0 (address 0): char 0x400, palette 0. The cell's
	// first row (8 dots) at 0x400 << 5 = 0x8000 holds dot 1.
	for i in u32(0) ..< 8 { v.vram[0x8000 + i] = 1 }
	v.regs[0x77] = 0x0004 // N1SCCM = 1
	base := u32(0x10000)
	put16(v, base, 0x0000)
	put16(v, base + 2, 0x0400)
	testing.expect_value(t, px(r, 0, 0), 0x0000FF) // SCC clear: opaque
	put16(v, base, 0x1000)
	testing.expect_value(t, px(r, 0, 0), 0x7F007F) // SCC set: blends
}

// The colour calculation window (WCTLD low byte) confines blending to window 0.
@(test)
cc_window_limits_blend :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	v := r.v
	v.regs[0x76] = 0x0002
	v.regs[0x84] = 0x1000
	v.regs[0x60], v.regs[0x61], v.regs[0x62], v.regs[0x63] = 0, 0, 2, 10 // window 0: x 0-2, y 0-10
	v.regs[0x6B] = 0x0003 // CCW0E (bit 1) + CCW0A (bit 0, inside)
	testing.expect_value(t, px(r, 0, 0), 0x7F007F)
	v.regs[0x60], v.regs[0x62] = 100, 200 // window moved away from dot (0,0)
	testing.expect_value(t, px(r, 0, 0), 0x0000FF)
	v.regs[0x6B] = 0x0002 // CCW0E, area clear = outside: blends outside the window
	testing.expect_value(t, px(r, 0, 0), 0x7F007F)
}

// ------------------------------------------------------------------ hi-res ---

// Hi-res (TVMD HRESO bit 1) is 640 dots across and layers are read once per
// dot. Darkseed stores a 640-wide picture in a 1024-wide 8 bpp bitmap; the old
// code sampled 320 positions and doubled them, so only the left half showed,
// stretched 2x.
@(test)
hires_samples_every_dot :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	two_bitmaps(r)
	v := r.v
	v.regs[0x00] = 0x8002 // display on, hi-res (640 wide)
	v.regs[0x10] = 0x0001 // NBG0 only
	v.regs[0x57] = 0x1000 // BKTAL: back colour from an empty VRAM word (not the red at 0)
	put16(v, 400 * 2, 0x801F) // red dot at x = 400, past the old 320-dot limit
	put16(v, 401 * 2, 0x83E0) // green next to it
	testing.expect_value(t, px(r, 400, 0), 0xFF0000)
	testing.expect_value(t, px(r, 401, 0), 0x00FF00) // neighbouring dots differ: no doubling
	testing.expect_value(t, px(r, 200, 0), 0x000000) // nothing there any more
}

// Sprites are still 320 wide: in hi-res each framebuffer column covers two dots.
@(test)
hires_sprites_cover_two_dots :: proc(t: ^testing.T) {
	r := rig_new()
	defer rig_free(r)
	v := r.v
	v.regs[0x00] = 0x8002
	v.regs[0x57] = 0x1000 // back colour: black
	v.regs[0x70] = 0x0020 // SPCTL: type 0, RGB data allowed
	v.regs[0x78] = 0x0007 // PRISA: sprite priority 7
	r.fb[10] = 0x801F // red sprite dot at framebuffer column 10
	testing.expect_value(t, px(r, 20, 0), 0xFF0000)
	testing.expect_value(t, px(r, 21, 0), 0xFF0000)
	testing.expect_value(t, px(r, 22, 0), 0x000000)
}
