// VDP2: the background/compositing chip. It owns 512 KiB of VRAM, 4 KiB of
// colour RAM and ~0x120 bytes of registers, and builds the final picture from
// up to four scroll layers (NBG0-3), a rotation layer (RBG0), the VDP1
// sprite framebuffer, and a back colour.
//
// Rendering is per scanline, from the registers as they are *at that line*, so
// raster tricks that change scroll or palette mid-frame work.
//
// Implemented: NBG0-3 (cell and bitmap, all colour depths, 8x8/16x16 cells,
// 1/2-word pattern names, flips, scroll, NBG0/1 zoom), NBG0/1 line scroll
// (horizontal, vertical, per-line zoom), sprite layer (all 16 sprite data
// types), priorities, back screen, colour offset, and colour calculation
// (ratio blend and additive, NBG0-3 and sprites, against the next layer down
// or the back screen), vertical cell scroll and windows 0/1 (rectangles and
// line window tables) for NBG0-3 and sprites.
// Colour calculation can be gated per cell, per dot (SFCCMD: SCC bit, colour
// code against SFCODE, or colour-RAM MSB) and by the colour calculation window.
// Not implemented: RBG0, mosaic, extended colour calculation (line colour
// insertion, 3-way blend), shadows, the sprite window.
package saturn_core

SCREEN_MAX_W :: 704
SCREEN_MAX_H :: 480

NTSC_LINES :: 263

VDP2 :: struct {
	vram: [0x80000]u8,
	cram: [0x1000]u8,
	regs: [0x100]u16, // word-indexed copy of every register (offset >> 1)

	vblank, hblank, odd: bool,
	vcount:              u32,
	hcnt_latch:          u16,

	// Output. `width`/`height` describe the current frame's real size.
	width, height: u32,
	pix:           [SCREEN_MAX_W * SCREEN_MAX_H]u32,
}

vdp2_reset :: proc "contextless" (v: ^VDP2) {
	// VRAM/CRAM contents survive a soft reset on hardware; registers do not.
	v.regs = {}
	v.vblank, v.hblank, v.odd, v.vcount = false, false, false, 0
	v.width, v.height = 320, 224
}

// ------------------------------------------------------------- registers ---

vdp2_reg_read :: proc "contextless" (v: ^VDP2, off: u32) -> u16 {
	i := (off & 0x1FE) >> 1
	switch i {
	case 0x02: return v.regs[0x02] // EXTEN
	case 0x04: // TVSTAT
		return u16(v.vblank) << 3 | u16(v.hblank) << 2 | u16(v.odd) << 1
	case 0x06: return v.regs[0x06] & 0x8000 // VRSIZE
	case 0x08: return v.hcnt_latch
	case 0x0A: // VCNT
		return u16(v.vcount << (1 if v.regs[0] & 0xC0 == 0xC0 else 0)) & 0x3FF
	}
	return v.regs[i]
}

vdp2_reg_write :: proc "contextless" (v: ^VDP2, off: u32, val: u16) {
	v.regs[(off & 0x1FE) >> 1] = val
}

// Display geometry derived from TVMD.
vdp2_mode :: proc "contextless" (v: ^VDP2) -> (w, h: u32, hires, dbl: bool) {
	tvmd := v.regs[0]
	w = 352 if tvmd & 1 != 0 else 320
	heights := [4]u32{224, 240, 256, 256}
	h = heights[(tvmd >> 4) & 3]
	hires = tvmd & 2 != 0
	dbl = tvmd & 0xC0 == 0xC0
	return
}

// ----------------------------------------------------------- VRAM access ---

@(private = "file")
vr16 :: #force_inline proc "contextless" (v: ^VDP2, a: u32) -> u32 {
	i := a & 0x7FFFE
	return u32(v.vram[i]) << 8 | u32(v.vram[i + 1])
}

// Colour RAM -> 0x00RRGGBB. `idx` is a colour-RAM entry number.
@(private = "file")
cram_color :: proc "contextless" (v: ^VDP2, idx: u32) -> u32 {
	mode := (v.regs[0x07] >> 12) & 3 // RAMCTL
	if mode == 2 {
		e := (idx & 0x3FF) * 4
		c := u32(v.cram[e]) << 24 | u32(v.cram[e + 1]) << 16 | u32(v.cram[e + 2]) << 8 | u32(v.cram[e + 3])
		return (c & 0xFF) << 16 | (c & 0xFF00) | (c >> 16) & 0xFF
	}
	e := (idx & (0x3FF if mode == 0 else 0x7FF)) * 2
	c := u32(v.cram[e]) << 8 | u32(v.cram[e + 1])
	return rgb555(c)
}

// The MSB of a colour-RAM entry (bit 15 in the RGB555 modes, bit 31 in RGB888).
// Special colour calculation mode 3 reads it as a per-colour "blend me" flag.
@(private = "file")
cram_msb :: proc "contextless" (v: ^VDP2, idx: u32) -> bool {
	mode := (v.regs[0x07] >> 12) & 3
	e := (idx & 0x3FF) * 4 if mode == 2 else (idx & (0x3FF if mode == 0 else 0x7FF)) * 2
	return v.cram[e] & 0x80 != 0
}

rgb555 :: #force_inline proc "contextless" (c: u32) -> u32 {
	r := (c & 0x1F) << 3
	g := ((c >> 5) & 0x1F) << 3
	b := ((c >> 10) & 0x1F) << 3
	return (r | r >> 5) << 16 | (g | g >> 5) << 8 | (b | b >> 5)
}

// -------------------------------------------------------------- layers -----

NBG :: struct {
	on:         bool,
	prio:       u32,
	bitmap:     bool,
	bm_w_shift: u32, // bitmap width = 1 << this
	bm_h_mask:  u32,
	bm_base:    u32, // byte address
	bm_pal:     u32,
	bpp:        u32, // 4, 8, 16, 32
	palette_2048: bool, // 16 bpp but values are colour-RAM indices, not RGB
	char_size:  u32, // 0 = 8x8, 1 = 16x16
	pn_one_word: bool,
	aux_mode:   bool,
	supp:       u32, // pattern name control register (supplement bits)
	plane_size: u32,
	maps:       [4]u32, // byte address of each plane
	scx, scy:   u32, // 8.8 fixed point
	xinc, yinc: u32, // 8.8 fixed point
	transp_off: bool, // colour 0 is drawn (TPON)
	cram_off:   u32,
	// Special colour calculation (SFCCMD): which dots of a layer that has CCEN
	// set are actually blended. 0 = all of them, 1 = cells (or the whole
	// bitmap) whose SCC bit is set, 2 = dots whose colour code matches
	// SFCODE, 3 = dots whose colour data has its MSB set.
	sccm:       u32,
	sfcode:     u32, // the 8-bit function code this layer matches (SFSEL picks A or B)
	bm_scc:     bool, // bitmap layers: the SCC bit from BMPNA/BMPNB

	// One-entry cache of the last pattern-name lookup (cell mode only). Everything
	// nbg_pixel derives from the pattern name depends only on which 8x8 cell the dot
	// is in, so the lookup runs once per cell instead of once per dot. nbg_config
	// builds a fresh NBG every line, which starts the cache empty.
	cell_ok:     bool,
	cell_kx, cell_ky: u32, // cell coordinates (ix >> 3, iy >> 3) the entry is for
	cell_base:   u32,      // character data address (charno << 5), before the row offset
	cell_cram:   u32,      // colour RAM index base from the palette number
	cell_hflip, cell_vflip, cell_scc: bool,
}

@(private = "file")
nbg_config :: proc "contextless" (v: ^VDP2, n: u32) -> (c: NBG) {
	r := &v.regs
	bgon := r[0x10]
	c.on = bgon & (1 << n) != 0
	c.transp_off = bgon & (0x100 << n) != 0
	prio_reg := r[0x7C + n / 2] // PRINA / PRINB
	c.prio = u32(prio_reg >> (8 * (n & 1))) & 7

	chctl: u32
	colors: u32
	switch n {
	case 0: chctl = u32(r[0x14]); colors = (chctl >> 4) & 7; c.char_size = chctl & 1; c.bitmap = chctl & 2 != 0
	case 1: chctl = u32(r[0x14]) >> 8; colors = (chctl >> 4) & 3; c.char_size = chctl & 1; c.bitmap = chctl & 2 != 0
	case 2: chctl = u32(r[0x15]); colors = (chctl >> 1) & 1; c.char_size = chctl & 1
	case 3: chctl = u32(r[0x15]) >> 4; colors = (chctl >> 1) & 1; c.char_size = chctl & 1
	}
	switch colors {
	case 0: c.bpp = 4
	case 1: c.bpp = 8
	case 2: c.bpp, c.palette_2048 = 16, true
	case 3: c.bpp = 16
	case: c.bpp = 32
	}

	pnc := u32(r[0x18 + n])
	c.pn_one_word = pnc & 0x8000 != 0
	c.aux_mode = pnc & 0x4000 != 0
	c.supp = pnc & 0x3FF

	c.plane_size = u32(r[0x1D] >> (n * 2)) & 3
	mpofn := u32(r[0x1E]) >> (n * 4) & 7

	if c.bitmap {
		bmsz := (chctl >> 2) & 3
		c.bm_w_shift = 10 if bmsz & 2 != 0 else 9
		c.bm_h_mask = 0x1FF if bmsz & 1 != 0 else 0xFF
		c.bm_base = mpofn << 17
		bmpn := u32(r[0x16]) >> (8 * n) // BMPNA: N0 low byte, N1 high byte
		c.bm_pal = (bmpn & 7) << 4
	} else {
		// Plane addresses, in bytes. A page is 64x64 cells (or 32x32 when
		// cells are 16x16) at one or two words per pattern name.
		shift := 13 - u32(c.pn_one_word) - (c.char_size << 1) + 1 // +1: words -> bytes
		for i in u32(0) ..< 4 {
			mreg := u32(r[0x20 + n * 2 + i / 2]) >> (8 * (i & 1)) & 0x3F
			c.maps[i] = (((mpofn << 6) + (mreg & ~c.plane_size)) << shift) & 0x7FFFF
		}
	}

	// Scroll position / zoom. NBG0/1 have 8.8 scroll and zoom; NBG2/3 integer.
	switch n {
	case 0, 1:
		o := 0x38 + n * 8
		c.scx = (u32(r[o]) & 0x7FF) << 8 | u32(r[o + 1] >> 8)
		c.scy = (u32(r[o + 2]) & 0x7FF) << 8 | u32(r[o + 3] >> 8)
		c.xinc = (u32(r[o + 4]) & 7) << 8 | u32(r[o + 5] >> 8)
		c.yinc = (u32(r[o + 6]) & 7) << 8 | u32(r[o + 7] >> 8)
		if c.xinc == 0 { c.xinc = 0x100 } // 0 only appears if software never set zoom
		if c.yinc == 0 { c.yinc = 0x100 }
	case 2, 3:
		c.scx = (u32(r[0x48 + (n - 2) * 2]) & 0x7FF) << 8
		c.scy = (u32(r[0x49 + (n - 2) * 2]) & 0x7FF) << 8
		c.xinc, c.yinc = 0x100, 0x100
	}
	c.cram_off = ((u32(r[0x72]) >> (n * 4)) & 7) << 8

	c.sccm = (u32(r[0x77]) >> (n * 2)) & 3 // SFCCMD
	sfcs := (u32(r[0x12]) >> n) & 1 // SFSEL: 0 = code A (SFCODE low byte), 1 = code B
	c.sfcode = (u32(r[0x13]) >> (8 * sfcs)) & 0xFF
	if c.bitmap { c.bm_scc = (u32(r[0x16]) >> (8 * n)) & 0x10 != 0 }
	return
}

// Resolves the cell containing plane coordinates (ix, iy) through the pattern
// name table and stores the result in the NBG's cell cache.
@(private = "file")
cell_lookup :: proc "contextless" (v: ^VDP2, c: ^NBG, ix, iy: u32) {
	bpp := c.bpp
	scc: bool
	cs := c.char_size
	map_idx := ((ix >> (9 + (c.plane_size & 1))) & 1) | ((iy >> (9 + ((c.plane_size & 2) >> 1) - 1)) & 2)
	page := ((ix >> 9) & c.plane_size & 1) | ((iy >> 8) & c.plane_size & 2)
	page_shift := 13 - u32(c.pn_one_word) - (cs << 1) + 1
	cells_per_row := u32(64) >> cs
	pn_index := (((ix >> 3) & 0x3F) >> cs) + ((((iy >> 3) & 0x3F) >> cs) * cells_per_row)
	pn_addr := (c.maps[map_idx] + (page << page_shift) + pn_index * (2 if !c.pn_one_word else 1) * 2) & 0x7FFFF

	palno: u32
	hflip, vflip: bool
	charno: u32
	pnd := vr16(v, pn_addr)
	supp := c.supp
	if !c.pn_one_word {
		palno = pnd & 0x7F
		vflip, hflip = pnd & 0x8000 != 0, pnd & 0x4000 != 0
		scc = pnd & 0x1000 != 0
		charno = vr16(v, pn_addr + 2) & 0x7FFF
	} else {
		scc = supp & 0x100 != 0 // one-word names: SCC comes from the layer's supplement register
		if bpp >= 8 { palno = ((pnd >> 12) & 7) << 4 } else { palno = ((pnd >> 12) & 0xF) | (((supp >> 5) & 7) << 4) }
		if !c.aux_mode {
			vflip, hflip = pnd & 0x800 != 0, pnd & 0x400 != 0
			if cs != 0 { charno = ((pnd & 0x3FF) << 2) + ((supp & 0x1C) << 10) + (supp & 3) } else { charno = (pnd & 0x3FF) + ((supp & 0x1F) << 10) }
		} else {
			if cs != 0 { charno = ((pnd & 0xFFF) << 2) + ((supp & 0x10) << 10) + (supp & 3) } else { charno = (pnd & 0xFFF) + ((supp & 0x1C) << 10) }
		}
	}
	if cs != 0 {
		cidx := (((ix >> 3) ~ u32(hflip)) & 1) + (((iy >> 2) ~ (u32(vflip) << 1)) & 2)
		charno = (charno + cidx * (bpp >> 2)) & 0x7FFF
	}
	c.cell_kx, c.cell_ky, c.cell_ok = ix >> 3, iy >> 3, true
	c.cell_base = charno << 5
	c.cell_hflip, c.cell_vflip, c.cell_scc = hflip, vflip, scc
	c.cell_cram = ((palno << 4) & ~((u32(1) << (bpp & 0x1F)) - 1)) if bpp < 16 else 0
}

// Fetches the pixel at plane coordinates (ix, iy). Returns 0x00RRGGBB and
// whether the dot is opaque.
@(private = "file")
nbg_pixel :: proc "contextless" (v: ^VDP2, c: ^NBG, ix, iy: u32) -> (color: u32, opaque: bool, cc_ok: bool) {
	bpp := c.bpp
	cram_index: u32
	addr: u32
	scc: bool // the pattern name's (or bitmap's) special colour calculation bit

	if c.bitmap {
		w := u32(1) << c.bm_w_shift
		off := c.bm_base + (((ix & (w - 1)) + ((iy & c.bm_h_mask) << c.bm_w_shift)) * bpp) / 8
		addr = off & 0x7FFFF
		cram_index = c.bm_pal << 4
		scc = c.bm_scc
	} else {
		kx, ky := ix >> 3, iy >> 3
		if !c.cell_ok || c.cell_kx != kx || c.cell_ky != ky {
			cell_lookup(v, c, ix, iy)
		}
		cellx := (ix & 7) ~ (7 if c.cell_hflip else 0)
		celly := (iy & 7) ~ (7 if c.cell_vflip else 0)
		addr = (c.cell_base + celly * bpp) & 0x7FFFF
		cram_index = c.cell_cram
		scc = c.cell_scc
		col, op, di := nbg_cell_dot(v, c, addr, cellx, cram_index)
		return col, op, special_cc_ok(c, scc, di)
	}
	// Bitmap dot at byte address `addr`; x within the byte/word depends on bpp.
	col, op, di := nbg_bitmap_dot(v, c, addr, ix, cram_index)
	return col, op, special_cc_ok(c, scc, di)
}

// What a dot fetch reports besides its colour: the colour code and MSB that
// special colour calculation (SFCCMD modes 2 and 3) looks at.
@(private = "file")
Dot_Info :: struct {
	code: u32,
	msb:  bool,
}

@(private = "file")
nbg_cell_dot :: proc "contextless" (v: ^VDP2, c: ^NBG, row: u32, x: u32, cram_index: u32) -> (color: u32, opaque: bool, di: Dot_Info) {
	switch c.bpp {
	case 4:
		b := u32(v.vram[(row + x / 2) & 0x7FFFF])
		dot := (b >> 4) if x & 1 == 0 else (b & 0xF)
		ci := cram_index + c.cram_off + dot
		return cram_color(v, ci), dot != 0 || c.transp_off, {dot, cram_msb(v, ci)}
	case 8:
		dot := u32(v.vram[(row + x) & 0x7FFFF])
		ci := cram_index + c.cram_off + dot
		return cram_color(v, ci), dot != 0 || c.transp_off, {dot, cram_msb(v, ci)}
	case 16:
		w := vr16(v, row + x * 2)
		if c.palette_2048 {
			ci := (w & 0x7FF) + c.cram_off
			return cram_color(v, ci), w & 0x7FF != 0 || c.transp_off, {w & 0xF, cram_msb(v, ci)}
		}
		return rgb555(w), w & 0x8000 != 0 || c.transp_off, {0, w & 0x8000 != 0}
	}
	hi, lo := vr16(v, row + x * 4), vr16(v, row + x * 4 + 2)
	return (lo & 0xFF) << 16 | (lo & 0xFF00) | (hi & 0xFF), hi & 0x8000 != 0 || c.transp_off, {0, hi & 0x8000 != 0}
}

@(private = "file")
nbg_bitmap_dot :: proc "contextless" (v: ^VDP2, c: ^NBG, addr: u32, ix: u32, cram_index: u32) -> (color: u32, opaque: bool, di: Dot_Info) {
	switch c.bpp {
	case 4:
		b := u32(v.vram[addr & 0x7FFFF])
		dot := (b >> 4) if ix & 1 == 0 else (b & 0xF)
		ci := cram_index + c.cram_off + dot
		return cram_color(v, ci), dot != 0 || c.transp_off, {dot, cram_msb(v, ci)}
	case 8:
		dot := u32(v.vram[addr & 0x7FFFF])
		ci := cram_index + c.cram_off + dot
		return cram_color(v, ci), dot != 0 || c.transp_off, {dot, cram_msb(v, ci)}
	case 16:
		w := vr16(v, addr)
		if c.palette_2048 {
			ci := (w & 0x7FF) + c.cram_off
			return cram_color(v, ci), w & 0x7FF != 0 || c.transp_off, {w & 0xF, cram_msb(v, ci)}
		}
		return rgb555(w), w & 0x8000 != 0 || c.transp_off, {0, w & 0x8000 != 0}
	}
	hi, lo := vr16(v, addr), vr16(v, addr + 2)
	return (lo & 0xFF) << 16 | (lo & 0xFF00) | (hi & 0xFF), hi & 0x8000 != 0 || c.transp_off, {0, hi & 0x8000 != 0}
}

// Whether this dot takes part in colour calculation, given the layer's
// special colour calculation mode (only consulted when CCEN is set).
@(private = "file")
special_cc_ok :: #force_inline proc "contextless" (c: ^NBG, scc: bool, di: Dot_Info) -> bool {
	switch c.sccm {
	case 1: return scc
	case 2: return c.sfcode & (1 << ((di.code >> 1) & 7)) != 0
	case 3: return di.msb
	}
	return true
}

// ------------------------------------------------------------- sprites -----

// One decoded VDP1 framebuffer word.
Sprite_Dot :: struct {
	color:  u32, // 0x00RRGGBB
	pr:     u32, // priority number (index into PRISA-PRISD)
	cc_idx: u32, // colour-calculation ratio number (index into CCRSA-CCRSD)
	msb:    bool, // the data's MSB (used by SPCCCS = 3)
}

// Decodes one VDP1 framebuffer word. Returns the dot and whether it is opaque.
@(private = "file")
sprite_pixel :: proc "contextless" (v: ^VDP2, src_in: u32) -> (d: Sprite_Dot, opaque: bool) {
	spctl := u32(v.regs[0x70])
	stype := spctl & 0xF
	rgb_ok := spctl & 0x20 != 0
	src := src_in
	if rgb_ok && src & 0x8000 != 0 {
		d.color, d.msb = rgb555(src), true
		return d, stype & 8 == 0 || src & 0xFF != 0
	}
	d.msb = src & (0x8000 if stype & 8 == 0 else 0x80) != 0
	if stype & 8 != 0 { src &= 0xFF }
	if src == 0 { return d, false }
	dc: u32
	switch stype {
	case 0x0: d.pr, d.cc_idx, dc = (src >> 14) & 3, (src >> 11) & 7, src & 0x7FF
	case 0x1: d.pr, d.cc_idx, dc = (src >> 13) & 7, (src >> 11) & 3, src & 0x7FF
	case 0x2: d.pr, d.cc_idx, dc = (src >> 14) & 1, (src >> 11) & 7, src & 0x7FF
	case 0x3: d.pr, d.cc_idx, dc = (src >> 13) & 3, (src >> 11) & 3, src & 0x7FF
	case 0x4: d.pr, d.cc_idx, dc = (src >> 13) & 3, (src >> 10) & 7, src & 0x3FF
	case 0x5: d.pr, d.cc_idx, dc = (src >> 12) & 7, (src >> 11) & 1, src & 0x7FF
	case 0x6: d.pr, d.cc_idx, dc = (src >> 12) & 7, (src >> 10) & 3, src & 0x3FF
	case 0x7: d.pr, d.cc_idx, dc = (src >> 12) & 7, (src >> 9) & 7, src & 0x1FF
	case 0x8: d.pr, dc = (src >> 7) & 1, src & 0x7F
	case 0x9: d.pr, d.cc_idx, dc = (src >> 7) & 1, (src >> 6) & 1, src & 0x3F
	case 0xA: d.pr, dc = (src >> 6) & 3, src & 0x3F
	case 0xB: d.cc_idx, dc = (src >> 6) & 3, src & 0x3F
	case 0xC: d.pr, dc = (src >> 7) & 1, src & 0xFF
	case 0xD: d.pr, dc = (src >> 7) & 1, src & 0xFF
	case 0xE: d.pr, dc = (src >> 6) & 3, src & 0xFF
	case 0xF: dc = src & 0xFF
	}
	cao := (u32(v.regs[0x73]) >> 4 & 7) << 8
	d.color = cram_color(v, cao + dc)
	return d, true
}

// ------------------------------------------------------------ colour offs --

@(private = "file")
color_offset :: proc "contextless" (v: ^VDP2, color: u32, layer_bit: u32) -> u32 {
	r := &v.regs
	if r[0x88] & (1 << layer_bit) == 0 { return color } // CLOFEN
	base: u32 = 0x8A if r[0x89] & (1 << layer_bit) == 0 else 0x8D // A or B bank
	chan :: proc "contextless" (c: u32, off: u16) -> u32 {
		o := i32(off & 0x1FF)
		if o & 0x100 != 0 { o -= 0x200 }
		return u32(clamp(i32(c) + o, 0, 255))
	}
	R := chan((color >> 16) & 0xFF, r[base])
	G := chan((color >> 8) & 0xFF, r[base + 1])
	B := chan(color & 0xFF, r[base + 2])
	return R << 16 | G << 8 | B
}

// ---------------------------------------------------------- line scroll ----

// NBG0/NBG1 line scroll. SCRCTL holds, per layer, which fields the table has
// (X scroll, Y scroll, X zoom) and how many lines share one entry. Entries are
// 32 bits each, in that order, and only for the enabled fields. A horizontal
// value is added to the layer's scroll register, and so is a vertical value: it
// stands in for the line's offset from the top (the y * zoom term), so a table
// holding plain line numbers is ordinary scrolling and SCY still applies (Mega
// Man 8's water stage scrolls NBG1 by SCY=9 with such a table; ignoring SCY left
// the water 9 lines low, detached from the pool in the layer behind it). The
// same game stores 0.625 * line there, with SCY = 0, to read a packed video frame
// from a 512-wide bitmap. A zoom value replaces the horizontal zoom.
@(private = "file")
apply_line_scroll :: proc "contextless" (v: ^VDP2, c: ^NBG, n: u32, y: u32, ybase: ^u32) {
	if n > 1 { return }
	scrctl := u32(v.regs[0x4D]) >> (8 * n)
	lscx, lscy, lzmx := scrctl & 2 != 0, scrctl & 4 != 0, scrctl & 8 != 0
	if !(lscx || lscy || lzmx) { return }
	interval := (scrctl >> 4) & 3 // 0: every line, 1: 2 lines, 2: 4 lines, 3: 8 lines
	fields := u32(lscx) + u32(lscy) + u32(lzmx)
	base := ((u32(v.regs[0x50 + n * 2]) & 7) << 16 | u32(v.regs[0x51 + n * 2])) * 2
	a := base + (y >> interval) * fields * 4
	rd :: proc "contextless" (v: ^VDP2, a: u32) -> u32 {return vr16(v, a) << 16 | vr16(v, a + 2)}
	if lscx { c.scx = (c.scx + ((rd(v, a) >> 8) & 0x7FFFF)) & 0x7FFFF; a += 4 }
	if lscy { ybase^ = (c.scy + ((rd(v, a) >> 8) & 0x7FFFF)) & 0x7FFFF; a += 4 }
	if lzmx {
		z := (rd(v, a) >> 8) & 0x7FF // 3.8 fixed point
		c.xinc = z if z != 0 else 0x100
	}
}

// How many access slots of one kind the VRAM cycle patterns reserve
// (0xC = NBG0 vertical cell scroll table read, 0xD = NBG1).
@(private = "file")
cyc_slots :: proc "contextless" (v: ^VDP2, code: u16) -> u32 {
	n: u32
	for i in 8 ..< 16 {
		w := v.regs[i]
		for sh in ([4]u32{0, 4, 8, 12}) { if (w >> sh) & 0xF == code { n += 1 } }
	}
	return n
}

// Vertical cell scroll: one 32-bit entry per 8-dot screen column (11.8 fixed
// point, added to the line's Y coordinate). The table holds one long per VCS
// access slot the cycle patterns reserve for the layer; the last one read is
// the value used. (With a single slot this is the usual consecutive table;
// Mega Man 8 reserves two and puts its ramp in the second long.) With both
// NBG0 and NBG1 enabled their entries are interleaved, NBG0 first.
@(private = "file")
load_vcs :: proc "contextless" (v: ^VDP2, n: u32, out: ^[96]u32) -> bool {
	scrctl := u32(v.regs[0x4D])
	on0, on1 := scrctl & 1 != 0, scrctl & 0x100 != 0
	if (n == 0 && !on0) || (n == 1 && !on1) || n > 1 { return false }
	base := ((u32(v.regs[0x4E]) & 7) << 16 | u32(v.regs[0x4F])) * 2
	c0, c1 := max(cyc_slots(v, 0xC), 1), max(cyc_slots(v, 0xD), 1)
	stride, off: u32
	switch {
	case on0 && on1:
		stride = (c0 + c1) * 4
		off = (c0 - 1) * 4 if n == 0 else (c0 + c1 - 1) * 4
	case n == 0:
		stride, off = c0 * 4, (c0 - 1) * 4
	case:
		stride, off = c1 * 4, (c1 - 1) * 4
	}
	for i in u32(0) ..< 96 {
		a := base + i * stride + off
		out[i] = ((vr16(v, a) << 16 | vr16(v, a + 2)) >> 8) & 0x7FFFF
	}
	return true
}

// ------------------------------------------------------------- windows ----

// One window's extent on the current line. Horizontal coordinates are in
// 640-wide dot units (a 320-wide screen uses every other value).
@(private = "file")
Win_Rng :: struct {
	x0, x1: u32,
	y_ok:   bool,
}

@(private = "file")
win_range :: proc "contextless" (v: ^VDP2, w: u32, y: u32) -> (o: Win_Rng) {
	r := &v.regs
	b := 0x60 + w * 4 // WPSX, WPSY, WPEX, WPEY
	lw := 0x6C + w * 2 // LWTA: line window table, bit 31 = enabled
	if r[lw] & 0x8000 != 0 {
		a := ((u32(r[lw]) & 7) << 16 | u32(r[lw + 1])) * 2 + y * 4
		o.x0, o.x1, o.y_ok = vr16(v, a) & 0x3FF, vr16(v, a + 2) & 0x3FF, true
	} else {
		o.x0, o.x1 = u32(r[b]) & 0x3FF, u32(r[b + 2]) & 0x3FF
		o.y_ok = y >= u32(r[b + 1]) & 0x1FF && y <= u32(r[b + 3]) & 0x1FF
	}
	return
}

// Whether a layer shows at horizontal position xx. `ctl` is the layer's window
// control byte (WCTLA-WCTLD): bit 0/2 = window 0/1 area (1 = show inside, 0 =
// show outside), bit 1/3 = window 0/1 enabled, bit 7 = combine two windows with
// AND (1) or OR (0). Bits 4/5 (the sprite window) are not implemented.
@(private = "file")
WIN_ENABLE :: 0x0A // either window enabled

@(private = "file")
win_visible :: proc "contextless" (ctl: u32, xx: u32, a, b: Win_Rng) -> bool {
	in_a := a.y_ok && xx >= a.x0 && xx <= a.x1
	in_b := b.y_ok && xx >= b.x0 && xx <= b.x1
	va := in_a if ctl & 1 != 0 else !in_a
	vb := in_b if ctl & 4 != 0 else !in_b
	switch {
	case ctl & 2 != 0 && ctl & 8 != 0:
		return (va && vb) if ctl & 0x80 != 0 else (va || vb)
	case ctl & 2 != 0: return va
	case ctl & 8 != 0: return vb
	}
	return true
}

// --------------------------------------------------------- line compose ----

// One layer's contribution to a pixel, before colour calculation.
@(private = "file")
Cand :: struct {
	color: u32,  // 0x00RRGGBB, before colour offset
	pri:   i32,
	id:    u32,  // tie-break and layer identity: 0 sprite, 1-4 NBG0-3, 5 back
	ratio: u32,  // colour-calculation ratio (0-31) this layer would blend with
	cc:    bool, // colour calculation enabled for this dot
	v:     bool,
}

// Whether a dot with colour calculation enabled that has no other layer under
// it is blended with the back screen. Unconfirmed on hardware: the Mega Man 8
// movie programs colour calculation on with ratio 15 over nothing but the back
// screen, and blending there would dim the whole movie to about half. Layers
// blended with a real layer below are unaffected.
@(private = "file")
CC_WITH_BACK_SCREEN :: false

// Layer number in CLOFEN/CLOFSL for each Cand.id.
@(private = "file")
OFFSET_BIT := [6]u32{6, 0, 1, 2, 3, 5}

@(private = "file")
better :: #force_inline proc "contextless" (a, b: Cand) -> bool {
	return a.pri > b.pri || (a.pri == b.pri && a.id < b.id)
}

@(private = "file")
blend :: proc "contextless" (top, sec: u32, add: bool, ratio: u32) -> u32 {
	out: u32
	for sh in ([3]u32{16, 8, 0}) {
		t, b := (top >> sh) & 0xFF, (sec >> sh) & 0xFF
		c: u32
		if add { c = min(t + b, 255) } else { c = (t * (32 - ratio) + b * ratio) >> 5 }
		out |= c << sh
	}
	return out
}

// Renders one visible scanline into `v.pix` at the output size set by
// vdp2_begin_frame. `fb` is the VDP1 framebuffer currently on display.
vdp2_draw_line :: proc "contextless" (v: ^VDP2, y: u32, fb: ^[0x20000]u16) {
	w, _, hires, dbl := vdp2_mode(v)
	out_w := w * 2 if hires else w
	row := y * (2 if dbl else 1)
	if row >= SCREEN_MAX_H { return }

	line := v.pix[row * SCREEN_MAX_W:][:out_w]
	if v.regs[0] & 0x8000 == 0 { // display off
		for i in 0 ..< len(line) { line[i] = 0 }
		return
	}

	// Back screen.
	bkta := (u32(v.regs[0x56] & 0x7) << 16) | u32(v.regs[0x57])
	bk_per_line := v.regs[0x56] & 0x8000 != 0
	bk_addr := bkta * 2 + (y * 2 if bk_per_line else 0)
	back_raw := rgb555(vr16(v, bk_addr))
	back := Cand{color = back_raw, id = 5, ratio = u32(v.regs[0x87] >> 8) & 0x1F, v = true}

	r := &v.regs
	ccctl := u32(r[0x76])
	cc_add := ccctl & 0x100 != 0     // CCMD: add instead of ratio blend
	cc_second := ccctl & 0x200 != 0  // CCRTMD: use the second screen's ratio
	sp_cc_on := ccctl & 0x40 != 0    // SPCCEN
	spctl := u32(r[0x70])
	sp_cond, sp_ccn := (spctl >> 12) & 3, (spctl >> 8) & 7

	nbgs: [4]NBG
	order: [4]u32 // NBG numbers, best priority first
	norder := 0
	ybase: [4]u32     // Y coordinate (8.8) of this line, before vertical cell scroll
	vcs: [2][96]u32   // vertical cell scroll value per 8-dot column
	has_vcs: [2]bool
	for n in u32(0) ..< 4 {
		nbgs[n] = nbg_config(v, n)
		ybase[n] = nbgs[n].scy + y * nbgs[n].yinc
		apply_line_scroll(v, &nbgs[n], n, y, &ybase[n])
		if n < 2 { has_vcs[n] = load_vcs(v, n, &vcs[n]) }
		if nbgs[n].on && nbgs[n].prio > 0 {
			// Insertion sort by (priority desc, number asc).
			k := norder
			for k > 0 && nbgs[order[k - 1]].prio < nbgs[n].prio { order[k] = order[k - 1]; k -= 1 }
			order[k] = n
			norder += 1
		}
	}
	// Windows: NBG0-3 and sprite control bytes in WCTLA-WCTLC.
	win_ctl := [5]u32{u32(r[0x68]) & 0xFF, u32(r[0x68]) >> 8, u32(r[0x69]) & 0xFF, u32(r[0x69]) >> 8, u32(r[0x6A]) >> 8}
	win0, win1 := win_range(v, 0, y), win_range(v, 1, y)
	ccwin_ctl := u32(r[0x6B]) & 0xFF
	nbg_ratio: [4]u32
	nbg_ratio[0], nbg_ratio[1] = u32(r[0x84]) & 0x1F, (u32(r[0x84]) >> 8) & 0x1F
	nbg_ratio[2], nbg_ratio[3] = u32(r[0x85]) & 0x1F, (u32(r[0x85]) >> 8) & 0x1F

	// Hi-res (640/704) shows every dot of the scroll layers: a layer is sampled
	// once per output dot, not once per low-res dot and doubled. Only the VDP1
	// sprite framebuffer stays 320/352 wide, so sprites are read at half rate.
	for x in u32(0) ..< out_w {
		wx := x if hires else x * 2 // window coordinate, in 640-wide dot units
		sx := x >> 1 if hires else x // sprite framebuffer column
		top, second: Cand
		insert :: proc "contextless" (top, second: ^Cand, c: Cand) {
			if !top.v || better(c, top^) {
				second^ = top^
				top^ = c
			} else if !second.v || better(c, second^) {
				second^ = c
			}
		}

		// Sprite layer.
		if sx < 512 && y < 256 {
			d, op := sprite_pixel(v, u32(fb[(y & 0xFF) * 512 + sx]))
			if op && win_visible(win_ctl[4], wx, win0, win1) {
				p := i32(r[0x78 + d.pr / 2] >> (8 * (d.pr & 1)) & 7) // PRISA-PRISD
				if p > 0 {
					cc := false
					if sp_cc_on {
						switch sp_cond {
						case 0: cc = d.pr <= sp_ccn
						case 1: cc = d.pr == sp_ccn
						case 2: cc = d.pr >= sp_ccn
						case 3: cc = d.msb
						}
					}
					rv := u32(r[0x80 + d.cc_idx / 2] >> (8 * (d.cc_idx & 1))) & 0x1F // CCRSA-CCRSD
					insert(&top, &second, Cand{color = d.color, pri = p, id = 0, ratio = rv, cc = cc, v = true})
				}
			}
		}

		// Scroll layers, best priority first; stop as soon as nothing further
		// down could change the result.
		for k in 0 ..< norder {
			n := order[k]
			c := &nbgs[n]
			cand := Cand{pri = i32(c.prio), id = n + 1}
			if top.v {
				if !better(cand, top) && (!top.cc || (second.v && !better(cand, second))) { break }
			}
			if win_ctl[n] & WIN_ENABLE != 0 && !win_visible(win_ctl[n], wx, win0, win1) { continue }
			ix := (c.scx + x * c.xinc) >> 8
			vy := ybase[n]
			if n < 2 && has_vcs[n] { vy += vcs[n][x >> 3] }
			iy := vy >> 8
			col, op, cc_ok := nbg_pixel(v, c, ix, iy)
			if !op { continue }
			cand.color, cand.v = col, true
			cand.cc = ccctl & (1 << n) != 0 && cc_ok
			cand.ratio = nbg_ratio[n]
			insert(&top, &second, cand)
		}

		if !top.v { top = back }
		out := top.color
		// The colour calculation window (WCTLD, low byte) restricts blending to
		// the inside (or outside) of window 0/1.
		cc_here := top.cc && (ccwin_ctl & WIN_ENABLE == 0 || win_visible(ccwin_ctl, wx, win0, win1))
		if cc_here && (second.v || CC_WITH_BACK_SCREEN) {
			sec := second if second.v else back
			out = blend(top.color, sec.color, cc_add, sec.ratio if cc_second else top.ratio)
		}
		out = color_offset(v, out, OFFSET_BIT[top.id])
		line[x] = out
	}
	if dbl { // interlace double density: duplicate into the odd row
		copy(v.pix[(row + 1) * SCREEN_MAX_W:][:out_w], line)
	}
}

// ------------------------------------------------------------ diagnostics ---

// What an NBG layer is set up to show, for logging.
Nbg_Info :: struct {
	on, bitmap:   bool,
	bpp:          u32,
	width:        u32, // bitmap width in dots (the row pitch), 0 for cell layers
	height:       u32,
	base:         u32, // bitmap byte address in VRAM
	prio:         u32,
	cell16:       bool,
	pn_one_word:  bool,
	cc, ls:       bool, // colour calculation enabled / line scroll enabled
}

vdp2_nbg_info :: proc "contextless" (v: ^VDP2, n: u32) -> (i: Nbg_Info) {
	c := nbg_config(v, n)
	i.on, i.bitmap, i.bpp, i.prio = c.on, c.bitmap, c.bpp, c.prio
	i.cell16, i.pn_one_word = c.char_size != 0, c.pn_one_word
	if c.bitmap {
		i.width = u32(1) << c.bm_w_shift
		i.height = c.bm_h_mask + 1
		i.base = c.bm_base
	}
	i.cc = v.regs[0x76] & (1 << n) != 0
	i.ls = n < 2 && (v.regs[0x4D] >> (8 * n)) & 0xE != 0
	return
}

// Row pitches (in dots) a full-colour image might really be stored with.
PITCH_CANDIDATES :: [?]u32{160, 256, 320, 352, 384, 448, 512, 640, 704, 1024}

// Looks at the pixel data a bitmap layer would read and measures, for each
// candidate row pitch, how well each dot matches the dot one row below it.
// A natural image matches itself best at the pitch it was written with. If
// that is not the pitch the layer is configured to read, the picture comes
// out sheared into stripes: the symptom of data written with one row stride
// and displayed with another. Returns the best pitch and the mean error (0-31
// scale) at the best and at the configured pitch; ok is false when the area
// is empty or too small to judge.
vdp2_pitch_probe :: proc "contextless" (v: ^VDP2, n: u32) -> (best, best_err, cfg_err: u32, ok: bool) {
	info := vdp2_nbg_info(v, n)
	if !info.bitmap || info.bpp < 16 { return }
	bytes_per := info.bpp / 8
	dot :: proc "contextless" (v: ^VDP2, base, bytes_per, i: u32) -> i32 {
		a := (base + i * bytes_per) & 0x7FFFF
		if bytes_per == 2 { return i32((vr16(v, a) >> 5) & 0x1F) }
		return i32(vr16(v, a + 2) >> 8) >> 3 // 32 bpp: green byte, scaled to 5 bits
	}
	N :: 30000
	nonzero := 0
	for i in u32(0) ..< 4096 { if dot(v, info.base, bytes_per, i) != 0 { nonzero += 1 } }
	if nonzero < 64 { return }
	best_err = 0xFFFF_FFFF
	for p in PITCH_CANDIDATES {
		if info.base + (N + p) * bytes_per > 0x80000 { continue }
		sum: u64
		for i in u32(0) ..< N {
			d := dot(v, info.base, bytes_per, i) - dot(v, info.base, bytes_per, i + p)
			sum += u64(abs(d))
		}
		e := u32(sum * 100 / N) // hundredths
		if p == info.width { cfg_err = e }
		if e < best_err { best, best_err = p, e }
	}
	ok = best != 0
	return
}

// Raw VRAM word, for logging.
vdp2_peek16 :: proc "contextless" (v: ^VDP2, a: u32) -> u32 {return vr16(v, a)}

// True when NBG0 or NBG1 uses line scroll or vertical cell scroll.
vdp2_uses_scroll_tables :: proc "contextless" (v: ^VDP2) -> bool {
	return v.regs[0x4D] & 0x0F0F != 0 && v.regs[0x10] & 3 != 0
}
