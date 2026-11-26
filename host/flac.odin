package host

// A FLAC frame decoder, for the "cdfl" hunks of a CHD: CD audio stored as a
// headerless run of FLAC frames (44.1 kHz, 16 bit, stereo), followed by the
// deflated subcode, which is not needed here.
//
// It decodes what the format allows inside a frame: constant, verbatim, fixed
// and LPC subframes, both Rice residual codings, wasted bits, and the three
// stereo decorrelation modes. Frame and subframe checksums are not verified.

@(private = "file")
Bit_Reader :: struct {
	data: []byte,
	pos:  int, // bit position
	err:  bool,
}

@(private = "file")
br_bits :: proc(b: ^Bit_Reader, n: int) -> u32 {
	v: u64
	for _ in 0 ..< n {
		byte_i := b.pos >> 3
		if byte_i >= len(b.data) {
			b.err = true
			return 0
		}
		v = v << 1 | u64((b.data[byte_i] >> u32(7 - (b.pos & 7))) & 1)
		b.pos += 1
	}
	return u32(v)
}

@(private = "file")
br_signed :: proc(b: ^Bit_Reader, n: int) -> i32 {
	if n == 0 {return 0}
	v := br_bits(b, n)
	if n < 32 && v & (1 << u32(n - 1)) != 0 {return i32(i64(v) - (i64(1) << u32(n)))}
	return i32(v)
}

@(private = "file")
br_unary :: proc(b: ^Bit_Reader) -> u32 {
	n: u32
	for !b.err && br_bits(b, 1) == 0 {n += 1}
	return n
}

// A UTF-8 style number (frame or sample index): its value is not needed, but its
// length is.
@(private = "file")
br_utf8 :: proc(b: ^Bit_Reader) {
	first := br_bits(b, 8)
	extra: int
	switch {
	case first & 0x80 == 0: extra = 0
	case first & 0xE0 == 0xC0: extra = 1
	case first & 0xF0 == 0xE0: extra = 2
	case first & 0xF8 == 0xF0: extra = 3
	case first & 0xFC == 0xF8: extra = 4
	case first & 0xFE == 0xFC: extra = 5
	case first == 0xFE: extra = 6
	case: b.err = true
	}
	for _ in 0 ..< extra {br_bits(b, 8)}
}

@(private = "file")
FIXED_COEFS := [5][4]i64{{0, 0, 0, 0}, {1, 0, 0, 0}, {2, -1, 0, 0}, {3, -3, 1, 0}, {4, -6, 4, -1}}

// Decodes the residual of one subframe into out[order:].
@(private = "file")
decode_residual :: proc(b: ^Bit_Reader, out: []i64, order: int) -> bool {
	method := br_bits(b, 2)
	if method > 1 {return false}
	porder := int(br_bits(b, 4))
	parts := 1 << u32(porder)
	n := len(out)
	if n >> u32(porder) < order && porder > 0 {return false}
	param_bits := 4 if method == 0 else 5
	escape := u32(15) if method == 0 else 31
	i := order
	for p in 0 ..< parts {
		count := n >> u32(porder)
		if p == 0 {count -= order}
		if count < 0 || i + count > n {return false}
		param := br_bits(b, param_bits)
		if param == escape {
			raw := int(br_bits(b, 5))
			for _ in 0 ..< count {
				out[i] = i64(br_signed(b, raw))
				i += 1
			}
		} else {
			for _ in 0 ..< count {
				q := br_unary(b)
				r := br_bits(b, int(param)) if param > 0 else 0
				v := u64(q) << param | u64(r)
				out[i] = i64(v >> 1) ~ -i64(v & 1)
				i += 1
			}
		}
		if b.err {return false}
	}
	return true
}

// Decodes one subframe of `n` samples at `bps` bits per sample into out.
@(private = "file")
decode_subframe :: proc(b: ^Bit_Reader, out: []i64, full_bps: int) -> bool {
	n := len(out)
	if br_bits(b, 1) != 0 {return false}
	kind := int(br_bits(b, 6))
	wasted := 0
	if br_bits(b, 1) != 0 {wasted = int(br_unary(b)) + 1}
	bps := full_bps - wasted
	if bps <= 0 || bps > 32 {return false}

	switch {
	case kind == 0: // constant
		v := i64(br_signed(b, bps))
		for i in 0 ..< n {out[i] = v}
	case kind == 1: // verbatim
		for i in 0 ..< n {out[i] = i64(br_signed(b, bps))}
	case kind >= 8 && kind <= 12: // fixed predictor
		order := kind & 7
		if order > n {return false}
		for i in 0 ..< order {out[i] = i64(br_signed(b, bps))}
		if !decode_residual(b, out, order) {return false}
		for i in order ..< n {
			pred: i64
			for k in 0 ..< order {pred += FIXED_COEFS[order][k] * out[i - 1 - k]}
			out[i] += pred
		}
	case kind >= 32: // LPC
		order := (kind & 31) + 1
		if order > n {return false}
		for i in 0 ..< order {out[i] = i64(br_signed(b, bps))}
		precision := int(br_bits(b, 4)) + 1
		if precision == 16 {return false}
		shift := br_signed(b, 5)
		if shift < 0 {return false}
		coefs: [32]i64
		for k in 0 ..< order {coefs[k] = i64(br_signed(b, precision))}
		if !decode_residual(b, out, order) {return false}
		for i in order ..< n {
			pred: i64
			for k in 0 ..< order {pred += coefs[k] * out[i - 1 - k]}
			out[i] += pred >> u32(shift)
		}
	case: return false
	}
	if wasted > 0 {
		for i in 0 ..< n {out[i] <<= u32(wasted)}
	}
	return !b.err
}

// Decodes FLAC frames from `src` until `frames` stereo sample pairs are produced.
// `out` receives interleaved left/right samples (len(out) >= frames * 2).
flac_decode_stereo16 :: proc(src: []byte, out: []i16, frames: int) -> bool {
	b := Bit_Reader{data = src}
	done := 0
	l := make([]i64, 65536)
	r := make([]i64, 65536)
	defer delete(l)
	defer delete(r)

	for done < frames {
		b.pos = (b.pos + 7) &~ 7
		if br_bits(&b, 14) != 0x3FFE {return false}
		br_bits(&b, 2) // reserved, blocking strategy
		bs_code := br_bits(&b, 4)
		sr_code := br_bits(&b, 4)
		chan_code := br_bits(&b, 4)
		size_code := br_bits(&b, 3)
		br_bits(&b, 1)
		br_utf8(&b)

		n: int
		switch bs_code {
		case 1: n = 192
		case 2 ..= 5: n = 576 << u32(bs_code - 2)
		case 6: n = int(br_bits(&b, 8)) + 1
		case 7: n = int(br_bits(&b, 16)) + 1
		case 8 ..= 15: n = 256 << u32(bs_code - 8)
		case: return false
		}
		switch sr_code {
		case 12: br_bits(&b, 8)
		case 13, 14: br_bits(&b, 16)
		}
		br_bits(&b, 8) // header CRC
		if b.err || n > len(l) {return false}

		bps: int
		switch size_code {
		case 0, 4: bps = 16
		case 1: bps = 8
		case 2: bps = 12
		case 5: bps = 20
		case 6: bps = 24
		case: return false
		}

		// Channel assignment: 0-7 independent (only stereo is meaningful here),
		// 8 left+side, 9 side+right, 10 mid+side.
		if chan_code != 1 && chan_code != 8 && chan_code != 9 && chan_code != 10 {return false}
		bps0 := bps + (1 if chan_code == 9 else 0)
		bps1 := bps + (1 if chan_code == 8 || chan_code == 10 else 0)
		if !decode_subframe(&b, l[:n], bps0) {return false}
		if !decode_subframe(&b, r[:n], bps1) {return false}
		b.pos = (b.pos + 7) &~ 7
		br_bits(&b, 16) // frame CRC
		if b.err {return false}

		switch chan_code {
		case 8: // left + side
			for i in 0 ..< n {r[i] = l[i] - r[i]}
		case 9: // side + right
			for i in 0 ..< n {l[i] = l[i] + r[i]}
		case 10: // mid + side
			for i in 0 ..< n {
				mid := l[i] << 1 | (r[i] & 1)
				side := r[i]
				l[i] = (mid + side) >> 1
				r[i] = (mid - side) >> 1
			}
		}
		take := min(n, frames - done)
		for i in 0 ..< take {
			out[(done + i) * 2] = i16(l[i])
			out[(done + i) * 2 + 1] = i16(r[i])
		}
		done += take
	}
	return true
}
