// The SMPC (System Manager & Peripheral Control): a small microcontroller that
// powers the other chips on and off, keeps the clock, and reads the pads.
//
// Software talks to it through byte registers at the odd addresses of
// 0x00100000-0x0010007F: write the IREGs, set SF=1, write a command to COMREG,
// then wait for SF to clear (or the SMPC interrupt). Commands here complete at
// the next scanline boundary rather than after their real microsecond-scale
// latencies, which is fast enough for software and slow enough to be async.
package saturn_core

SMPC_CMD_MSHON    :: 0x00
SMPC_CMD_SSHON    :: 0x02
SMPC_CMD_SSHOFF   :: 0x03
SMPC_CMD_SNDON    :: 0x06
SMPC_CMD_SNDOFF   :: 0x07
SMPC_CMD_CDON     :: 0x08
SMPC_CMD_CDOFF    :: 0x09
SMPC_CMD_SYSRES   :: 0x0D
SMPC_CMD_CKCHG352 :: 0x0E
SMPC_CMD_CKCHG320 :: 0x0F
SMPC_CMD_INTBACK  :: 0x10
SMPC_CMD_SETTIME  :: 0x16
SMPC_CMD_SETSMEM  :: 0x17
SMPC_CMD_NMIREQ   :: 0x18
SMPC_CMD_RESENAB  :: 0x19
SMPC_CMD_RESDISA  :: 0x1A

SMPC_SR_RESB :: 0x10
SMPC_SR_NPE  :: 0x20
SMPC_SR_PDL  :: 0x40

// Area codes reported to software (and checked by games against the disc).
AREA_JAPAN  :: 0x01
AREA_NA     :: 0x04
AREA_EUROPE :: 0x0C

SMPC_Port :: struct {
	data_out, data_dir: u8,
	direct_mode:        bool,
	ex_latch:           bool,
	bus_state:          u8,
}

SMPC :: struct {
	ireg:   [7]u8,
	oreg:   [0x20]u8,
	sr, sf: u8,
	bus_buffer: u8,

	pending_command: i32, // -1 = none
	ib_wait:         bool, // INTBACK status sent, waiting for CONTINUE/BREAK
	ib_peripheral:   bool, // INTBACK peripheral phase scheduled

	rtc:      [7]u8, // BCD: year hi/lo, weekday<<4|month, day, hour, min, sec
	rtc_ticks: u32,
	save_mem:  [4]u8,
	area:      u8,

	clock_352:      bool,
	sound_cpu_on:   bool,
	cd_on:          bool,
	slave_on:       bool,
	reset_nmi_enable: bool,

	ports: [2]SMPC_Port,
	pad:   [2]u16, // bits as in Mednafen's gamepad: 1 = pressed (see api_to_pad)
}

smpc_reset :: proc "contextless" (m: ^SMPC) {
	area := m.area if m.area != 0 else AREA_JAPAN
	m^ = {}
	m.area = area
	m.pending_command = -1
	m.cd_on = true
	m.rtc = {0x20, 0x26, 0x1A, 0x12, 0x12, 0x00, 0x00} // 2026-10-12, a Monday
}

// ------------------------------------------------------------- registers ---

// `reg` is the word index: (address & 0x7F) >> 1.
smpc_read :: proc "contextless" (s: ^Saturn, reg: u32) -> u8 {
	m := &s.smpc
	switch reg {
	case 0x10 ..= 0x2F: return m.oreg[reg - 0x10]
	case 0x30: return m.sr
	case 0x31: return m.sf
	case 0x3A: return m.ports[0].bus_state & 0x7F
	case 0x3B: return m.ports[1].bus_state & 0x7F
	case 0x3C: return m.ports[0].data_dir
	case 0x3D: return m.ports[1].data_dir
	case 0x3E: return u8(m.ports[0].direct_mode) | u8(m.ports[1].direct_mode) << 1
	case 0x3F: return u8(m.ports[0].ex_latch) | u8(m.ports[1].ex_latch) << 1
	}
	return m.bus_buffer
}

smpc_write :: proc "contextless" (s: ^Saturn, reg: u32, v: u8) {
	m := &s.smpc
	m.bus_buffer = v
	switch reg {
	case 0x00:
		m.ireg[0] = v
		// While an INTBACK is waiting for the host, IREG0 carries CONTINUE/BREAK.
		if m.ib_wait {
			if v & 0x40 != 0 {
				m.ib_wait, m.sf = false, 0
			} else if v & 0x80 != 0 {
				m.ib_wait, m.ib_peripheral = false, true
			}
		}
	case 0x01 ..= 0x06: m.ireg[reg] = v
	case 0x0F: m.pending_command = i32(v)
	case 0x31: m.sf = v & 1
	case 0x3A: m.ports[0].data_out = v & 0x7F; update_bus(m, 0)
	case 0x3B: m.ports[1].data_out = v & 0x7F; update_bus(m, 1)
	case 0x3C: m.ports[0].data_dir = v & 0x7F; update_bus(m, 0)
	case 0x3D: m.ports[1].data_dir = v & 0x7F; update_bus(m, 1)
	case 0x3E:
		m.ports[0].direct_mode, m.ports[1].direct_mode = v & 1 != 0, v & 2 != 0
		update_bus(m, 0); update_bus(m, 1)
	case 0x3F:
		m.ports[0].ex_latch, m.ports[1].ex_latch = v & 1 != 0, v & 2 != 0
	}
}

// What the pad drives onto the I/O lines in direct mode: TH/TR (bits 6,5 of
// the output) select which nibble of the button word is shown.
@(private = "file")
update_bus :: proc "contextless" (m: ^SMPC, port: int) {
	p := &m.ports[port]
	buttons := ~m.pad[port] // hardware reads buttons as 0 = pressed
	nibble := u8(buttons >> ((p.data_out >> 5) << 2)) & 0xF
	p.bus_state = 0x10 | (p.data_out & (p.data_dir | 0xE0)) | (nibble & ~p.data_dir)
}

// ------------------------------------------------------------- execution ---

// Called once per scanline.
smpc_update :: proc "contextless" (s: ^Saturn) {
	m := &s.smpc
	if m.ib_peripheral && !s.vdp2.vblank {
		m.ib_peripheral = false
		intback_peripheral(s)
		return
	}
	if m.pending_command < 0 { return }
	cmd := u8(m.pending_command)
	m.pending_command = -1
	m.oreg[0x1F] = cmd
	finished := true
	log_smpc_command(s, cmd)

	switch cmd {
	case SMPC_CMD_SSHON:
		c := s.cpu[1].cycles
		sh2_reset(&s.cpu[1], s, true)
		s.cpu[1].cycles = c
		m.slave_on = true
	case SMPC_CMD_SSHOFF:
		s.cpu[1].halted = true
		m.slave_on = false
	case SMPC_CMD_SNDON:
		m.sound_cpu_on = true
		scsp_sound_cpu(s, true)
	case SMPC_CMD_SNDOFF:
		m.sound_cpu_on = false
		scsp_sound_cpu(s, false)
	case SMPC_CMD_CDON:   m.cd_on = true
	case SMPC_CMD_CDOFF:  m.cd_on = false
	case SMPC_CMD_SYSRES: system_soft_reset(s)
	case SMPC_CMD_CKCHG352, SMPC_CMD_CKCHG320:
		// Switching the dot clock resets the video side and the slave CPU,
		// then interrupts the master with an NMI.
		m.clock_352 = cmd == SMPC_CMD_CKCHG352
		s.cpu[1].halted, m.slave_on = true, false
		vdp1_reset(&s.vdp1)
		vdp2_reset(&s.vdp2)
		scu_reset(s)
		s.cpu[0].nmi = true
	case SMPC_CMD_NMIREQ: s.cpu[0].nmi = true
	case SMPC_CMD_RESENAB: m.reset_nmi_enable = true
	case SMPC_CMD_RESDISA: m.reset_nmi_enable = false
	case SMPC_CMD_SETTIME: m.rtc = m.ireg
	case SMPC_CMD_SETSMEM: m.save_mem = {m.ireg[0], m.ireg[1], m.ireg[2], m.ireg[3]}
	case SMPC_CMD_INTBACK: finished = intback(s)
	}
	if finished { m.sf = 0 }
}

// Returns true when the command is complete (false: waiting for CONTINUE).
@(private = "file")
intback :: proc "contextless" (s: ^Saturn) -> bool {
	m := &s.smpc
	m.sr &= ~u8(SMPC_SR_NPE)
	if m.ireg[0] & 0xF != 0 { // system status report
		m.oreg[0] = 0x80 | (0x00 if m.reset_nmi_enable else 0x40)
		for i in 0 ..< 7 { m.oreg[1 + i] = m.rtc[i] }
		m.oreg[8] = 0 // cartridge code
		m.oreg[9] = m.area
		m.oreg[0xA] = 0x24 | 0x08 | 0x02 | (0x40 if m.clock_352 else 0) | (0x10 if m.slave_on else 0) | (1 if m.sound_cpu_on else 0)
		m.oreg[0xB] = (0x40 if m.cd_on else 0) | 0x02
		for i in 0 ..< 4 { m.oreg[0xC + i] = m.save_mem[i] }
		if m.ireg[1] & 8 != 0 { m.sr |= SMPC_SR_NPE }
		m.sr = (m.sr & ~u8(0x80)) | 0x0F
		scu_set_int(s, INT_SMPC)
		if m.ireg[1] & 8 != 0 {
			m.ib_wait = true
			return false
		}
		return true
	}
	if m.ireg[1] & 8 != 0 {
		m.ib_peripheral = true
		return false
	}
	return true
}

// Standard digital pad report. `p` has Mednafen's bit order (1 = pressed):
// 0 up, 1 down, 2 left, 3 right, 4 start, 5 A, 6 B, 7 C, 8 X, 9 Y, 10 Z, 11 L, 12 R.
@(private = "file")
pad_report :: proc "contextless" (p: u16) -> (d1, d2: u8) {
	b :: proc "contextless" (v: u16, bit: u32) -> u8 {return u8(~v >> bit) & 1} // 1 = released
	q := p
	d1 = b(q, 3) << 7 | b(q, 2) << 6 | b(q, 1) << 5 | b(q, 0) << 4 | b(q, 4) << 3 | b(q, 5) << 2 | b(q, 7) << 1 | b(q, 6)
	d2 = b(q, 12) << 7 | b(q, 8) << 6 | b(q, 9) << 5 | b(q, 10) << 4 | b(q, 11) << 3 | 0x7
	return
}

@(private = "file")
intback_peripheral :: proc "contextless" (s: ^Saturn) {
	m := &s.smpc
	mode0 := (m.ireg[1] >> 4) & 3
	mode1 := (m.ireg[1] >> 6) & 3
	o := 0
	for port in 0 ..< 2 {
		mode := mode0 if port == 0 else mode1
		if mode & 2 != 0 { continue } // port skipped
		d1, d2 := pad_report(m.pad[port])
		// 0xF1: no multitap, one device. 0x02: digital pad, two data bytes.
		m.oreg[o], m.oreg[o + 1], m.oreg[o + 2], m.oreg[o + 3] = 0xF1, 0x02, d1, d2
		o += 4
	}
	for o < 0x20 && o < 8 { m.oreg[o] = 0xFF; o += 1 }
	m.sr = (m.sr & ~u8(SMPC_SR_NPE | 0x0F)) | SMPC_SR_PDL | 0x80 | (mode0 & 3) | (mode1 & 3) << 2
	scu_set_int(s, INT_SMPC)
	m.sf = 0
}

// Once per VBlank: advance the clock (one second per 60 frames).
smpc_vblank :: proc "contextless" (s: ^Saturn) {
	m := &s.smpc
	m.rtc_ticks += 1
	if m.rtc_ticks >= 60 {
		m.rtc_ticks = 0
		rtc_second(m)
	}
}

@(private = "file")
bcd_inc :: proc "contextless" (v: u8) -> u8 {
	r := v + 1
	if r & 0xF > 9 { r += 6 }
	return r
}

@(private = "file")
rtc_second :: proc "contextless" (m: ^SMPC) {
	r := &m.rtc
	if r[6] = bcd_inc(r[6]); r[6] < 0x60 { return }
	r[6] = 0
	if r[5] = bcd_inc(r[5]); r[5] < 0x60 { return }
	r[5] = 0
	if r[4] = bcd_inc(r[4]); r[4] < 0x24 { return }
	r[4] = 0
	// New day: weekday cycles 0-6; month length is approximated as 31 days.
	wd := (r[2] >> 4) + 1
	if wd > 6 { wd = 0 }
	r[2] = wd << 4 | r[2] & 0xF
	if r[3] = bcd_inc(r[3]); r[3] < 0x32 { return }
	r[3] = 1
	mon := r[2] & 0xF + 1
	if mon > 12 {
		mon = 1
		if r[1] = bcd_inc(r[1]); r[1] == 0xA0 { r[1] = 0; r[0] = bcd_inc(r[0]) }
	}
	r[2] = r[2] & 0xF0 | mon
}

// One log line per SMPC command (SSHON, SNDON, INTBACK ...): whether the BIOS
// ever starts the slave CPU or the sound CPU is the first thing to look at when
// a boot stalls.
@(private = "file")
log_smpc_command :: proc "contextless" (s: ^Saturn, cmd: u8) {
	m := &s.smpc
	if diag_smpc_repeat(s, {cmd, m.ireg[0], m.ireg[1], m.ireg[2]}) { return }
	l: Log_Buf
	lb_str(&l, "smpc cmd=")
	lb_hex(&l, u32(cmd), 2)
	lb_str(&l, " ireg=")
	for i in 0 ..< 3 { lb_hex(&l, u32(m.ireg[i]), 2); lb_str(&l, " ") }
	lb_str(&l, "f=")
	lb_dec(&l, s.frame)
	log_flush(s, .Info, &l)
}
