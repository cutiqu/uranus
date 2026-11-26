package host

// Mode 1 CD-ROM sync, EDC and ECC regeneration (ECMA-130). CHD stores data
// sectors with these stripped whenever they were valid on the original disc,
// so reading a sector back means putting them back.

@(private = "file")
edc_table: [256]u32
@(private = "file")
ecc_f, ecc_b: [256]u8

@(init, private = "file")
cd_ecc_init :: proc "contextless" () {
	for i in 0 ..< 256 {
		j := u32(i)
		for _ in 0 ..< 8 {j = (j >> 1) ~ (0xD8018001 if j & 1 != 0 else 0)}
		edc_table[i] = j
		k := u32(i) << 1
		if i & 0x80 != 0 {k ~= 0x11D}
		ecc_f[i] = u8(k)
		ecc_b[i ~ int(u8(k))] = u8(i)
	}
}

CD_SYNC := [12]u8{0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00}

@(private = "file")
ecc_block :: proc "contextless" (sector: []u8, major_count, minor_count, major_mult, minor_inc: int, dest: int) {
	src := sector[12:] // parity covers everything after the sync
	size := major_count * minor_count
	for major in 0 ..< major_count {
		index := (major >> 1) * major_mult + (major & 1)
		a, b: u8
		for _ in 0 ..< minor_count {
			t := src[index]
			index += minor_inc
			if index >= size {index -= size}
			a ~= t
			b ~= t
			a = ecc_f[a]
		}
		a = ecc_b[ecc_f[a] ~ b]
		sector[dest + major] = a
		sector[dest + major + major_count] = a ~ b
	}
}

// Writes the 12-byte sync, and for mode 1 sectors the EDC and P/Q parity too.
cd_restore_sector :: proc "contextless" (sector: []u8) {
	for i in 0 ..< 12 {sector[i] = CD_SYNC[i]}
	if sector[15] != 1 {return}
	c: u32
	for i in 0 ..< 0x810 {c = (c >> 8) ~ edc_table[(c ~ u32(sector[i])) & 0xFF]}
	sector[0x810], sector[0x811], sector[0x812], sector[0x813] = u8(c), u8(c >> 8), u8(c >> 16), u8(c >> 24)
	for i in 0x814 ..< 0x81C {sector[i] = 0}
	ecc_block(sector, 86, 24, 2, 86, 0x81C)
	ecc_block(sector, 52, 43, 86, 88, 0x8C8)
}
