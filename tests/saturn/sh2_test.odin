package saturn_tests

// SH-2 interpreter and on-chip peripheral checks. Each test assembles a few
// opcodes into work RAM and steps the CPU; these cover the instruction groups
// that were broken or missing in the first Saturn core.

import "core:testing"
import sat "../../core"

CODE :: 0x06000000

// Runs `ops` from CODE until the PC reaches the end of them (so a delayed
// branch's slot counts as part of its branch).
@(private = "file")
run :: proc(s: ^sat.Saturn, ops: []u16) {
	for op, i in ops { sat.mem_write16(s, CODE + u32(i * 2), op) }
	cpu := &s.cpu[0]
	cpu.pc = CODE
	cpu.sr = 0x0F0
	cpu.r[15] = 0x060FF000
	for steps := 0; cpu.pc != CODE + u32(len(ops) * 2) && steps < 1000; steps += 1 { sat.sh2_step(cpu) }
}

@(private = "file")
fresh :: proc() -> ^sat.Saturn {
	s := new(sat.Saturn)
	sat.sh2_reset(&s.cpu[0], s, false)
	return s
}

@(test)
post_increment_load :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	sat.mem_write32(s, 0x06000100, 0xCAFEF00D)
	s.cpu[0].r[2] = 0x06000100
	run(s, {0x6322}) // mov.l @r2,r3: no increment
	testing.expect_value(t, s.cpu[0].r[3], 0xCAFEF00D)
	testing.expect_value(t, s.cpu[0].r[2], 0x06000100)
	run(s, {0x6326}) // mov.l @r2+,r3
	testing.expect_value(t, s.cpu[0].r[2], 0x06000104)
}

@(test)
pr_push_pop :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	s.cpu[0].pr = 0xDEADBEE0
	// sts.l pr,@-r15 ; mov #0,r0 ; lds r0,pr ; lds.l @r15+,pr
	run(s, {0x4F22, 0xE000, 0x400A | 0x20, 0x4F26})
	testing.expect_value(t, s.cpu[0].pr, 0xDEADBEE0)
	testing.expect_value(t, s.cpu[0].r[15], 0x060FF000)
}

@(test)
bsr_rts_delay_slots :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	// 0: bsr 10  2: add #1,r1 (slot)  4: add #10,r1 (return lands here)
	// 6: bra 18  8: nop (slot)        10: add #100,r1 (subroutine)
	// 12: rts    14: nop (slot)       16: nop     18: end
	run(s, {0xB003, 0x7101, 0x710A, 0xA004, 0x0009, 0x7164, 0x000B, 0x0009, 0x0009})
	testing.expect_value(t, s.cpu[0].r[1], 111)
}

@(test)
conditional_branches :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	// sett ; bt +0 (skips the next op) ; add #1,r1 ; add #2,r1
	run(s, {0x0018, 0x8900, 0x7101, 0x7102})
	testing.expect_value(t, s.cpu[0].r[1], 2)
	s.cpu[0].r[1] = 0
	// clrt ; bf +0 ; add #1,r1 ; add #2,r1
	run(s, {0x0008, 0x8B00, 0x7101, 0x7102})
	testing.expect_value(t, s.cpu[0].r[1], 2)
}

@(test)
movt_and_compare :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	s.cpu[0].r[1], s.cpu[0].r[2] = 5, 5
	run(s, {0x3210, 0x0329}) // cmp/eq r1,r2 ; movt r3
	testing.expect_value(t, s.cpu[0].r[3], 1)
}

@(test)
displacement_byte_access :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	s.cpu[0].r[0] = 0xFFFFFF85
	s.cpu[0].r[1] = 0x06000200
	run(s, {0x8012}) // mov.b r0,@(2,r1)
	testing.expect_value(t, sat.mem_read8(s, 0x06000202), 0x85)
	s.cpu[0].r[0] = 0
	run(s, {0x8412}) // mov.b @(2,r1),r0: sign-extends
	testing.expect_value(t, s.cpu[0].r[0], 0xFFFFFF85)
}

@(test)
multiply_long :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	s.cpu[0].r[1], s.cpu[0].r[2] = 1000, 0xFFFFFFFD // -3
	run(s, {0x0217, 0x031A}) // mul.l r1,r2 ; sts macl,r3
	testing.expect_value(t, s.cpu[0].r[3], 0xFFFFF448) // -3000
	testing.expect_value(t, s.cpu[0].r[2], 0xFFFFFFFD) // Rn is untouched
}

@(test)
divider_unit :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	cpu := &s.cpu[0]
	sat.oc_write32(cpu, 0xFFFFFF00, 7)
	sat.oc_write32(cpu, 0xFFFFFF04, 100)
	testing.expect_value(t, sat.oc_read32(cpu, 0xFFFFFF14), 14)
	testing.expect_value(t, sat.oc_read32(cpu, 0xFFFFFF10), 2)
	sat.oc_write32(cpu, 0xFFFFFF04, 0xFFFFFF9C) // -100
	testing.expect_value(t, sat.oc_read32(cpu, 0xFFFFFF14), 0xFFFFFFF2) // -14
	testing.expect_value(t, sat.oc_read32(cpu, 0xFFFFFF10), 0xFFFFFFFE) // -2
	sat.oc_write32(cpu, 0xFFFFFF00, 0)
	sat.oc_write32(cpu, 0xFFFFFF04, 5)
	testing.expect_value(t, sat.oc_read32(cpu, 0xFFFFFF08) & 1, 1) // overflow flag
}

@(test)
free_running_timer :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	cpu := &s.cpu[0]
	sat.oc_write8(cpu, 0xFFFFFE16, 0) // TCR: phi/8
	cpu.cycles += 800
	testing.expect_value(t, sat.oc_read16(cpu, 0xFFFFFE12), 100)
}

@(test)
scu_masks_and_levels :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	sat.scu_reset(s)
	// Everything is masked at reset, so a pending VBlank-IN must not reach the CPU.
	sat.scu_set_int(s, sat.INT_VBLANK_IN)
	testing.expect_value(t, s.cpu[0].ext_level, 0)
	// Unmasking presents it at level 15 with vector 0x40. Accepting it must leave
	// IMS exactly as software wrote it (the SCU never masks on its own).
	sat.scu_write32(s, 0xA0, 0xBFFE)
	testing.expect_value(t, s.cpu[0].ext_level, 15)
	testing.expect_value(t, sat.scu_vector_fetch(s, false), 0x40)
	testing.expect_value(t, s.cpu[0].ext_level, 0)
	testing.expect_value(t, sat.scu_read32(s, 0xA0), 0xBFFE)
}

// A game that unmasks VBlank-IN once at boot and never touches IMS again must keep
// getting the interrupt. (Regression: the SCU used to force IMS to 0xBFFF on every
// accepted interrupt, so such a game saw one VBlank and then polled a flag forever.)
@(test)
scu_keeps_delivering_without_ims_rewrite :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	sat.scu_reset(s)
	sat.scu_write32(s, 0xA0, 0xBFFE)
	for _ in 0 ..< 5 {
		sat.scu_set_int(s, sat.INT_VBLANK_IN)
		testing.expect_value(t, s.cpu[0].ext_level, 15)
		testing.expect_value(t, sat.scu_vector_fetch(s, false), 0x40)
		testing.expect_value(t, sat.scu_read32(s, 0xA0), 0xBFFE)
	}
}

// An interrupt that becomes pending while another is outstanding must be presented
// once the CPU has accepted the first, without waiting for another SCU event or an
// IMS write. Driven through the real CPU path (take_interrupt).
@(test)
scu_reoffers_pending_after_accept :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	sat.scu_reset(s)
	sat.scu_write32(s, 0xA0, 0xBFFA) // unmask VBlank-IN (level 15) and HBlank-IN (level 13)
	cpu := &s.cpu[0]
	cpu.vbr = 0x06001000
	sat.mem_write32(s, cpu.vbr + 0x40 * 4, CODE + 0x100)
	sat.mem_write32(s, cpu.vbr + 0x42 * 4, CODE + 0x200)
	for i in 0 ..< 0x100 { sat.mem_write16(s, CODE + u32(i * 2), 0x0009) } // nop sled
	cpu.pc, cpu.sr, cpu.r[15] = CODE, 0, 0x060FF000
	sat.scu_set_int(s, sat.INT_VBLANK_IN) // offered at once
	sat.scu_set_int(s, sat.INT_HBLANK_IN) // arrives while VBlank-IN is outstanding
	testing.expect_value(t, cpu.ext_level, 15)
	sat.sh2_step(cpu) // the CPU takes VBlank-IN (vector 0x40)
	testing.expect_value(t, cpu.vec_count[0x40], 1)
	testing.expect_value(t, cpu.ext_level, 13) // HBlank-IN is now on the IRL lines, held by SR.I = 15
	cpu.sr &= ~u32(0xF0) // the handler returns (RTE restores SR)
	sat.sh2_step(cpu)
	testing.expect_value(t, cpu.vec_count[0x42], 1)
	testing.expect_value(t, cpu.ext_level, 0)
}

// The manual's unsigned 32/16 division routine: 16 DIV1 steps then ROTCL.
@(test)
div1_unsigned_division :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	ops := make([dynamic]u16)
	defer delete(ops)
	append(&ops, 0x4028, 0x0019) // shll16 r0 ; div0u
	for _ in 0 ..< 16 { append(&ops, 0x3104) } // div1 r0,r1
	append(&ops, 0x4124, 0x611D) // rotcl r1 ; extu.w r1,r1
	s.cpu[0].r[1], s.cpu[0].r[0] = 100000, 7
	run(s, ops[:])
	testing.expect_value(t, s.cpu[0].r[1], 14285)
}

// SSHON resets the slave and must leave it runnable, starting at the BIOS vector.
@(test)
slave_starts_after_sshon :: proc(t: ^testing.T) {
	s := fresh()
	defer free(s)
	// The BIOS is read-only through the bus, so plant the start vector in the image.
	s.bios[0], s.bios[1], s.bios[2], s.bios[3] = 0, 0, 2, 0
	s.cpu[1].halted = true
	s.smpc.pending_command = sat.SMPC_CMD_SSHON
	sat.smpc_update(s)
	testing.expect(t, !s.cpu[1].halted)
	testing.expect_value(t, s.cpu[1].pc, 0x200)
}
