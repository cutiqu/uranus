// The whole machine, and the scheduler that runs it.
//
// One frame is NTSC_LINES scanlines. Per line: run both SH-2s in short
// interleaved slices up to the start of HBlank, draw the line, raise HBlank,
// run to the end of the line, then service the slow devices (SMPC commands,
// CD block, VDP1 completion). VBlank-OUT is the start of line 0; VBlank-IN is
// the start of the first line after the active area.
package saturn_core

import "base:intrinsics"

import api "../api"

LINE_CYCLES_320 :: 1820 // master clock cycles per scanline at the 320-wide dot clock
LINE_CYCLES_352 :: 1708
SLICE           :: 200  // CPU interleave granularity, in cycles
BIOS_SIZE       :: 0x80000

// Where the host CPU's time goes, in cycle-counter ticks (see the `prof` log line).
Prof :: struct {
	frames: u64,
	sh2, vdp2, scsp, frame: u64,
	vdp1_seen: u64,
}

@(private = "file")
tsc :: #force_inline proc "contextless" () -> u64 { return u64(intrinsics.read_cycle_counter()) }

Saturn :: struct {
	cpu:    [2]SH2,
	bios:   [BIOS_SIZE]u8,
	wram_l: [0x100000]u8,
	wram_h: [0x100000]u8,
	backup: [0x8000]u8, // internal backup RAM; saved by the host as Save_RAM

	smpc: SMPC,
	scu:  SCU,
	vdp1: VDP1,
	vdp2: VDP2,
	scsp: SCSP,
	cdb:  CDB,
	diag: Diag,
	prof: Prof,

	host:         ^api.Host,
	bios_loaded:  bool,
	backup_dirty: bool,
	backup_checked: bool, // the first frame after load verifies the (possibly host-loaded) backup RAM
	frame:        u64,
	line_start:   i64, // absolute master-clock cycle at which the current line began

	audio:       [2 * 800]i16,
	audio_frames: uint,
	audio_frac:  f64,

	out_w, out_h: u32,
	illegal_logged: u32,
}

// ---------------------------------------------------------------- logging ---
// Cores may not import fmt or allocate, so messages are assembled by hand.

Log_Buf :: struct {
	b: [480]u8,
	n: int,
}

lb_str :: proc "contextless" (l: ^Log_Buf, s: string) {
	for i in 0 ..< len(s) {
		if l.n < len(l.b) - 1 { l.b[l.n] = s[i]; l.n += 1 }
	}
}

lb_hex :: proc "contextless" (l: ^Log_Buf, v: u32, digits: int) {
	hex_digits := "0123456789ABCDEF"
	for i := digits - 1; i >= 0; i -= 1 {
		if l.n < len(l.b) - 1 { l.b[l.n] = hex_digits[(v >> u32(i * 4)) & 0xF]; l.n += 1 }
	}
}

// Prints ticks as millions with one decimal, e.g. 12.3.
lb_mt :: proc "contextless" (l: ^Log_Buf, ticks: u64) {
	t := ticks / 100_000 // tenths of a million
	lb_dec(l, t / 10)
	lb_str(l, ".")
	lb_dec(l, t % 10)
}

lb_dec :: proc "contextless" (l: ^Log_Buf, v: u64) {
	tmp: [20]u8
	n := 0
	x := v
	for {
		tmp[n] = u8('0' + x % 10)
		n += 1
		x /= 10
		if x == 0 { break }
	}
	for i := n - 1; i >= 0; i -= 1 {
		if l.n < len(l.b) - 1 { l.b[l.n] = tmp[i]; l.n += 1 }
	}
}

log_flush :: proc "contextless" (s: ^Saturn, level: api.Log_Level, l: ^Log_Buf) {
	if s.host == nil || s.host.log == nil { return }
	l.b[l.n] = 0
	s.host.log(s.host.userdata, level, cstring(raw_data(l.b[:])))
}

log_msg :: proc "contextless" (s: ^Saturn, level: api.Log_Level, msg: string) {
	l: Log_Buf
	lb_str(&l, msg)
	log_flush(s, level, &l)
}

// ------------------------------------------------------------------ reset ---

// Internal backup RAM as a factory-fresh console has it: the first 0x40 bytes carry
// "BackUpRam Format" four times and the rest is empty (the same layout Mednafen
// starts with). Without that header a game says "Base RAM is not ready for backup
// (has not been initialized)" and stops, as Hexen did.
BRAM_HEADER := [16]u8{'B', 'a', 'c', 'k', 'U', 'p', 'R', 'a', 'm', ' ', 'F', 'o', 'r', 'm', 'a', 't'}

backup_format :: proc "contextless" (s: ^Saturn) {
	for i in 0 ..< len(s.backup) { s.backup[i] = 0 }
	for i in 0 ..< 0x40 { s.backup[i] = BRAM_HEADER[i & 15] }
	s.backup_dirty = true
}

// The host copies a saved file over the backup RAM after load_game, and an earlier
// run of this core may have saved it blank. A blank (all-zero) image is formatted;
// anything else is left alone, valid or not: it is someone's data.
backup_ensure_formatted :: proc "contextless" (s: ^Saturn) {
	valid := true
	for i in 0 ..< 16 { if s.backup[i] != BRAM_HEADER[i] { valid = false } }
	if valid { return }
	for i in 0 ..< len(s.backup) { if s.backup[i] != 0 { return } }
	backup_format(s)
}

// Full power-cycle of everything except the BIOS image, backup RAM and disc.
system_reset :: proc "contextless" (s: ^Saturn) {
	for i in 0 ..< len(s.wram_l) { s.wram_l[i] = 0 }
	for i in 0 ..< len(s.wram_h) { s.wram_h[i] = 0 }
	s.vdp1 = {}
	s.vdp2 = {}
	s.scsp = {}
	scsp_reset(s)
	smpc_reset(&s.smpc)
	cdb_reset(&s.cdb)
	vdp1_reset(&s.vdp1)
	vdp2_reset(&s.vdp2)
	scu_reset(s)
	s.frame, s.line_start = 0, 0
	s.audio_frac = 0
	s.illegal_logged = 0
	cpus_reset(s)
}

// SMPC SYSRES: resets the CPUs and the chips around them, but not RAM.
system_soft_reset :: proc "contextless" (s: ^Saturn) {
	vdp1_reset(&s.vdp1)
	vdp2_reset(&s.vdp2)
	scu_reset(s)
	cpus_reset(s)
}

@(private = "file")
cpus_reset :: proc "contextless" (s: ^Saturn) {
	now := s.line_start
	sh2_reset(&s.cpu[0], s, false)
	sh2_reset(&s.cpu[1], s, true)
	s.cpu[1].halted = true
	s.cpu[0].cycles, s.cpu[1].cycles = now, now
}

// Chooses the console region from the disc's IP.BIN area symbols so that
// games do not refuse to run, preferring North America, then Europe, then Japan.
pick_area :: proc "contextless" (s: ^Saturn) {
	ip, ok := cdb_ip_bin(&s.cdb)
	area: u8 = AREA_JAPAN
	if ok {
		has :: proc "contextless" (ip: []u8, c: u8) -> bool {
			for i in 0x40 ..< 0x50 { if ip[i] == c { return true } }
			return false
		}
		if has(ip, 'U') { area = AREA_NA } else if has(ip, 'E') { area = AREA_EUROPE }
	}
	s.smpc.area = area
}

// ------------------------------------------------------------- scheduling ---

@(private = "file")
run_cpus :: proc "contextless" (s: ^Saturn, until: i64) {
	m, sl := &s.cpu[0], &s.cpu[1]
	for m.cycles < until {
		target := min(m.cycles + SLICE, until)
		sh2_run(m, target)
		sh2_run(sl, target)
	}
	if sl.cycles < until { sh2_run(sl, until) }
}

run_frame :: proc "contextless" (s: ^Saturn) {
	frame_t0 := tsc()
	s.audio_frames = 0 // the SCSP appends one stereo frame per 44.1 kHz sample
	w, h, hires, dbl := vdp2_mode(&s.vdp2)
	active := h
	line_cycles := i64(LINE_CYCLES_352 if s.smpc.clock_352 else LINE_CYCLES_320)
	hblank_at := line_cycles * 3 / 4

	s.out_w = w * 2 if hires else w
	s.out_h = h * 2 if dbl else h

	for line in u32(0) ..< NTSC_LINES {
		s.vdp2.vcount = line
		if line == 0 {
			s.vdp2.vblank = false
			s.vdp2.odd = !s.vdp2.odd
			vdp1_frame_change(&s.vdp1)
			scu_vblank(s, false)
		} else if line == active {
			s.vdp2.vblank = true
			scu_vblank(s, true)
			smpc_vblank(s)
		}

		t := tsc()
		run_cpus(s, s.line_start + hblank_at)
		s.prof.sh2 += tsc() - t

		s.vdp2.hblank = true
		s.vdp2.hcnt_latch = u16(w)
		t = tsc()
		if line < active { vdp2_draw_line(&s.vdp2, line, &s.vdp1.fb[1 - s.vdp1.draw]) }
		s.prof.vdp2 += tsc() - t
		scu_hblank(s, true)

		t = tsc()
		run_cpus(s, s.line_start + line_cycles)
		s.prof.sh2 += tsc() - t
		s.line_start += line_cycles

		s.vdp2.hblank = false
		scu_hblank(s, false)
		smpc_update(s)
		cdb_line(s)
		t = tsc()
		scsp_line(s, u64(line_cycles))
		s.prof.scsp += tsc() - t
		if s.vdp1.end_int_pending {
			s.vdp1.end_int_pending = false
			scu_set_int(s, INT_SPRITE_END)
		}
	}

	s.prof.frame += tsc() - frame_t0
	s.prof.frames += 1
	report_illegal(s)
	diag_frame(s)
	debug_line(s)
	s.frame += 1
}

// Illegal-instruction exceptions almost always mean an interpreter bug or a
// jump into data, so the first few are worth a log line each.
@(private = "file")
report_illegal :: proc "contextless" (s: ^Saturn) {
	for i in 0 ..< 2 {
		c := &s.cpu[i]
		if c.illegal_count > s.illegal_logged && s.illegal_logged < 8 {
			s.illegal_logged += 1
			l: Log_Buf
			lb_str(&l, "saturn: illegal instruction on ")
			lb_str(&l, "slave " if i == 1 else "master ")
			lb_hex(&l, u32(c.last_illegal), 4)
			lb_str(&l, " at ")
			lb_hex(&l, c.last_illegal_pc, 8)
			log_flush(s, .Warn, &l)
		}
	}
}

@(private = "file")
debug_line :: proc "contextless" (s: ^Saturn) {
	if s.frame % 60 != 0 { return }
	l: Log_Buf
	lb_str(&l, "saturn f=")
	lb_dec(&l, s.frame)
	lb_str(&l, " pc=")
	lb_hex(&l, s.cpu[0].pc, 8)
	lb_str(&l, " spc=")
	lb_hex(&l, s.cpu[1].pc, 8)
	lb_str(&l, " tvmd=")
	lb_hex(&l, u32(s.vdp2.regs[0]), 4)
	lb_str(&l, " bgon=")
	lb_hex(&l, u32(s.vdp2.regs[0x10]), 4)
	lb_str(&l, " ims=")
	lb_hex(&l, s.scu.ims, 4)
	lb_str(&l, " cd=")
	lb_hex(&l, u32(s.cdb.status), 2)
	lb_str(&l, " hirq=")
	lb_hex(&l, u32(s.cdb.hirq), 4)
	lb_str(&l, "/")
	lb_hex(&l, u32(s.cdb.hirq_mask), 4)
	lb_str(&l, " fad=")
	lb_hex(&l, s.cdb.cur_fad, 6)
	lb_str(&l, " sr=")
	lb_hex(&l, s.cpu[0].sr, 3)
	lb_str(&l, " ist=")
	lb_hex(&l, s.scu.ist, 8)
	lb_str(&l, " slave=")
	lb_str(&l, "halted" if s.cpu[1].halted else ("sleeping" if s.cpu[1].sleeping else "running"))
	lb_str(&l, " 68k=")
	lb_hex(&l, s.scsp.cpu.pc, 6)
	lb_str(&l, "H" if s.scsp.cpu.halted else ("S" if s.scsp.cpu.stopped else "R"))
	lb_str(&l, " scipd=")
	lb_hex(&l, u32(s.scsp.scipd), 4)
	lb_str(&l, " irq:")
	for v in 0 ..< 256 {
		if s.cpu[0].vec_count[v] != 0 {
			lb_str(&l, " ")
			lb_hex(&l, u32(v), 2)
			lb_str(&l, "x")
			lb_dec(&l, u64(s.cpu[0].vec_count[v]))
			s.cpu[0].vec_count[v] = 0
		}
	}
	log_flush(s, .Debug, &l)

	// Both CPUs' view of each other: where each is, whether the slave sleeps, the
	// free-running-timer interrupt setup that MINIT/SINIT pulses go through, and
	// how many pulses were sent. Two CPUs each waiting for a flag the other sets
	// look like this: both PCs parked in small loops and no pulses (or pulses the
	// receiver never turns into an interrupt: ftcsr ICF set but tier ICIE clear).
	l = {}
	lb_str(&l, "saturn: smp f=")
	lb_dec(&l, s.frame)
	for i in 0 ..< 2 {
		c := &s.cpu[i]
		lb_str(&l, " m" if i == 0 else " | s")
		lb_str(&l, " pc=")
		lb_hex(&l, c.pc, 8)
		lb_str(&l, " sr=")
		lb_hex(&l, c.sr, 3)
		lb_str(&l, " halted" if c.halted else (" sleeping" if c.sleeping else " running"))
		lb_str(&l, " tier=")
		lb_hex(&l, u32(c.oc.tier), 2)
		lb_str(&l, " ftcsr=")
		lb_hex(&l, u32(c.oc.ftcsr), 2)
		lb_str(&l, " iprb=")
		lb_hex(&l, u32(c.oc.iprb), 4)
		lb_str(&l, " vcrc=")
		lb_hex(&l, u32(c.oc.vcrc), 4)
		lb_str(&l, " vbr=")
		lb_hex(&l, c.vbr, 8)
	}
	lb_str(&l, " | minit=")
	lb_dec(&l, u64(s.diag.minit_n))
	lb_str(&l, " sinit=")
	lb_dec(&l, u64(s.diag.sinit_n))
	lb_str(&l, " slave irq:")
	for v in 0 ..< 256 {
		if s.cpu[1].vec_count[v] != 0 {
			lb_str(&l, " ")
			lb_hex(&l, u32(v), 2)
			lb_str(&l, "x")
			lb_dec(&l, u64(s.cpu[1].vec_count[v]))
			s.cpu[1].vec_count[v] = 0
		}
	}
	log_flush(s, .Debug, &l)

	// The sound side: the BIOS and games talk to the 68000 through a mailbox in
	// sound RAM (the BIOS uses 0x700), and a driver that waits for a sample to end
	// or a timer shows up here as `keyon` slots that never finish.
	l = {}
	lb_str(&l, "saturn: snd f=")
	lb_dec(&l, s.frame)
	lb_str(&l, " mbox[700]=")
	for i in 0 ..< 16 {
		lb_hex(&l, u32(s.scsp.ram[0x700 + i]), 2)
		if i & 3 == 3 { lb_str(&l, " ") }
	}
	keyon := 0
	for slot in 0 ..< 32 { if s.scsp.regs[slot * 0x20] & 0x08 != 0 { keyon += 1 } }
	lb_str(&l, "keyon=")
	lb_dec(&l, u64(keyon))
	lb_str(&l, " scieb=")
	lb_hex(&l, u32(s.scsp.scieb), 4)
	lb_str(&l, " lv=")
	for i in 0 ..< 3 { lb_hex(&l, u32(s.scsp.scilv[i]), 2) }
	lb_str(&l, " mcieb=")
	lb_hex(&l, u32(s.scsp.mcieb), 4)
	lb_str(&l, " mcipd=")
	lb_hex(&l, u32(s.scsp.mcipd), 4)
	lb_str(&l, " 68k_ipl=")
	lb_dec(&l, u64(s.scsp.cpu.ipl))
	// Slots the position tracker has running, how often a driver read the monitor
	// register (0x408) since the last line, and the sound RAM words around 0x404
	// (the SH-2 side of a streaming game polls those for the driver's play position).
	running := 0
	for slot in 0 ..< 32 { if s.scsp.slots[slot].run { running += 1 } }
	lb_str(&l, " slots_run=")
	lb_dec(&l, u64(running))
	lb_str(&l, " ca_reads=")
	lb_dec(&l, u64(s.scsp.ca_reads))
	s.scsp.ca_reads = 0
	lb_str(&l, " sram[400]=")
	for i in 0 ..< 16 {
		lb_hex(&l, u32(s.scsp.ram[0x400 + i]), 2)
		if i & 3 == 3 && i < 15 { lb_str(&l, " ") }
	}
	log_flush(s, .Debug, &l)

	// Host cost per frame in millions of cycle-counter ticks. At 60 fps a frame has
	// (CPU GHz x 16.7) of them; sh2 includes everything the CPUs trigger except VDP1
	// drawing, which is split out. `rest` is SMPC/SCU/CD-block/video-copy bookkeeping.
	p := &s.prof
	if p.frames > 0 {
		v1 := s.vdp1.prof - p.vdp1_seen
		p.vdp1_seen = s.vdp1.prof
		n := p.frames
		cpu := p.sh2 - min(p.sh2, v1)
		rest := p.frame - min(p.frame, cpu + v1 + p.vdp2 + p.scsp)
		l = {}
		lb_str(&l, "saturn: prof f=")
		lb_dec(&l, s.frame)
		lb_str(&l, " Mticks/frame total=")
		lb_mt(&l, p.frame / n)
		lb_str(&l, " cpus=")
		lb_mt(&l, cpu / n)
		lb_str(&l, " vdp1=")
		lb_mt(&l, v1 / n)
		lb_str(&l, " vdp2=")
		lb_mt(&l, p.vdp2 / n)
		lb_str(&l, " 68k+scsp=")
		lb_mt(&l, p.scsp / n)
		lb_str(&l, " rest=")
		lb_mt(&l, rest / n)
		log_flush(s, .Debug, &l)
		p.frames, p.sh2, p.vdp2, p.scsp, p.frame = 0, 0, 0, 0, 0
	}
}
