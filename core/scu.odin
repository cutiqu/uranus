// The SCU: the Saturn's system controller. It owns interrupt routing between
// the peripherals and the CPUs, two timers, and three DMA channels.
//
// Not implemented yet: the DSP (its registers read as zero, programs never
// run) and cartridge-side A-bus behaviour. A game that waits on the DSP will
// hang; the BIOS does not use it.
package saturn_core

// Interrupt bit numbers in IST/IMS. External interrupts are 16 + n.
INT_VBLANK_IN  :: 0
INT_VBLANK_OUT :: 1
INT_HBLANK_IN  :: 2
INT_TIMER0     :: 3
INT_TIMER1     :: 4
INT_DSP_END    :: 5
INT_SOUND_REQ  :: 6
INT_SMPC       :: 7
INT_PAD        :: 8
INT_DMA2_END   :: 9
INT_DMA1_END   :: 10
INT_DMA0_END   :: 11
INT_DMA_ILLEGAL :: 12
INT_SPRITE_END :: 13
INT_EXT_CDBLOCK :: 16

// SH-2 IRL level for each internal source (indexed by bit), and for each group
// of external interrupts (indexed by n). Vector = 0x40 + bit, 0x50 + n.
@(private = "file")
INTERNAL_LEVEL := [16]u8{0xF, 0xE, 0xD, 0xC, 0xB, 0xA, 0x9, 0x8, 0x8, 0x6, 0x6, 0x5, 0x3, 0x2, 0, 0}
@(private = "file")
EXTERNAL_LEVEL := [16]u8{7, 7, 7, 7, 4, 4, 4, 4, 1, 1, 1, 1, 1, 1, 1, 1}

SCU_DMA :: struct {
	read, write, count: u32, // D0R/D0W/D0C
	add:                u32, // D0AD
	enable:             u32, // D0EN
	mode:               u32, // D0MD
}

SCU :: struct {
	ist:    u32, // pending interrupts
	ims:    u32, // mask
	ilevel: u8,  // level currently presented to the master CPU (0 = none)
	ivec:   u8,
	ext_asserted: u32, // level-sensitive A-bus lines, for edge detection

	t0c, t1s, t1md: u32,
	t0_counter:     u32,
	t0_met:         bool,

	dma: [3]SCU_DMA,

	asr0, asr1, aref, rsel: u32,
	vb, hb:                 bool, // what the slave CPU's interrupt pins follow
}

scu_reset :: proc "contextless" (s: ^Saturn) {
	s.scu = {}
	s.scu.ims = 0xBFFF
}

// ------------------------------------------------------------ interrupts ---

// Offers the highest-priority unmasked pending interrupt to the master CPU.
@(private = "file")
scu_check :: proc "contextless" (s: ^Saturn) {
	u := &s.scu
	if u.ilevel != 0 { return }
	ipmd := u.ist & ~u32(i32(i16(u.ims))) // IMS bit 15 masks every external line
	if ipmd == 0 { return }
	wi, we: u32 = 16, 16
	for i in u32(0) ..< 16 {
		if ipmd & (1 << i) != 0 { wi = i; break }
	}
	for i in u32(0) ..< 16 {
		if ipmd & (1 << (16 + i)) != 0 { we = i; break }
	}
	olev, ovec, bit: u32
	if wi < 16 { olev, ovec, bit = u32(INTERNAL_LEVEL[wi]), 0x40 + wi, wi }
	if we < 16 && u32(EXTERNAL_LEVEL[we]) > olev { olev, ovec, bit = u32(EXTERNAL_LEVEL[we]), 0x50 + we, 16 + we }
	if olev == 0 { return }
	u.ilevel, u.ivec = u8(olev), u8(ovec)
	u.ist &= ~(u32(1) << bit)
	sh2_set_irl(&s.cpu[0], u.ilevel)
}

scu_set_int :: proc "contextless" (s: ^Saturn, bit: u32) {
	s.scu.ist |= 1 << bit
	scu_dma_trigger_by_int(s, bit)
	scu_check(s)
}

// A-bus interrupt lines are level-sensitive; only a rising edge latches.
scu_set_ext_line :: proc "contextless" (s: ^Saturn, n: u32, active: bool) {
	bit := u32(1) << (16 + n)
	if active && s.scu.ext_asserted & bit == 0 {
		s.scu.ist |= bit
		scu_check(s)
	}
	s.scu.ext_asserted = (s.scu.ext_asserted & ~bit) | (bit if active else 0)
}

// Called by the master CPU when it accepts the interrupt.
scu_vector_fetch :: proc "contextless" (s: ^Saturn, slave: bool) -> u8 {
	u := &s.scu
	if slave { return 0x43 if u.vb else 0x41 }
	vec := u.ivec
	// IMS is software-owned: accepting an interrupt never changes it. (An earlier
	// version forced IMS to 0xBFFF here; a game that unmasks once at boot and whose
	// handlers never rewrite IMS then got exactly one interrupt and polled a flag
	// forever. Yabause/Yaba Sanshiro only write IMS on reset and on register writes.)
	u.ilevel = 0
	sh2_set_irl(&s.cpu[0], 0)
	return vec
}

// Presents the next pending, unmasked interrupt after the master has accepted one.
// scu_check only offers a new level while none is outstanding, so anything that
// became pending in the meantime must be re-offered once the CPU has taken the
// current one (sh2.odin calls this at the end of take_interrupt).
scu_reoffer :: proc "contextless" (s: ^Saturn) {
	scu_check(s)
}

// ---------------------------------------------------------- video events ---

scu_hblank :: proc "contextless" (s: ^Saturn, in_hblank: bool) {
	u := &s.scu
	if in_hblank {
		if u.t1md & 1 != 0 {
			u.t0_counter = (u.t0_counter + 1) & 0x1FF
			u.t0_met = u.t0_counter == u.t0c & 0x3FF
			if u.t0_met { scu_set_int(s, INT_TIMER0) }
			// Timer 1 really counts pixel clocks within the line; firing once
			// per line is the closest this model gets.
			if u.t1md & 0x100 == 0 || u.t0_met { scu_set_int(s, INT_TIMER1) }
		}
		scu_set_int(s, INT_HBLANK_IN)
	}
	u.hb = in_hblank
	scu_slave_irl(s)
}

scu_vblank :: proc "contextless" (s: ^Saturn, in_vblank: bool) {
	u := &s.scu
	if in_vblank {
		scu_set_int(s, INT_VBLANK_IN)
	} else {
		u.t0_counter = 0
		scu_set_int(s, INT_VBLANK_OUT)
	}
	u.vb = in_vblank
	scu_slave_irl(s)
}

@(private = "file")
scu_slave_irl :: proc "contextless" (s: ^Saturn) {
	level: u8
	if s.scu.vb { level = 6 } else if s.scu.hb { level = 2 }
	sh2_set_irl(&s.cpu[1], level)
}

// --------------------------------------------------------------- DMA -------

// Which bus an address is on: 0 = A-bus (cart, CD block), 1 = B-bus (VDPs,
// SCSP), 2 = CPU-side work RAM.
@(private = "file")
bus_of :: proc "contextless" (a: u32) -> int {
	switch (a >> 24) & 0x1F {
	case 0x02, 0x03, 0x04: return 0
	case 0x05:
		if a & 0x00F00000 == 0x00800000 { return 0 } // CD block is on the A-bus
		return 1
	case 0x06, 0x07: return 2
	}
	return -1
}

@(private = "file")
dma_unit_read :: proc "contextless" (s: ^Saturn, a: u32, bus: int) -> u32 {
	if bus == 1 { return u32(mem_read16(s, a)) << 16 | u32(mem_read16(s, a + 2)) }
	return mem_read32(s, a)
}

@(private = "file")
dma_run :: proc "contextless" (s: ^Saturn, level: int) {
	d := &s.scu.dma[level]
	max_count: u32 = 0x100000 if level == 0 else 0x1000
	indirect := d.mode & 0x01000000 != 0
	radd := u32(4) if d.add & 0x100 != 0 else 0
	adds := [8]u32{0, 2, 4, 8, 16, 32, 64, 128}
	wadd := adds[d.add & 7]
	ra, wa, count := d.read & 0x1FFFFFFF, d.write & 0x1FFFFFFF, d.count
	table := d.write & 0x1FFFFFFF
	last := false
	entry := 0

	for {
		if indirect {
			count = mem_read32(s, table)
			wa = mem_read32(s, table + 4) & 0x1FFFFFFF
			rv := mem_read32(s, table + 8)
			ra = rv & 0x1FFFFFFF
			last = rv & 0x80000000 != 0
			table += 12
		}
		if count == 0 { count = max_count }
		diag_dma_to_vram(s, level, d.mode, entry if indirect else -1, ra, wa, count, d.add)
		entry += 1
		rb, wb := bus_of(ra), bus_of(wa)
		if rb < 0 || wb < 0 || rb == wb {
			scu_set_int(s, INT_DMA_ILLEGAL)
			return
		}
		for count > 0 {
			v := dma_unit_read(s, ra, rb)
			if wb == 1 {
				mem_write16(s, wa, u16(v >> 16))
				wa += wadd
				mem_write16(s, wa, u16(v))
				wa += wadd
			} else {
				mem_write32(s, wa, v)
				wa += wadd
			}
			ra += radd
			count = count - 4 if count > 4 else 0
		}
		if !indirect || last { break }
	}
	// Optional address write-back (read/write update bits in the mode word).
	if !indirect {
		if d.mode & 0x00010000 != 0 { d.read = ra }
		if d.mode & 0x00000100 != 0 { d.write = wa }
	}
	ends := [3]u32{INT_DMA0_END, INT_DMA1_END, INT_DMA2_END}
	scu_set_int(s, ends[level])
}

// Starts any enabled channel whose start factor is the given interrupt.
@(private = "file")
scu_dma_trigger_by_int :: proc "contextless" (s: ^Saturn, bit: u32) {
	factor: u32
	switch bit {
	case INT_VBLANK_IN:  factor = 0
	case INT_VBLANK_OUT: factor = 1
	case INT_HBLANK_IN:  factor = 2
	case INT_TIMER0:     factor = 3
	case INT_TIMER1:     factor = 4
	case INT_SOUND_REQ:  factor = 5
	case INT_SPRITE_END: factor = 6
	case: return
	}
	for lvl in 0 ..< 3 {
		d := &s.scu.dma[lvl]
		if d.enable & 0x100 != 0 && d.mode & 7 == factor { dma_run(s, lvl) }
	}
}

// ------------------------------------------------------------- registers ---

scu_read32 :: proc "contextless" (s: ^Saturn, off: u32) -> u32 {
	u := &s.scu
	o := off & 0xFC
	if o < 0x60 {
		lvl := o >> 5
		if lvl < 3 {
			d := &u.dma[lvl]
			switch o & 0x1F {
			case 0x00: return d.read
			case 0x04: return d.write
			case 0x08: return d.count
			case 0x0C: return d.add
			case 0x10: return d.enable
			case 0x14: return d.mode
			}
		}
		return 0
	}
	switch o {
	case 0x7C: return 0 // DSTA: transfers finish instantly, so never busy
	case 0x90: return u.t0c
	case 0x94: return u.t1s
	case 0x98: return u.t1md
	case 0xA0: return u.ims
	case 0xA4: return u.ist
	case 0xB0: return u.asr0
	case 0xB4: return u.asr1
	case 0xB8: return u.aref
	case 0xC4: return u.rsel
	case 0xC8: return 4 // version
	}
	return 0
}

scu_write32 :: proc "contextless" (s: ^Saturn, off: u32, v: u32) {
	u := &s.scu
	o := off & 0xFC
	if o < 0x60 {
		lvl := o >> 5
		if lvl >= 3 { return }
		d := &u.dma[lvl]
		switch o & 0x1F {
		case 0x00: d.read = v & 0x7FFFFFF
		case 0x04: d.write = v & 0x7FFFFFF
		case 0x08: d.count = v & (0xFFFFF if lvl == 0 else 0xFFF)
		case 0x0C: d.add = v & 0x107
		case 0x10:
			d.enable = v & 0x101
			if v & 0x101 == 0x101 && d.mode & 7 == 7 { dma_run(s, int(lvl)) } // immediate start
		case 0x14: d.mode = v & 0x01010107
		}
		return
	}
	switch o {
	case 0x90: u.t0c = v & 0x3FF
	case 0x94: u.t1s = v & 0x1FF
	case 0x98: u.t1md = v & 0x101
	case 0xA0:
		u.ims = v & 0xBFFF
		scu_check(s)
	case 0xA4: u.ist &= v // write 0 to clear
	case 0xA8: // AIACK
	case 0xB0: u.asr0 = v
	case 0xB4: u.asr1 = v
	case 0xB8: u.aref = v
	case 0xC4: u.rsel = v & 1
	}
}
