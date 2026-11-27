// The Saturn memory map, as seen by the SH-2s (and by SCU DMA). Addresses
// arriving here are already physical (top three bits stripped by the CPU).
//
//   0x00000000  BIOS ROM (512 KiB, mirrored)      0x05800000  CD block
//   0x00100000  SMPC (odd-byte registers)         0x05A00000  SCSP RAM
//   0x00180000  backup RAM (odd bytes)            0x05B00000  SCSP registers
//   0x00200000  work RAM low (1 MiB)              0x05C00000  VDP1 VRAM / framebuffer
//   0x01000000  MINIT   0x01800000 SINIT          0x05D00000  VDP1 registers
//   0x02000000  cartridge (absent: reads 0xFF)    0x05E00000  VDP2 VRAM
//   0x06000000  work RAM high (1 MiB, mirrored)   0x05F00000  VDP2 CRAM / registers
//                                                 0x05FE0000  SCU registers
package saturn_core

@(private = "file")
be16 :: #force_inline proc "contextless" (b: []u8, i: u32) -> u16 {
	return u16(b[i]) << 8 | u16(b[i + 1])
}

@(private = "file")
be32 :: #force_inline proc "contextless" (b: []u8, i: u32) -> u32 {
	return u32(b[i]) << 24 | u32(b[i + 1]) << 16 | u32(b[i + 2]) << 8 | u32(b[i + 3])
}

@(private = "file")
put16 :: #force_inline proc "contextless" (b: []u8, i: u32, v: u16) {
	b[i], b[i + 1] = u8(v >> 8), u8(v)
}

@(private = "file")
put32 :: #force_inline proc "contextless" (b: []u8, i: u32, v: u32) {
	b[i], b[i + 1], b[i + 2], b[i + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

// Region ids for the slow path.
@(private = "file")
Region :: enum u8 {Open, Bios, Smpc, Backup, Wram_L, Minit, Sinit, Cart, Cdb, Scsp_Ram, Scsp_Reg, Vdp1_Vram, Vdp1_Fb, Vdp1_Reg, Vdp2_Vram, Vdp2_Cram, Vdp2_Reg, Scu, Wram_H}

@(private = "file")
region_of :: proc "contextless" (a: u32) -> Region {
	switch a >> 24 {
	case 0x00:
		switch (a >> 20) & 0xF {
		case 0: return .Bios
		case 1: return .Smpc if a & 0x80000 == 0 else .Backup
		case 2, 3: return .Wram_L
		}
	case 0x01: return .Minit if a & 0x800000 == 0 else .Sinit
	case 0x02, 0x03, 0x04: return .Cart
	case 0x05:
		switch (a >> 20) & 0xF {
		case 8: return .Cdb
		case 0xA: return .Scsp_Ram
		case 0xB: return .Scsp_Reg
		case 0xC: return .Vdp1_Vram if a & 0x80000 == 0 else .Vdp1_Fb
		case 0xD: return .Vdp1_Reg
		case 0xE: return .Vdp2_Vram
		case 0xF:
			switch (a >> 16) & 0xF {
			case 0 ..= 7: return .Vdp2_Cram
			case 8 ..= 0xB: return .Vdp2_Reg
			case 0xE: return .Scu
			}
		}
	case 0x06, 0x07: return .Wram_H
	}
	return .Open
}

// ------------------------------------------------------------------ reads ---

mem_read8 :: proc "contextless" (s: ^Saturn, a: u32) -> u8 {
	// Work RAM high (0x06000000-0x07FFFFFF) is where nearly all hot code and data lives:
	// skip the region switch. Same result as the .Wram_H case below.
	if a >> 25 == 3 { return s.wram_h[a & 0xFFFFF] }
	switch region_of(a) {
	case .Wram_H: return s.wram_h[a & 0xFFFFF]
	case .Wram_L: return s.wram_l[a & 0xFFFFF]
	case .Bios: return s.bios[a & 0x7FFFF]
	case .Smpc: return smpc_read(s, (a & 0x7F) >> 1) if a & 1 != 0 else 0xFF
	case .Backup: return s.backup[(a >> 1) & 0x7FFF] if a & 1 != 0 else 0xFF
	case .Cart: return 0xFF
	case .Cdb, .Vdp1_Reg, .Vdp2_Reg, .Scu, .Vdp1_Fb:
		v := mem_read16(s, a & ~u32(1))
		return u8(v) if a & 1 != 0 else u8(v >> 8)
	case .Scsp_Ram: return s.scsp.ram[a & 0x7FFFF]
	case .Scsp_Reg: return scsp_reg_read8(s, a & 0xFFF)
	case .Vdp1_Vram: return s.vdp1.vram[a & 0x7FFFF]
	case .Vdp2_Vram: return s.vdp2.vram[a & 0x7FFFF]
	case .Vdp2_Cram: return s.vdp2.cram[a & 0xFFF]
	case .Minit, .Sinit, .Open:
	}
	return 0
}

mem_read16 :: proc "contextless" (s: ^Saturn, a: u32) -> u16 {
	if a >> 25 == 3 { return be16(s.wram_h[:], a & 0xFFFFE) }
	switch region_of(a) {
	case .Wram_H: return be16(s.wram_h[:], a & 0xFFFFE)
	case .Wram_L: return be16(s.wram_l[:], a & 0xFFFFE)
	case .Bios: return be16(s.bios[:], a & 0x7FFFE)
	case .Smpc: return 0xFF00 | u16(smpc_read(s, (a & 0x7F) >> 1))
	case .Backup: return 0xFF00 | u16(s.backup[(a >> 1) & 0x7FFF])
	case .Cart: return 0xFFFF
	case .Cdb:
		if a & 0x7FFF < 0x1000 { return cdb_read16(s, (a & 0x3F) >> 2) }
		return 0
	case .Scsp_Ram: return be16(s.scsp.ram[:], a & 0x7FFFE)
	case .Scsp_Reg: return scsp_reg_read16(s, a & 0xFFE)
	case .Vdp1_Vram: return be16(s.vdp1.vram[:], a & 0x7FFFE)
	case .Vdp1_Fb: return vdp1_fb_read16(&s.vdp1, a & 0x3FFFE)
	case .Vdp1_Reg: return vdp1_reg_read(&s.vdp1, a)
	case .Vdp2_Vram: return be16(s.vdp2.vram[:], a & 0x7FFFE)
	case .Vdp2_Cram: return be16(s.vdp2.cram[:], a & 0xFFE)
	case .Vdp2_Reg: return vdp2_reg_read(&s.vdp2, a)
	case .Scu:
		v := scu_read32(s, a & 0xFC)
		return u16(v >> 16) if a & 2 == 0 else u16(v)
	case .Minit, .Sinit, .Open:
	}
	return 0
}

mem_read32 :: proc "contextless" (s: ^Saturn, a: u32) -> u32 {
	if a >> 25 == 3 { return be32(s.wram_h[:], a & 0xFFFFC) }
	switch region_of(a) {
	case .Wram_H: return be32(s.wram_h[:], a & 0xFFFFC)
	case .Wram_L: return be32(s.wram_l[:], a & 0xFFFFC)
	case .Bios: return be32(s.bios[:], a & 0x7FFFC)
	case .Scsp_Ram: return be32(s.scsp.ram[:], a & 0x7FFFC)
	case .Vdp1_Vram: return be32(s.vdp1.vram[:], a & 0x7FFFC)
	case .Vdp2_Vram: return be32(s.vdp2.vram[:], a & 0x7FFFC)
	case .Vdp2_Cram: return be32(s.vdp2.cram[:], a & 0xFFC)
	case .Scu: return scu_read32(s, a & 0xFC)
	case .Cart: return 0xFFFFFFFF
	case .Smpc, .Backup, .Cdb, .Scsp_Reg, .Vdp1_Fb, .Vdp1_Reg, .Vdp2_Reg, .Minit, .Sinit, .Open:
	}
	// Everything else is 16 bits wide: a long access is two word accesses.
	// (For the CD data port that is exactly what a long read of it means.)
	return u32(mem_read16(s, a)) << 16 | u32(mem_read16(s, a + 2))
}

// ----------------------------------------------------------------- writes ---

mem_write8 :: proc "contextless" (s: ^Saturn, a: u32, v: u8) {
	if a >> 25 == 3 { s.wram_h[a & 0xFFFFF] = v; return }
	switch region_of(a) {
	case .Wram_H: s.wram_h[a & 0xFFFFF] = v
	case .Wram_L: s.wram_l[a & 0xFFFFF] = v
	case .Smpc: if a & 1 != 0 { smpc_write(s, (a & 0x7F) >> 1, v) }
	case .Backup: if a & 1 != 0 { s.backup[(a >> 1) & 0x7FFF] = v; s.backup_dirty = true }
	case .Scsp_Ram: s.scsp.ram[a & 0x7FFFF] = v
	case .Scsp_Reg: scsp_reg_write8(s, a & 0xFFF, v)
	case .Vdp1_Vram: s.vdp1.vram[a & 0x7FFFF] = v
	case .Vdp2_Vram: s.vdp2.vram[a & 0x7FFFF] = v
	case .Vdp2_Cram: s.vdp2.cram[a & 0xFFF] = v
	case .Vdp1_Fb, .Vdp1_Reg, .Vdp2_Reg, .Scu, .Cdb:
		// Registers behind a 16/32-bit port: merge the byte into the word.
		w := mem_read16(s, a & ~u32(1))
		if a & 1 != 0 { w = w & 0xFF00 | u16(v) } else { w = w & 0x00FF | u16(v) << 8 }
		mem_write16(s, a & ~u32(1), w)
	case .Bios, .Cart, .Minit, .Sinit, .Open: // a byte write does not pulse FTI (Mednafen: only wider writes do)
	}
}

mem_write16 :: proc "contextless" (s: ^Saturn, a: u32, v: u16) {
	if a >> 25 == 3 { put16(s.wram_h[:], a & 0xFFFFE, v); return }
	switch region_of(a) {
	case .Wram_H: put16(s.wram_h[:], a & 0xFFFFE, v)
	case .Wram_L: put16(s.wram_l[:], a & 0xFFFFE, v)
	case .Smpc: smpc_write(s, (a & 0x7F) >> 1, u8(v))
	case .Backup: s.backup[(a >> 1) & 0x7FFF] = u8(v); s.backup_dirty = true
	case .Minit: s.diag.minit_n += 1; sh7604_frt_capture(&s.cpu[1]) // the master pulses the slave's FTI pin
	case .Sinit: s.diag.sinit_n += 1; sh7604_frt_capture(&s.cpu[0])
	case .Cdb: if a & 0x7FFF < 0x1000 { cdb_write16(s, (a & 0x3F) >> 2, v) }
	case .Scsp_Ram: put16(s.scsp.ram[:], a & 0x7FFFE, v)
	case .Scsp_Reg: scsp_reg_write16(s, a & 0xFFE, v)
	case .Vdp1_Vram: put16(s.vdp1.vram[:], a & 0x7FFFE, v)
	case .Vdp1_Fb: vdp1_fb_write16(&s.vdp1, a & 0x3FFFE, v)
	case .Vdp1_Reg: vdp1_reg_write(s, a, v)
	case .Vdp2_Vram: put16(s.vdp2.vram[:], a & 0x7FFFE, v)
	case .Vdp2_Cram: put16(s.vdp2.cram[:], a & 0xFFE, v)
	case .Vdp2_Reg: vdp2_reg_write(&s.vdp2, a, v)
	case .Scu:
		// SCU registers are 32 bits wide; a halfword write replaces one half.
		cur := scu_read32(s, a & 0xFC)
		if a & 2 == 0 { cur = cur & 0xFFFF | u32(v) << 16 } else { cur = cur & 0xFFFF0000 | u32(v) }
		scu_write32(s, a & 0xFC, cur)
	case .Bios, .Cart, .Open:
	}
}

mem_write32 :: proc "contextless" (s: ^Saturn, a: u32, v: u32) {
	if a >> 25 == 3 { put32(s.wram_h[:], a & 0xFFFFC, v); return }
	switch region_of(a) {
	case .Wram_H: put32(s.wram_h[:], a & 0xFFFFC, v)
	case .Wram_L: put32(s.wram_l[:], a & 0xFFFFC, v)
	case .Scsp_Ram: put32(s.scsp.ram[:], a & 0x7FFFC, v)
	case .Vdp1_Vram: put32(s.vdp1.vram[:], a & 0x7FFFC, v)
	case .Vdp2_Vram: put32(s.vdp2.vram[:], a & 0x7FFFC, v)
	case .Vdp2_Cram: put32(s.vdp2.cram[:], a & 0xFFC, v)
	case .Scu: scu_write32(s, a & 0xFC, v)
	case .Bios, .Cart, .Open:
	case .Smpc, .Backup, .Cdb, .Scsp_Reg, .Vdp1_Fb, .Vdp1_Reg, .Vdp2_Reg, .Minit, .Sinit:
		mem_write16(s, a, u16(v >> 16))
		mem_write16(s, a + 2, u16(v))
	}
}
