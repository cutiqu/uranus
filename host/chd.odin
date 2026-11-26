package host

// A reader for CD-ROM images in MAME's CHD container (version 5).
//
// A CHD is a sequence of fixed-size "hunks", each stored raw or compressed. For
// CDs a hunk holds 8 frames of 2448 bytes (2352 sector bytes + 96 subcode),
// compressed by "cdlz" (LZMA) or "cdzl" (deflate) with the sync and ECC of
// valid data sectors stripped, or by "cdfl" (FLAC, audio only). Metadata
// entries describe the tracks.
//
// Not supported: parent CHDs and versions before 5. "cdfl" hunks (CD-DA audio
// compressed with FLAC) are decoded by flac.odin.

import "core:compress/deflate"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

CHD_FRAME_SIZE :: 2448 // sector (2352) + subcode (96)
CHD_TRACK_PADDING :: 4 // every track is padded to a multiple of this many frames

Chd_Entry :: struct {
	offset: u64, // file offset, or hunk number for self references
	length: u32,
	kind:   u8, // 0..3 codec slot, 4 stored, 5 self reference, 6 all zeros
}

Chd_Track :: struct {
	number:           int,
	is_data:          bool,
	data_size:        u32, // bytes of the 2352-byte slot that carry the sector: 2048, 2336 or 2352
	frames:           u32, // frames in the stream for this track, including a stored pregap
	pregap:           u32,
	pregap_in_stream: bool, // PGTYPE starts with 'V': the pregap frames are in `frames`
	stream_start:     u32, // first frame of the track in the stream
}

Chd :: struct {
	file:        ^os.File,
	hunk_bytes:  u32,
	hunk_count:  u32,
	codecs:      [4]u32,
	entries:     []Chd_Entry,
	tracks:      [dynamic]Chd_Track,
	cache:       []u8,
	cache_hunk:  i64,
	comp:        []u8,
	flac_warned: bool,
}

chd_close :: proc(c: ^Chd) {
	if c == nil {return}
	if c.file != nil {os.close(c.file)}
	delete(c.entries)
	delete(c.tracks)
	delete(c.cache)
	delete(c.comp)
	free(c)
}

@(private = "file")
read_at :: proc(f: ^os.File, offset: i64, buf: []byte) -> bool {
	got := 0
	for got < len(buf) {
		n, err := os.read_at(f, buf[got:], offset + i64(got))
		if err != nil || n <= 0 {return false}
		got += n
	}
	return true
}

@(private = "file")
be32 :: proc(b: []byte) -> u32 {return(
		u32(b[0]) << 24 |
		u32(b[1]) << 16 |
		u32(b[2]) << 8 |
		u32(b[3]) \
	)}
@(private = "file")
be64 :: proc(b: []byte) -> u64 {return u64(be32(b)) << 32 | u64(be32(b[4:]))}

// ------------------------------------------------------------ bit stream ---

@(private = "file")
Bits :: struct {
	data: []byte,
	pos:  int, // in bits
}

@(private = "file")
bits_peek :: proc(b: ^Bits, n: int) -> u32 {
	v: u32
	for i in 0 ..< n {
		p := b.pos + i
		bit: u32
		if p >> 3 < len(b.data) {bit = u32(b.data[p >> 3] >> u32(7 - (p & 7))) & 1}
		v = v << 1 | bit
	}
	return v
}

@(private = "file")
bits_read :: proc(b: ^Bits, n: int) -> u32 {
	v := bits_peek(b, n)
	b.pos += n
	return v
}

// The map's canonical Huffman code: 16 symbols, codes up to 8 bits.
@(private = "file")
Huff :: struct {
	bits:  [16]u8,
	codes: [16]u32,
}

@(private = "file")
huff_import :: proc(h: ^Huff, b: ^Bits) -> bool {
	cur := 0
	for cur < 16 {
		n := bits_read(b, 4)
		if n != 1 {
			h.bits[cur] = u8(n)
			cur += 1
		} else {
			n = bits_read(b, 4)
			if n == 1 {
				h.bits[cur] = 1
				cur += 1
			} else {
				rep := int(bits_read(b, 4)) + 3
				for _ in 0 ..< rep {
					if cur >= 16 {return false}
					h.bits[cur] = u8(n)
					cur += 1
				}
			}
		}
	}
	// Assign canonical codes, longest first.
	histo: [33]u32
	for i in 0 ..< 16 {
		if h.bits[i] > 8 {return false}
		histo[h.bits[i]] += 1
	}
	start: u32
	for len := 32; len > 0; len -= 1 {
		next := (start + histo[len]) >> 1
		histo[len] = start
		start = next
	}
	for i in 0 ..< 16 {
		if h.bits[i] > 0 {
			h.codes[i] = histo[h.bits[i]]
			histo[h.bits[i]] += 1
		}
	}
	return true
}

@(private = "file")
huff_decode :: proc(h: ^Huff, b: ^Bits) -> (sym: int, ok: bool) {
	for len in 1 ..= 8 {
		code := bits_peek(b, len)
		for i in 0 ..< 16 {
			if int(h.bits[i]) == len && h.codes[i] == code {
				b.pos += len
				return i, true
			}
		}
	}
	return 0, false
}

// ----------------------------------------------------------------- open ----

CHD_TAG :: "MComprHD"

// Opens `path`. Problems are described in `err` (a static string).
chd_open :: proc(path: string) -> (c: ^Chd, err: string) {
	f, ferr := os.open(path)
	if ferr != nil {return nil, "cannot open file"}
	c = new(Chd)
	c.file = f
	c.cache_hunk = -1
	ok := false
	defer if !ok {chd_close(c); c = nil}

	h: [124]byte
	if !read_at(f, 0, h[:]) || string(h[:8]) != CHD_TAG {return nil, "not a CHD file"}
	if be32(h[12:]) != 5 {return nil, "only CHD version 5 is supported"}
	for i in 0 ..< 4 {c.codecs[i] = be32(h[16 + i * 4:])}
	map_offset := be64(h[40:])
	meta_offset := be64(h[48:])
	c.hunk_bytes = be32(h[56:])
	logical := be64(h[32:])
	if c.hunk_bytes == 0 ||
	   c.hunk_bytes % CHD_FRAME_SIZE != 0 {return nil, "not a CD CHD (hunk size)"}
	c.hunk_count = u32((logical + u64(c.hunk_bytes) - 1) / u64(c.hunk_bytes))
	for i in 0 ..< 20 {if h[104 + i] != 0 {return nil, "parent CHDs are not supported"}}

	if !chd_read_map(c, map_offset) {return nil, "corrupt hunk map"}
	if !chd_read_tracks(c, meta_offset) {return nil, "no CD track metadata"}
	c.cache = make([]u8, c.hunk_bytes)
	c.comp = make([]u8, c.hunk_bytes * 2)
	ok = true
	return c, ""
}

@(private = "file")
chd_read_map :: proc(c: ^Chd, offset: u64) -> bool {
	c.entries = make([]Chd_Entry, c.hunk_count)
	if c.codecs[0] == 0 {
		// Uncompressed map: one big-endian 32-bit hunk index per hunk.
		raw := make([]byte, int(c.hunk_count) * 4)
		defer delete(raw)
		if !read_at(c.file, i64(offset), raw) {return false}
		for i in 0 ..< int(c.hunk_count) {
			index := be32(raw[i * 4:])
			// An index of 0 means the hunk was never written: all zeros.
			c.entries[i] = {u64(index) * u64(c.hunk_bytes), c.hunk_bytes, 4 if index != 0 else 6}
		}
		return true
	}

	hdr: [16]byte
	if !read_at(c.file, i64(offset), hdr[:]) {return false}
	map_bytes := int(be32(hdr[:]))
	first := u64(hdr[4]) << 40 | u64(hdr[5]) << 32 | u64(be32(hdr[6:]))
	length_bits, self_bits := int(hdr[12]), int(hdr[13])
	data := make([]byte, map_bytes)
	defer delete(data)
	if !read_at(c.file, i64(offset) + 16, data) {return false}
	bs := Bits {
		data = data,
	}

	huff: Huff
	if !huff_import(&huff, &bs) {return false}

	// Pass 1: each hunk's compression type, run-length coded.
	types := make([]u8, c.hunk_count)
	defer delete(types)
	last: u8
	rep := 0
	for i in 0 ..< int(c.hunk_count) {
		if rep > 0 {
			types[i] = last
			rep -= 1
			continue
		}
		v, ok := huff_decode(&huff, &bs)
		if !ok {return false}
		switch v {
		case 7:
			// RLE small
			types[i] = last
			s, ok2 := huff_decode(&huff, &bs)
			if !ok2 {return false}
			rep = 2 + s
		case 8:
			// RLE large
			types[i] = last
			a, ok2 := huff_decode(&huff, &bs)
			b, ok3 := huff_decode(&huff, &bs)
			if !ok2 || !ok3 {return false}
			rep = 2 + 16 + (a << 4) + b
		case:
			types[i] = u8(v)
			last = u8(v)
		}
	}

	// Pass 2: lengths and offsets.
	cur := first
	last_self: u64
	for i in 0 ..< int(c.hunk_count) {
		e := &c.entries[i]
		t := types[i]
		switch t {
		case 0, 1, 2, 3:
			e.kind, e.offset = t, cur
			e.length = bits_read(&bs, length_bits)
			cur += u64(e.length)
			bits_read(&bs, 16) // CRC
		case 4:
			e.kind, e.offset, e.length = 4, cur, c.hunk_bytes
			cur += u64(c.hunk_bytes)
			bits_read(&bs, 16)
		case 5:
			e.kind, e.offset = 5, u64(bits_read(&bs, self_bits))
			last_self = e.offset
		case 9:
			// same hunk as the previous self reference
			e.kind, e.offset = 5, last_self
		case 10:
			// the one after it
			last_self += 1
			e.kind, e.offset = 5, last_self
		case:
			return false // parent references
		}
	}
	return true
}

// ---------------------------------------------------------------- tracks ----

@(private = "file")
field_value :: proc(s, key: string) -> (string, bool) {
	rest := s
	for tok in strings.split_iterator(&rest, " ") {
		if strings.has_prefix(tok, key) && len(tok) > len(key) && tok[len(key)] == ':' {
			return tok[len(key) + 1:], true
		}
	}
	return "", false
}

@(private = "file")
chd_read_tracks :: proc(c: ^Chd, offset: u64) -> bool {
	off := offset
	for off != 0 {
		h: [16]byte
		if !read_at(c.file, i64(off), h[:]) {return false}
		tag := be32(h[:])
		length := int(be32(h[4:]) & 0xFFFFFF)
		next := be64(h[8:])
		if tag == 0x43485432 || tag == 0x43485452 { 	// 'CHT2' or 'CHTR'
			buf := make([]byte, length)
			defer delete(buf)
			if !read_at(c.file, i64(off) + 16, buf) {return false}
			text := strings.trim_right(string(buf), "\x00 ")
			t: Chd_Track
			v, _ := field_value(text, "TRACK")
			n, _ := strconv.parse_int(v)
			t.number = n
			ty, _ := field_value(text, "TYPE")
			switch ty {
			case "AUDIO":
				t.data_size = 2352
			case "MODE1", "MODE2_FORM1":
				t.is_data, t.data_size = true, 2048
			case "MODE1_RAW", "MODE2_RAW":
				t.is_data, t.data_size = true, 2352
			case "MODE2", "MODE2_FORM_MIX":
				t.is_data, t.data_size = true, 2336
			case:
				return false
			}
			fr, _ := field_value(text, "FRAMES")
			frames, _ := strconv.parse_int(fr)
			t.frames = u32(frames)
			pg, has_pg := field_value(text, "PREGAP")
			pregap, _ := strconv.parse_int(pg)
			t.pregap = u32(pregap) if has_pg else 0
			pt, _ := field_value(text, "PGTYPE")
			t.pregap_in_stream = strings.has_prefix(pt, "V")
			append(&c.tracks, t)
		}
		off = next
	}
	if len(c.tracks) == 0 {return false}
	// Tracks are stored in order, each padded to a multiple of 4 frames.
	frame: u32
	for &t in c.tracks {
		t.stream_start = frame
		frame += (t.frames + CHD_TRACK_PADDING - 1) / CHD_TRACK_PADDING * CHD_TRACK_PADDING
	}
	return true
}

// ----------------------------------------------------------------- hunks ----

@(private = "file")
inflate_raw :: proc(src: []byte, dst: []byte) -> bool {
	buf: [dynamic]u8
	defer delete(buf)

	if deflate.inflate_raw_from_bytes(&buf, src, expected_output_size = len(dst)) != nil {
		return false
	}

	if len(buf) < len(dst) {return false}
	copy(dst, buf[:len(dst)])
	return true
}

// Decodes a CD hunk ("cdlz"/"cdzl"): [ecc flags][base length][base][subcode].
// Subcode is not needed, so it is skipped.
@(private = "file")
decode_cd_hunk :: proc(c: ^Chd, src: []byte, dst: []byte, lzma: bool) -> bool {
	frames := len(dst) / CHD_FRAME_SIZE
	len_bytes := 2 if len(dst) < 65536 else 3
	ecc_bytes := (frames + 7) / 8
	header := ecc_bytes + len_bytes
	if len(src) < header {return false}
	base_len := int(src[ecc_bytes]) << 8 | int(src[ecc_bytes + 1])
	if len_bytes > 2 {base_len = base_len << 8 | int(src[ecc_bytes + 2])}
	if header + base_len > len(src) {return false}

	sectors := make([]byte, frames * 2352)
	defer delete(sectors)
	base := src[header:][:base_len]
	ok := lzma_decode(base, sectors, 3, 0, 2) if lzma else inflate_raw(base, sectors)
	if !ok {return false}

	for f in 0 ..< frames {
		out := dst[f * CHD_FRAME_SIZE:][:CHD_FRAME_SIZE]
		copy(out[:2352], sectors[f * 2352:][:2352])
		for i in 2352 ..< CHD_FRAME_SIZE {out[i] = 0}
		if src[f / 8] & (1 << u32(f % 8)) != 0 {cd_restore_sector(out)}
	}
	return true
}

@(private = "file")
decode_hunk :: proc(c: ^Chd, hunk: u32, dst: []byte, depth: int) -> bool {
	if hunk >= c.hunk_count || depth > 8 {return false}
	e := c.entries[hunk]
	switch e.kind {
	case 6:
		for i in 0 ..< len(dst) {dst[i] = 0}
		return true
	case 4:
		return read_at(c.file, i64(e.offset), dst)
	case 5:
		return decode_hunk(c, u32(e.offset), dst, depth + 1)
	case 0, 1, 2, 3:
		if int(e.length) > len(c.comp) {return false}
		src := c.comp[:e.length]
		if !read_at(c.file, i64(e.offset), src) {return false}
		switch c.codecs[e.kind] {
		case 0x63646C7A:
			return decode_cd_hunk(c, src, dst, true) // 'cdlz'
		case 0x63647A6C:
			return decode_cd_hunk(c, src, dst, false) // 'cdzl'
		case 0x6364666C:
			// 'cdfl': FLAC audio, then the deflated subcode (ignored)
			frames := len(dst) / CHD_FRAME_SIZE
			pcm := make([]i16, frames * 588 * 2)
			defer delete(pcm)
			for i in 0 ..< len(dst) {dst[i] = 0}
			if !flac_decode_stereo16(src, pcm, frames * 588) {
				if !c.flac_warned {
					c.flac_warned = true
					fmt.eprintfln(
						"uranus: chd: a FLAC audio hunk could not be decoded; that audio will be silent",
					)
				}
				return true
			}
			// Audio is kept big-endian in a CHD (the track's swap flag undoes it).
			for f in 0 ..< frames {
				out := dst[f * CHD_FRAME_SIZE:]
				for i in 0 ..< 588 * 2 {
					v := u16(pcm[f * 588 * 2 + i])
					out[i * 2] = u8(v >> 8)
					out[i * 2 + 1] = u8(v)
				}
			}
			return true
		}
	}
	return false
}

// Reads CD frame `frame` of the stream: the first `size` bytes are the
// sector payload (2048, 2336 or 2352) as stored.
chd_read_frame :: proc(c: ^Chd, frame: u32, out: []byte) -> bool {
	fph := c.hunk_bytes / CHD_FRAME_SIZE
	hunk := frame / fph
	if i64(hunk) != c.cache_hunk {
		if !decode_hunk(c, hunk, c.cache, 0) {
			c.cache_hunk = -1
			return false
		}
		c.cache_hunk = i64(hunk)
	}
	copy(out, c.cache[(frame % fph) * CHD_FRAME_SIZE:][:len(out)])
	return true
}
