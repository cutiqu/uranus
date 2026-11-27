// The SH-2 (SH7604) interpreter. Both Saturn CPUs are instances of this.
//
// Structure: `sh2_step` runs ONE instruction (or takes one interrupt). A
// delayed branch executes its delay-slot instruction inline, right inside the
// branch, so there is never a half-finished branch to carry between steps and
// interrupts can only arrive on instruction boundaries.
//
// Timing is approximate: about one cycle per instruction plus a flat cost for
// memory the CPU cannot hit in its cache (see `access_cost`). The Saturn has
// two CPUs hammering a shared bus, so being exact needs a real bus model.
package saturn_core

SR_T      :: 0x001
SR_S      :: 0x002
SR_Q      :: 0x100
SR_M      :: 0x200
SR_MASK   :: 0x3F3 // the SH-2 SR has no MD/RB/BL bits, only these
SR_I_MASK :: 0x0F0

// Exception vector numbers.
VEC_POWER_ON_PC :: 0
VEC_POWER_ON_SP :: 1
VEC_ILLEGAL     :: 4
VEC_SLOT_ILLEGAL :: 6
VEC_ADDR_ERROR  :: 9
VEC_NMI         :: 11

SH2 :: struct {
	r:    [16]u32,
	pc:   u32, // address of the NEXT instruction to execute
	pr:   u32,
	gbr:  u32,
	vbr:  u32,
	mach: u32,
	macl: u32,
	sr:   u32,

	cycles:   i64, // this CPU's clock, in master-clock cycles
	is_slave: bool,
	halted:   bool, // held in reset by SMPC (slave before SSHON)
	sleeping: bool, // SLEEP executed; woken by an interrupt

	// Interrupt inputs. The SCU drives `ext_level` (the IRL pins) and supplies
	// the vector through `ext_ack` when the CPU accepts it.
	ext_level: u8,
	ext_ack:   proc "contextless" (s: ^Saturn, slave: bool) -> u8,
	nmi:       bool,
	irq_level: u8, // highest pending level among all sources, 0 = none
	irq_src:   Irq_Source,

	oc:        SH7604, // on-chip peripherals (sh7604.odin)
	cache_ram: [0x1000]u8, // cache data array: some games use it as scratchpad
	s:         ^Saturn,

	// Diagnostics only (diag.odin). `trace_on` records the last data reads so a stuck
	// polling loop can be identified; `vec_count` counts interrupts taken per vector.
	trace_on:  bool,
	trace_n:   u32,
	trace:     [32]Read_Trace,
	io_hist:   [64]IO_Count, // reads of hardware registers while tracing
	vec_count: [256]u32,

	illegal_count: u32, // diagnostics
	last_illegal:  u16,
	last_illegal_pc: u32,
}

IO_Count :: struct {
	addr, count: u32,
}

Read_Trace :: struct {
	addr, val: u32,
	size:      u8,
}

Irq_Source :: enum u8 { None, NMI, External, DIVU, DMAC0, DMAC1, WDT, FRT_ICI, FRT_OCI, FRT_OVI }

sh2_reset :: proc "contextless" (cpu: ^SH2, s: ^Saturn, is_slave: bool) {
	cpu^ = {}
	cpu.s = s
	cpu.is_slave = is_slave
	cpu.sr = SR_I_MASK
	cpu.ext_ack = scu_vector_fetch
	sh7604_reset(cpu)
	// Both CPUs fetch their start PC and stack pointer from the vector table at
	// address 0 (the BIOS). Whether the slave runs is the SMPC's decision.
	cpu.pc = mem_read32(s, 0)
	cpu.r[15] = mem_read32(s, 4)
}

// ------------------------------------------------------------ bus access ---

// What an access costs beyond the instruction's own cycle. High work RAM is
// SDRAM behind the cache, so it is cheap; everything else is slower.
@(private = "file")
access_cost :: #force_inline proc "contextless" (a: u32) -> i64 {
	return 1 if (a & 0x1E000000) == 0x06000000 else 6
}

sh2_read8 :: #force_inline proc "contextless" (cpu: ^SH2, a: u32) -> u8 {
	v := read8_raw(cpu, a)
	if cpu.trace_on { trace_read(cpu, a, u32(v), 1) }
	return v
}

@(private = "file")
read8_raw :: proc "contextless" (cpu: ^SH2, a: u32) -> u8 {
	cpu.cycles += access_cost(a)
	switch a >> 29 {
	case 0, 1: return mem_read8(cpu.s, a & 0x1FFFFFFF)
	case 6:    return cpu.cache_ram[a & 0xFFF]
	case 7:    if a >= 0xFFFFFE00 { return oc_read8(cpu, a) }
	}
	return 0
}

sh2_read16 :: #force_inline proc "contextless" (cpu: ^SH2, a: u32) -> u16 {
	v := read16_raw(cpu, a)
	if cpu.trace_on { trace_read(cpu, a, u32(v), 2) }
	return v
}

@(private = "file")
read16_raw :: proc "contextless" (cpu: ^SH2, a: u32) -> u16 {
	cpu.cycles += access_cost(a)
	switch a >> 29 {
	case 0, 1: return mem_read16(cpu.s, a & 0x1FFFFFFE)
	case 6:    i := a & 0xFFE; return u16(cpu.cache_ram[i]) << 8 | u16(cpu.cache_ram[i + 1])
	case 7:    if a >= 0xFFFFFE00 { return oc_read16(cpu, a & ~u32(1)) }
	}
	return 0
}

sh2_read32 :: #force_inline proc "contextless" (cpu: ^SH2, a: u32) -> u32 {
	v := read32_raw(cpu, a)
	if cpu.trace_on { trace_read(cpu, a, u32(v), 4) }
	return v
}

@(private = "file")
read32_raw :: proc "contextless" (cpu: ^SH2, a: u32) -> u32 {
	cpu.cycles += access_cost(a)
	switch a >> 29 {
	case 0, 1: return mem_read32(cpu.s, a & 0x1FFFFFFC)
	case 6:
		i := a & 0xFFC
		return u32(cpu.cache_ram[i]) << 24 | u32(cpu.cache_ram[i + 1]) << 16 | u32(cpu.cache_ram[i + 2]) << 8 | u32(cpu.cache_ram[i + 3])
	case 7:    if a >= 0xFFFFFE00 { return oc_read32(cpu, a & ~u32(3)) }
	}
	return 0
}

sh2_write8 :: proc "contextless" (cpu: ^SH2, a: u32, v: u8) {
	cpu.cycles += access_cost(a)
	switch a >> 29 {
	case 0, 1: mem_write8(cpu.s, a & 0x1FFFFFFF, v)
	case 6:    cpu.cache_ram[a & 0xFFF] = v
	case 7:    if a >= 0xFFFFFE00 { oc_write8(cpu, a, v) }
	}
}

sh2_write16 :: proc "contextless" (cpu: ^SH2, a: u32, v: u16) {
	cpu.cycles += access_cost(a)
	switch a >> 29 {
	case 0, 1: mem_write16(cpu.s, a & 0x1FFFFFFE, v)
	case 6:    i := a & 0xFFE; cpu.cache_ram[i] = u8(v >> 8); cpu.cache_ram[i + 1] = u8(v)
	case 7:    if a >= 0xFFFFFE00 { oc_write16(cpu, a & ~u32(1), v) }
	}
}

sh2_write32 :: proc "contextless" (cpu: ^SH2, a: u32, v: u32) {
	cpu.cycles += access_cost(a)
	switch a >> 29 {
	case 0, 1: mem_write32(cpu.s, a & 0x1FFFFFFC, v)
	case 6:
		i := a & 0xFFC
		cpu.cache_ram[i], cpu.cache_ram[i + 1], cpu.cache_ram[i + 2], cpu.cache_ram[i + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
	case 7:    if a >= 0xFFFFFE00 { oc_write32(cpu, a & ~u32(3), v) }
	}
}

@(private = "file")
trace_read :: proc "contextless" (cpu: ^SH2, a, v: u32, size: u8) {
	cpu.trace[cpu.trace_n & 31] = {a, v, size}
	cpu.trace_n += 1
	// Hardware registers only (A-/B-bus, SMPC, on-chip), counted per address.
	x := a & 0x1FFFFFFF
	if (x >= 0x05000000 && x < 0x06000000) || (x >= 0x00100000 && x < 0x00180000) || x >= 0x1FFFFE00 {
		for i in 0 ..< 64 {
			e := &cpu.io_hist[(u32(i) + (x >> 2)) & 63]
			if e.count == 0 { e^ = {a, 1}; return }
			if e.addr == a { e.count += 1; return }
		}
	}
}

// ------------------------------------------------------------ exceptions ---

// Pushes SR and the return PC, then jumps through the vector table.
@(private = "file")
enter_exception :: proc "contextless" (cpu: ^SH2, vec: u32, ret_pc: u32) {
	cpu.r[15] -= 4
	sh2_write32(cpu, cpu.r[15], cpu.sr)
	cpu.r[15] -= 4
	sh2_write32(cpu, cpu.r[15], ret_pc)
	cpu.pc = sh2_read32(cpu, cpu.vbr + vec * 4)
}

@(private = "file")
take_interrupt :: proc "contextless" (cpu: ^SH2) {
	level := cpu.irq_level
	scu_taken := cpu.irq_src == .External && !cpu.is_slave // master took the SCU's interrupt
	vec: u32
	switch cpu.irq_src {
	case .None:     return
	case .NMI:      vec = VEC_NMI; cpu.nmi = false
	case .External: vec = u32(cpu.ext_ack(cpu.s, cpu.is_slave)); cpu.ext_level = 0
	case .DIVU:     vec = u32(cpu.oc.vcrdiv & 0x7F)
	case .DMAC0:    vec = u32(cpu.oc.dma[0].vcr & 0x7F)
	case .DMAC1:    vec = u32(cpu.oc.dma[1].vcr & 0x7F)
	case .WDT:      vec = u32(cpu.oc.vcrwdt >> 8) & 0x7F
	case .FRT_ICI:  vec = u32(cpu.oc.vcrc >> 8) & 0x7F
	case .FRT_OCI:  vec = u32(cpu.oc.vcrc) & 0x7F
	case .FRT_OVI:  vec = u32(cpu.oc.vcrd >> 8) & 0x7F
	}
	cpu.sleeping = false
	cpu.vec_count[vec & 0xFF] += 1
	enter_exception(cpu, vec, cpu.pc)
	cpu.sr = (cpu.sr & ~u32(SR_I_MASK)) | (u32(min(level, 15)) << 4)
	cpu.cycles += 4
	sh7604_recalc_irq(cpu)
	if scu_taken { scu_reoffer(cpu.s) } // ext_level was just cleared; offer whatever else is pending
}

// ----------------------------------------------------------------- step ----

sh2_step :: proc "contextless" (cpu: ^SH2) {
	if cpu.oc.next_event <= cpu.cycles { sh7604_events(cpu) }

	if cpu.irq_level > u8((cpu.sr >> 4) & 0xF) || cpu.nmi {
		if cpu.nmi { cpu.irq_level = 16; cpu.irq_src = .NMI }
		take_interrupt(cpu)
	}
	if cpu.sleeping {
		cpu.cycles += 4
		return
	}

	pc0 := cpu.pc
	op := mem_read16(cpu.s, pc0 & 0x1FFFFFFE) if (pc0 >> 29) < 2 else sh2_read16(cpu, pc0)
	cpu.cycles += 1 if (pc0 & 0x1E000000) == 0x06000000 else 3
	cpu.pc = pc0 + 2
	exec(cpu, op, pc0)
}

// Runs this CPU until its clock reaches `until`.
sh2_run :: proc "contextless" (cpu: ^SH2, until: i64) {
	if cpu.halted {
		cpu.cycles = until
		return
	}
	for cpu.cycles < until { sh2_step(cpu) }
}

// Executes the delay-slot instruction of the branch at `cpu.pc - 2`, then
// transfers control to `target`.
@(private = "file")
delayed :: proc "contextless" (cpu: ^SH2, target: u32) {
	slot_pc := cpu.pc
	op := sh2_read16(cpu, slot_pc)
	cpu.pc = slot_pc + 2
	exec(cpu, op, slot_pc)
	cpu.pc = target
}

@(private = "file")
illegal :: proc "contextless" (cpu: ^SH2, op: u16, pc0: u32) {
	cpu.illegal_count += 1
	cpu.last_illegal, cpu.last_illegal_pc = op, pc0
	enter_exception(cpu, VEC_ILLEGAL, pc0)
}

@(private = "file")
set_t :: #force_inline proc "contextless" (cpu: ^SH2, c: bool) {
	cpu.sr = (cpu.sr & ~u32(SR_T)) | u32(c)
}

@(private = "file")
get_t :: #force_inline proc "contextless" (cpu: ^SH2) -> u32 {
	return cpu.sr & SR_T
}

@(private = "file")
sext8 :: #force_inline proc "contextless" (v: u32) -> u32 {return u32(i32(i8(v)))}
@(private = "file")
sext16 :: #force_inline proc "contextless" (v: u32) -> u32 {return u32(i32(i16(v)))}

@(private = "file")
set_mac :: #force_inline proc "contextless" (cpu: ^SH2, v: i64) {
	cpu.mach = u32(u64(v) >> 32)
	cpu.macl = u32(v)
}

@(private = "file")
get_mac :: #force_inline proc "contextless" (cpu: ^SH2) -> i64 {
	return i64(u64(cpu.mach) << 32 | u64(cpu.macl))
}

@(private = "file")
exec :: proc "contextless" (cpu: ^SH2, op: u16, pc0: u32) {
	n := (op >> 8) & 0xF
	m := (op >> 4) & 0xF
	r := &cpu.r

	switch op >> 12 {
	case 0x0:
		switch op & 0xF {
		case 0x2: // STC SR/GBR/VBR,Rn
			switch m {
			case 0: r[n] = cpu.sr
			case 1: r[n] = cpu.gbr
			case 2: r[n] = cpu.vbr
			case: illegal(cpu, op, pc0)
			}
		case 0x3: // BSRF / BRAF
			switch m {
			case 0: cpu.pr = pc0 + 4; delayed(cpu, pc0 + 4 + r[n])
			case 2: delayed(cpu, pc0 + 4 + r[n])
			case: illegal(cpu, op, pc0)
			}
		case 0x4: sh2_write8(cpu, r[0] + r[n], u8(r[m]))
		case 0x5: sh2_write16(cpu, r[0] + r[n], u16(r[m]))
		case 0x6: sh2_write32(cpu, r[0] + r[n], r[m])
		case 0x7: cpu.macl = r[n] * r[m]; cpu.cycles += 1 // MUL.L
		case 0x8:
			switch m {
			case 0: cpu.sr &= ~u32(SR_T) // CLRT
			case 1: cpu.sr |= SR_T       // SETT
			case 2: cpu.mach, cpu.macl = 0, 0 // CLRMAC
			case: illegal(cpu, op, pc0)
			}
		case 0x9:
			switch m {
			case 0: if n != 0 { illegal(cpu, op, pc0) } // NOP
			case 1: cpu.sr &= ~u32(SR_M | SR_Q | SR_T) // DIV0U
			case 2: r[n] = get_t(cpu) // MOVT
			case: illegal(cpu, op, pc0)
			}
		case 0xA: // STS
			switch m {
			case 0: r[n] = cpu.mach
			case 1: r[n] = cpu.macl
			case 2: r[n] = cpu.pr
			case: illegal(cpu, op, pc0)
			}
		case 0xB:
			switch m {
			case 0: delayed(cpu, cpu.pr) // RTS
			case 1: cpu.sleeping = true; cpu.pc = pc0 + 2 // SLEEP
			case 2: // RTE
				target := sh2_read32(cpu, r[15])
				r[15] += 4
				sr := sh2_read32(cpu, r[15]) & SR_MASK
				r[15] += 4
				// The delay slot runs with the restored SR.
				cpu.sr = sr
				delayed(cpu, target)
			case: illegal(cpu, op, pc0)
			}
		case 0xC: r[n] = sext8(u32(sh2_read8(cpu, r[0] + r[m])))
		case 0xD: r[n] = sext16(u32(sh2_read16(cpu, r[0] + r[m])))
		case 0xE: r[n] = sh2_read32(cpu, r[0] + r[m])
		case 0xF: // MAC.L @Rm+,@Rn+
			a := i64(i32(sh2_read32(cpu, r[n])))
			r[n] += 4
			b := i64(i32(sh2_read32(cpu, r[m])))
			r[m] += 4
			res := get_mac(cpu) + a * b
			if cpu.sr & SR_S != 0 {
				if res > 0x00007FFFFFFFFFFF { res = 0x00007FFFFFFFFFFF }
				if res < -0x0000800000000000 { res = -0x0000800000000000 }
			}
			set_mac(cpu, res)
			cpu.cycles += 2
		case: illegal(cpu, op, pc0)
		}

	case 0x1: // MOV.L Rm,@(disp,Rn)
		sh2_write32(cpu, r[n] + u32(op & 0xF) * 4, r[m])

	case 0x2:
		switch op & 0xF {
		case 0x0: sh2_write8(cpu, r[n], u8(r[m]))
		case 0x1: sh2_write16(cpu, r[n], u16(r[m]))
		case 0x2: sh2_write32(cpu, r[n], r[m])
		case 0x4: r[n] -= 1; sh2_write8(cpu, r[n], u8(r[m]))
		case 0x5: r[n] -= 2; sh2_write16(cpu, r[n], u16(r[m]))
		case 0x6: r[n] -= 4; sh2_write32(cpu, r[n], r[m])
		case 0x7: // DIV0S
			q := (r[n] >> 31) & 1
			mm := (r[m] >> 31) & 1
			cpu.sr = (cpu.sr & ~u32(SR_Q | SR_M | SR_T)) | q << 8 | mm << 9 | (q ~ mm)
		case 0x8: set_t(cpu, r[n] & r[m] == 0) // TST
		case 0x9: r[n] &= r[m]
		case 0xA: r[n] ~= r[m]
		case 0xB: r[n] |= r[m]
		case 0xC: // CMP/STR
			x := r[n] ~ r[m]
			set_t(cpu, x & 0xFF == 0 || x & 0xFF00 == 0 || x & 0xFF0000 == 0 || x & 0xFF000000 == 0)
		case 0xD: r[n] = (r[m] << 16) | (r[n] >> 16) // XTRCT
		case 0xE: cpu.macl = u32(r[n] & 0xFFFF) * u32(r[m] & 0xFFFF); cpu.cycles += 1 // MULU.W
		case 0xF: cpu.macl = u32(i32(i16(r[n])) * i32(i16(r[m]))); cpu.cycles += 1  // MULS.W
		case: illegal(cpu, op, pc0)
		}

	case 0x3:
		switch op & 0xF {
		case 0x0: set_t(cpu, r[n] == r[m])
		case 0x2: set_t(cpu, r[n] >= r[m])
		case 0x3: set_t(cpu, i32(r[n]) >= i32(r[m]))
		case 0x4: div1(cpu, n, m)
		case 0x5: set_mac(cpu, i64(u64(r[n]) * u64(r[m]))); cpu.cycles += 1 // DMULU.L
		case 0x6: set_t(cpu, r[n] > r[m])
		case 0x7: set_t(cpu, i32(r[n]) > i32(r[m]))
		case 0x8: r[n] -= r[m]
		case 0xA: // SUBC
			t := u64(get_t(cpu))
			borrow := u64(r[n]) < u64(r[m]) + t
			r[n] = r[n] - r[m] - u32(t)
			set_t(cpu, borrow)
		case 0xB: // SUBV
			d := i64(i32(r[n])) - i64(i32(r[m]))
			r[n] -= r[m]
			set_t(cpu, d > 0x7FFFFFFF || d < -0x80000000)
		case 0xC: r[n] += r[m]
		case 0xD: set_mac(cpu, i64(i32(r[n])) * i64(i32(r[m]))); cpu.cycles += 1 // DMULS.L
		case 0xE: // ADDC
			t := u64(get_t(cpu))
			carry := u64(r[n]) + u64(r[m]) + t > 0xFFFFFFFF
			r[n] = r[n] + r[m] + u32(t)
			set_t(cpu, carry)
		case 0xF: // ADDV
			d := i64(i32(r[n])) + i64(i32(r[m]))
			r[n] += r[m]
			set_t(cpu, d > 0x7FFFFFFF || d < -0x80000000)
		case: illegal(cpu, op, pc0)
		}

	case 0x4: exec4(cpu, op, pc0, n, m)

	case 0x5: r[n] = sh2_read32(cpu, r[m] + u32(op & 0xF) * 4)

	case 0x6:
		switch op & 0xF {
		case 0x0: r[n] = sext8(u32(sh2_read8(cpu, r[m])))
		case 0x1: r[n] = sext16(u32(sh2_read16(cpu, r[m])))
		case 0x2: r[n] = sh2_read32(cpu, r[m])
		case 0x3: r[n] = r[m]
		case 0x4: v := sext8(u32(sh2_read8(cpu, r[m]))); r[m] += 1; r[n] = v
		case 0x5: v := sext16(u32(sh2_read16(cpu, r[m]))); r[m] += 2; r[n] = v
		case 0x6: v := sh2_read32(cpu, r[m]); r[m] += 4; r[n] = v
		case 0x7: r[n] = ~r[m]
		case 0x8: r[n] = (r[m] & 0xFFFF0000) | (r[m] & 0xFF) << 8 | (r[m] >> 8) & 0xFF // SWAP.B
		case 0x9: r[n] = (r[m] << 16) | (r[m] >> 16) // SWAP.W
		case 0xA: // NEGC
			t := u64(get_t(cpu))
			borrow := u64(r[m]) + t > 0
			r[n] = 0 - r[m] - u32(t)
			set_t(cpu, borrow)
		case 0xB: r[n] = 0 - r[m]
		case 0xC: r[n] = r[m] & 0xFF
		case 0xD: r[n] = r[m] & 0xFFFF
		case 0xE: r[n] = sext8(r[m])
		case 0xF: r[n] = sext16(r[m])
		}

	case 0x7: r[n] += sext8(u32(op & 0xFF))

	case 0x8:
		switch n {
		case 0x0: sh2_write8(cpu, r[m] + u32(op & 0xF), u8(r[0]))
		case 0x1: sh2_write16(cpu, r[m] + u32(op & 0xF) * 2, u16(r[0]))
		case 0x4: r[0] = sext8(u32(sh2_read8(cpu, r[m] + u32(op & 0xF))))
		case 0x5: r[0] = sext16(u32(sh2_read16(cpu, r[m] + u32(op & 0xF) * 2)))
		case 0x8: set_t(cpu, r[0] == sext8(u32(op & 0xFF)))
		case 0x9: // BT
			if get_t(cpu) != 0 { cpu.pc = pc0 + 4 + sext8(u32(op & 0xFF)) * 2; cpu.cycles += 2 }
		case 0xB: // BF
			if get_t(cpu) == 0 { cpu.pc = pc0 + 4 + sext8(u32(op & 0xFF)) * 2; cpu.cycles += 2 }
		case 0xD: // BT/S
			if get_t(cpu) != 0 { delayed(cpu, pc0 + 4 + sext8(u32(op & 0xFF)) * 2); cpu.cycles += 1 }
		case 0xF: // BF/S
			if get_t(cpu) == 0 { delayed(cpu, pc0 + 4 + sext8(u32(op & 0xFF)) * 2); cpu.cycles += 1 }
		case: illegal(cpu, op, pc0)
		}

	case 0x9: r[n] = sext16(u32(sh2_read16(cpu, pc0 + 4 + u32(op & 0xFF) * 2)))
	case 0xA: delayed(cpu, pc0 + 4 + sext12(op) * 2) // BRA
	case 0xB: cpu.pr = pc0 + 4; delayed(cpu, pc0 + 4 + sext12(op) * 2) // BSR

	case 0xC:
		imm := u32(op & 0xFF)
		switch n {
		case 0x0: sh2_write8(cpu, cpu.gbr + imm, u8(r[0]))
		case 0x1: sh2_write16(cpu, cpu.gbr + imm * 2, u16(r[0]))
		case 0x2: sh2_write32(cpu, cpu.gbr + imm * 4, r[0])
		case 0x3: // TRAPA
			enter_exception(cpu, imm, pc0 + 2)
		case 0x4: r[0] = sext8(u32(sh2_read8(cpu, cpu.gbr + imm)))
		case 0x5: r[0] = sext16(u32(sh2_read16(cpu, cpu.gbr + imm * 2)))
		case 0x6: r[0] = sh2_read32(cpu, cpu.gbr + imm * 4)
		case 0x7: r[0] = ((pc0 + 4) & ~u32(3)) + imm * 4 // MOVA
		case 0x8: set_t(cpu, r[0] & imm == 0)
		case 0x9: r[0] &= imm
		case 0xA: r[0] ~= imm
		case 0xB: r[0] |= imm
		case 0xC: set_t(cpu, u32(sh2_read8(cpu, cpu.gbr + r[0])) & imm == 0)
		case 0xD: a := cpu.gbr + r[0]; sh2_write8(cpu, a, sh2_read8(cpu, a) & u8(imm))
		case 0xE: a := cpu.gbr + r[0]; sh2_write8(cpu, a, sh2_read8(cpu, a) ~ u8(imm))
		case 0xF: a := cpu.gbr + r[0]; sh2_write8(cpu, a, sh2_read8(cpu, a) | u8(imm))
		}

	case 0xD: r[n] = sh2_read32(cpu, ((pc0 + 4) & ~u32(3)) + u32(op & 0xFF) * 4)
	case 0xE: r[n] = sext8(u32(op & 0xFF))
	case: illegal(cpu, op, pc0)
	}
}

@(private = "file")
sext12 :: #force_inline proc "contextless" (op: u16) -> u32 {
	v := u32(op & 0xFFF)
	return v | 0xFFFFF000 if v & 0x800 != 0 else v
}

// DIV1: one step of non-restoring division. Always the manual's algorithm.
@(private = "file")
div1 :: proc "contextless" (cpu: ^SH2, n, m: u16) {
	r := &cpu.r
	old_q := (cpu.sr & SR_Q) != 0
	mflag := (cpu.sr & SR_M) != 0
	q := (r[n] >> 31) & 1 != 0
	r[n] = (r[n] << 1) | get_t(cpu)
	tmp0 := r[n]
	tmp1: bool
	if !old_q {
		if !mflag {
			r[n] -= r[m]
			tmp1 = r[n] > tmp0
			q = tmp1 if !q else !tmp1
		} else {
			r[n] += r[m]
			tmp1 = r[n] < tmp0
			q = !tmp1 if !q else tmp1
		}
	} else {
		if !mflag {
			r[n] += r[m]
			tmp1 = r[n] < tmp0
			q = tmp1 if !q else !tmp1
		} else {
			r[n] -= r[m]
			tmp1 = r[n] > tmp0
			q = !tmp1 if !q else tmp1
		}
	}
	cpu.sr = (cpu.sr & ~u32(SR_Q | SR_T)) | u32(q) << 8
	set_t(cpu, q == mflag)
}

@(private = "file")
exec4 :: proc "contextless" (cpu: ^SH2, op: u16, pc0: u32, n, m: u16) {
	r := &cpu.r

	if op & 0xF == 0xF { // MAC.W @Rm+,@Rn+
		a := i64(i16(sh2_read16(cpu, r[n])))
		r[n] += 2
		b := i64(i16(sh2_read16(cpu, r[m])))
		r[m] += 2
		if cpu.sr & SR_S != 0 {
			res := i64(i32(cpu.macl)) + a * b
			if res > 0x7FFFFFFF { res = 0x7FFFFFFF; cpu.mach = 1 }
			if res < -0x80000000 { res = -0x80000000; cpu.mach = 1 }
			cpu.macl = u32(res)
		} else {
			set_mac(cpu, get_mac(cpu) + a * b)
		}
		cpu.cycles += 2
		return
	}

	switch op & 0xFF {
	case 0x00: set_t(cpu, r[n] >> 31 != 0); r[n] <<= 1 // SHLL
	case 0x01: set_t(cpu, r[n] & 1 != 0); r[n] >>= 1   // SHLR
	case 0x02: r[n] -= 4; sh2_write32(cpu, r[n], cpu.mach)
	case 0x03: r[n] -= 4; sh2_write32(cpu, r[n], cpu.sr)
	case 0x04: t := r[n] >> 31; r[n] = (r[n] << 1) | t; set_t(cpu, t != 0) // ROTL
	case 0x05: t := r[n] & 1; r[n] = (r[n] >> 1) | t << 31; set_t(cpu, t != 0) // ROTR
	case 0x06: cpu.mach = sh2_read32(cpu, r[n]); r[n] += 4
	case 0x07: cpu.sr = sh2_read32(cpu, r[n]) & SR_MASK; r[n] += 4
	case 0x08: r[n] <<= 2
	case 0x09: r[n] >>= 2
	case 0x0A: cpu.mach = r[n]
	case 0x0B: cpu.pr = pc0 + 4; delayed(cpu, r[n]) // JSR
	case 0x0E: cpu.sr = r[n] & SR_MASK

	case 0x10: r[n] -= 1; set_t(cpu, r[n] == 0) // DT
	case 0x11: set_t(cpu, i32(r[n]) >= 0)
	case 0x12: r[n] -= 4; sh2_write32(cpu, r[n], cpu.macl)
	case 0x13: r[n] -= 4; sh2_write32(cpu, r[n], cpu.gbr)
	case 0x15: set_t(cpu, i32(r[n]) > 0)
	case 0x16: cpu.macl = sh2_read32(cpu, r[n]); r[n] += 4
	case 0x17: cpu.gbr = sh2_read32(cpu, r[n]); r[n] += 4
	case 0x18: r[n] <<= 8
	case 0x19: r[n] >>= 8
	case 0x1A: cpu.macl = r[n]
	case 0x1B: // TAS.B
		v := sh2_read8(cpu, r[n])
		set_t(cpu, v == 0)
		sh2_write8(cpu, r[n], v | 0x80)
	case 0x1E: cpu.gbr = r[n]

	case 0x20: set_t(cpu, r[n] >> 31 != 0); r[n] <<= 1 // SHAL
	case 0x21: set_t(cpu, r[n] & 1 != 0); r[n] = u32(i32(r[n]) >> 1) // SHAR
	case 0x22: r[n] -= 4; sh2_write32(cpu, r[n], cpu.pr)
	case 0x23: r[n] -= 4; sh2_write32(cpu, r[n], cpu.vbr)
	case 0x24: t := r[n] >> 31; r[n] = (r[n] << 1) | get_t(cpu); set_t(cpu, t != 0) // ROTCL
	case 0x25: t := r[n] & 1; r[n] = (r[n] >> 1) | get_t(cpu) << 31; set_t(cpu, t != 0) // ROTCR
	case 0x26: cpu.pr = sh2_read32(cpu, r[n]); r[n] += 4
	case 0x27: cpu.vbr = sh2_read32(cpu, r[n]); r[n] += 4
	case 0x28: r[n] <<= 16
	case 0x29: r[n] >>= 16
	case 0x2A: cpu.pr = r[n]
	case 0x2B: delayed(cpu, r[n]) // JMP
	case 0x2E: cpu.vbr = r[n]
	case: illegal(cpu, op, pc0)
	}
}
