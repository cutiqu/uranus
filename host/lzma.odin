package host

// A raw LZMA1 decoder: no header, output size known in advance, no end marker.
// That is exactly what CHD's "cdlz" codec stores, and all it is used for.

@(private = "file")
Rc :: struct {
	src:         []byte,
	pos:         int,
	range, code: u32,
}

@(private = "file")
rc_next :: proc(rc: ^Rc) -> u32 {
	if rc.pos >= len(rc.src) {return 0}
	b := rc.src[rc.pos]
	rc.pos += 1
	return u32(b)
}

@(private = "file")
rc_norm :: #force_inline proc(rc: ^Rc) {
	if rc.range < 1 << 24 {
		rc.range <<= 8
		rc.code = rc.code << 8 | rc_next(rc)
	}
}

@(private = "file")
rc_bit :: proc(rc: ^Rc, p: ^u16) -> u32 {
	bound := (rc.range >> 11) * u32(p^)
	bit: u32
	if rc.code < bound {
		rc.range = bound
		p^ += (2048 - p^) >> 5
	} else {
		rc.range -= bound
		rc.code -= bound
		p^ -= p^ >> 5
		bit = 1
	}
	rc_norm(rc)
	return bit
}

@(private = "file")
rc_direct :: proc(rc: ^Rc, n: u32) -> u32 {
	v: u32
	for _ in 0 ..< n {
		rc.range >>= 1
		bit: u32
		if rc.code >= rc.range {
			rc.code -= rc.range
			bit = 1
		}
		v = v << 1 | bit
		rc_norm(rc)
	}
	return v
}

// Bit-tree decoders: probabilities are indexed from 1.
@(private = "file")
rc_tree :: proc(rc: ^Rc, probs: []u16, bits: u32) -> u32 {
	m: u32 = 1
	for _ in 0 ..< bits {m = m << 1 | rc_bit(rc, &probs[m])}
	return m - (1 << bits)
}

@(private = "file")
rc_rtree :: proc(rc: ^Rc, probs: []u16, base: int, bits: u32) -> u32 {
	// `base` is signed: the special-position model starts one before its array.
	m, sym: u32 = 1, 0
	for i in 0 ..< bits {
		b := rc_bit(rc, &probs[base + int(m)])
		m = m << 1 | b
		sym |= b << i
	}
	return sym
}

@(private = "file")
Len_Coder :: struct {
	choice, choice2: u16,
	low, mid:        [16 * 8]u16,
	high:            [256]u16,
}

@(private = "file")
len_decode :: proc(rc: ^Rc, l: ^Len_Coder, pos_state: u32) -> u32 {
	if rc_bit(rc, &l.choice) == 0 {return rc_tree(rc, l.low[pos_state * 8:], 3)}
	if rc_bit(rc, &l.choice2) == 0 {return 8 + rc_tree(rc, l.mid[pos_state * 8:], 3)}
	return 16 + rc_tree(rc, l.high[:], 8)
}

LZMA_MAX_LC_LP :: 4

// Decodes exactly len(dst) bytes. False if the stream is malformed.
lzma_decode :: proc(src, dst: []byte, lc, lp, pb: u32) -> bool {
	if len(src) < 5 || src[0] != 0 || lc + lp > LZMA_MAX_LC_LP {return false}
	rc := Rc {
		src   = src,
		pos   = 5,
		range = 0xFFFFFFFF,
		code  = u32(src[1]) << 24 | u32(src[2]) << 16 | u32(src[3]) << 8 | u32(src[4]),
	}

	// All probabilities start at one half (1024 of 2048).
	is_match: [12 * 16]u16
	is_rep, is_rep_g0, is_rep_g1, is_rep_g2: [12]u16
	is_rep0_long: [12 * 16]u16
	pos_slot: [4 * 64]u16
	spec_pos: [128]u16
	align: [16]u16
	match_len, rep_len: Len_Coder
	literal := make([]u16, 0x300 << (lc + lp))
	defer delete(literal)
	for &p in is_match {p = 1024}
	for &p in is_rep {p = 1024}
	for &p in is_rep_g0 {p = 1024}
	for &p in is_rep_g1 {p = 1024}
	for &p in is_rep_g2 {p = 1024}
	for &p in is_rep0_long {p = 1024}
	for &p in pos_slot {p = 1024}
	for &p in spec_pos {p = 1024}
	for &p in align {p = 1024}
	for &p in literal {p = 1024}
	for l in ([]^Len_Coder{&match_len, &rep_len}) {
		l.choice, l.choice2 = 1024, 1024
		for &p in l.low {p = 1024}
		for &p in l.mid {p = 1024}
		for &p in l.high {p = 1024}
	}

	state: u32
	rep0, rep1, rep2, rep3: u32
	pos := 0
	n := len(dst)
	for pos < n {
		pos_state := u32(pos) & (1 << pb - 1)
		if rc_bit(&rc, &is_match[state << 4 + pos_state]) == 0 {
			prev: u32 = u32(dst[pos - 1]) if pos > 0 else 0
			lit_state := ((u32(pos) & (1 << lp - 1)) << lc) + (prev >> (8 - lc))
			probs := literal[0x300 * lit_state:][:0x300]
			sym: u32 = 1
			if state >= 7 {
				if rep0 >= u32(pos) {return false}
				match_byte := u32(dst[pos - int(rep0) - 1])
				offs: u32 = 0x100
				for sym < 0x100 {
					match_byte <<= 1
					match_bit := match_byte & offs
					bit := rc_bit(&rc, &probs[offs + match_bit + sym])
					sym = sym << 1 | bit
					offs &= ~match_bit if bit == 0 else match_bit
				}
			} else {
				for sym < 0x100 {sym = sym << 1 | rc_bit(&rc, &probs[sym])}
			}
			dst[pos] = u8(sym)
			pos += 1
			state = 0 if state < 4 else (state - 3 if state < 10 else state - 6)
			continue
		}

		length: u32
		if rc_bit(&rc, &is_rep[state]) == 0 {
			rep3, rep2, rep1 = rep2, rep1, rep0
			length = len_decode(&rc, &match_len, pos_state)
			state = 7 if state < 7 else 10
			// distance
			len_state := min(length, 3)
			slot := rc_tree(&rc, pos_slot[len_state * 64:], 6)
			if slot < 4 {
				rep0 = slot
			} else {
				direct := (slot >> 1) - 1
				d := (2 | slot & 1) << direct
				if slot < 14 {
					d += rc_rtree(&rc, spec_pos[:], int(d) - int(slot) - 1, direct)
				} else {
					d += rc_direct(&rc, direct - 4) << 4
					d += rc_rtree(&rc, align[:], 0, 4)
				}
				rep0 = d
			}
			if rep0 == 0xFFFFFFFF {break} // end marker (not expected here)
		} else {
			if pos == 0 {return false}
			if rc_bit(&rc, &is_rep_g0[state]) == 0 {
				if rc_bit(&rc, &is_rep0_long[state << 4 + pos_state]) == 0 {
					// short rep: a single byte at distance rep0
					if rep0 >= u32(pos) {return false}
					state = 9 if state < 7 else 11
					dst[pos] = dst[pos - int(rep0) - 1]
					pos += 1
					continue
				}
			} else {
				dist: u32
				if rc_bit(&rc, &is_rep_g1[state]) == 0 {
					dist = rep1
				} else {
					if rc_bit(&rc, &is_rep_g2[state]) == 0 {
						dist = rep2
					} else {
						dist = rep3
						rep3 = rep2
					}
					rep2 = rep1
				}
				rep1 = rep0
				rep0 = dist
			}
			length = len_decode(&rc, &rep_len, pos_state)
			state = 8 if state < 7 else 11
		}

		count := int(length) + 2
		if rep0 >= u32(pos) {return false}
		for _ in 0 ..< count {
			if pos >= n {break}
			dst[pos] = dst[pos - int(rep0) - 1]
			pos += 1
		}
	}
	return pos == n
}
