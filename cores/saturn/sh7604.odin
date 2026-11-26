// SH7604 on-chip peripherals, one set per CPU, mapped at 0xFFFFFE00-0xFFFFFFFF:
// the free-running timer (FRT), watchdog (WDT), divider (DIVU), two DMA
// channels (DMAC), and the interrupt-priority registers (INTC).
//
// The timers are *lazy*: nothing ticks per instruction. Each timer remembers
// the CPU cycle at which its count was last exact and catches up when it is
// read, written, or when its next interrupt-relevant event is due
// (`next_event`, checked once per instruction in sh2_step).
package saturn_core

// FTCSR / TIER / TCR bits.
FRT_ICF :: 0x80
FRT_OCFA :: 0x08
FRT_OCFB :: 0x04
FRT_OVF :: 0x02
FRT_CCLRA :: 0x01

DMA_Chan :: struct {
	sar, dar, tcr, chcr: u32,
	vcr:                 u32,
	drcr:                u8,
}

SH7604 :: struct {
	// FRT
	tier, ftcsr, tcr, tocr:                          u8,
	frc, ocra, ocrb, ficr:                           u16,
	frt_base:                                        i64, // cycle at which `frc` was exact

	// WDT
	wtcsr, wtcnt, rstcsr:                            u8,
	wdt_base:                                        i64,

	// DIVU
	dvsr, dvdnt, dvdnth, dvdntl, dvcr, vcrdiv:       u32,

	// DMAC
	dma:                                             [2]DMA_Chan,
	dmaor:                                           u32,

	// INTC
	ipra, iprb, vcra, vcrb, vcrc, vcrd, vcrwdt, icr: u16,

	// Everything with no behaviour here (SCI, BSC, CCR, SBYCR...) just reads
	// back what was written, so software that probes it does not misbehave.
	raw:                                             [0x200]u8,
	next_event:                                      i64, // CPU cycle of the next timer event that may raise an IRQ
}

sh7604_reset :: proc "contextless" (cpu: ^SH2) {
	oc := &cpu.oc
	oc^ = {}
	oc.tier, oc.tocr = 0x01, 0xE0
	oc.ocra, oc.ocrb = 0xFFFF, 0xFFFF
	oc.wtcsr, oc.rstcsr = 0x18, 0x1F
	oc.raw[0x01] = 0xFF // BRR
	oc.raw[0x03] = 0xFF // TDR
	oc.raw[0x04] = 0x84 // SSR
	// BSC. BCR1 bit 15 is the MASTER bit, a pin strapped low on the master SH-2 and
	// high on the slave. The BIOS reset code reads it to tell the two apart: both
	// CPUs start at the same vector, and a slave that reads 0 runs the whole master
	// boot again (which is what restarted the machine when a game issued SSHON).
	// Everything else in the BSC powers on as zero, as in Mednafen. (Setting the
	// SH7604 manual's defaults here, BCR1=0x03F0 / BCR2=0xFC / WCR=0xAAFF, made the
	// BIOS skip its glass-shard intro: it seems to read these registers to decide
	// whether this is a cold boot.) Layout: 32-bit registers at 0x1E0.., value in
	// the low half.
	oc.raw[0x1E2] = 0x80 if cpu.is_slave else 0 // BCR1
	oc.next_event = max(i64)
}

// ------------------------------------------------------------- interrupts ---

sh7604_recalc_irq :: proc "contextless" (cpu: ^SH2) {
	oc := &cpu.oc
	best: u8 = cpu.ext_level
	src: Irq_Source = .External if best > 0 else .None

	consider :: proc "contextless" (
		best: ^u8,
		src: ^Irq_Source,
		level: u16,
		which: Irq_Source,
		active: bool,
	) {
		if active && u8(level & 0xF) > best^ {
			best^ = u8(level & 0xF)
			src^ = which
		}
	}
	consider(&best, &src, oc.ipra >> 12, .DIVU, oc.dvcr & 3 == 3)
	consider(&best, &src, oc.ipra >> 8, .DMAC0, oc.dma[0].chcr & 6 == 6)
	consider(&best, &src, oc.ipra >> 8, .DMAC1, oc.dma[1].chcr & 6 == 6)
	consider(&best, &src, oc.ipra >> 4, .WDT, oc.wtcsr & 0xC0 == 0x80)
	consider(&best, &src, oc.iprb >> 8, .FRT_ICI, oc.ftcsr & oc.tier & FRT_ICF != 0)
	consider(&best, &src, oc.iprb >> 8, .FRT_OCI, oc.ftcsr & oc.tier & (FRT_OCFA | FRT_OCFB) != 0)
	consider(&best, &src, oc.iprb >> 8, .FRT_OVI, oc.ftcsr & oc.tier & FRT_OVF != 0)
	cpu.irq_level, cpu.irq_src = best, src
}

// The SCU (or SMPC logic) drives the IRL pins through here.
sh2_set_irl :: proc "contextless" (cpu: ^SH2, level: u8) {
	cpu.ext_level = level
	sh7604_recalc_irq(cpu)
}

// ------------------------------------------------------------------- FRT ----

@(private = "file")
frt_div :: proc "contextless" (oc: ^SH7604) -> i64 {
	switch oc.tcr & 3 {
	case 0:
		return 8
	case 1:
		return 32
	case 2:
		return 128
	}
	return 0 // external clock: nothing on the Saturn drives it
}

@(private = "file")
frt_sync :: proc "contextless" (cpu: ^SH2) {
	oc := &cpu.oc
	div := frt_div(oc)
	if div == 0 {
		oc.frt_base = cpu.cycles
		return
	}
	ticks := (cpu.cycles - oc.frt_base) / div
	if ticks <= 0 {return}
	oc.frt_base += ticks * div
	for ticks > 0 {
		da := i64((oc.ocra - oc.frc) & 0xFFFF)
		db := i64((oc.ocrb - oc.frc) & 0xFFFF)
		dov := i64(0x10000) - i64(oc.frc)
		if da == 0 {da = 0x10000}
		if db == 0 {db = 0x10000}
		d := min(da, db, dov, ticks)
		oc.frc += u16(d)
		ticks -= d
		if d == da {
			oc.ftcsr |= FRT_OCFA
			if oc.ftcsr & FRT_CCLRA != 0 {oc.frc = 0}
		}
		if d == db {oc.ftcsr |= FRT_OCFB}
		if d == dov {oc.ftcsr |= FRT_OVF}
	}
}

// Next cycle at which an *enabled* FRT interrupt becomes pending.
@(private = "file")
frt_next :: proc "contextless" (oc: ^SH7604) -> i64 {
	div := frt_div(oc)
	if div == 0 || oc.tier & (FRT_OCFA | FRT_OCFB | FRT_OVF) == 0 {return max(i64)}
	best := i64(0x10001)
	if oc.tier & FRT_OCFA !=
	   0 {d := i64((oc.ocra - oc.frc) & 0xFFFF); best = min(best, d if d != 0 else 0x10000)}
	if oc.tier & FRT_OCFB !=
	   0 {d := i64((oc.ocrb - oc.frc) & 0xFFFF); best = min(best, d if d != 0 else 0x10000)}
	if oc.tier & FRT_OVF != 0 {best = min(best, i64(0x10000) - i64(oc.frc))}
	return oc.frt_base + best * div
}

// A pulse on the FTI pin (MINIT / SINIT from the other CPU).
sh7604_frt_capture :: proc "contextless" (cpu: ^SH2) {
	frt_sync(cpu)
	cpu.oc.ficr = cpu.oc.frc
	cpu.oc.ftcsr |= FRT_ICF
	sh7604_recalc_irq(cpu)
}

// ------------------------------------------------------------------- WDT ----

@(private = "file")
wdt_div :: proc "contextless" (oc: ^SH7604) -> i64 {
	divs := [8]i64{2, 64, 128, 256, 512, 1024, 4096, 8192}
	return divs[oc.wtcsr & 7]
}

@(private = "file")
wdt_sync :: proc "contextless" (cpu: ^SH2) {
	oc := &cpu.oc
	if oc.wtcsr & 0x20 == 0 {
		oc.wdt_base = cpu.cycles
		return
	}
	div := wdt_div(oc)
	ticks := (cpu.cycles - oc.wdt_base) / div
	if ticks <= 0 {return}
	oc.wdt_base += ticks * div
	cnt := i64(oc.wtcnt) + ticks
	if cnt > 0xFF {oc.wtcsr |= 0x80}
	oc.wtcnt = u8(cnt)
}

sh7604_events :: proc "contextless" (cpu: ^SH2) {
	frt_sync(cpu)
	wdt_sync(cpu)
	sh7604_recalc_irq(cpu)
	sh7604_schedule(cpu)
}

@(private = "file")
sh7604_schedule :: proc "contextless" (cpu: ^SH2) {
	oc := &cpu.oc
	t := frt_next(oc)
	if oc.wtcsr & 0x60 == 0x20 {t = min(t, oc.wdt_base + (256 - i64(oc.wtcnt)) * wdt_div(oc))}
	oc.next_event = t
}

// ------------------------------------------------------------------ DIVU ----

@(private = "file")
divu_32 :: proc "contextless" (oc: ^SH7604) {
	dividend := i32(oc.dvdnt)
	divisor := i32(oc.dvsr)
	if divisor == 0 {
		oc.dvcr |= 1
		oc.dvdnth = u32(dividend >> 29)
		oc.dvdntl = 0x7FFFFFFF + u32(dividend < 0)
	} else if divisor == -1 && dividend == min(i32) {
		oc.dvdntl, oc.dvdnth = 0x80000000, 0
	} else {
		oc.dvdnth = u32(dividend % divisor)
		oc.dvdntl = u32(dividend / divisor)
	}
	oc.dvdnt = oc.dvdntl
}

@(private = "file")
divu_64 :: proc "contextless" (oc: ^SH7604) {
	divisor := i64(i32(oc.dvsr))
	dividend := i64(u64(oc.dvdnth) << 32 | u64(oc.dvdntl))
	overflow := divisor == 0 || (dividend == min(i64) && divisor == -1)
	q: i64
	if !overflow {
		q = dividend / divisor
		if q > 0x7FFFFFFF ||
		   q <
			   -0x7FFFFFFF {overflow = !(q == 0x80000000 && divisor < 0 && dividend % divisor == 0)}
	}
	if overflow {
		oc.dvcr |= 1
		oc.dvdntl = 0x7FFFFFFF + u32(i32(oc.dvdnth ~ oc.dvsr) < 0)
		oc.dvdnth = u32(dividend) if divisor == 0 else u32(dividend % divisor) // approximation of the partial result
	} else {
		oc.dvdnth = u32(dividend % divisor)
		oc.dvdntl = u32(q)
	}
	oc.dvdnt = oc.dvdntl
}

// ------------------------------------------------------------------ DMAC ----

@(private = "file")
dmac_run :: proc "contextless" (cpu: ^SH2, ch: int) {
	d := &cpu.oc.dma[ch]
	s := cpu.s
	units := [4]u32{1, 2, 4, 16}
	unit := units[(d.chcr >> 10) & 3]
	sm := (d.chcr >> 12) & 3
	dm := (d.chcr >> 14) & 3
	count := d.tcr & 0xFFFFFF
	if count == 0 {count = 0x1000000}
	step :: proc "contextless" (mode, unit: u32) -> u32 {
		switch mode {
		case 1:
			return unit
		case 2:
			return 0 - unit
		}
		return 0
	}
	sstep, dstep := step(sm, unit), step(dm, unit)
	for ; count > 0; count -= 1 {
		sa, da := d.sar & 0x1FFFFFFF, d.dar & 0x1FFFFFFF
		switch unit {
		case 1:
			mem_write8(s, da, mem_read8(s, sa))
		case 2:
			mem_write16(s, da, mem_read16(s, sa))
		case 4:
			mem_write32(s, da, mem_read32(s, sa))
		case 16:
			for i in u32(0) ..< 4 {mem_write32(s, da + i * 4, mem_read32(s, sa + i * 4))}
		}
		d.sar += sstep
		d.dar += dstep
	}
	d.tcr = 0
	d.chcr |= 2 // TE
	sh7604_recalc_irq(cpu)
}

@(private = "file")
dmac_check :: proc "contextless" (cpu: ^SH2) {
	if cpu.oc.dmaor & 1 == 0 {return}
	for ch in 0 ..< 2 {
		c := cpu.oc.dma[ch].chcr
		// Only auto-request transfers start by themselves; DREQ/module
		// requests would need the requesting device to cooperate.
		if c & 3 == 1 && c & 0x200 != 0 {dmac_run(cpu, ch)}
	}
}

// ------------------------------------------------------------- registers ----

oc_read8 :: proc "contextless" (cpu: ^SH2, a: u32) -> u8 {
	oc := &cpu.oc
	off := a & 0x1FF
	switch off {
	case 0x10:
		return oc.tier | 1
	case 0x11:
		frt_sync(cpu); return oc.ftcsr
	case 0x12:
		frt_sync(cpu); return u8(oc.frc >> 8)
	case 0x13:
		frt_sync(cpu); return u8(oc.frc)
	case 0x14:
		v := oc.ocrb if oc.tocr & 0x10 != 0 else oc.ocra; return u8(v >> 8)
	case 0x15:
		v := oc.ocrb if oc.tocr & 0x10 != 0 else oc.ocra; return u8(v)
	case 0x16:
		return oc.tcr
	case 0x17:
		return oc.tocr | 0xE0
	case 0x18:
		return u8(oc.ficr >> 8)
	case 0x19:
		return u8(oc.ficr)
	case 0x60, 0x61:
		return hi_lo(oc.iprb, off & 1)
	case 0x62, 0x63:
		return hi_lo(oc.vcra, off & 1)
	case 0x64, 0x65:
		return hi_lo(oc.vcrb, off & 1)
	case 0x66, 0x67:
		return hi_lo(oc.vcrc, off & 1)
	case 0x68, 0x69:
		return hi_lo(oc.vcrd, off & 1)
	case 0x71:
		return oc.dma[0].drcr
	case 0x72:
		return oc.dma[1].drcr
	case 0x80:
		wdt_sync(cpu); return oc.wtcsr
	case 0x81:
		wdt_sync(cpu); return oc.wtcnt
	case 0x83:
		return oc.rstcsr
	case 0xE0, 0xE1:
		return hi_lo(oc.icr, off & 1)
	case 0xE2, 0xE3:
		return hi_lo(oc.ipra, off & 1)
	case 0xE4, 0xE5:
		return hi_lo(oc.vcrwdt, off & 1)
	case 0x100 ..< 0x200:
		return u8(oc_read32(cpu, a & ~u32(3)) >> ((3 - (a & 3)) * 8))
	}
	return oc.raw[off]
}

@(private = "file")
hi_lo :: #force_inline proc "contextless" (v: u16, lo: u32) -> u8 {
	return u8(v) if lo != 0 else u8(v >> 8)
}

oc_read16 :: proc "contextless" (cpu: ^SH2, a: u32) -> u16 {
	off := a & 0x1FF
	switch off {
	case 0x60, 0x62, 0x64, 0x66, 0x68, 0xE0, 0xE2, 0xE4:
		return u16(oc_read8(cpu, a)) << 8 | u16(oc_read8(cpu, a + 1))
	case 0x12, 0x14, 0x18:
		return u16(oc_read8(cpu, a)) << 8 | u16(oc_read8(cpu, a + 1))
	case 0x100 ..< 0x200:
		v := oc_read32(cpu, a & ~u32(3))
		return u16(v >> 16) if a & 2 == 0 else u16(v)
	}
	return u16(oc_read8(cpu, a)) << 8 | u16(oc_read8(cpu, a + 1))
}

oc_read32 :: proc "contextless" (cpu: ^SH2, a: u32) -> u32 {
	oc := &cpu.oc
	off := a & 0x1FF
	switch off {
	case 0x100 ..< 0x200:
		// BSC and unused space: plain storage
		switch off {
		case 0x100:
			return oc.dvsr
		case 0x104:
			return oc.dvdnt
		case 0x108:
			return oc.dvcr
		case 0x10C:
			return oc.vcrdiv // Fixed typo from vcrdv
		case 0x110, 0x118:
			return oc.dvdnth
		case 0x114, 0x11C:
			return oc.dvdntl
		case 0x180:
			return oc.dma[0].sar
		case 0x184:
			return oc.dma[0].dar
		case 0x188:
			return oc.dma[0].tcr
		case 0x18C:
			return oc.dma[0].chcr
		case 0x190:
			return oc.dma[1].sar
		case 0x194:
			return oc.dma[1].dar
		case 0x198:
			return oc.dma[1].tcr
		case 0x19C:
			return oc.dma[1].chcr
		case 0x1A0:
			return oc.dma[0].vcr
		case 0x1A8:
			return oc.dma[1].vcr
		case 0x1B0:
			return oc.dmaor
		}

		return(
			u32(oc.raw[off]) << 24 |
			u32(oc.raw[off + 1]) << 16 |
			u32(oc.raw[off + 2]) << 8 |
			u32(oc.raw[off + 3]) \
		)
	}
	return u32(oc_read16(cpu, a)) << 16 | u32(oc_read16(cpu, a + 2))
}

oc_write8 :: proc "contextless" (cpu: ^SH2, a: u32, v: u8) {
	oc := &cpu.oc
	off := a & 0x1FF
	switch off {
	case 0x10:
		frt_sync(cpu); oc.tier = v & 0x8E | 1; sh7604_events(cpu)
	case 0x11:
		frt_sync(cpu)
		oc.ftcsr = (oc.ftcsr & v & 0x8E) | (v & FRT_CCLRA)
		sh7604_events(cpu)
	case 0x12:
		frt_sync(cpu); oc.frc = u16(v) << 8 | oc.frc & 0xFF; sh7604_events(cpu)
	case 0x13:
		frt_sync(cpu); oc.frc = oc.frc & 0xFF00 | u16(v); sh7604_events(cpu)
	case 0x14, 0x15:
		frt_sync(cpu)
		p := &oc.ocra
		if oc.tocr & 0x10 != 0 {p = &oc.ocrb}
		p^ = (p^ & 0x00FF | u16(v) << 8) if off == 0x14 else (p^ & 0xFF00 | u16(v))
		sh7604_events(cpu)
	case 0x16:
		frt_sync(cpu); oc.tcr = v & 0x83; sh7604_events(cpu)
	case 0x17:
		oc.tocr = v | 0xE0
	case 0x60, 0x61:
		set_hi_lo(&oc.iprb, off & 1, v); sh7604_recalc_irq(cpu)
	case 0x62, 0x63:
		set_hi_lo(&oc.vcra, off & 1, v)
	case 0x64, 0x65:
		set_hi_lo(&oc.vcrb, off & 1, v)
	case 0x66, 0x67:
		set_hi_lo(&oc.vcrc, off & 1, v)
	case 0x68, 0x69:
		set_hi_lo(&oc.vcrd, off & 1, v)
	case 0x71:
		oc.dma[0].drcr = v & 3
	case 0x72:
		oc.dma[1].drcr = v & 3
	case 0xE0, 0xE1:
		set_hi_lo(&oc.icr, off & 1, v)
	case 0xE2, 0xE3:
		set_hi_lo(&oc.ipra, off & 1, v); sh7604_recalc_irq(cpu)
	case 0xE4, 0xE5:
		set_hi_lo(&oc.vcrwdt, off & 1, v)
	case 0x100 ..< 0x200:
		// DIVU/DMAC/BSC are 32-bit registers; byte writes are rare. Merge
		// into the current value and write it back whole.
		cur := oc_read32(cpu, a & ~u32(3))
		sh := (3 - (a & 3)) * 8
		oc_write32(cpu, a & ~u32(3), (cur & ~(u32(0xFF) << sh)) | u32(v) << sh)
	case:
		oc.raw[off] = v
	}
}

@(private = "file")
set_hi_lo :: #force_inline proc "contextless" (p: ^u16, lo: u32, v: u8) {
	if lo != 0 {p^ = p^ & 0xFF00 | u16(v)} else {p^ = p^ & 0x00FF | u16(v) << 8}
}

oc_write16 :: proc "contextless" (cpu: ^SH2, a: u32, v: u16) {
	oc := &cpu.oc
	off := a & 0x1FF
	switch off {
	case 0x80:
		// WTCSR / WTCNT: the high byte is a write key
		wdt_sync(cpu)
		switch v >> 8 {
		case 0xA5:
			oc.wtcsr = (oc.wtcsr & u8(v) & 0x80) | u8(v) & 0x7F; oc.wdt_base = cpu.cycles
		case 0x5A:
			oc.wtcnt = u8(v); oc.wdt_base = cpu.cycles
		}
		sh7604_events(cpu)
	case 0x82:
		// RSTCSR
		switch v >> 8 {
		case 0xA5:
			oc.rstcsr &= u8(v) | 0x7F
		case 0x5A:
			oc.rstcsr = oc.rstcsr & 0x80 | u8(v) & 0x60 | 0x1F
		}
	case 0x100 ..< 0x200:
		cur := oc_read32(cpu, a & ~u32(3))
		if a & 2 ==
		   0 {oc_write32(cpu, a & ~u32(3), cur & 0xFFFF | u32(v) << 16)} else {oc_write32(cpu, a & ~u32(3), cur & 0xFFFF0000 | u32(v))}
	case:
		oc_write8(cpu, a, u8(v >> 8))
		oc_write8(cpu, a + 1, u8(v))
	}
}

oc_write32 :: proc "contextless" (cpu: ^SH2, a: u32, v: u32) {
	oc := &cpu.oc
	off := a & 0x1FF
	switch off {
	case 0x100 ..< 0x200:
		switch off {
		case 0x100:
			oc.dvsr = v; return
		case 0x104:
			oc.dvdnt = v; oc.dvdntl = v; divu_32(oc); sh7604_recalc_irq(cpu); return
		case 0x108:
			oc.dvcr = v & 3; sh7604_recalc_irq(cpu); return
		case 0x10C:
			oc.vcrdiv = v & 0x7F; return
		case 0x110, 0x118:
			oc.dvdnth = v; return
		case 0x114, 0x11C:
			oc.dvdntl = v; oc.dvdnt = v; divu_64(oc); sh7604_recalc_irq(cpu); return
		case 0x180:
			oc.dma[0].sar = v; return
		case 0x184:
			oc.dma[0].dar = v; return
		case 0x188:
			oc.dma[0].tcr = v & 0xFFFFFF; return
		case 0x18C:
			oc.dma[0].chcr = (oc.dma[0].chcr & 2 & v) | (v & 0xFFFD); dmac_check(cpu)
			sh7604_recalc_irq(cpu)
			return
		case 0x190:
			oc.dma[1].sar = v; return
		case 0x194:
			oc.dma[1].dar = v; return
		case 0x198:
			oc.dma[1].tcr = v & 0xFFFFFF; return
		case 0x19C:
			oc.dma[1].chcr = (oc.dma[1].chcr & 2 & v) | (v & 0xFFFD); dmac_check(cpu)
			sh7604_recalc_irq(cpu)
			return
		case 0x1A0:
			oc.dma[0].vcr = v & 0x7F; return
		case 0x1A8:
			oc.dma[1].vcr = v & 0x7F; return
		case 0x1B0:
			oc.dmaor = v & 0xF; dmac_check(cpu); return
		}

		// BSC registers are written with a 0xA55A key in the high half.
		oc.raw[off], oc.raw[off + 1] = 0, 0
		if off == 0x1E0 {
			// BCR1: the MASTER bit (15) is a pin, software cannot change it.
			oc.raw[off + 2] = (oc.raw[off + 2] & 0x80) | u8(v >> 8) & 0x1F
			oc.raw[off + 3] = u8(v) & 0xF7
		} else {
			oc.raw[off + 2], oc.raw[off + 3] = u8(v >> 8), u8(v)
		}
	case:
		oc_write16(cpu, a, u16(v >> 16))
		oc_write16(cpu, a + 2, u16(v))
	}
}
