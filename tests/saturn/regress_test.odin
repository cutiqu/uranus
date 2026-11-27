package saturn_tests

// Regressions found by comparing the core with Mednafen/Yabause against a real
// BIOS log (see SATURN_BRINGUP.md, "Slave CPU and VDP1 frame change").

import "core:testing"
import sat "../../core"

// BCR1 bit 15 (MASTER) is strapped low on the master SH-2 and high on the slave.
// The BIOS reset code reads it to tell the CPUs apart; a slave that reads 0 runs
// the whole master boot again (SSHON then restarts the machine).
@(test)
bcr1_master_bit :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	sat.sh2_reset(&s.cpu[0], s, false)
	sat.sh2_reset(&s.cpu[1], s, true)

	m := sat.sh2_read32(&s.cpu[0], 0xFFFFFFE0)
	sl := sat.sh2_read32(&s.cpu[1], 0xFFFFFFE0)
	testing.expect_value(t, m & 0xFFFF, 0x0000)
	testing.expect_value(t, sl & 0xFFFF, 0x8000)

	// Software cannot change the pin, only the other bits (keyed write, as the BIOS does).
	sat.sh2_write32(&s.cpu[0], 0xFFFFFFE0, 0xA55A_83F1)
	sat.sh2_write32(&s.cpu[1], 0xFFFFFFE0, 0xA55A_03F1)
	testing.expect_value(t, sat.sh2_read32(&s.cpu[0], 0xFFFFFFE0) & 0xFFFF, 0x03F1)
	testing.expect_value(t, sat.sh2_read32(&s.cpu[1], 0xFFFFFFE0) & 0xFFFF, 0x83F1)

	// The 16-bit view at +2 (where Yabause and real code read it) agrees.
	testing.expect_value(t, sat.sh2_read16(&s.cpu[1], 0xFFFFFFE2), 0x83F1)
}

// SSHON resets the slave from the same BIOS vector; it must come back as a slave.
@(test)
sshon_slave_keeps_pin :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	sat.sh2_reset(&s.cpu[1], s, true)
	sat.sh2_write32(&s.cpu[1], 0xFFFFFFE0, 0xA55A_03F0)
	sat.sh2_reset(&s.cpu[1], s, true) // what SMPC SSHON does
	testing.expect_value(t, sat.sh2_read16(&s.cpu[1], 0xFFFFFFE2), 0x8000)
}

// FBCR: bit 0 = FCT (change trigger), bit 1 = FCM (manual mode). They were swapped.
@(test)
vdp1_fbcr_decode :: proc(t: ^testing.T) {
	v := new(sat.VDP1)
	defer free(v)

	// FCM=0 (1-cycle mode): swaps every frame whatever FCT says.
	for fbcr in ([2]u16{0, 1}) {
		sat.vdp1_reset(v)
		v.fbcr = fbcr
		sat.vdp1_frame_change(v)
		testing.expect_value(t, v.draw, 1)
		sat.vdp1_frame_change(v)
		testing.expect_value(t, v.draw, 0)
	}

	// FCM=1, FCT=0 (manual erase): never swaps.
	sat.vdp1_reset(v)
	v.fbcr = 2
	v.manual_pending = true
	sat.vdp1_frame_change(v)
	testing.expect_value(t, v.draw, 0)

	// FCM=1, FCT=1 (manual change): swaps only when a change was requested.
	sat.vdp1_reset(v)
	v.fbcr = 3
	sat.vdp1_frame_change(v)
	testing.expect_value(t, v.draw, 0)
	v.manual_pending = true
	sat.vdp1_frame_change(v)
	testing.expect_value(t, v.draw, 1)
}

// A fresh console's backup RAM carries the "BackUpRam Format" header; a blank
// saved copy (what earlier runs wrote back) is formatted, real data is not touched.
@(test)
backup_ram_is_formatted :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	sat.backup_format(s)
	for i in 0 ..< 0x40 { testing.expect_value(t, s.backup[i], sat.BRAM_HEADER[i & 15]) }
	testing.expect_value(t, s.backup[0x40], 0)

	// Host loads an all-zero .sav over it.
	for i in 0 ..< len(s.backup) { s.backup[i] = 0 }
	sat.backup_ensure_formatted(s)
	testing.expect_value(t, s.backup[0], 'B')

	// Existing, non-blank data (even unformatted) is left alone.
	for i in 0 ..< len(s.backup) { s.backup[i] = 0 }
	s.backup[100] = 0x55
	sat.backup_ensure_formatted(s)
	testing.expect_value(t, s.backup[0], 0)
	testing.expect_value(t, s.backup[100], 0x55)
}

// MINIT/SINIT pulse the other CPU's FTI pin on word and long writes, not on byte
// writes (verified on hardware by Mednafen).
@(test)
minit_sinit_write_widths :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	sat.sh2_reset(&s.cpu[0], s, false)
	sat.sh2_reset(&s.cpu[1], s, true)

	s.cpu[1].oc.ftcsr = 0
	sat.mem_write8(s, 0x01000000, 0xFF)
	testing.expect(t, s.cpu[1].oc.ftcsr & 0x80 == 0) // byte: nothing

	s.cpu[1].oc.ftcsr = 0
	sat.mem_write16(s, 0x01000000, 0xFFFF)
	testing.expect(t, s.cpu[1].oc.ftcsr & 0x80 != 0) // word: ICF on the slave

	s.cpu[1].oc.ftcsr = 0
	sat.mem_write32(s, 0x01000000, 0xFFFFFFFF)
	testing.expect(t, s.cpu[1].oc.ftcsr & 0x80 != 0) // long

	s.cpu[0].oc.ftcsr = 0
	sat.mem_write16(s, 0x01800000, 0xFFFF)
	testing.expect(t, s.cpu[0].oc.ftcsr & 0x80 != 0) // SINIT pulses the master
}

// SCSP: a keyed-on slot's position advances at its pitch, loops, and is visible to
// a driver through the monitor register (0x408). Audio streaming drivers poll it
// to know when to refill their buffer; with it frozen an audio/video stream stalls.
@(private = "file")
scsp_run_samples :: proc(s: ^sat.Saturn, n: u64) {
	sat.scsp_line(s, u64(28_636_363) * n / 44100)
}

@(test)
scsp_slot_position_monitor :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	sat.scsp_reset(s)
	s.scsp.cpu.halted = true // no sound CPU in this test

	sat.scsp_reg_write16(s, 0x04, 0)      // LSA
	sat.scsp_reg_write16(s, 0x06, 0x4000) // LEA
	sat.scsp_reg_write16(s, 0x10, 0)      // OCT 0, FNS 0: one sample per tick
	sat.scsp_reg_write16(s, 0x408, 0)     // monitor slot 0

	// Idle slots read as released and silent.
	testing.expect_value(t, sat.scsp_reg_read16(s, 0x408), 0x007F)

	sat.scsp_reg_write16(s, 0x00, 0x1820) // KYONEX | KYONB | loop mode 1
	scsp_run_samples(s, 10000)
	ca := sat.scsp_reg_read16(s, 0x408)
	testing.expect_value(t, (ca >> 7) & 0xF, 2) // 10000 >> 12
	testing.expect_value(t, (ca >> 5) & 3, 0)   // attack (rate 0: it never gets further)

	// It keeps moving and stays inside the loop.
	seen: [8]bool
	for _ in 0 ..< 40 {
		scsp_run_samples(s, 2000)
		pos := (sat.scsp_reg_read16(s, 0x408) >> 7) & 0xF
		testing.expect(t, pos <= 4)
		seen[pos & 7] = true
	}
	testing.expect(t, seen[0] && seen[1] && seen[2] && seen[3]) // it wrapped around

	// Key off (taken at the next sample): release phase.
	sat.scsp_reg_write16(s, 0x00, 0x1000)
	scsp_run_samples(s, 2)
	testing.expect_value(t, (sat.scsp_reg_read16(s, 0x408) >> 5) & 3, 3)

	// Pitch: an octave up runs twice as fast.
	sat.scsp_reg_write16(s, 0x10, 1 << 11) // OCT = +1
	sat.scsp_reg_write16(s, 0x06, 0xFFFF)  // loop end out of the way
	sat.scsp_reg_write16(s, 0x00, 0x1820)
	scsp_run_samples(s, 10000)
	testing.expect_value(t, (sat.scsp_reg_read16(s, 0x408) >> 7) & 0xF, 4) // 20000 >> 12

	// Monitoring another slot reports that slot.
	sat.scsp_reg_write16(s, 0x408, 5 << 11)
	testing.expect_value(t, sat.scsp_reg_read16(s, 0x408), 0x007F)
}

// A PCM16 loop in sound RAM comes out of the mixer at the programmed level, on
// both channels for a centred pan, scaled by the master volume.
@(test)
scsp_plays_a_sample :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	sat.scsp_reset(s)
	s.scsp.cpu.halted = true

	for i in 0 ..< 0x100 { // 128 samples of 0x4000, big-endian
		s.scsp.ram[0x1000 + i] = 0x40 if i & 1 == 0 else 0x00
	}
	sat.scsp_reg_write16(s, 0x400, 0x000F) // master volume: max
	sat.scsp_reg_write16(s, 0x02, 0x1000)  // start address
	sat.scsp_reg_write16(s, 0x04, 0)       // loop start
	sat.scsp_reg_write16(s, 0x06, 0x0080)  // loop end: 128 samples
	sat.scsp_reg_write16(s, 0x08, 0x001F)  // AR 31: fastest attack
	sat.scsp_reg_write16(s, 0x0A, 0)       // DL 0 .. RR 0
	sat.scsp_reg_write16(s, 0x0C, 0)       // TL 0
	sat.scsp_reg_write16(s, 0x10, 0)       // pitch: one sample per tick
	sat.scsp_reg_write16(s, 0x16, 0xE000)  // DISDL 7, centred, no effect send
	sat.scsp_reg_write16(s, 0x00, 0x1820)  // KYONEX | KYONB | loop

	scsp_run_samples(s, 790)
	testing.expect(t, s.audio_frames > 700)
	l, r := s.audio[2 * 700], s.audio[2 * 700 + 1]
	testing.expect_value(t, l, r)
	testing.expect(t, l > 15000 && l < 16400) // 0x4000 at full level and volume

	// Key off and let the release run out: silence.
	sat.scsp_reg_write16(s, 0x0A, 0x001F) // RR 31
	sat.scsp_reg_write16(s, 0x00, 0x1000)
	s.audio_frames = 0
	scsp_run_samples(s, 790)
	testing.expect_value(t, s.audio[2 * 700], 0)
}

// CD audio reaches the output through the effect send of slots 16 (left input)
// and 17 (right input), each panned as programmed.
@(test)
scsp_mixes_cd_audio :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	sat.scsp_reset(s)
	s.scsp.cpu.halted = true
	for i in 0 ..< sat.CDDA_RING { s.cdb.cdda[i] = {1000, -2000} }
	s.cdb.cdda_n = sat.CDDA_RING

	sat.scsp_reg_write16(s, 0x400, 0x000F)
	sat.scsp_reg_write16(s, 0x216, 0x00FF) // slot 16: EFSDL 7, EFPAN hard left
	sat.scsp_reg_write16(s, 0x236, 0x00EF) // slot 17: EFSDL 7, EFPAN hard right
	scsp_run_samples(s, 200)
	testing.expect_value(t, s.audio[2 * 100], 1000)
	testing.expect_value(t, s.audio[2 * 100 + 1], -2000)

	// With the FIFO empty the input is silence, not a repeat.
	s.cdb.cdda_n = 0
	s.audio_frames = 0
	scsp_run_samples(s, 200)
	testing.expect_value(t, s.audio[2 * 100], 0)
}
