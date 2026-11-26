// SCSP (sound chip), its 512 KiB of sound RAM and the 68000 that runs from it.
//
// What exists: the sound RAM, the register file, the sound CPU, and everything
// the CPUs use to talk to each other: the three timers, the interrupt enable /
// pending / level registers for the 68000 (SCIEB/SCIPD/SCIRE/SCILV0-2), the
// matching set that interrupts the SH-2 through the SCU (MCIEB/MCIPD/MCIRE), and
// the 44.1 kHz sample tick. The BIOS and every game upload a 68000 driver and
// then handshake with it through sound RAM, so a boot cannot get past the logo
// without a working sound CPU.
//
// Slots play: sample fetch from sound RAM (PCM16 / PCM8, linear interpolation),
// the pitch / loop / key-on machinery, the envelope generator, total level, direct
// pan and level, and the master volume, modelled on Mednafen's SCSP. The monitor
// register (0x408: current address / envelope phase / level of one chosen slot)
// reads back what real hardware would; sound drivers that stream audio watch that
// position to know when to refill their ring buffer.
//
// What does not exist: the DSP (so no reverb or effects), FM modulation, the LFOs,
// and DMA. CD audio enters through the two external-input slots (16 and 17) as it
// does on the real console.
package saturn_core

SCSP_MASTER_HZ :: u64(28_636_363) // the line scheduler counts in these clocks
SCSP_SAMPLE_HZ :: u64(44_100)
M68K_HZ        :: u64(11_289_600)

// SCIPD / MCIPD bits.
SCSP_INT_MIDI_IN   :: 0x008
SCSP_INT_DMA_END   :: 0x010
SCSP_INT_CPU       :: 0x020 // software interrupt, written by the other CPU
SCSP_INT_TIMER_A   :: 0x040 // B and C follow at 0x080 and 0x100
SCSP_INT_MIDI_OUT  :: 0x200
SCSP_INT_SAMPLE    :: 0x400

// One of the 32 slots. The register file holds the programmed values; this is the
// running state (Mednafen's CurrentAddr / PhaseWhacker / LoopSub model).
SCSP_Slot :: struct {
	cur:       u16, // current sample address, counted from the start address
	phase:     u32, // fractional part, 1/16384 of a sample
	on:        bool, // keyed on
	run:       bool, // position advancing (a non-looping slot stops at its end)
	in_loop:   bool,
	loop_sub:  bool, // playing a reverse leg
	env_phase: u8, // 0 attack, 1 decay 1, 2 decay 2, 3 release
	env_level: u16, // 10 bit attenuation, 0 loudest; approximated, see scsp_key_execute
}

SCSP_Timer :: struct {
	ctl:     u8, // counts every 2^ctl samples
	reload:  i16, // value loaded at the next count, or -1
	counter: u8,
}

SCSP :: struct {
	ram:  [0x80000]u8,
	regs: [0x1000]u8,

	cpu: M68K,

	scieb, scipd: u16, // interrupts to the 68000: enable, pending
	mcieb, mcipd: u16, // interrupts to the SH-2
	scilv:        [3]u8,
	main_int:     bool, // last state of (mcipd & mcieb) != 0

	slots:    [32]SCSP_Slot,
	key_exec: bool, // KYONEX was written: take the key on/off bits at the next sample
	lfsr:     u32,
	mslc:     u8, // slot whose position 0x408 reports
	ca_reads: u32, // reads of 0x408, for the diagnostics

	timers:         [3]SCSP_Timer,
	sample_counter: u32,
	sample_acc:     u64,
	cpu_acc:        u64,
	cpu_target:     i64,
}

scsp_reset :: proc "contextless" (s: ^Saturn) {
	c := &s.scsp
	c.regs = {}
	c.scieb, c.scipd, c.mcieb, c.mcipd = 0, 0, 0, 0
	c.scilv = {}
	c.main_int = false
	for i in 0 ..< 3 { c.timers[i] = {reload = -1} }
	for i in 0 ..< 32 { c.slots[i] = {env_phase = 3, env_level = 0x3FF} } // idle slots sit in release
	c.mslc, c.ca_reads = 0, 0
	c.key_exec, c.lfsr = false, 1
	c.sample_counter, c.sample_acc, c.cpu_acc, c.cpu_target = 0, 0, 0, 0
	scsp_sound_cpu(s, false)
}

// SMPC SNDON / SNDOFF: both reset the 68000, then run or hold it.
scsp_sound_cpu :: proc "contextless" (s: ^Saturn, on: bool) {
	c := &s.scsp
	c.cpu.bus = {ctx = s, read = scsp_bus_read, write = scsp_bus_write}
	m68k_reset(&c.cpu)
	c.cpu.halted = !on
	c.cpu_target, c.cpu_acc = 0, 0
	scsp_update_ints(s)
}

// ----------------------------------------------------------- 68000 bus -----

scsp_bus_read :: proc "contextless" (ctx: rawptr, addr: u32, size: u32) -> u32 {
	s := (^Saturn)(ctx)
	v: u32
	if addr < 0x100000 {
		for i in u32(0) ..< size { v = v << 8 | u32(s.scsp.ram[(addr + i) & 0x7FFFF]) }
	} else if addr < 0x200000 {
		for i in u32(0) ..< size { v = v << 8 | u32(scsp_reg_read8(s, (addr + i) & 0xFFF)) }
	}
	return v
}

scsp_bus_write :: proc "contextless" (ctx: rawptr, addr: u32, size: u32, v: u32) {
	s := (^Saturn)(ctx)
	if addr < 0x100000 {
		for i in u32(0) ..< size { s.scsp.ram[(addr + i) & 0x7FFFF] = u8(v >> (8 * (size - 1 - i))) }
	} else if addr < 0x200000 {
		for i in u32(0) ..< size { scsp_reg_write8(s, (addr + i) & 0xFFF, u8(v >> (8 * (size - 1 - i)))) }
	}
}

// ------------------------------------------------------------ registers ----
//
// Both CPUs see the same registers (SH-2 at 0x25B00000, 68000 at 0x100000), as
// big-endian 16-bit words; everything is handled per byte so any access width
// works. Offsets 0x418-0x42F are the timers and interrupt controller.

scsp_reg_read8 :: proc "contextless" (s: ^Saturn, off: u32) -> u8 {
	c := &s.scsp
	switch off {
	case 0x418 ..= 0x41D, 0x422, 0x423, 0x42E, 0x42F: return 0 // write-only
	case 0x408: c.ca_reads += 1; return u8(scsp_monitor(c) >> 8)
	case 0x409: return u8(scsp_monitor(c))
	case 0x41E: return u8(c.scieb >> 8)
	case 0x41F: return u8(c.scieb)
	case 0x420: return u8(c.scipd >> 8)
	case 0x421: return u8(c.scipd)
	case 0x42A: return u8(c.mcieb >> 8)
	case 0x42B: return u8(c.mcieb)
	case 0x42C: return u8(c.mcipd >> 8)
	case 0x42D: return u8(c.mcipd)
	}
	return c.regs[off & 0xFFF]
}

scsp_reg_write8 :: proc "contextless" (s: ^Saturn, off: u32, v: u8) {
	c := &s.scsp
	switch off {
	case 0x000 ..< 0x400: // slot registers
		c.regs[off] = v
		if off & 0x1F == 0 && v & 0x10 != 0 { scsp_key_execute(c) } // KYONEX
	case 0x408: c.mslc = (v >> 3) & 0x1F // MSLC (the data bits are read-only)
	case 0x409:
	case 0x418, 0x41A, 0x41C: c.timers[(off - 0x418) >> 1].ctl = v & 7
	case 0x419, 0x41B, 0x41D: c.timers[(off - 0x418) >> 1].reload = i16(v)
	case 0x41E: c.scieb = (c.scieb & 0x00FF) | u16(v & 7) << 8; scsp_update_ints(s)
	case 0x41F: c.scieb = (c.scieb & 0x0700) | u16(v); scsp_update_ints(s)
	case 0x420, 0x42C: // pending bits 8-10 are not writable
	case 0x421: if v & SCSP_INT_CPU != 0 { c.scipd |= SCSP_INT_CPU; scsp_update_ints(s) }
	case 0x422: c.scipd &= ~(u16(v & 7) << 8); scsp_update_ints(s)
	case 0x423: c.scipd &= ~u16(v); scsp_update_ints(s)
	case 0x424, 0x426, 0x428: // level registers use only their low byte
	case 0x425, 0x427, 0x429: c.scilv[(off - 0x425) >> 1] = v; scsp_update_ints(s)
	case 0x42A: c.mcieb = (c.mcieb & 0x00FF) | u16(v & 7) << 8; scsp_update_ints(s)
	case 0x42B: c.mcieb = (c.mcieb & 0x0700) | u16(v); scsp_update_ints(s)
	case 0x42D: if v & SCSP_INT_CPU != 0 { c.mcipd |= SCSP_INT_CPU; scsp_update_ints(s) }
	case 0x42E: c.mcipd &= ~(u16(v & 7) << 8); scsp_update_ints(s)
	case 0x42F: c.mcipd &= ~u16(v); scsp_update_ints(s)
	case: c.regs[off & 0xFFF] = v
	}
}

scsp_reg_read16 :: proc "contextless" (s: ^Saturn, off: u32) -> u16 {
	return u16(scsp_reg_read8(s, off)) << 8 | u16(scsp_reg_read8(s, off + 1))
}

scsp_reg_write16 :: proc "contextless" (s: ^Saturn, off: u32, v: u16) {
	scsp_reg_write8(s, off, u8(v >> 8))
	scsp_reg_write8(s, off + 1, u8(v))
}

// ------------------------------------------------------------- slots -------

@(private = "file")
slot_word :: proc "contextless" (c: ^SCSP, n, w: int) -> u16 {
	return u16(c.regs[n * 0x20 + w * 2]) << 8 | u16(c.regs[n * 0x20 + w * 2 + 1])
}

// KYONEX: the key on/off bits of all slots are taken at the next sample.
@(private = "file")
scsp_key_execute :: proc "contextless" (c: ^SCSP) {
	c.key_exec = true
}

// The envelope level the monitor register and the mixer see.
@(private = "file")
slot_vlevel :: proc "contextless" (c: ^SCSP, n: int) -> u16 {
	s := &c.slots[n]
	if (s.env_phase == 0 && slot_word(c, n, 4) & 0x20 != 0) || slot_word(c, n, 5) & 0x8000 != 0 { return 0 }
	return s.env_level
}

// What 0x408 reads for the selected slot: bits 10-7 current address (bits 15-12
// of the sample position), bits 6-5 envelope phase, bits 4-0 envelope level.
@(private = "file")
scsp_monitor :: proc "contextless" (c: ^SCSP) -> u16 {
	n := int(c.mslc & 0x1F)
	s := &c.slots[n]
	v: u16
	if s.run {
		a := ~s.cur if s.loop_sub else s.cur
		v = (a >> 12) << 7
	}
	return v | u16(s.env_phase) << 5 | (slot_vlevel(c, n) >> 5) & 0x1F
}

// One clock of a slot's envelope generator. The sample counter decides when a
// given rate steps, so a rate of 0x10 steps twice as often as 0x0E.
@(private = "file")
run_eg :: proc "contextless" (s: ^SCSP_Slot, rates: [4]u32, kes: u32, dl: u16, lpslnk: bool, sc, scxc: u32) {
	level := s.env_level
	nos := rates[s.env_phase & 3]
	erate := min(u32(0x1F), kes + nos)
	wbt := (u32(0x18) - min(u32(0x18), erate)) >> 1
	sadj: u32 = 1 if (erate < 0x18 && erate != 0) else 0
	clk := (((scxc | (scxc >> sadj)) >> (wbt + sadj)) & 1) != 0 && nos != 0
	if s.env_phase == 0 && nos + kes >= 0x20 { clk = false } // stuck in attack
	if clk {
		inc: i32 = ~i32(level) if s.env_phase == 0 else 16
		ermaxo := max(u32(0x18), min(u32(0x1E), erate))
		srac := ((u32(0x20) - ermaxo) >> 1) + (ermaxo & 1 & (sc >> (wbt + 1)))
		s.env_level = u16(clamp(i32(level) + (inc >> srac), 0, 0x3FF))
	}
	// The level from before this step decides the phase change, as on hardware.
	if s.env_phase == 1 {
		if (level >> 5) == dl { s.env_phase = 2 }
	} else if s.env_phase == 0 {
		if (lpslnk && s.in_loop) || (!lpslnk && level == 0) { s.env_phase = 1 }
	}
}

// Volume of a channel for a send level (3 bits) and pan (5 bits): bit 4 of the
// pan picks the side that is attenuated, bits 3-0 the amount.
@(private = "file")
pan_vol :: proc "contextless" (level, pan: u32) -> [2]i32 {
	basev := u32(0x80) << level
	if level == 0 { basev = 0 }
	panv := basev >> ((pan & 0xF) >> 1)
	if pan & 1 != 0 { panv -= panv >> 2 }
	if pan & 0xF == 0xF { panv = 0 }
	out: [2]i32
	if pan & 0x10 != 0 {
		out = {i32(basev), i32(panv)}
	} else {
		out = {i32(panv), i32(basev)}
	}
	return out
}

// One 44.1 kHz step of every slot: envelope, key on/off, loop handling, sample
// fetch, level, and mixing into a stereo output sample. `ext` is the CD audio.
@(private = "file")
scsp_slots_step :: proc "contextless" (c: ^SCSP, ext: [2]i16) -> (out_l, out_r: i16) {
	sc := c.sample_counter
	scxc := (sc ~ (sc - 1)) & (sc ~ 1)
	acc: [2]i32

	for n in 0 ..< 32 {
		s := &c.slots[n]
		w5 := slot_word(c, n, 5)
		bypass := w5 & 0x8000 != 0
		// Fast path: a slot that is released, silent and not about to be keyed makes
		// no sound (slots 16 and 17 still carry the CD audio).
		if s.env_phase == 3 && s.env_level >= 0x3C0 && !bypass && !c.key_exec && n != 16 && n != 17 {
			s.run = false
			c.lfsr = (c.lfsr >> 1) | (((c.lfsr >> 5) ~ c.lfsr) & 1) << 16
			continue
		}
		w0 := slot_word(c, n, 0)
		w4 := slot_word(c, n, 4)
		w6 := slot_word(c, n, 6)
		w8 := slot_word(c, n, 8)

		if s.env_level >= 0x3C0 && !bypass { s.run = false } // silenced by its envelope

		oct := u32(w8 >> 11) & 0xF
		krs := u32(w5 >> 10) & 0xF
		kes: u32 = 0
		if krs != 0xF { kes = u32(clamp(i32(krs) + i32(oct ~ 8) - 8, 0, 0xF)) }
		rates := [4]u32{u32(w4 & 0x1F), u32(w4 >> 6) & 0x1F, u32(w4 >> 11) & 0x1F, u32(w5 & 0x1F)}
		run_eg(s, rates, kes, (w5 >> 5) & 0x1F, w5 & 0x4000 != 0, sc, scxc)

		kyonb := w0 & 0x800 != 0
		if c.key_exec && (s.env_phase == 3) == kyonb {
			if kyonb {
				s.phase, s.cur = 0, 0
				s.in_loop, s.loop_sub, s.run, s.on = false, false, true, true
				s.env_phase = 0
				s.env_level = 0 if rates[0] + kes >= 0x20 else 0x280
			} else {
				s.env_phase, s.on = 3, false
			}
		}

		// Loop handling.
		mode := u8(w0 >> 5) & 3
		lsa := slot_word(c, n, 2)
		lea := slot_word(c, n, 3)
		if !s.in_loop {
			if s.cur + 1 > lsa {
				if mode == 2 {
					s.cur += u16(0) - (lsa + lea)
					s.loop_sub = true
				}
				s.in_loop = true
			}
		} else {
			ca := 1 + (~s.cur if s.loop_sub else s.cur)
			comp := lsa if (s.loop_sub && mode & 2 != 0) else lea
			if s.loop_sub != (ca > comp) {
				if mode == 0 { s.run = false }
				if mode == 3 {
					s.loop_sub = !s.loop_sub
					if s.loop_sub { s.cur -= lea << 1 } else { s.cur += lsa << 1 }
				} else if s.loop_sub && mode & 2 == 0 {
					s.cur += lea - lsa
				} else {
					s.cur += lsa - lea
				}
			}
		}

		// Sample fetch.
		src := (w0 >> 7) & 3
		sbtab := [4]u16{0, 0x7FFF, 0x8000, 0xFFFF} // sample bit inversion control
		sbxor := sbtab[(w0 >> 9) & 3]
		smp: i16
		if src == 1 { smp = i16(u16(c.lfsr << 8)) } // noise
		smp = i16(u16(smp) ~ sbxor)

		if s.run {
			pw, a := s.phase, s.cur
			if s.loop_sub { pw, a = ~pw, ~a }
			sia := i32((pw >> 8) & 0x3F)
			sa := u32(w0 & 0xF) << 16 | u32(slot_word(c, n, 1))
			s0, s1: i16
			if w0 & 0x10 != 0 { // 8 bit
				s0 = i16(u16(c.ram[(sa + u32(a)) & 0x7FFFF]) << 8)
				s1 = i16(u16(c.ram[(sa + u32(a + 1)) & 0x7FFFF]) << 8)
			} else {
				i0 := (((sa >> 1) + u32(a)) & 0x3FFFF) * 2
				i1 := (((sa >> 1) + u32(a + 1)) & 0x3FFFF) * 2
				s0 = i16(u16(c.ram[i0]) << 8 | u16(c.ram[i0 + 1]))
				s1 = i16(u16(c.ram[i1]) << 8 | u16(c.ram[i1 + 1]))
			}
			s0 = i16(u16(s0) ~ sbxor)
			s1 = i16(u16(s1) ~ sbxor)
			if src == 0 { smp = i16((i32(s0) * (0x40 - sia) + i32(s1) * sia) >> 6) }

			fns := u32(w8 & 0x7FF)
			s.phase += ((0x400 ~ fns) << (oct ~ 8)) >> 4
			s.cur += u16(s.phase >> 14)
			s.phase &= 0x3FFF
		}

		c.lfsr = (c.lfsr >> 1) | (((c.lfsr >> 5) ~ c.lfsr) & 1) << 16

		// Level: envelope plus total level (unless sound-direct).
		if w6 & 0x100 == 0 {
			vlevel := i32(slot_vlevel(c, n)) + i32(w6 & 0xFF) << 2
			if vlevel > 0x3FF { vlevel = 0x3FF }
			smp = i16((i32(smp) * i32((vlevel & 0x3F) ~ 0x7F)) >> u32((vlevel >> 6) + 7))
		}

		// Mix: direct output, plus the CD audio through slots 16 and 17's effect send.
		w11 := slot_word(c, n, 11)
		dv := pan_vol(u32(w11 >> 13) & 7, u32(w11 >> 8) & 0x1F)
		acc[0] += (i32(smp) * dv[0]) >> 14
		acc[1] += (i32(smp) * dv[1]) >> 14
		if n == 16 || n == 17 {
			ev := pan_vol(u32(w11 >> 5) & 7, u32(w11) & 0x1F)
			e := i32(ext[n & 1])
			acc[0] += (e * ev[0]) >> 14
			acc[1] += (e * ev[1]) >> 14
		}
	}
	c.key_exec = false

	// Master volume.
	mvol := u32(c.regs[0x401]) & 0xF
	mv := u32(0x2) << (mvol >> 1)
	if mvol & 1 == 0 { mv -= mv >> 2 }
	if mvol == 0 { mv = 0 }
	acc[0] = clamp((acc[0] * i32(mv)) >> 8, -32768, 32767)
	acc[1] = clamp((acc[1] * i32(mv)) >> 8, -32768, 32767)
	return i16(acc[0]), i16(acc[1])
}

// ----------------------------------------------------------- interrupts ----

// Recomputes both interrupt outputs: the level on the 68000's IPL pins, and the
// sound-request line into the SCU (raised on the rising edge).
scsp_update_ints :: proc "contextless" (s: ^Saturn) {
	c := &s.scsp

	// Sources 8-10 share the level bits of source 7.
	active := c.scipd & c.scieb
	level: u8
	for b in u32(0) ..< 11 {
		if active >> b & 1 == 0 { continue }
		lb := min(b, 7)
		lv := (c.scilv[0] >> lb & 1) | (c.scilv[1] >> lb & 1) << 1 | (c.scilv[2] >> lb & 1) << 2
		level = max(level, lv)
	}
	c.cpu.ipl = level

	main := c.mcipd & c.mcieb != 0
	if main && !c.main_int { scu_set_int(s, INT_SOUND_REQ) }
	c.main_int = main
}

// One 44.1 kHz sample period: advance the timers and raise the sample interrupt.
@(private = "file")
scsp_sample :: proc "contextless" (s: ^Saturn) {
	c := &s.scsp
	c.sample_counter += 1
	for i in 0 ..< 3 {
		t := &c.timers[i]
		if c.sample_counter & ((u32(1) << t.ctl) - 1) != 0 { continue }
		if t.reload >= 0 {
			t.counter = u8(t.reload)
			t.reload = -1
		} else {
			t.counter += 1
		}
		if t.counter == 0xFF {
			c.scipd |= u16(SCSP_INT_TIMER_A) << u32(i)
			c.mcipd |= u16(SCSP_INT_TIMER_A) << u32(i)
		}
	}
	l, r := scsp_slots_step(c, cdb_cdda_pop(&s.cdb))
	if s.audio_frames < 800 {
		s.audio[s.audio_frames * 2], s.audio[s.audio_frames * 2 + 1] = l, r
		s.audio_frames += 1
	}
	c.scipd |= SCSP_INT_SAMPLE
	c.mcipd |= SCSP_INT_SAMPLE
	scsp_update_ints(s)
}

// Called once per scanline with that line's length in master clocks.
scsp_line :: proc "contextless" (s: ^Saturn, line_cycles: u64) {
	c := &s.scsp
	c.cpu.bus = {ctx = s, read = scsp_bus_read, write = scsp_bus_write}

	c.sample_acc += line_cycles * SCSP_SAMPLE_HZ
	for c.sample_acc >= SCSP_MASTER_HZ {
		c.sample_acc -= SCSP_MASTER_HZ
		scsp_sample(s)
	}

	if c.cpu.halted {
		c.cpu.cycles, c.cpu_target = 0, 0
		return
	}
	c.cpu_acc += line_cycles * M68K_HZ
	c.cpu_target += i64(c.cpu_acc / SCSP_MASTER_HZ)
	c.cpu_acc %= SCSP_MASTER_HZ
	m68k_run(&c.cpu, c.cpu_target)
}
