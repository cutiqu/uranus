package host

// CD images. Whatever the file format, a disc is presented to a core as an
// api.Disc: a table of contents plus a reader that returns any sector as 2352
// raw bytes. Internally a disc is a list of *segments*, runs of consecutive
// sectors that come from one place: a stretch of a file, a stretch of a CHD,
// or silence (a PREGAP that is not stored anywhere).
//
//   .cue  one or more FILEs of raw tracks (MODE1/2048, MODE1/2352, MODE2/2336,
//         MODE2/2352, AUDIO), INDEX 00/01 and PREGAP honoured
//   .chd  MAME compressed hunks (see chd.odin)
//   .iso/.bin/.img  a single data track, 2048 or 2352 bytes per sector

import api "../api"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Segment_Kind :: enum u8 {
	Zero,
	File,
	Chd,
}

Segment :: struct {
	start, count: u32, // absolute LBA range
	kind:         Segment_Kind,
	file:         int, // index into Disc_Image.files
	offset:       i64, // File: byte offset of the first sector
	chd_frame:    u32, // Chd: first frame of the run
	size:         u32, // payload bytes per sector in the source: 2048, 2336 or 2352
	stride:       u32, // bytes between sectors in the file (2448 for sectors with subcode)
	swap:         bool, // CHD audio is stored with each 16-bit sample byte-swapped
}

Disc_Image :: struct {
	disc:  api.Disc, // what the core sees; disc.userdata points back here
	files: [dynamic]^os.File,
	segs:  [dynamic]Segment,
	chd:   ^Chd,
}

disc_close :: proc(d: ^Disc_Image) {
	if d == nil {return}
	for f in d.files {os.close(f)}
	delete(d.files)
	delete(d.segs)
	chd_close(d.chd)
	free(d)
}

// ---------------------------------------------------------- sector reads ----

@(private = "file")
bcd :: proc(v: u32) -> u8 {return u8((v / 10) << 4 | v % 10)}

// Builds a raw sector from a stored payload of 2048, 2336 or 2352 bytes. The
// first two get a synthesized sync and header (their EDC/ECC stay zero).
@(private = "file")
raw_from_payload :: proc(payload: []byte, lba: u32, out: []byte) {
	if len(payload) == 2352 {
		copy(out, payload)
		return
	}
	for i in 0 ..< 2352 {out[i] = 0}
	copy(out[:12], CD_SYNC[:])
	fad := lba + 150
	out[12], out[13], out[14] = bcd(fad / 4500), bcd(fad / 75 % 60), bcd(fad % 75)
	if len(payload) == 2048 {
		out[15] = 1
		copy(out[16:], payload)
	} else {
		out[15] = 2
		copy(out[16:], payload)
	}
}

@(private = "file")
disc_read_sector :: proc "c" (userdata: rawptr, lba: u32, out: [^]byte) -> bool {
	context = runtime.default_context()
	d := (^Disc_Image)(userdata)
	buf := out[:api.DISC_SECTOR_SIZE]
	for i in 0 ..< len(buf) {buf[i] = 0}

	seg: ^Segment
	for &s in d.segs {
		if lba >= s.start && lba - s.start < s.count {
			seg = &s
			break
		}
	}
	if seg == nil {return false}
	idx := lba - seg.start

	payload: [2352]byte
	switch seg.kind {
	case .Zero:
		return true
	case .File:
		off := seg.offset + i64(idx) * i64(seg.stride)
		n, err := os.read_at(d.files[seg.file], payload[:seg.size], off)
		if err != nil || n != int(seg.size) {return false}
	case .Chd:
		if !chd_read_frame(d.chd, seg.chd_frame + idx, payload[:seg.size]) {return false}
		if seg.swap {
			for i := 0; i + 1 < int(seg.size); i += 2 {payload[i], payload[i + 1] = payload[i + 1], payload[i]}
		}
	}
	raw_from_payload(payload[:seg.size], lba, buf)
	return true
}

// Fills in the api.Disc the core will hold.
@(private = "file")
finish :: proc(d: ^Disc_Image, track_starts: []u32, is_data: []bool, lead_out: u32) {
	d.disc.userdata = d
	d.disc.read_sector = disc_read_sector
	d.disc.lead_out = lead_out
	d.disc.track_count = u32(len(track_starts))
	for i in 0 ..< len(track_starts) {
		d.disc.tracks[i] = {is_data[i], track_starts[i]}
	}
}

// -------------------------------------------------------------- raw image ---

@(private = "file")
open_raw :: proc(path: string) -> (d: ^Disc_Image, ok: bool) {
	f, err := os.open(path)
	if err != nil {return nil, false}
	size, _ := os.file_size(f)
	head: [16]byte
	_, _ = os.read_at(f, head[:], 0)
	sync_ok := true
	for i in 0 ..< 12 {if head[i] != CD_SYNC[i] {sync_ok = false}}
	sector: u32 = 2352 if sync_ok && size % 2352 == 0 else 2048
	if size < i64(sector) {
		os.close(f)
		return nil, false
	}
	d = new(Disc_Image)
	append(&d.files, f)
	count := u32(size / i64(sector))
	append(&d.segs, Segment{start = 0, count = count, kind = .File, size = sector, stride = sector})
	finish(d, {0}, {true}, count)
	return d, true
}

// ------------------------------------------------------------------- cue ----

@(private = "file")
Cue_Track :: struct {
	is_data:     bool,
	size:        u32,
	file:        int,
	idx0, idx1:  i64, // sector within the file, -1 if absent
	pregap:      u32, // silence inserted before the track (not stored)
}

@(private = "file")
Cue_File :: struct {
	path:    string,
	bytes: i64,
}

// Splits one cue line into tokens, honouring double quotes.
@(private = "file")
cue_tokens :: proc(line: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	i := 0
	for i < len(line) {
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {i += 1}
		if i >= len(line) {break}
		if line[i] == '"' {
			j := i + 1
			for j < len(line) && line[j] != '"' {j += 1}
			append(&out, line[i + 1:j])
			i = j + 1
		} else {
			j := i
			for j < len(line) && line[j] != ' ' && line[j] != '\t' {j += 1}
			append(&out, line[i:j])
			i = j
		}
	}
	return out[:]
}

// "mm:ss:ff" -> sectors.
@(private = "file")
parse_msf :: proc(s: string) -> (i64, bool) {
	parts := strings.split(s, ":", context.temp_allocator)
	if len(parts) != 3 {return 0, false}
	m, ok1 := strconv.parse_int(parts[0])
	sec, ok2 := strconv.parse_int(parts[1])
	f, ok3 := strconv.parse_int(parts[2])
	return i64((m * 60 + sec) * 75 + f), ok1 && ok2 && ok3
}

// Finds a file a cue sheet names: as written (relative to the cue), then by
// bare name in the cue's directory, since dumps often carry stale paths.
@(private = "file")
resolve_cue_file :: proc(cue_dir, name: string) -> (path: string, ok: bool) {
	norm, _ := strings.replace_all(name, "\\", "/", context.temp_allocator)
	try := [2]string{norm, filepath.base(norm)}
	for t in try {
		p, _ := filepath.join({cue_dir, t}, context.temp_allocator)
		if os.exists(p) {return p, true}
	}
	return "", false
}

@(private = "file")
open_cue :: proc(cue_path: string) -> (d: ^Disc_Image, ok: bool) {
	text_bytes, rerr := os.read_entire_file(cue_path, context.temp_allocator)
	if rerr != nil {return nil, false}
	cue_dir := filepath.dir(cue_path)

	files := make([dynamic]Cue_File, context.temp_allocator)
	tracks := make([dynamic]Cue_Track, context.temp_allocator)
	for raw in strings.split_lines(string(text_bytes), context.temp_allocator) {
		tok := cue_tokens(strings.trim_space(raw))
		if len(tok) == 0 {continue}
		cmd := strings.to_upper(tok[0], context.temp_allocator)
		switch cmd {
		case "FILE":
			if len(tok) < 2 {return nil, false}
			if len(tok) >= 3 {
				switch strings.to_upper(tok[2], context.temp_allocator) {
				case "WAVE", "MP3", "AIFF", "FLAC", "OGG":
					fmt.eprintfln("uranus: %s: compressed or WAV audio files in a cue sheet are not supported", tok[1])
					return nil, false
				}
			}
			p, found := resolve_cue_file(cue_dir, tok[1])
			if !found {
				fmt.eprintfln("uranus: cue sheet references a missing file: %s", tok[1])
				return nil, false
			}
			append(&files, Cue_File{path = p})
		case "TRACK":
			if len(tok) < 3 || len(files) == 0 {return nil, false}
			t := Cue_Track{file = len(files) - 1, idx0 = -1, idx1 = -1}
			switch strings.to_upper(tok[2], context.temp_allocator) {
			case "AUDIO": t.size = 2352
			case "MODE1/2048", "MODE2/2048": t.is_data, t.size = true, 2048
			case "MODE1/2352", "MODE2/2352": t.is_data, t.size = true, 2352
			case "MODE2/2336": t.is_data, t.size = true, 2336
			case:
				fmt.eprintfln("uranus: unsupported track type %s", tok[2])
				return nil, false
			}
			append(&tracks, t)
		case "INDEX":
			if len(tok) < 3 || len(tracks) == 0 {return nil, false}
			n, _ := strconv.parse_int(tok[1])
			pos, good := parse_msf(tok[2])
			if !good {return nil, false}
			if n == 0 {tracks[len(tracks) - 1].idx0 = pos}
			if n == 1 {tracks[len(tracks) - 1].idx1 = pos}
		case "PREGAP":
			if len(tok) < 2 || len(tracks) == 0 {return nil, false}
			pos, good := parse_msf(tok[1])
			if !good {return nil, false}
			tracks[len(tracks) - 1].pregap = u32(pos)
		}
	}
	if len(tracks) == 0 || len(tracks) > api.MAX_DISC_TRACKS {return nil, false}

	d = new(Disc_Image)
	good := false
	defer if !good {disc_close(d); d = nil}

	for &f in files {
		h, err := os.open(f.path)
		if err != nil {return nil, false}
		append(&d.files, h)
		size, _ := os.file_size(h)
		f.bytes = size
	}

	// Lay the tracks out one after another along the disc.
	abs: u32
	starts := make([dynamic]u32, context.temp_allocator)
	kinds := make([dynamic]bool, context.temp_allocator)
	for ti in 0 ..< len(tracks) {
		t := &tracks[ti]
		if t.idx1 < 0 {return nil, false}
		first := t.idx0 if t.idx0 >= 0 else t.idx1
		// A track ends where the next track in the same file begins, or at the end of the file.
		file_sectors := files[t.file].bytes / i64(t.size)
		end := file_sectors
		if ti + 1 < len(tracks) && tracks[ti + 1].file == t.file {
			n := &tracks[ti + 1]
			end = n.idx0 if n.idx0 >= 0 else n.idx1
		}
		if end <= first {return nil, false}
		if t.pregap > 0 {
			append(&d.segs, Segment{start = abs, count = t.pregap, kind = .Zero})
			abs += t.pregap
		}
		count := u32(end - first)
		append(&d.segs, Segment{start = abs, count = count, kind = .File, file = t.file, offset = first * i64(t.size), size = t.size, stride = t.size})
		append(&starts, abs + u32(t.idx1 - first))
		append(&kinds, t.is_data)
		abs += count
	}
	finish(d, starts[:], kinds[:], abs)
	good = true
	return d, true
}

// ------------------------------------------------------------------- chd ----

@(private = "file")
open_chd :: proc(path: string) -> (d: ^Disc_Image, ok: bool) {
	c, err := chd_open(path)
	if c == nil {
		fmt.eprintfln("uranus: %s: %s", filepath.base(path), err)
		return nil, false
	}
	d = new(Disc_Image)
	d.chd = c
	starts := make([dynamic]u32, context.temp_allocator)
	kinds := make([dynamic]bool, context.temp_allocator)
	abs: u32
	for t in c.tracks {
		if t.pregap > 0 && !t.pregap_in_stream {
			append(&d.segs, Segment{start = abs, count = t.pregap, kind = .Zero})
			abs += t.pregap
		}
		append(&d.segs, Segment{start = abs, count = t.frames, kind = .Chd, chd_frame = t.stream_start, size = t.data_size, swap = !t.is_data})
		append(&starts, abs + (t.pregap if t.pregap_in_stream else 0))
		append(&kinds, t.is_data)
		abs += t.frames
	}
	finish(d, starts[:], kinds[:], abs)
	return d, true
}

// ------------------------------------------------------------------ entry ---

// True for file extensions that name a disc image.
is_disc_path :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return ext == ".cue" || ext == ".chd" || ext == ".iso" || ext == ".bin" || ext == ".img"
}

// Opens a disc image of any supported format. Reports problems on stderr.
disc_open :: proc(path: string) -> (d: ^Disc_Image, ok: bool) {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	switch ext {
	case ".cue": return open_cue(path)
	case ".chd": return open_chd(path)
	}
	return open_raw(path)
}
