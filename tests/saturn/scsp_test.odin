package saturn_tests

// SCSP: the register-level contract the BIOS sound driver relies on, with a
// real 68000 program running from sound RAM.

import sat "../../core"
import "core:testing"

snd_put_words :: proc(s: ^sat.Saturn, at: u32, words: ..u16) {
	for w, i in words {
		s.scsp.ram[at + u32(i) * 2] = u8(w >> 8)
		s.scsp.ram[at + u32(i) * 2 + 1] = u8(w + 0)
	}
}

snd_put_long :: proc(s: ^sat.Saturn, at: u32, v: u32) {
	snd_put_words(s, at, u16(v >> 16), u16(v))
}

lines :: proc(s: ^sat.Saturn, n: int) {
	for _ in 0 ..< n { sat.scsp_line(s, 1820) }
}

new_saturn :: proc() -> ^sat.Saturn {
	s := new(sat.Saturn)
	sat.scsp_reset(s)
	return s
}

// The exact shape of the stall seen on a real BIOS: the SH-2 leaves 08 in sound
// RAM byte 0x700 and polls it until the 68000 driver clears it.
@(test)
scsp_sound_driver_handshake_through_sound_ram :: proc(t: ^testing.T) {
	s := new_saturn()
	defer free(s)
	snd_put_long(s, 0, 0x1000) // SSP
	snd_put_long(s, 4, 0x400) // PC
	snd_put_words(s, 0x400, 0x4238, 0x0700, 0x60FE) // clr.b ($700).w ; bra *
	s.scsp.ram[0x700] = 0x08

	lines(s, 5) // held in reset until SNDON
	testing.expect_value(t, s.scsp.ram[0x700], 8)

	sat.scsp_sound_cpu(s, true)
	lines(s, 1)
	testing.expect_value(t, s.scsp.ram[0x700], 0)

	// SNDOFF resets and halts it again.
	sat.scsp_sound_cpu(s, false)
	s.scsp.ram[0x700] = 8
	lines(s, 5)
	testing.expect_value(t, s.scsp.ram[0x700], 8)
}

@(test)
scsp_registers_are_visible_to_both_cpus :: proc(t: ^testing.T) {
	s := new_saturn()
	defer free(s)
	// SH-2 style 16-bit write of a plain register, read back by the 68000 bus.
	sat.scsp_reg_write16(s, 0x400, 0x1234)
	testing.expect_value(t, sat.scsp_bus_read(s, 0x100400, 2), 0x1234)
	sat.scsp_bus_write(s, 0x100402, 1, 0xAB)
	testing.expect_value(t, sat.scsp_reg_read16(s, 0x402), 0xAB00)

	// Interrupt enable round trip (SCIEB keeps 11 bits).
	sat.scsp_reg_write16(s, 0x41E, 0xFFFF)
	testing.expect_value(t, sat.scsp_reg_read16(s, 0x41E), 0x07FF)
}

// Timer A with a prescale of 1 sample overflows after (0xFF - reload) samples;
// its interrupt reaches the 68000 at the level programmed in SCILV.
@(test)
scsp_timer_interrupts_the_sound_cpu :: proc(t: ^testing.T) {
	s := new_saturn()
	defer free(s)
	snd_put_long(s, 0, 0x1000)
	snd_put_long(s, 4, 0x400)
	snd_put_long(s, (24 + 4) * 4, 0x500) // level 4 handler
	snd_put_words(
		s, 0x400,
		0x46FC, 0x2000, // move #$2000,sr
		0x4E72, 0x2000, // stop #$2000
		0x60FE,
	)
	snd_put_words(
		s, 0x500,
		0x11FC, 0x0001, 0x0710, // move.b #1,($710).w
		0x33FC, 0x0040, 0x0010, 0x0422, // move.w #$40,$100422  (SCIRE: acknowledge timer A)
		0x4E73, // rte
	)
	sat.scsp_reg_write16(s, 0x418, 0x00F0) // timer A: ctl 0, reload F0
	sat.scsp_reg_write16(s, 0x41E, 0x0040) // enable timer A
	sat.scsp_reg_write16(s, 0x428, 0x0040) // SCILV2 bit 6 -> level 4
	sat.scsp_sound_cpu(s, true)

	lines(s, 2)
	testing.expect_value(t, s.scsp.ram[0x710], 0) // not yet: ~16 samples to go
	lines(s, 10)
	testing.expect_value(t, s.scsp.ram[0x710], 1)
	testing.expect_value(t, s.scsp.scipd & 0x40, 0) // handler acknowledged it
}

// The 68000 raising an interrupt for the SH-2 (MCIPD bit 5 with MCIEB enabled)
// asserts the SCU's sound-request interrupt.
@(test)
scsp_sound_cpu_can_interrupt_the_main_cpu :: proc(t: ^testing.T) {
	s := new_saturn()
	defer free(s)
	snd_put_long(s, 0, 0x1000)
	snd_put_long(s, 4, 0x400)
	snd_put_words(s, 0x400, 0x33FC, 0x0020, 0x0010, 0x042C, 0x60FE) // move.w #$20,$10042C
	sat.scsp_reg_write16(s, 0x42A, 0x0020) // MCIEB: enable CPU interrupt
	sat.scsp_sound_cpu(s, true)
	testing.expect_value(t, s.scu.ilevel, 0)
	lines(s, 1)
	// Unmasked, so the SCU presents it at once: sound request is level 9, vector 0x46.
	testing.expect_value(t, s.scu.ilevel, 9)
	testing.expect_value(t, s.scu.ivec, 0x46)
}

// And the other direction: the SH-2 writes SCIPD bit 5 to ring the 68000.
@(test)
scsp_main_cpu_can_interrupt_the_sound_cpu :: proc(t: ^testing.T) {
	s := new_saturn()
	defer free(s)
	snd_put_long(s, 0, 0x1000)
	snd_put_long(s, 4, 0x400)
	snd_put_long(s, (24 + 2) * 4, 0x500) // level 2
	snd_put_words(s, 0x400, 0x46FC, 0x2000, 0x4E72, 0x2000, 0x60FE)
	snd_put_words(s, 0x500, 0x11FC, 0x0001, 0x0711, 0x60FE)
	sat.scsp_reg_write16(s, 0x41E, 0x0020) // SCIEB bit 5
	sat.scsp_reg_write16(s, 0x426, 0x0020) // SCILV1 bit 5 -> level 2
	sat.scsp_sound_cpu(s, true)
	lines(s, 2)
	testing.expect_value(t, s.scsp.ram[0x711], 0)
	sat.scsp_reg_write16(s, 0x420, 0x0020) // SH-2 sets the pending bit
	lines(s, 1)
	testing.expect_value(t, s.scsp.ram[0x711], 1)
}
