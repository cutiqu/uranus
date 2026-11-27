// Save states. Every field of the machine is described once, as a list of sync_*
// calls (see corelib/state.odin), and that one list counts, saves and loads.
//
// WHAT IS SAVED. Everything that makes the next frame come out the way it
// does: both SH-2s with their on-chip peripherals, the 68000, the SCSP, SMPC,
// SCU, both VDPs (RAM and registers), the CD block (its buffers, filters and
// the transfer in progress) and all of work RAM.
//
// WHAT IS NOT, and why:
//   * the BIOS image        a state records a hash of it instead, so a state made
//                           under one BIOS is refused under another;
//   * backup RAM            that is the game's *save file* (persisted by the host as
//                           <game>.sav). Loading a state must never roll back, or
//                           blank, the player's saved games;
//   * the disc              the host owns it. The state records the first bytes of
//                           IP.BIN and a state from another disc is refused;
//   * pointers and procs    (host, disc, each SH-2's machine pointer and interrupt
//                           callback, the 68000's bus) are wired up again on load;
//   * diagnostics           traces, profiling counters, the stall detector, the
//                           rendered frame (the next frame redraws it) and the audio
//                           of the last frame.
//
// A LOADED STATE IS UNTRUSTED. It is read into `staged` and checked before it
// touches the running machine, so a corrupt or hostile file is refused whole
// rather than half-applied, and cannot index out of range or send a scheduler
// loop on an endless catch-up (see `valid`).
package saturn_core

import lib "../../corelib"
import "base:intrinsics"

STATE_MAGIC   :: u32(0x5341_5455) // "UTAS" in memory order: Saturn state
STATE_VERSION :: u32(1)

// How far from the scanline clock a CPU's own clock may be in a state we accept.
// A real one is within a handful of cycles; the bound only exists so that a
// corrupt value cannot make a scheduler loop run for minutes catching up.
@(private = "file")
CLOCK_SLACK :: i64(1) << 24

// The on-chip timers are lazy (sh7604.odin): their base cycle stays put until the
// timer is next read, written or due, so it may trail the CPU by a long way, but
// it can never be ahead of it. The allowance is about 40 minutes of emulated time.
@(private = "file")
TIMER_LAG_MAX :: i64(1) << 36

@(private = "file")
staged: Saturn // where a state is parsed and checked before it is applied

// Why the last load_state said no, for the log: a short reason, plus the line of
// the check in `valid` that failed (0 when it was not one of those).
@(private = "file")
reject_why:  string
@(private = "file")
reject_line: int

@(private = "file")
bad :: proc "contextless" (loc := #caller_location) -> bool {
	reject_why, reject_line = "a field holds a value the machine cannot have", int(loc.line)
	return false
}

// "" after a successful load; otherwise a sentence for the log.
state_reject_reason :: proc "contextless" () -> (why: string, line: int) {
	return reject_why, reject_line
}

// ------------------------------------------------------------ the chips ----

@(private = "file")
sync_sh7604 :: proc "contextless" (s: ^lib.State, v: ^SH7604) {
	lib.sync_int(s, &v.tier); lib.sync_int(s, &v.ftcsr); lib.sync_int(s, &v.tcr); lib.sync_int(s, &v.tocr)
	lib.sync_int(s, &v.frc); lib.sync_int(s, &v.ocra); lib.sync_int(s, &v.ocrb); lib.sync_int(s, &v.ficr)
	lib.sync_int(s, &v.frt_base)

	lib.sync_int(s, &v.wtcsr); lib.sync_int(s, &v.wtcnt); lib.sync_int(s, &v.rstcsr)
	lib.sync_int(s, &v.wdt_base)

	lib.sync_int(s, &v.dvsr); lib.sync_int(s, &v.dvdnt); lib.sync_int(s, &v.dvdnth)
	lib.sync_int(s, &v.dvdntl); lib.sync_int(s, &v.dvcr); lib.sync_int(s, &v.vcrdiv)

	for &d in v.dma {
		lib.sync_int(s, &d.sar); lib.sync_int(s, &d.dar); lib.sync_int(s, &d.tcr)
		lib.sync_int(s, &d.chcr); lib.sync_int(s, &d.vcr); lib.sync_int(s, &d.drcr)
	}
	lib.sync_int(s, &v.dmaor)

	lib.sync_int(s, &v.ipra); lib.sync_int(s, &v.iprb); lib.sync_int(s, &v.vcra); lib.sync_int(s, &v.vcrb)
	lib.sync_int(s, &v.vcrc); lib.sync_int(s, &v.vcrd); lib.sync_int(s, &v.vcrwdt); lib.sync_int(s, &v.icr)

	lib.sync_bytes(s, v.raw[:])
	lib.sync_int(s, &v.next_event)
}

@(private = "file")
sync_sh2 :: proc "contextless" (s: ^lib.State, v: ^SH2) {
	lib.sync_ints(s, v.r[:])
	lib.sync_int(s, &v.pc); lib.sync_int(s, &v.pr); lib.sync_int(s, &v.gbr); lib.sync_int(s, &v.vbr)
	lib.sync_int(s, &v.mach); lib.sync_int(s, &v.macl); lib.sync_int(s, &v.sr)

	lib.sync_int(s, &v.cycles)
	lib.sync_bool(s, &v.is_slave); lib.sync_bool(s, &v.halted); lib.sync_bool(s, &v.sleeping)

	lib.sync_int(s, &v.ext_level)
	lib.sync_bool(s, &v.nmi)
	lib.sync_int(s, &v.irq_level)
	src := u8(v.irq_src)
	lib.sync_int(s, &src)
	if s.mode == .Load { v.irq_src = Irq_Source(src) } // range-checked in `valid`

	sync_sh7604(s, &v.oc)
	lib.sync_bytes(s, v.cache_ram[:])

	lib.sync_int(s, &v.illegal_count); lib.sync_int(s, &v.last_illegal); lib.sync_int(s, &v.last_illegal_pc)
}

@(private = "file")
sync_m68k :: proc "contextless" (s: ^lib.State, v: ^M68K) {
	lib.sync_ints(s, v.d[:]); lib.sync_ints(s, v.a[:])
	lib.sync_int(s, &v.usp); lib.sync_int(s, &v.ssp); lib.sync_int(s, &v.pc); lib.sync_int(s, &v.sr)
	lib.sync_int(s, &v.ipl)
	lib.sync_bool(s, &v.stopped); lib.sync_bool(s, &v.halted)
	lib.sync_int(s, &v.cycles); lib.sync_int(s, &v.odd_accesses)
	lib.sync_int(s, &v.ipc)
}

@(private = "file")
sync_scsp :: proc "contextless" (s: ^lib.State, v: ^SCSP) {
	lib.sync_bytes(s, v.ram[:])
	lib.sync_bytes(s, v.regs[:])
	sync_m68k(s, &v.cpu)

	lib.sync_int(s, &v.scieb); lib.sync_int(s, &v.scipd); lib.sync_int(s, &v.mcieb); lib.sync_int(s, &v.mcipd)
	lib.sync_bytes(s, v.scilv[:])
	lib.sync_bool(s, &v.main_int)

	for &sl in v.slots {
		lib.sync_int(s, &sl.cur); lib.sync_int(s, &sl.phase)
		lib.sync_bool(s, &sl.on); lib.sync_bool(s, &sl.run)
		lib.sync_bool(s, &sl.in_loop); lib.sync_bool(s, &sl.loop_sub)
		lib.sync_int(s, &sl.env_phase); lib.sync_int(s, &sl.env_level)
	}
	lib.sync_bool(s, &v.key_exec)
	lib.sync_int(s, &v.lfsr); lib.sync_int(s, &v.mslc); lib.sync_int(s, &v.ca_reads)

	for &t in v.timers {
		lib.sync_int(s, &t.ctl); lib.sync_int(s, &t.reload); lib.sync_int(s, &t.counter)
	}
	lib.sync_int(s, &v.sample_counter); lib.sync_int(s, &v.sample_acc)
	lib.sync_int(s, &v.cpu_acc); lib.sync_int(s, &v.cpu_target)
}

@(private = "file")
sync_smpc :: proc "contextless" (s: ^lib.State, v: ^SMPC) {
	lib.sync_bytes(s, v.ireg[:]); lib.sync_bytes(s, v.oreg[:])
	lib.sync_int(s, &v.sr); lib.sync_int(s, &v.sf); lib.sync_int(s, &v.bus_buffer)

	lib.sync_int(s, &v.pending_command)
	lib.sync_bool(s, &v.ib_wait); lib.sync_bool(s, &v.ib_peripheral)

	lib.sync_bytes(s, v.rtc[:])
	lib.sync_int(s, &v.rtc_ticks)
	lib.sync_bytes(s, v.save_mem[:])
	lib.sync_int(s, &v.area)

	lib.sync_bool(s, &v.clock_352); lib.sync_bool(s, &v.sound_cpu_on); lib.sync_bool(s, &v.cd_on)
	lib.sync_bool(s, &v.slave_on); lib.sync_bool(s, &v.reset_nmi_enable)

	for &p in v.ports {
		lib.sync_int(s, &p.data_out); lib.sync_int(s, &p.data_dir)
		lib.sync_bool(s, &p.direct_mode); lib.sync_bool(s, &p.ex_latch)
		lib.sync_int(s, &p.bus_state)
	}
	lib.sync_ints(s, v.pad[:])
}

@(private = "file")
sync_scu :: proc "contextless" (s: ^lib.State, v: ^SCU) {
	lib.sync_int(s, &v.ist); lib.sync_int(s, &v.ims)
	lib.sync_int(s, &v.ilevel); lib.sync_int(s, &v.ivec)
	lib.sync_int(s, &v.ext_asserted)

	lib.sync_int(s, &v.t0c); lib.sync_int(s, &v.t1s); lib.sync_int(s, &v.t1md)
	lib.sync_int(s, &v.t0_counter)
	lib.sync_bool(s, &v.t0_met)

	for &d in v.dma {
		lib.sync_int(s, &d.read); lib.sync_int(s, &d.write); lib.sync_int(s, &d.count)
		lib.sync_int(s, &d.add); lib.sync_int(s, &d.enable); lib.sync_int(s, &d.mode)
	}

	lib.sync_int(s, &v.asr0); lib.sync_int(s, &v.asr1); lib.sync_int(s, &v.aref); lib.sync_int(s, &v.rsel)
	lib.sync_bool(s, &v.vb); lib.sync_bool(s, &v.hb)
}

@(private = "file")
sync_vdp1 :: proc "contextless" (s: ^lib.State, v: ^VDP1) {
	lib.sync_bytes(s, v.vram[:])
	for i in 0 ..< 2 { lib.sync_ints(s, v.fb[i][:]) }
	draw := u8(v.draw)
	lib.sync_int(s, &draw)
	if s.mode == .Load { v.draw = int(draw) } // range-checked in `valid`

	lib.sync_int(s, &v.tvmr); lib.sync_int(s, &v.fbcr); lib.sync_int(s, &v.ptmr)
	lib.sync_int(s, &v.ewdr); lib.sync_int(s, &v.ewlr); lib.sync_int(s, &v.ewrr)
	lib.sync_int(s, &v.edsr); lib.sync_int(s, &v.lopr); lib.sync_int(s, &v.copr)
	lib.sync_bool(s, &v.manual_pending); lib.sync_bool(s, &v.end_int_pending)

	lib.sync_int(s, &v.sys_x); lib.sync_int(s, &v.sys_y)
	lib.sync_int(s, &v.uc_x0); lib.sync_int(s, &v.uc_y0); lib.sync_int(s, &v.uc_x1); lib.sync_int(s, &v.uc_y1)
	lib.sync_int(s, &v.loc_x); lib.sync_int(s, &v.loc_y)
}

@(private = "file")
sync_vdp2 :: proc "contextless" (s: ^lib.State, v: ^VDP2) {
	lib.sync_bytes(s, v.vram[:])
	lib.sync_bytes(s, v.cram[:])
	lib.sync_ints(s, v.regs[:])

	lib.sync_bool(s, &v.vblank); lib.sync_bool(s, &v.hblank); lib.sync_bool(s, &v.odd)
	lib.sync_int(s, &v.vcount); lib.sync_int(s, &v.hcnt_latch)
	lib.sync_int(s, &v.width); lib.sync_int(s, &v.height)
	// `pix` is the picture drawn from all of the above; the next frame redraws it.
}

@(private = "file")
sync_cdb :: proc "contextless" (s: ^lib.State, v: ^CDB) {
	// `disc` is the host's and stays as it is. `user_off` and `ip` describe the
	// disc, and `valid` insists they match the one in the drive.
	lib.sync_int(s, &v.user_off)
	lib.sync_bytes(s, v.ip[:])

	lib.sync_int(s, &v.hirq); lib.sync_int(s, &v.hirq_mask)
	lib.sync_ints(s, v.cr[:]); lib.sync_ints(s, v.res[:])
	lib.sync_int(s, &v.status); lib.sync_int(s, &v.cur_fad)
	lib.sync_bool(s, &v.results_read)
	lib.sync_int(s, &v.auth_type)

	lib.sync_int(s, &v.play_end); lib.sync_int(s, &v.line_count); lib.sync_int(s, &v.periodic)
	lib.sync_bool(s, &v.stalled)

	for &b in v.buffers {
		lib.sync_bytes(s, b.data[:])
		lib.sync_int(s, &b.part); lib.sync_int(s, &b.fad); lib.sync_int(s, &b.order)
	}
	for &f in v.filters {
		lib.sync_int(s, &f.start); lib.sync_int(s, &f.count)
		lib.sync_int(s, &f.mode); lib.sync_int(s, &f.channel); lib.sync_int(s, &f.file)
		lib.sync_int(s, &f.submode); lib.sync_int(s, &f.submode_mask)
		lib.sync_int(s, &f.cinfo); lib.sync_int(s, &f.cinfo_mask)
		lib.sync_int(s, &f.true_out); lib.sync_int(s, &f.false_out)
	}
	lib.sync_int(s, &v.cd_filter); lib.sync_int(s, &v.last_dest)
	for i in 0 ..< CDDA_RING { lib.sync_ints(s, v.cdda[i][:]) }
	lib.sync_int(s, &v.cdda_r); lib.sync_int(s, &v.cdda_n)
	lib.sync_int(s, &v.fs_spos); lib.sync_int(s, &v.fs_part); lib.sync_int(s, &v.fs_fad)
	lib.sync_int(s, &v.get_len); lib.sync_int(s, &v.put_len)
	lib.sync_int(s, &v.order)

	lib.sync_int(s, &v.dt_kind)
	lib.sync_int(s, &v.dt_pos); lib.sync_int(s, &v.dt_words)
	lib.sync_bytes(s, v.dt_list[:])
	lib.sync_int(s, &v.dt_count)
	lib.sync_bool(s, &v.dt_delete)
	lib.sync_int(s, &v.dt_total)

	for &f in v.files {
		lib.sync_int(s, &f.fad); lib.sync_int(s, &f.size)
		lib.sync_int(s, &f.unit); lib.sync_int(s, &f.gap); lib.sync_int(s, &f.num); lib.sync_int(s, &f.attr)
		lib.sync_bool(s, &f.is_dir)
		lib.sync_int(s, &f.lba)
	}
	lib.sync_int(s, &v.file_count)
	lib.sync_bool(s, &v.fs_loaded)
}

// --------------------------------------------------------- the machine ----

// A state made under another BIOS holds that BIOS's code and data in work RAM;
// resuming it under this one would crash in ways that look like emulator bugs.
bios_hash :: proc "contextless" (m: ^Saturn) -> u32 {
	h := u32(0x811C_9DC5) // FNV-1a
	for b in m.bios { h = (h ~ u32(b)) * 0x0100_0193 }
	return h
}

@(private = "file")
sync_machine :: proc "contextless" (s: ^lib.State, m: ^Saturn, bios: u32) {
	magic, version, hash := STATE_MAGIC, STATE_VERSION, bios
	lib.sync_int(s, &magic); lib.sync_int(s, &version); lib.sync_int(s, &hash)
	if s.mode == .Load && (magic != STATE_MAGIC || version != STATE_VERSION || hash != bios) {
		s.ok = false
		if magic != STATE_MAGIC || version != STATE_VERSION {
			reject_why = "not a Saturn state of this version"
		} else {
			reject_why = "it was saved with a different BIOS"
		}
		return
	}

	lib.sync_int(s, &m.frame); lib.sync_int(s, &m.line_start)
	lib.sync_f64(s, &m.audio_frac)
	lib.sync_int(s, &m.out_w); lib.sync_int(s, &m.out_h)
	lib.sync_int(s, &m.illegal_logged)

	sync_sh2(s, &m.cpu[0]); sync_sh2(s, &m.cpu[1])
	lib.sync_bytes(s, m.wram_l[:]); lib.sync_bytes(s, m.wram_h[:])
	sync_smpc(s, &m.smpc)
	sync_scu(s, &m.scu)
	sync_vdp1(s, &m.vdp1)
	sync_vdp2(s, &m.vdp2)
	sync_scsp(s, &m.scsp)
	sync_cdb(s, &m.cdb)
}

// ------------------------------------------------------------ validation ---

@(private = "file")
near :: #force_inline proc "contextless" (a, b: i64) -> bool {
	d := a - b
	return d >= -CLOCK_SLACK && d <= CLOCK_SLACK
}

// `base` is a lazy timer's last exact cycle, `now` its CPU's clock.
@(private = "file")
lagging :: #force_inline proc "contextless" (base, now: i64) -> bool {
	d := now - base
	return d >= -CLOCK_SLACK && d <= TIMER_LAG_MAX
}

@(private = "file")
valid_cpu :: proc "contextless" (c: ^SH2, slave: bool, now: i64) -> bool {
	if c.is_slave != slave { return bad() }
	if c.sr & ~u32(SR_MASK) != 0 { return bad() }
	if c.ext_level > 15 || c.irq_level > 15 || u8(c.irq_src) > u8(Irq_Source.FRT_OVI) { return bad() }
	// The clocks drive catch-up loops: a state may not put one a lifetime behind.
	if !near(c.cycles, now) { return bad() }
	if !lagging(c.oc.frt_base, c.cycles) { return bad() }
	if !lagging(c.oc.wdt_base, c.cycles) { return bad() }
	return true
}

@(private = "file")
valid_cdb :: proc "contextless" (c: ^CDB, live: ^CDB) -> bool {
	// Same disc as the one in the drive.
	same := c.user_off == live.user_off
	for i in 0 ..< len(c.ip) { if c.ip[i] != live.ip[i] { same = false } }
	if !same {
		reject_why, reject_line = "it was saved with a different disc", 0
		return false
	}

	if c.get_len != 2048 && c.get_len != 2336 && c.get_len != 2340 && c.get_len != 2352 { return bad() }
	if c.put_len != 2048 && c.put_len != 2336 && c.put_len != 2340 && c.put_len != 2352 { return bad() }
	if c.cd_filter != 0xFF && c.cd_filter >= NUM_FILTERS { return bad() }
	if c.cdda_r >= CDDA_RING || c.cdda_n > CDDA_RING { return bad() }
	if c.file_count > len(c.files) || c.dt_count > NUM_BUFFERS || c.dt_kind > 3 { return bad() }

	// The transfer in progress reads through these, word by word.
	switch c.dt_kind {
	case 2:
		for i in 0 ..< int(c.dt_count) { if c.dt_list[i] >= NUM_BUFFERS { return bad() } }
		if c.dt_words > c.dt_count * (c.get_len / 2) { return bad() }
	case 3:
		if c.dt_words > 6 * len(c.files) { return bad() }
	}
	return true
}

// Everything in a parsed state that indexes memory or bounds a loop.
@(private = "file")
valid :: proc "contextless" (m: ^Saturn, live: ^Saturn) -> bool {
	if m.line_start < 0 { return bad() }
	if m.out_w == 0 || m.out_w > SCREEN_MAX_W || m.out_h == 0 || m.out_h > SCREEN_MAX_H { return bad() }
	if !(m.audio_frac >= 0 && m.audio_frac < 16) { return bad() } // also rejects NaN

	if !valid_cpu(&m.cpu[0], false, m.line_start) || !valid_cpu(&m.cpu[1], true, m.line_start) { return false } // it said why

	if m.smpc.pending_command < -1 || m.smpc.pending_command > 0xFF { return bad() }
	if m.scu.ilevel > 15 { return bad() }
	if m.vdp1.draw > 1 { return bad() }
	if m.vdp2.width > SCREEN_MAX_W || m.vdp2.height > SCREEN_MAX_H || m.vdp2.vcount > 1023 { return bad() }

	c := &m.scsp
	if c.cpu.sr & ~u32(M68K_SR_MASK) != 0 || c.cpu.ipl > 7 { return bad() }
	if c.mslc > 31 { return bad() }
	for sl in c.slots { if sl.env_phase > 3 || sl.env_level > 0x3FF { return bad() } }
	for t in c.timers { if t.ctl > 7 || t.reload < -1 { return bad() } }
	if c.sample_acc >= SCSP_MASTER_HZ || c.cpu_acc >= SCSP_MASTER_HZ { return bad() }
	if !near(c.cpu_target, c.cpu.cycles) { return bad() }

	return valid_cdb(&m.cdb, &live.cdb)
}

// After a state has been applied: what was never in it, set right again.
@(private = "file")
rewire :: proc "contextless" (s: ^Saturn) {
	for i in 0 ..< 2 {
		c := &s.cpu[i]
		c.s = s
		c.ext_ack = scu_vector_fetch
		c.trace_on, c.trace_n = false, 0
		c.vec_count = {}
		c.io_hist = {}
	}
	s.scsp.cpu.bus = {ctx = s, read = scsp_bus_read, write = scsp_bus_write}
	s.diag.tracing, s.diag.stall = false, false
	s.audio_frames = 0 // the last frame's audio is not part of a state
}

// ------------------------------------------------------------ entry points -

state_size :: proc "contextless" (s: ^Saturn) -> uint {
	c := lib.state_count()
	sync_machine(&c, s, bios_hash(s))
	return uint(c.pos)
}

save_state :: proc "contextless" (s: ^Saturn, buf: []byte) -> bool {
	if !s.bios_loaded {
		reject_why, reject_line = "no BIOS is loaded", 0
		return false
	}
	need := int(state_size(s))
	if len(buf) < need {
		reject_why, reject_line = "the buffer is too small", 0
		return false
	}
	w := lib.state_save(buf[:need])
	sync_machine(&w, s, bios_hash(s))
	return lib.state_finished(&w)
}

// For tools only (tools/saturn_probe), not part of the core interface: loads the machine
// contents of a state without requiring the BIOS it was saved with, by taking the BIOS
// hash from the file's own header. Nothing is checked beyond the framing, so use it on
// states you trust; load_state, which the player uses, is unchanged.
state_inspect :: proc "contextless" (s: ^Saturn, buf: []byte) -> bool {
	if len(buf) < 12 { return false }
	hash := u32(buf[8]) | u32(buf[9]) << 8 | u32(buf[10]) << 16 | u32(buf[11]) << 24
	r := lib.state_load(buf)
	sync_machine(&r, s, hash)
	return lib.state_finished(&r)
}

load_state :: proc "contextless" (s: ^Saturn, buf: []byte) -> bool {
	reject_why, reject_line = "", 0
	if !s.bios_loaded {
		reject_why = "no BIOS is loaded"
		return false
	}
	bios := bios_hash(s)

	// 1. Parse into the staging machine and check it. The live one is untouched.
	intrinsics.mem_zero(&staged, size_of(Saturn))
	r := lib.state_load(buf)
	sync_machine(&r, &staged, bios)
	if !lib.state_finished(&r) {
		if reject_why == "" { reject_why = "the file is the wrong size (cut short, or from another build)" }
		return false
	}
	if !valid(&staged, s) { return false }

	// 2. It is good: read the same bytes again, this time into the machine.
	a := lib.state_load(buf)
	sync_machine(&a, s, bios)
	if !lib.state_finished(&a) { // cannot happen: same bytes, same code
		reject_why = "internal error applying a checked state"
		return false
	}
	rewire(s)
	return true
}
