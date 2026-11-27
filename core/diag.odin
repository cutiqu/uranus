// Stall diagnostics. When the master CPU sits in the same few dozen bytes for
// about three seconds, trace its data reads for one frame and log a report:
// registers, the code around the PC, and the addresses it keeps reading (with
// the values it gets). A polling loop gives itself away immediately: the
// address is the thing the BIOS is waiting on, the value is what it sees.
package saturn_core

Diag :: struct {
	last_pc:  u32,
	same:     u32, // consecutive samples (every 30 frames) at about the same PC
	tracing:  bool,
	stall:    bool, // the trace in progress was started by the stall detector
	cooldown: u32,

	// Log collapsing: a command identical to the previous one is counted instead of
	// printed, and the count is printed when something different arrives.
	last_cdb:    [9]u16,
	cdb_repeats: u32,
	cdb_first:   u64,
	last_smpc:   [4]u8,
	smpc_repeats: u32,

	// Polling commands (get status, sector counts, data transfer) are rate-limited:
	// a few per second are shown, the rest only counted in a once-a-second summary,
	// so the commands that start and stop things stay visible in the log.
	poll_shown:  u32,
	poll_hidden: u32,

	// Writes to MINIT / SINIT (a long write counts twice: it is two word writes).
	minit_n: u32,
	sinit_n: u32,

	// Display-set-up logging (see diag_vdp2) and the log budget for DMA into video RAM.
	vdp2_sig:      u64,
	vdp2_sig_age:  u32,
	vdp2_logged:   bool,
	vdp2_probed:   bool,
	vdp2_last_log: u64,
	dma_budget:    u32,
}

// Returns true if this CD command repeats the previous one (and so should not be
// printed). Flushes the repeat count of the previous run when a new one starts.
diag_cdb_repeat :: proc "contextless" (s: ^Saturn, key: [9]u16) -> bool {
	d := &s.diag
	if key == d.last_cdb && d.cdb_repeats < 100000 {
		d.cdb_repeats += 1
		return true
	}
	if d.cdb_repeats > 0 {
		l: Log_Buf
		lb_str(&l, "cdb cmd: the line above repeated ")
		lb_dec(&l, u64(d.cdb_repeats))
		lb_str(&l, " more times, frames ")
		lb_dec(&l, d.cdb_first)
		lb_str(&l, "-")
		lb_dec(&l, s.frame)
		log_flush(s, .Info, &l)
	}
	d.last_cdb, d.cdb_repeats, d.cdb_first = key, 0, s.frame
	return false
}

diag_smpc_repeat :: proc "contextless" (s: ^Saturn, key: [4]u8) -> bool {
	d := &s.diag
	if key == d.last_smpc && d.smpc_repeats < 100000 {
		d.smpc_repeats += 1
		return true
	}
	if d.smpc_repeats > 0 {
		l: Log_Buf
		lb_str(&l, "smpc cmd: the line above repeated ")
		lb_dec(&l, u64(d.smpc_repeats))
		lb_str(&l, " more times")
		log_flush(s, .Info, &l)
	}
	d.last_smpc, d.smpc_repeats = key, 0
	return false
}

// True if this CD command is routine polling and the per-second budget is used up.
diag_cdb_poll_hidden :: proc "contextless" (s: ^Saturn, cmd: u16) -> bool {
	poll := cmd == 0x00 || (cmd >= 0x51 && cmd <= 0x53) || cmd == 0x06 || (cmd >= 0x61 && cmd <= 0x63)
	if !poll { return false }
	d := &s.diag
	if d.poll_shown < 12 {
		d.poll_shown += 1
		return false
	}
	d.poll_hidden += 1
	return true
}

diag_cdb_summary :: proc "contextless" (s: ^Saturn) {
	d := &s.diag
	if d.poll_hidden > 0 {
		c := &s.cdb
		l: Log_Buf
		lb_str(&l, "cdb cmd: ")
		lb_dec(&l, u64(d.poll_hidden))
		lb_str(&l, " polling commands hidden (status/sector count/transfer) f=")
		lb_dec(&l, s.frame)
		lb_str(&l, " drive status=")
		lb_hex(&l, u32(c.status), 2)
		lb_str(&l, " fad=")
		lb_hex(&l, c.cur_fad, 6)
		lb_str(&l, " play_end=")
		lb_hex(&l, c.play_end, 6)
		lb_str(&l, " hirq=")
		lb_hex(&l, u32(c.hirq), 4)
		lb_str(&l, " free_buffers=")
		lb_dec(&l, u64(free_buffers(c)))
		lb_str(&l, " stalled=")
		lb_str(&l, "yes" if c.stalled else "no")
		log_flush(s, .Info, &l)
	}
	d.poll_hidden, d.poll_shown = 0, 0
}

diag_frame :: proc "contextless" (s: ^Saturn) {
	d := &s.diag
	m := &s.cpu[0]
	if s.frame % 60 == 0 { diag_cdb_summary(s) }
	diag_vdp2(s)
	if d.tracing {
		d.tracing, m.trace_on = false, false
		if d.stall {
			report_stall(s)
			d.cooldown = 1200 // 20 s before the next report
		}
		report_io(s)
		d.stall = false
	}
	if d.cooldown > 0 { d.cooldown -= 1 }
	// Every 5 seconds from frame 600, trace one frame of hardware register reads.
	if !d.tracing && s.frame >= 600 && s.frame % 300 == 0 {
		d.tracing, m.trace_on, m.trace_n = true, true, 0
		m.io_hist = {}
	}
	if s.frame % 30 == 0 {
		delta := i32(m.pc) - i32(d.last_pc)
		if -0x40 <= delta && delta <= 0x40 { d.same += 1 } else { d.same = 0 }
		d.last_pc = m.pc
		if d.same >= 6 && d.cooldown == 0 && !d.tracing {
			d.tracing, d.stall, m.trace_on, m.trace_n = true, true, true, 0
			m.io_hist = {}
		}
	}
}

@(private = "file")
readable_code :: proc "contextless" (a: u32) -> bool {
	x := a & 0x1FFFFFFF
	return x < 0x80000 || (x >= 0x200000 && x < 0x300000) || (x >= 0x06000000 && x < 0x06100000)
}

@(private = "file")
report_stall :: proc "contextless" (s: ^Saturn) {
	m := &s.cpu[0]
	l: Log_Buf

	lb_str(&l, "saturn: STALL master pc=")
	lb_hex(&l, m.pc, 8)
	lb_str(&l, " sr=")
	lb_hex(&l, m.sr, 4)
	lb_str(&l, " pr=")
	lb_hex(&l, m.pr, 8)
	lb_str(&l, " gbr=")
	lb_hex(&l, m.gbr, 8)
	lb_str(&l, " vbr=")
	lb_hex(&l, m.vbr, 8)
	log_flush(s, .Warn, &l)

	for row in 0 ..< 4 {
		l = {}
		lb_str(&l, "saturn: STALL regs")
		for i in 0 ..< 4 {
			lb_str(&l, " r")
			lb_dec(&l, u64(row * 4 + i))
			lb_str(&l, "=")
			lb_hex(&l, m.r[row * 4 + i], 8)
		}
		log_flush(s, .Warn, &l)
	}

	if readable_code(m.pc) {
		l = {}
		start := (m.pc & ~u32(1)) - 8
		lb_str(&l, "saturn: STALL code from ")
		lb_hex(&l, start, 8)
		lb_str(&l, ":")
		for i in u32(0) ..< 16 {
			lb_str(&l, " ")
			lb_hex(&l, u32(mem_read16(s, (start + i * 2) & 0x1FFFFFFE)), 4)
		}
		log_flush(s, .Warn, &l)
	}

	// Distinct data reads of the last frame, newest first (b/w/l = 8/16/32 bit).
	n := min(m.trace_n, 32)
	l = {}
	lb_str(&l, "saturn: STALL reads")
	shown := 0
	for k in u32(0) ..< n {
		e := m.trace[(m.trace_n - 1 - k) & 31]
		dup := false
		for j in u32(0) ..< k {
			o := m.trace[(m.trace_n - 1 - j) & 31]
			if o == e { dup = true; break }
		}
		if dup { continue }
		if l.n > 170 { log_flush(s, .Warn, &l); l = {}; lb_str(&l, "saturn: STALL reads") }
		lb_str(&l, " ")
		lb_str(&l, "b" if e.size == 1 else ("w" if e.size == 2 else "l"))
		lb_hex(&l, e.addr, 8)
		lb_str(&l, "=")
		lb_hex(&l, e.val, int(e.size) * 2)
		shown += 1
	}
	if shown == 0 { lb_str(&l, " (none: the loop reads no data, e.g. SLEEP or a register-only wait)") }
	log_flush(s, .Warn, &l)

	l = {}
	lb_str(&l, "saturn: STALL scu ist=")
	lb_hex(&l, s.scu.ist, 8)
	lb_str(&l, " ims=")
	lb_hex(&l, s.scu.ims, 4)
	lb_str(&l, " slave=")
	lb_str(&l, "halted" if s.cpu[1].halted else ("sleeping" if s.cpu[1].sleeping else "running"))
	lb_str(&l, " slave_pc=")
	lb_hex(&l, s.cpu[1].pc, 8)
	lb_str(&l, " 68k_pc=")
	lb_hex(&l, s.scsp.cpu.pc, 6)
	lb_str(&l, " 68k=")
	lb_str(&l, "halted" if s.scsp.cpu.halted else ("stopped" if s.scsp.cpu.stopped else "running"))
	lb_str(&l, " sndram[700]=")
	lb_hex(&l, u32(s.scsp.ram[0x700]), 2)
	lb_str(&l, " sound_cpu_on=")
	lb_str(&l, "1" if s.smpc.sound_cpu_on else "0")
	log_flush(s, .Warn, &l)
}

// The hardware registers the master CPU read most during the traced frame. A BIOS
// that is waiting for something gives it away here: the address is the register,
// the count says how hard it is being polled.
@(private = "file")
report_io :: proc "contextless" (s: ^Saturn) {
	m := &s.cpu[0]
	l: Log_Buf
	lb_str(&l, "saturn: io reads in frame ")
	lb_dec(&l, s.frame)
	lb_str(&l, ", most-read registers:")
	used: [64]bool
	for _ in 0 ..< 10 {
		best, bi := u32(0), -1
		for i in 0 ..< 64 {
			if !used[i] && m.io_hist[i].count > best { best, bi = m.io_hist[i].count, i }
		}
		if bi < 0 { break }
		used[bi] = true
		lb_str(&l, " ")
		lb_hex(&l, m.io_hist[bi].addr, 8)
		lb_str(&l, "x")
		lb_dec(&l, u64(best))
	}
	if l.n < 60 { lb_str(&l, " (none)") }
	log_flush(s, .Info, &l)
}

// ------------------------------------------------------- video diagnostics ---

// Hash of the VDP2 registers that decide what the picture is made of (not the
// scroll positions, which change every frame in normal play).
@(private = "file")
vdp2_signature :: proc "contextless" (v: ^VDP2) -> u64 {
	h: u64 = 0xCBF29CE484222325
	for i in 0 ..< 0x90 {
		if i < 0x0C || (i >= 0x38 && i < 0x4C) { continue }
		h = (h ~ u64(v.regs[i])) * 0x100000001B3
	}
	return h
}

// Logs the display set-up (-v) when it changes, then, once it has stayed the
// same for a second (the game has had time to fill VRAM), measures the row
// pitch of any full-colour bitmap layer against what the layer is set to read.
diag_vdp2 :: proc "contextless" (s: ^Saturn) {
	d := &s.diag
	v := &s.vdp2
	if s.frame % 60 == 0 { d.dma_budget = 40 }
	sig := vdp2_signature(v)
	if sig != d.vdp2_sig {
		d.vdp2_sig, d.vdp2_sig_age = sig, 0
		d.vdp2_logged, d.vdp2_probed = false, false
	} else {
		d.vdp2_sig_age += 1
	}

	// A fade or a raster effect can change the set-up every frame: at most 4 lines a second.
	if !d.vdp2_logged && s.frame >= d.vdp2_last_log + 15 {
		d.vdp2_logged, d.vdp2_last_log = true, s.frame
		l: Log_Buf
		lb_str(&l, "saturn: vdp2 f=")
		lb_dec(&l, s.frame)
		reg :: proc "contextless" (l: ^Log_Buf, name: string, v: ^VDP2, i: int) {
			lb_str(l, " ")
			lb_str(l, name)
			lb_str(l, "=")
			lb_hex(l, u32(v.regs[i]), 4)
		}
		reg(&l, "tvmd", v, 0x00)
		reg(&l, "ramctl", v, 0x07)
		reg(&l, "bgon", v, 0x10)
		reg(&l, "chctla", v, 0x14)
		reg(&l, "chctlb", v, 0x15)
		reg(&l, "mpofn", v, 0x1E)
		reg(&l, "scrctl", v, 0x4D)
		reg(&l, "spctl", v, 0x70)
		reg(&l, "ccctl", v, 0x76)
		reg(&l, "prina", v, 0x7C)
		reg(&l, "prinb", v, 0x7D)
		reg(&l, "rpmd", v, 0x58)
		reg(&l, "wctla", v, 0x68)
		log_flush(s, .Info, &l)

		// Everything that decides *which* dots of a CC-enabled layer blend.
		l = {}
		lb_str(&l, "saturn: vdp2 cc")
		reg(&l, "ccctl", v, 0x76)
		reg(&l, "sfccmd", v, 0x77)
		reg(&l, "sfsel", v, 0x12)
		reg(&l, "sfcode", v, 0x13)
		reg(&l, "lnclen", v, 0x74)
		reg(&l, "wctld", v, 0x6B)
		reg(&l, "ccrna", v, 0x84)
		reg(&l, "ccrnb", v, 0x85)
		reg(&l, "ccrlb", v, 0x87)
		reg(&l, "ccrsa", v, 0x80)
		reg(&l, "bmpna", v, 0x16)
		reg(&l, "pncn0", v, 0x18)
		reg(&l, "pncn1", v, 0x19)
		reg(&l, "pncn2", v, 0x1A)
		reg(&l, "clofen", v, 0x88)
		log_flush(s, .Info, &l)

		for n in u32(0) ..< 4 {
			i := vdp2_nbg_info(v, n)
			if !i.on { continue }
			l = {}
			lb_str(&l, "saturn: vdp2   NBG")
			lb_dec(&l, u64(n))
			lb_str(&l, " prio=")
			lb_dec(&l, u64(i.prio))
			lb_str(&l, " bpp=")
			lb_dec(&l, u64(i.bpp))
			if i.bitmap {
				lb_str(&l, " bitmap ")
				lb_dec(&l, u64(i.width))
				lb_str(&l, "x")
				lb_dec(&l, u64(i.height))
				lb_str(&l, " base=")
				lb_hex(&l, i.base, 5)
			} else {
				lb_str(&l, " cells ")
				lb_str(&l, "16x16" if i.cell16 else "8x8")
				lb_str(&l, " pn=")
				lb_str(&l, "1w" if i.pn_one_word else "2w")
			}
			if i.cc { lb_str(&l, " cc") }
			if i.ls { lb_str(&l, " linescroll") }
			log_flush(s, .Info, &l)
		}
		if v.regs[0x10] & 0x30 != 0 { log_msg(s, .Info, "saturn: vdp2   RBG0/RBG1 is enabled but not implemented: that layer will not appear") }
	}

	if !d.vdp2_probed && d.vdp2_sig_age >= 60 {
		d.vdp2_probed = true
		if vdp2_uses_scroll_tables(v) || v.regs[0x68] & 0x3F3F != 0 { diag_vdp2_tables(s) }
		for n in u32(0) ..< 2 {
			best, best_err, cfg_err, ok := vdp2_pitch_probe(v, n)
			if !ok { continue }
			l: Log_Buf
			lb_str(&l, "saturn: vdp2 NBG")
			lb_dec(&l, u64(n))
			lb_str(&l, " bitmap row-pitch probe: configured ")
			lb_dec(&l, u64(vdp2_nbg_info(v, n).width))
			lb_str(&l, " dots (error ")
			lb_dec(&l, u64(cfg_err))
			lb_str(&l, "), best fit ")
			lb_dec(&l, u64(best))
			lb_str(&l, " dots (error ")
			lb_dec(&l, u64(best_err))
			lb_str(&l, ")")
			if best != vdp2_nbg_info(v, n).width && best_err * 2 < cfg_err {
				lb_str(&l, "  <-- image data is stored with a different row pitch than the layer reads")
				log_flush(s, .Info, &l)
			} else {
				log_flush(s, .Info, &l)
			}
		}
	}
}

// Logs one DMA transfer into VDP1/VDP2 video RAM (rate limited): which channel,
// how it was started, and the addresses, so the writer of a picture can be told
// apart from a log. `entry` is the indirect-table entry number (or -1).
diag_dma_to_vram :: proc "contextless" (s: ^Saturn, level: int, mode: u32, entry: int, ra, wa, count, add: u32) {
	d := &s.diag
	region := (wa >> 20) & 0xF
	if (wa >> 24) & 0x1F != 5 || (region != 0xC && region != 0xE) { return }
	if d.dma_budget == 0 { return }
	d.dma_budget -= 1
	l: Log_Buf
	lb_str(&l, "saturn: scu dma")
	lb_dec(&l, u64(level))
	lb_str(&l, " f=")
	lb_dec(&l, s.frame)
	lb_str(&l, " mode=")
	lb_hex(&l, mode, 8)
	if entry >= 0 {
		lb_str(&l, " indirect#")
		lb_dec(&l, u64(entry))
	}
	lb_str(&l, " read=")
	lb_hex(&l, ra, 8)
	lb_str(&l, " write=")
	lb_hex(&l, wa, 8)
	lb_str(&l, " bytes=")
	lb_dec(&l, u64(count))
	lb_str(&l, " add=")
	lb_hex(&l, add, 3)
	log_flush(s, .Info, &l)
}

// One-shot dump of everything that decides how a line-scrolled layer is drawn:
// the scroll/zoom/window/colour-calculation registers and the first entries of
// the line-scroll, vertical-cell-scroll and line-window tables. Written once,
// a second after the display set-up settles.
diag_vdp2_tables :: proc "contextless" (s: ^Saturn) {
	v := &s.vdp2
	r := &v.regs
	l: Log_Buf
	put :: proc "contextless" (l: ^Log_Buf, name: string, val: u32, digits: int) {
		lb_str(l, " ")
		lb_str(l, name)
		lb_str(l, "=")
		lb_hex(l, val, digits)
	}
	lb_str(&l, "saturn: vdp2 tables f=")
	lb_dec(&l, s.frame)
	put(&l, "zmctl", u32(r[0x4C]), 4)
	put(&l, "scrctl", u32(r[0x4D]), 4)
	put(&l, "vcsta", u32(r[0x4E]) << 16 | u32(r[0x4F]), 8)
	put(&l, "lsta0", u32(r[0x50]) << 16 | u32(r[0x51]), 8)
	put(&l, "lsta1", u32(r[0x52]) << 16 | u32(r[0x53]), 8)
	put(&l, "bmpna", u32(r[0x16]), 4)
	put(&l, "cycA0", u32(r[0x08]) << 16 | u32(r[0x09]), 8)
	put(&l, "cycA1", u32(r[0x0A]) << 16 | u32(r[0x0B]), 8)
	put(&l, "cycB0", u32(r[0x0C]) << 16 | u32(r[0x0D]), 8)
	put(&l, "cycB1", u32(r[0x0E]) << 16 | u32(r[0x0F]), 8)
	log_flush(s, .Info, &l)

	l = {}
	lb_str(&l, "saturn: vdp2 NBG0 scroll")
	names := [8]string{"scxin", "scxdn", "scyin", "scydn", "zmxin", "zmxdn", "zmyin", "zmydn"}
	for i in 0 ..< 8 { put(&l, names[i], u32(r[0x38 + i]), 4) }
	log_flush(s, .Info, &l)

	l = {}
	lb_str(&l, "saturn: vdp2 windows")
	wn := [16]string{"wpsx0", "wpsy0", "wpex0", "wpey0", "wpsx1", "wpsy1", "wpex1", "wpey1", "wctla", "wctlb", "wctlc", "wctld", "lwta0u", "lwta0l", "lwta1u", "lwta1l"}
	for i in 0 ..< 16 { put(&l, wn[i], u32(r[0x60 + i]), 4) }
	log_flush(s, .Info, &l)

	l = {}
	lb_str(&l, "saturn: vdp2 colour")
	put(&l, "ccctl", u32(r[0x76]), 4)
	put(&l, "ccrna", u32(r[0x84]), 4)
	put(&l, "ccrnb", u32(r[0x85]), 4)
	put(&l, "ccrlb", u32(r[0x87]), 4)
	put(&l, "clofen", u32(r[0x88]), 4)
	put(&l, "clofsl", u32(r[0x89]), 4)
	put(&l, "coar", u32(r[0x8A]), 4)
	put(&l, "coag", u32(r[0x8B]), 4)
	put(&l, "coab", u32(r[0x8C]), 4)
	put(&l, "cobr", u32(r[0x8D]), 4)
	put(&l, "cobg", u32(r[0x8E]), 4)
	put(&l, "cobb", u32(r[0x8F]), 4)
	log_flush(s, .Info, &l)

	// Line-scroll table: 32-bit entries, lines 0-9, 100, 111, 112, 150, 223.
	lsta := (u32(r[0x50] & 7) << 16 | u32(r[0x51])) * 2
	fields := u32(r[0x4D] >> 1 & 1) + u32(r[0x4D] >> 2 & 1) + u32(r[0x4D] >> 3 & 1)
	if fields > 0 {
		lines := [?]u32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 100, 111, 112, 150, 223}
		l = {}
		lb_str(&l, "saturn: vdp2 NBG0 line-scroll table (")
		lb_dec(&l, u64(fields))
		lb_str(&l, " long(s) per entry) line:value(s)")
		for ln in lines {
			a := lsta + (ln >> ((u32(r[0x4D]) >> 4) & 3)) * fields * 4
			lb_str(&l, " ")
			lb_dec(&l, u64(ln))
			lb_str(&l, ":")
			for f in u32(0) ..< fields {
				if f > 0 { lb_str(&l, "/") }
				lb_hex(&l, vdp2_peek16(v, a + f * 4) << 16 | vdp2_peek16(v, a + f * 4 + 2), 8)
			}
			if l.n > 200 { log_flush(s, .Info, &l); l = {}; lb_str(&l, "saturn: vdp2   ...") }
		}
		log_flush(s, .Info, &l)
	}

	// Vertical cell scroll table: first 16 entries.
	if r[0x4D] & 0x0101 != 0 {
		vcsta := (u32(r[0x4E] & 7) << 16 | u32(r[0x4F])) * 2
		l = {}
		lb_str(&l, "saturn: vdp2 vertical cell scroll table at ")
		lb_hex(&l, vcsta, 5)
		lb_str(&l, ":")
		for i in u32(0) ..< 20 {
			lb_str(&l, " ")
			lb_hex(&l, vdp2_peek16(v, vcsta + i * 4) << 16 | vdp2_peek16(v, vcsta + i * 4 + 2), 8)
			if l.n > 200 { log_flush(s, .Info, &l); l = {}; lb_str(&l, "saturn: vdp2   ...") }
		}
		log_flush(s, .Info, &l)
	}

	// Line window table for window 0: (start, end) word pairs.
	if r[0x6C] & 0x8000 != 0 {
		lw := (u32(r[0x6C] & 7) << 16 | u32(r[0x6D])) * 2
		l = {}
		lb_str(&l, "saturn: vdp2 line window 0 table at ")
		lb_hex(&l, lw, 5)
		lb_str(&l, " (start,end):")
		for i in u32(0) ..< 12 {
			lb_str(&l, " ")
			lb_hex(&l, vdp2_peek16(v, lw + i * 4), 4)
			lb_str(&l, ",")
			lb_hex(&l, vdp2_peek16(v, lw + i * 4 + 2), 4)
		}
		log_flush(s, .Info, &l)
	}
}
