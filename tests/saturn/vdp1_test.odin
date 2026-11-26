package saturn_tests

import "core:testing"
import sat "../../cores/saturn"

// Gouraud shading (CMDPMOD bit 2). The BIOS start-up animation draws hundreds of
// shaded lines per frame; flat drawing makes it a white blob.

@(private = "file")
w16 :: proc(v: ^sat.VDP1, addr: u32, x: u32) {
	v.vram[addr], v.vram[addr + 1] = u8(x >> 8), u8(x)
}

// One command at VRAM 0 followed by END, Gouraud table at 0x100.
@(private = "file")
cmd :: proc(v: ^sat.VDP1, ctrl, pmod, colr: u32, pts: [8]i32, table: [4]u32) {
	w16(v, 0, ctrl)
	w16(v, 4, pmod)
	w16(v, 6, colr)
	for p, i in pts { w16(v, 0x0C + u32(i) * 2, u32(p) & 0xFFFF) }
	w16(v, 0x1C, 0x100 / 8) // CMDGRDA
	for g, i in table { w16(v, 0x100 + u32(i) * 2, g) }
	w16(v, 0x20, 0x8000) // END
	sat.vdp1_run_list(v)
}

@(private = "file")
dot :: proc(v: ^sat.VDP1, x, y: u32) -> u16 {
	return v.fb[v.draw][y * 512 + x]
}

// R, G, B (5 bits each) of an RGB555 dot.
@(private = "file")
rgb :: proc(c: u16) -> [3]u16 {
	return {c & 0x1F, (c >> 5) & 0x1F, (c >> 10) & 0x1F}
}

@(test)
gouraud_line_ramps_between_endpoints :: proc(t: ^testing.T) {
	v := new(sat.VDP1)
	defer free(v)
	sat.vdp1_reset(v)
	// Line from (0,0) to (31,0), white. Entry A darkens by 16, entry B is neutral.
	cmd(v, 6, 0x0004, 0xFFFF, {0, 0, 31, 0, 0, 0, 0, 0}, {0x0000, 0x4210, 0, 0})
	testing.expect_value(t, rgb(dot(v, 0, 0)), [3]u16{15, 15, 15})
	testing.expect_value(t, rgb(dot(v, 31, 0)), [3]u16{31, 31, 31})
	mid := rgb(dot(v, 16, 0))
	testing.expect(t, mid[0] > 15 && mid[0] < 31, "midpoint should lie between the endpoints")
	testing.expect(t, dot(v, 16, 0) & 0x8000 != 0, "shaded dot is an RGB dot")
}

@(test)
flat_line_ignores_table :: proc(t: ^testing.T) {
	v := new(sat.VDP1)
	defer free(v)
	sat.vdp1_reset(v)
	cmd(v, 6, 0x0000, 0xFFFF, {0, 0, 31, 0, 0, 0, 0, 0}, {0x0000, 0x0000, 0, 0})
	testing.expect_value(t, dot(v, 0, 0), 0xFFFF)
	testing.expect_value(t, dot(v, 31, 0), 0xFFFF)
}

@(test)
neutral_table_changes_nothing :: proc(t: ^testing.T) {
	v := new(sat.VDP1)
	defer free(v)
	sat.vdp1_reset(v)
	// Polygon, mid-grey-blue; every table entry is 16/16/16.
	col: u32 = 0x8000 | 20 << 10 | 9 << 5 | 3
	cmd(v, 4, 0x0004, col, {2, 2, 9, 2, 9, 9, 2, 9}, {0x4210, 0x4210, 0x4210, 0x4210})
	testing.expect_value(t, u32(dot(v, 5, 5)), col)
}

@(test)
gouraud_polygon_corners_follow_table :: proc(t: ^testing.T) {
	v := new(sat.VDP1)
	defer free(v)
	sat.vdp1_reset(v)
	// White polygon, A (top-left) darkest, C (bottom-right) neutral. Table order is
	// A, B, C, D. Blue channel only: 16 + delta.
	dark: u32 = 0 // -16 on every channel
	neutral: u32 = 0x4210
	cmd(v, 4, 0x0004, 0xFFFF, {0, 0, 15, 0, 15, 15, 0, 15}, {dark, neutral, neutral, neutral})
	a, c := rgb(dot(v, 0, 0)), rgb(dot(v, 15, 15))
	testing.expect_value(t, a, [3]u16{15, 15, 15})
	testing.expect_value(t, c, [3]u16{31, 31, 31})
}
