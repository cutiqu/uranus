// The CD block: the Saturn's CD-ROM controller, driven through four command
// registers (CR1-CR4) and a host-interrupt register (HIRQ). Software sends a
// command, the block answers in the same registers, and sector data comes out
// of a separate data port.
//
// Model: sectors read from the disc image land in one of 200 buffers; filters
// decide which of 24 "partitions" (buffer groups) each sector belongs to; the
// host then pulls whole partitions out through the data port.
//
// The disc is a host-owned api.Disc: a table of contents plus a function that
// returns any sector as 2352 raw bytes. The host handles every image format
// (cue/bin, chd, iso), so none of that lives here.
//
// Status: written from the CD block documentation and Mednafen's behaviour,
// but not yet run against a real game. Audio tracks appear in the TOC and can be
// "played" (time advances, no sound yet); single session only; the file-system
// commands handle plain ISO9660.
package saturn_core

import api "../api"

HIRQ_CMOK :: 0x0001
HIRQ_DRDY :: 0x0002
HIRQ_CSCT :: 0x0004
HIRQ_BFUL :: 0x0008
HIRQ_PEND :: 0x0010
HIRQ_DCHG :: 0x0020
HIRQ_ESEL :: 0x0040
HIRQ_EHST :: 0x0080
HIRQ_ECPY :: 0x0100
HIRQ_EFLS :: 0x0200
HIRQ_SCDQ :: 0x0400

CDB_STAT_BUSY    :: 0x00
CDB_STAT_PAUSE   :: 0x01
CDB_STAT_PLAY    :: 0x03
CDB_STAT_NODISC  :: 0x07
CDB_STAT_PERIODIC :: 0x20 // set on the unprompted ~75 Hz status refresh
CDB_STAT_DTREQ   :: 0x40

NUM_BUFFERS   :: 200
NUM_FILTERS   :: 24
FAD_START     :: 150 // the first user sector is at FAD 150 (LBA 0)
CDDA_RING :: 2048 // frames of CD audio buffered ahead of the SCSP
CDDA_FRAMES :: 588 // stereo frames in one 2352-byte audio sector
SECTOR_PERIOD :: 105 // scanlines per sector: 2x speed is 150 sectors/s

CDB_Buffer :: struct {
	data:  [2352]u8, // always stored in raw layout (sync + header + user data)
	part:  u8,       // partition number, 0xFF = free
	fad:   u32,
	order: u32,
}

CDB_Filter :: struct {
	start, count:         u32, // FAD range (Set Filter Range)
	mode:                 u8,
	channel, file:        u8, // subheader conditions (Set Filter Subheader Conditions)
	submode, submode_mask: u8,
	cinfo, cinfo_mask:    u8,
	true_out:             u8, // partition number a matching sector goes to, 0xFF = discard
	false_out:            u8, // another *filter* that gets the sector next, 0xFF = discard
}

// Filter mode bits (Set Filter Mode).
FILTER_FILE    :: 0x01
FILTER_CHANNEL :: 0x02
FILTER_SUBMODE :: 0x04
FILTER_CINFO   :: 0x08
FILTER_SHREV   :: 0x10 // reverse the subheader conditions
FILTER_FADR    :: 0x40

CDB_File :: struct {
	fad, size:      u32,
	unit, gap, num: u8,
	attr:           u8,
	is_dir:         bool,
	lba:            u32,
}

CDB :: struct {
	disc:     ^api.Disc, // nil = tray empty
	user_off: u32,       // offset of the 2048 user bytes in a raw data sector (16 or 24)
	ip:       [256]u8,   // the first bytes of IP.BIN, kept for region detection
	hirq, hirq_mask: u16,
	cr:    [4]u16, // command registers as written by the host
	res:   [4]u16, // response registers
	status: u8,
	cur_fad: u32,
	results_read: bool, // the host has read CR4 since the last command reply
	auth_type:   u8,    // 0 not authenticated, 1 audio, 2 non-Saturn data, 4 Saturn disc

	// Playback
	play_end:   u32,
	line_count: u32,
	periodic:   u32,
	stalled:    bool, // buffers full: reading paused

	// Selectors
	buffers:   [NUM_BUFFERS]CDB_Buffer,
	filters:   [NUM_FILTERS]CDB_Filter,
	cd_filter: u8, // filter the CD device feeds (0xFF = none)
	last_dest: u8, // partition the drive last stored a sector in (Get Last Buffer Destination)
	cdda:      [CDDA_RING][2]i16, // CD audio waiting for the SCSP (it pulls one frame per sample)
	cdda_r:    u32,
	cdda_n:    u32,
	fs_spos:   u16, // FAD search result (Execute/Get FAD Search)
	fs_part:   u8,
	fs_fad:    u32,
	get_len, put_len: u32, // sector length codes in bytes
	order:     u32,

	// Data transfer
	dt_kind:   u8, // 0 none, 1 TOC, 2 sectors, 3 file info
	dt_pos, dt_words: u32,
	dt_list:   [NUM_BUFFERS]u8,
	dt_count:  u32,
	dt_delete: bool,
	dt_total:  u32,

	// File system (ISO9660)
	files:     [256]CDB_File,
	file_count: u32,
	fs_loaded: bool,
}

// -------------------------------------------------------------- disc setup --

SATURN_MAGIC :: "SEGA SEGASATURN "

@(private = "file")
matches :: proc "contextless" (d: []u8, at: int, s: string) -> bool {
	if at + len(s) > len(d) { return false }
	for i in 0 ..< len(s) { if d[at + i] != s[i] { return false } }
	return true
}

// Reads the first sector of the disc to confirm it is a Saturn disc and to learn
// whether its data sectors are mode 1 or mode 2. False if it is not usable.
cdb_set_disc :: proc "contextless" (c: ^CDB, d: ^api.Disc) -> bool {
	c.disc = nil
	if d == nil || d.track_count == 0 || !d.tracks[0].is_data || d.lead_out < 17 { return false }
	sec: [2352]u8
	if !d.read_sector(d.userdata, 0, raw_data(sec[:])) { return false }
	off: u32 = 24 if sec[15] == 2 else 16
	if !matches(sec[:], int(off), SATURN_MAGIC) { return false }
	c.user_off = off
	for i in 0 ..< len(c.ip) { c.ip[i] = sec[int(off) + i] }
	c.disc = d
	c.status = CDB_STAT_PAUSE
	c.cur_fad = FAD_START
	return true
}

// First bytes of the disc's IP.BIN, for region detection.
cdb_ip_bin :: proc "contextless" (c: ^CDB) -> (p: []u8, ok: bool) {
	if c.disc == nil { return }
	return c.ip[:], true
}

@(private = "file")
lead_out :: #force_inline proc "contextless" (c: ^CDB) -> u32 {
	return c.disc.lead_out if c.disc != nil else 0
}

// The track containing `lba` (the last one that starts at or before it).
@(private = "file")
track_at :: proc "contextless" (c: ^CDB, lba: u32) -> int {
	n := int(c.disc.track_count)
	for i := n - 1; i > 0; i -= 1 { if lba >= c.disc.tracks[i].start_lba { return i } }
	return 0
}

// Selector defaults after a power-up or software reset: every filter feeds the
// buffer partition of the same number on a match and nothing on a miss. The
// BIOS relies on this identity wiring; without it sectors are read and dropped.
@(private = "file")
reset_selectors :: proc "contextless" (c: ^CDB) {
	for i in 0 ..< NUM_BUFFERS { c.buffers[i].part = 0xFF }
	for i in 0 ..< NUM_FILTERS {
		c.filters[i] = {}
		c.filters[i].true_out, c.filters[i].false_out = u8(i), 0xFF
	}
	c.cd_filter = 0xFF
	c.last_dest = 0xFF
	c.fs_spos = 0xFFFF
}

cdb_reset :: proc "contextless" (c: ^CDB) {
	disc, user_off, ip := c.disc, c.user_off, c.ip
	c^ = {}
	c.disc, c.user_off, c.ip = disc, user_off, ip
	c.hirq = 0x0BE1
	c.results_read = true
	c.hirq_mask = 0
	c.get_len, c.put_len = 2048, 2048
	reset_selectors(c)
	c.status = CDB_STAT_PAUSE if disc != nil else CDB_STAT_NODISC
	c.cur_fad = FAD_START
}

// -------------------------------------------------------------- registers ---

@(private = "file")
update_irq :: proc "contextless" (s: ^Saturn) {
	scu_set_ext_line(s, 0, s.cdb.hirq & s.cdb.hirq_mask != 0)
}

@(private = "file")
raise :: proc "contextless" (s: ^Saturn, bits: u16) {
	s.cdb.hirq |= bits
	update_irq(s)
}

// `reg` is (address & 0x3F) >> 2, as in the hardware's register decode.
cdb_read16 :: proc "contextless" (s: ^Saturn, reg: u32) -> u16 {
	c := &s.cdb
	switch reg {
	case 0: return dt_read(c)
	case 2: return c.hirq
	case 3: return c.hirq_mask
	case 6: return c.res[0]
	case 7: return c.res[1]
	case 8: return c.res[2]
	case 9: c.results_read = true; return c.res[3]
	}
	return 0
}

cdb_write16 :: proc "contextless" (s: ^Saturn, reg: u32, v: u16) {
	c := &s.cdb
	switch reg {
	case 2: c.hirq &= v; update_irq(s) // writing 0 clears
	case 3: c.hirq_mask = v; update_irq(s)
	case 6: c.cr[0] = v
	case 7: c.cr[1] = v
	case 8: c.cr[2] = v
	case 9:
		c.cr[3] = v
		execute(s) // writing CR4 starts the command
	}
}

// ---------------------------------------------------------------- helpers ---

@(private = "file")
set_res :: proc "contextless" (c: ^CDB, a, b, cc, d: u16) {
	c.res = {a, b, cc, d}
	c.results_read = false
}

// The standard status report that most commands answer with.
@(private = "file")
status_report :: proc "contextless" (c: ^CDB, flags: u8 = 0) {
	st := u16(c.status | flags)
	if c.disc == nil {
		set_res(c, st << 8, 0xFFFF, 0xFFFF, 0xFFFF)
		return
	}
	fad := c.cur_fad
	set_res(c, st << 8 | 0x80, 0x4101, 0x0100 | u16(fad >> 16), u16(fad))
}

free_buffers :: proc "contextless" (c: ^CDB) -> u32 {
	n: u32
	for i in 0 ..< NUM_BUFFERS { if c.buffers[i].part == 0xFF { n += 1 } }
	return n
}

// Buffers of a partition, oldest first. Returns the count.
@(private = "file")
partition_list :: proc "contextless" (c: ^CDB, part: u8, out: ^[NUM_BUFFERS]u8) -> u32 {
	n: u32
	for i in 0 ..< NUM_BUFFERS {
		if c.buffers[i].part == part { out[n] = u8(i); n += 1 }
	}
	// insertion sort by arrival order
	for i in u32(1) ..< n {
		j := i
		for j > 0 && c.buffers[out[j - 1]].order > c.buffers[out[j]].order {
			out[j - 1], out[j] = out[j], out[j - 1]
			j -= 1
		}
	}
	return n
}

// ---------------------------------------------------------- disc reading ----

// Loads the sector at `fad` into `b` in raw layout (the host always delivers
// 2352 bytes, with sync and header synthesized for cooked images). An
// unreadable sector comes through as zeros.
@(private = "file")
load_sector :: proc "contextless" (c: ^CDB, b: ^CDB_Buffer, fad: u32) {
	b.fad = fad
	if !c.disc.read_sector(c.disc.userdata, fad - FAD_START, raw_data(b.data[:])) {
		for i in 0 ..< 2352 { b.data[i] = 0 }
	}
}

@(private = "file")
filter_reset_cond :: proc "contextless" (f: ^CDB_Filter) {
	f.start, f.count, f.mode = 0, 0, 0
	f.channel, f.file = 0, 0
	f.submode, f.submode_mask, f.cinfo, f.cinfo_mask = 0, 0, 0, 0
}

// Does a raw sector satisfy filter `f`'s conditions? (Mednafen's TestFilterCond.)
// Subheader conditions only apply to mode 2 sectors; mode 1 reads as all zeros.
@(private = "file")
filter_test :: proc "contextless" (f: ^CDB_Filter, data: []u8, fad: u32) -> bool {
	if f.mode & FILTER_FADR != 0 {
		if fad < f.start || fad >= f.start + f.count { return false }
	}
	file, channel, submode, cinfo: u8
	if data[15] == 2 { file, channel, submode, cinfo = data[16], data[17], data[18], data[19] }
	rev := f.mode & FILTER_SHREV != 0 && f.mode & 0x0F != 0
	if f.mode & FILTER_FILE != 0 && file != f.file { return rev }
	if f.mode & FILTER_CHANNEL != 0 && channel != f.channel { return rev }
	if f.mode & FILTER_SUBMODE != 0 && submode & f.submode_mask != f.submode { return rev }
	if f.mode & FILTER_CINFO != 0 && cinfo & f.cinfo_mask != f.cinfo { return rev }
	return !rev
}

// Runs a sector through the filter chain starting at `start`: a match sends it
// to the filter's true output (a partition number, 0xFF = drop it); a miss hands
// it to the filter on the false output. Returns the partition, or 0xFF.
@(private = "file")
route_sector :: proc "contextless" (c: ^CDB, start: u8, data: []u8, fad: u32) -> u8 {
	cur := start
	for _ in 0 ..< NUM_FILTERS {
		if cur >= NUM_FILTERS { return 0xFF }
		f := &c.filters[cur]
		if filter_test(f, data, fad) { return f.true_out if f.true_out < NUM_FILTERS else 0xFF }
		cur = f.false_out
	}
	return 0xFF
}

// Nothing may feed filter `n` from a false output any more (an input can only
// have one source); the CD device connection counts as a source too.
@(private = "file")
filter_disconnect_input :: proc "contextless" (c: ^CDB, n: u8) {
	if n >= NUM_FILTERS { return }
	if c.cd_filter == n { c.cd_filter = 0xFF }
	for i in 0 ..< NUM_FILTERS { if c.filters[i].false_out == n { c.filters[i].false_out = 0xFF } }
}

@(private = "file")
free_slot :: proc "contextless" (c: ^CDB) -> int {
	for i in 0 ..< NUM_BUFFERS { if c.buffers[i].part == 0xFF { return i } }
	return -1
}

@(private = "file")
read_one_sector :: proc "contextless" (s: ^Saturn) {
	c := &s.cdb
	if !c.disc.tracks[track_at(c, c.cur_fad - FAD_START)].is_data {
		c.cur_fad += 1 // CD audio goes to the sound chip, not the sector buffers
		return
	}
	if c.cd_filter == 0xFF {
		c.cur_fad += 1 // nowhere to put it: the drive just spins past
		return
	}
	// Read into a scratch buffer first: where the sector goes (or whether it is
	// kept at all) depends on its header and subheader.
	scratch: CDB_Buffer
	load_sector(c, &scratch, c.cur_fad)
	out := route_sector(c, c.cd_filter, scratch.data[:], c.cur_fad)
	if out != 0xFF {
		slot := free_slot(c)
		if slot < 0 {
			// Buffers full: the real drive pauses (the host sees PAUSE, not PLAY)
			// and picks up again once sectors are freed (see buffers_freed).
			c.stalled = true
			c.status = CDB_STAT_PAUSE
			raise(s, HIRQ_BFUL)
			return
		}
		c.order += 1
		scratch.part, scratch.order = out, c.order
		c.buffers[slot] = scratch
		c.last_dest = out
		raise(s, HIRQ_CSCT)
		if free_buffers(c) == 0 { raise(s, HIRQ_BFUL) }
	}
	c.cur_fad += 1
}

// Something freed sector buffers: a drive that paused because they were full
// carries on playing.
@(private = "file")
buffers_freed :: proc "contextless" (c: ^CDB) {
	if c.stalled && free_buffers(c) > 0 {
		c.stalled = false
		if c.status == CDB_STAT_PAUSE { c.status = CDB_STAT_PLAY }
	}
}

// The SCSP asks for one stereo frame of CD audio per output sample.
cdb_cdda_pop :: proc "contextless" (c: ^CDB) -> [2]i16 {
	if c.cdda_n == 0 { return {0, 0} }
	v := c.cdda[c.cdda_r]
	c.cdda_r = (c.cdda_r + 1) & (CDDA_RING - 1)
	c.cdda_n -= 1
	return v
}

// Reads the audio sector at the current position into the FIFO and moves on.
@(private = "file")
cdda_read_sector :: proc "contextless" (c: ^CDB) {
	raw: [2352]u8
	if !c.disc.read_sector(c.disc.userdata, c.cur_fad - FAD_START, raw_data(raw[:])) {
		for i in 0 ..< 2352 { raw[i] = 0 }
	}
	w := (c.cdda_r + c.cdda_n) & (CDDA_RING - 1)
	for i in 0 ..< CDDA_FRAMES {
		l := i16(u16(raw[i * 4]) | u16(raw[i * 4 + 1]) << 8)
		r := i16(u16(raw[i * 4 + 2]) | u16(raw[i * 4 + 3]) << 8)
		c.cdda[(w + u32(i)) & (CDDA_RING - 1)] = {l, r}
	}
	c.cdda_n += CDDA_FRAMES
	c.cur_fad += 1
}

// Called once per scanline.
cdb_line :: proc "contextless" (s: ^Saturn) {
	c := &s.cdb
	c.periodic += 1
	if c.periodic >= 210 { // ~75 Hz: refresh the status the host sees when idle
		c.periodic = 0
		// Like the real block: the idle report carries the PERIODIC flag, and never
		// replaces a command reply the host has not read yet.
		if c.dt_kind == 0 && c.results_read {
			status_report(c, CDB_STAT_PERIODIC)
			c.results_read = true
		}
		raise(s, HIRQ_SCDQ)
	}
	if c.disc == nil { return }
	if c.stalled {
		buffers_freed(c)
		if c.stalled { return }
	}
	if c.status != CDB_STAT_PLAY { return }
	if c.cur_fad >= c.play_end || c.cur_fad - FAD_START >= lead_out(c) {
		// (CD audio already in the FIFO, a few milliseconds of it, plays out.)
		c.status = CDB_STAT_PAUSE
		raise(s, HIRQ_PEND)
		return
	}
	if !c.disc.tracks[track_at(c, c.cur_fad - FAD_START)].is_data {
		// CD audio plays at 1x in real time: keep the FIFO a few sectors ahead of the
		// SCSP, which consumes it at exactly 44.1 kHz.
		if c.cdda_n + CDDA_FRAMES <= CDDA_RING { cdda_read_sector(c) }
		return
	}
	c.line_count += 1
	if c.line_count < SECTOR_PERIOD { return }
	c.line_count = 0
	read_one_sector(s)
}

// ---------------------------------------------------------- data transfer ---

// Byte at `pos` of the sector as the host sees it with the current length.
@(private = "file")
sector_byte :: proc "contextless" (c: ^CDB, b: ^CDB_Buffer, pos: u32) -> u8 {
	base: u32
	switch c.get_len {
	case 2048: base = c.user_off
	case 2336: base = 16
	case 2340: base = 12
	}
	i := base + pos
	return b.data[i] if i < 2352 else 0
}

@(private = "file")
dt_read :: proc "contextless" (c: ^CDB) -> u16 {
	if c.dt_kind == 0 || c.dt_pos >= c.dt_words { return 0 }
	w := c.dt_pos
	c.dt_pos += 1
	c.dt_total = c.dt_pos
	switch c.dt_kind {
	case 1: // TOC
		e := toc_entry(c, w / 2)
		return u16(e >> 16) if w & 1 == 0 else u16(e)
	case 2: // sector data
		per := c.get_len / 2
		b := &c.buffers[c.dt_list[w / per]]
		o := (w % per) * 2
		return u16(sector_byte(c, b, o)) << 8 | u16(sector_byte(c, b, o + 1))
	case 3: // file info: 6 words per entry
		fi := w / 6
		f := &c.files[fi]
		r := [6]u16{u16(f.fad >> 16), u16(f.fad), u16(f.size >> 16), u16(f.size), u16(f.unit) << 8 | u16(f.gap), u16(f.num) << 8 | u16(f.attr)}
		return r[w % 6]
	}
	return 0
}

// The disc's table of contents as the CD block reports it: 99 track entries,
// then first-track, last-track and lead-out descriptors, 4 bytes each:
// (control/ADR << 24) | FAD, or (control/ADR << 24) | (track number << 16).
toc_entry :: proc "contextless" (c: ^CDB, i: u32) -> u32 {
	if c.disc == nil { return 0xFFFFFFFF }
	n := c.disc.track_count
	ctrl :: proc "contextless" (t: api.Disc_Track) -> u32 { return 0x41000000 if t.is_data else 0x01000000 }
	switch {
	case i < 99:
		if i >= n { return 0xFFFFFFFF }
		return ctrl(c.disc.tracks[i]) | (c.disc.tracks[i].start_lba + FAD_START)
	case i == 99: return ctrl(c.disc.tracks[0]) | 1 << 16
	case i == 100: return ctrl(c.disc.tracks[n - 1]) | n << 16
	case i == 101: return ctrl(c.disc.tracks[n - 1]) | (c.disc.lead_out + FAD_START)
	}
	return 0xFFFFFFFF
}

// ------------------------------------------------------- ISO9660 directory --

@(private = "file")
rd32le :: proc "contextless" (b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

// Reads the user data of LBA `lba` into `out`. Returns false past the image.
@(private = "file")
read_user :: proc "contextless" (c: ^CDB, lba: u32, out: ^[2048]u8) -> bool {
	if lba >= lead_out(c) { return false }
	sec: [2352]u8
	if !c.disc.read_sector(c.disc.userdata, lba, raw_data(sec[:])) { return false }
	for i in 0 ..< 2048 { out[i] = sec[int(c.user_off) + i] }
	return true
}

// Loads the directory at (lba, size) into the file table. Entry 0 is '.', 1 is '..'.
@(private = "file")
load_directory :: proc "contextless" (c: ^CDB, lba, size: u32) {
	c.file_count = 0
	buf: [2048]u8
	remaining := size
	sec := lba
	for remaining > 0 && c.file_count < len(c.files) {
		if !read_user(c, sec, &buf) { break }
		pos := 0
		for pos < 2048 {
			rl := int(buf[pos])
			if rl == 0 { break }
			if c.file_count >= len(c.files) { break }
			f := &c.files[c.file_count]
			f.lba = rd32le(buf[:], pos + 2)
			f.fad = f.lba + FAD_START
			f.size = rd32le(buf[:], pos + 10)
			f.attr = buf[pos + 25]
			f.is_dir = f.attr & 2 != 0
			f.unit, f.gap = buf[pos + 26], buf[pos + 27]
			f.num = u8(c.file_count)
			c.file_count += 1
			pos += rl
		}
		sec += 1
		remaining = remaining - 2048 if remaining > 2048 else 0
	}
	c.fs_loaded = true
}

@(private = "file")
load_root :: proc "contextless" (c: ^CDB) {
	buf: [2048]u8
	if !read_user(c, 16, &buf) { return }
	load_directory(c, rd32le(buf[:], 156 + 2), rd32le(buf[:], 156 + 10))
}

// -------------------------------------------------------------- commands ----

// A play/seek position is either a FAD (bit 23 set) or a track and index
// number (track << 8 | index). As an end position a track number means "through
// the end of that track", and 0 means the end of the disc.
@(private = "file")
position_to_fad :: proc "contextless" (c: ^CDB, pos: u32, is_end: bool) -> u32 {
	if pos & 0x800000 != 0 { return max(pos & 0x7FFFFF, FAD_START) }
	track := (pos >> 8) & 0xFF
	n := c.disc.track_count
	if is_end {
		if track == 0 || track >= n { return FAD_START + c.disc.lead_out }
		return FAD_START + c.disc.tracks[track].start_lba // the next track's start
	}
	if track == 0 { track = 1 }
	if track > n { track = n }
	return FAD_START + c.disc.tracks[track - 1].start_lba
}

// The answer to a command with an invalid argument (a selector number past 23 ...).
@(private = "file")
reject :: proc "contextless" (c: ^CDB) {
	set_res(c, 0xFF00, 0xFFFF, 0xFFFF, 0xFFFF)
}

@(private = "file")
execute :: proc "contextless" (s: ^Saturn) {
	c := &s.cdb
	cr := c.cr
	cmd := u8(cr[0] >> 8)
	part := u8(cr[2] >> 8)

	// Commands that stop the drive cut off the CD audio at once.
	if cmd == 0x04 || cmd == 0x11 || cmd == 0x75 || cmd == 0xE0 { c.cdda_n = 0 }

	switch cmd {
	case 0x00: status_report(c)
	case 0x01: set_res(c, u16(c.status) << 8, 0x0002, 0x0000, 0x0600) // hardware info: version 6 (what Mednafen reports)
	case 0x02: // get TOC
		c.dt_kind, c.dt_pos, c.dt_words, c.dt_total = 1, 0, 0xCC, 0
		set_res(c, u16(c.status | CDB_STAT_DTREQ) << 8, 0xCC, 0, 0)
		raise(s, HIRQ_DRDY)
	case 0x03: // session info
		leadout := FAD_START + lead_out(c)
		if cr[0] & 0xFF == 0 {
			set_res(c, u16(c.status) << 8, 0, 0x0100 | u16(leadout >> 16), u16(leadout))
		} else {
			set_res(c, u16(c.status) << 8, 0, 0x0100, 0)
		}
	case 0x04: // initialise CD system
		if cr[0] & 1 != 0 { reset_selectors(c); c.get_len, c.put_len = 2048, 2048 } // software reset
		c.stalled = false
		if c.disc != nil { c.status = CDB_STAT_PAUSE; c.cur_fad = FAD_START }
		c.dt_kind = 0
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x06: // end data transfer
		words := c.dt_total
		was_sectors := c.dt_kind == 2
		if was_sectors && c.dt_delete {
			for i in 0 ..< c.dt_count { c.buffers[c.dt_list[i]].part = 0xFF }
			buffers_freed(c)
		}
		c.dt_kind, c.dt_delete = 0, false
		set_res(c, u16(c.status) << 8 | u16(words >> 16 & 0xFF), u16(words), 0, 0)
		// "End of host I/O": the BIOS and most games wait for this after pulling
		// sector data. (TOC and file-info transfers do not raise it.)
		if was_sectors { raise(s, HIRQ_EHST) }
	case 0x10: // play
		if c.disc != nil {
			start := u32(cr[0] & 0xFF) << 16 | u32(cr[1])
			end := u32(cr[2] & 0xFF) << 16 | u32(cr[3])
			if start != 0 {
				// A start of 0xFFFFFF carries on from where the drive paused (with the
				// range it was given, if the end is 0xFFFFFF too).
				resume := start == 0xFFFFFF
				if !resume { c.cur_fad = position_to_fad(c, start, false); c.cdda_n = 0 }
				if resume && end == 0xFFFFFF {
					// keep the previous end
				} else if end & 0x800000 != 0 { // a sector count from the start
					c.play_end = c.cur_fad + (end & 0x7FFFFF)
				} else {
					c.play_end = position_to_fad(c, end, true)
				}
				c.status = CDB_STAT_PLAY
				c.line_count, c.stalled = 0, false
			}
		}
		status_report(c)
	case 0x11: // seek
		c.stalled = false
		sp := u32(cr[0] & 0xFF) << 16 | u32(cr[1])
		if sp == 0 {
			c.status = CDB_STAT_PAUSE if c.disc != nil else CDB_STAT_NODISC // stop
		} else if c.disc != nil {
			// 0xFFFFFF is "pause where you are": the position is kept (it used to be
			// read as a seek to FAD 0x7FFFFF, so every status afterwards showed that).
			if sp != 0xFFFFFF { c.cur_fad = position_to_fad(c, sp, false) }
			c.status = CDB_STAT_PAUSE
		}
		status_report(c)
	case 0x30: // set CD device connection
		if part >= NUM_FILTERS && part != 0xFF { reject(c); break }
		// Whatever the CD now feeds cannot also be fed by a filter's false output.
		for i in 0 ..< NUM_FILTERS { if c.filters[i].false_out == part { c.filters[i].false_out = 0xFF } }
		c.cd_filter = part
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x31: set_res(c, u16(c.status) << 8, 0, u16(c.cd_filter) << 8, 0) // get CD device connection
	case 0x32: set_res(c, u16(c.status) << 8, 0, u16(c.last_dest) << 8, 0) // get last buffer destination
	case 0x40: // set filter range
		if part >= NUM_FILTERS { reject(c); break }
		c.filters[part].start = u32(cr[0] & 0xFF) << 16 | u32(cr[1])
		c.filters[part].count = u32(cr[2] & 0xFF) << 16 | u32(cr[3])
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x41: // get filter range
		if part >= NUM_FILTERS { reject(c); break }
		f := &c.filters[part]
		set_res(c, u16(c.status) << 8 | u16(f.start >> 16), u16(f.start), u16(part) << 8 | u16(f.count >> 16), u16(f.count))
	case 0x42: // set filter subheader conditions
		if part >= NUM_FILTERS { reject(c); break }
		f := &c.filters[part]
		f.channel = u8(cr[0])
		f.submode_mask, f.cinfo_mask = u8(cr[1] >> 8), u8(cr[1])
		f.file = u8(cr[2])
		f.submode, f.cinfo = u8(cr[3] >> 8), u8(cr[3])
		status_report(c)
		raise(s, HIRQ_ESEL) // the host waits for this; without it the CD library times out
	case 0x43: // get filter subheader conditions
		if part >= NUM_FILTERS { reject(c); break }
		f := &c.filters[part]
		set_res(c, u16(c.status) << 8 | u16(f.channel), u16(f.submode_mask) << 8 | u16(f.cinfo_mask),
			u16(part) << 8 | u16(f.file), u16(f.submode) << 8 | u16(f.cinfo))
	case 0x44: // set filter mode
		if part >= NUM_FILTERS { reject(c); break }
		c.filters[part].mode = u8(cr[0])
		if cr[0] & 0x80 != 0 { filter_reset_cond(&c.filters[part]) }
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x45: // get filter mode
		if part >= NUM_FILTERS { reject(c); break }
		set_res(c, u16(c.status) << 8 | u16(c.filters[part].mode), 0, u16(part) << 8, 0)
	case 0x46: // set filter connection
		tconn, fconn := u8(cr[1] >> 8), u8(cr[1])
		if part >= NUM_FILTERS || (cr[0] & 1 != 0 && tconn >= NUM_FILTERS && tconn != 0xFF) ||
		   (cr[0] & 2 != 0 && fconn >= NUM_FILTERS && fconn != 0xFF) {
			reject(c)
			break
		}
		if cr[0] & 1 != 0 { c.filters[part].true_out = tconn }
		if cr[0] & 2 != 0 {
			filter_disconnect_input(c, fconn)
			c.filters[part].false_out = fconn
		}
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x47: // get filter connection
		if part >= NUM_FILTERS { reject(c); break }
		f := &c.filters[part]
		set_res(c, u16(c.status) << 8, u16(f.true_out) << 8 | u16(f.false_out), u16(part) << 8, 0)
	case 0x48: // reset selector
		flags := u8(cr[0])
		if flags == 0 {
			// Just empty one partition.
			if part >= NUM_FILTERS { reject(c); break }
			for i in 0 ..< NUM_BUFFERS { if c.buffers[i].part == part { c.buffers[i].part = 0xFF } }
		} else {
			// Each bit resets one thing, for every selector at once.
			for n in 0 ..< NUM_FILTERS {
				if flags & 0x04 != 0 { for i in 0 ..< NUM_BUFFERS { if c.buffers[i].part == u8(n) { c.buffers[i].part = 0xFF } } }
				f := &c.filters[n]
				if flags & 0x10 != 0 { filter_reset_cond(f) } // conditions
				if flags & 0x20 != 0 { // input connectors
					if c.cd_filter == u8(n) { c.cd_filter = 0xFF }
					if f.false_out < NUM_FILTERS { f.false_out = 0xFF }
				}
				if flags & 0x40 != 0 { f.true_out = u8(n) } // true outputs: back to partition n
				if flags & 0x80 != 0 { f.false_out = 0xFF }
			}
		}
		buffers_freed(c)
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x50: // get buffer size
		set_res(c, u16(c.status) << 8, u16(free_buffers(c)), 0x1800, NUM_BUFFERS) // free blocks, selector count, total blocks
	case 0x51: // get sector number in a partition
		if part >= NUM_FILTERS { reject(c); break }
		list: [NUM_BUFFERS]u8
		n := partition_list(c, part, &list)
		set_res(c, u16(c.status) << 8, 0, 0, u16(n))
	case 0x52: // calculate actual size
		list: [NUM_BUFFERS]u8
		n := partition_list(c, part, &list)
		first := u32(cr[1])
		count := u32(cr[3])
		if count == 0xFFFF || first + count > n { count = n - min(first, n) }
		c.dt_total = count * (c.get_len / 2)
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x53: set_res(c, u16(c.status) << 8 | u16(c.dt_total >> 16 & 0xFF), u16(c.dt_total), 0, 0)
	case 0x54: // get sector info
		list: [NUM_BUFFERS]u8
		n := partition_list(c, part, &list)
		offs := u32(cr[1])
		if part >= NUM_FILTERS || n == 0 || (offs != 0xFFFF && offs >= n) { reject(c); break }
		b := &c.buffers[list[n - 1 if offs == 0xFFFF else offs]]
		file, chan, submode, cinfo: u8
		if b.data[15] == 2 { file, chan, submode, cinfo = b.data[16], b.data[17], b.data[18], b.data[19] }
		set_res(c, u16(c.status) << 8 | u16(b.fad >> 16), u16(b.fad), u16(file) << 8 | u16(chan), u16(submode) << 8 | u16(cinfo))
	case 0x55: // execute FAD search
		list: [NUM_BUFFERS]u8
		n := partition_list(c, part, &list)
		offs := u32(cr[1])
		sfad := u32(cr[2] & 0xFF) << 16 | u32(cr[3])
		if part >= NUM_FILTERS || n == 0 || (offs != 0xFFFF && offs >= n) { reject(c); break }
		c.fs_spos, c.fs_part, c.fs_fad = 0xFFFF, part, 0
		start := n - 1 if offs == 0xFFFF else offs
		matched := false
		for i in start ..< n {
			fad := c.buffers[list[i]].fad
			if fad <= sfad && fad >= c.fs_fad + u32(matched) {
				c.fs_spos, c.fs_fad, matched = u16(i), fad, true
			}
		}
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x56: set_res(c, u16(c.status) << 8, c.fs_spos, u16(c.fs_part) << 8 | u16(c.fs_fad >> 16), u16(c.fs_fad)) // get FAD search result
	case 0x60: // set sector length
		lens := [4]u32{2048, 2336, 2340, 2352}
		g, p := u32(cr[0] & 0xFF), u32(cr[1] >> 8)
		if g < 4 { c.get_len = lens[g] }
		if p < 4 { c.put_len = lens[p] }
		status_report(c)
		raise(s, HIRQ_ESEL)
	case 0x61, 0x63: // get (and delete) sector data
		list: [NUM_BUFFERS]u8
		n := partition_list(c, part, &list)
		first := u32(cr[1])
		count := u32(cr[3])
		if count == 0xFFFF || first + count > n { count = n - min(first, n) }
		if count == 0 {
			set_res(c, u16(c.status | 0x80) << 8, 0xFFFF, 0, 0) // rejected
			break
		}
		for i in 0 ..< count { c.dt_list[i] = list[first + i] }
		c.dt_count, c.dt_kind, c.dt_pos, c.dt_total = count, 2, 0, 0
		c.dt_words = count * (c.get_len / 2)
		c.dt_delete = cmd == 0x63
		status_report(c, CDB_STAT_DTREQ)
		raise(s, HIRQ_DRDY)
	case 0x62: // delete sector data
		list: [NUM_BUFFERS]u8
		n := partition_list(c, part, &list)
		first := u32(cr[1])
		count := u32(cr[3])
		if count == 0xFFFF || first + count > n { count = n - min(first, n) }
		for i in 0 ..< count { c.buffers[list[first + i]].part = 0xFF }
		buffers_freed(c)
		status_report(c)
		raise(s, HIRQ_EHST)
	case 0x65, 0x66: // copy / move sector data into a filter
		dst := u8(cr[0])
		list: [NUM_BUFFERS]u8
		n := partition_list(c, part, &list)
		if part >= NUM_FILTERS || dst >= NUM_FILTERS { reject(c); break }
		first, count := u32(cr[1]), u32(cr[3])
		if first == 0xFFFF { first = n - 1 if n > 0 else 0 }
		if count == 0xFFFF { count = n - min(first, n) }
		if c.dt_kind != 0 || count == 0 || first + count > n || (cmd == 0x65 && count > free_buffers(c)) {
			status_report(c, 0x80) // WAIT: cannot do it right now
			break
		}
		filter_disconnect_input(c, dst)
		for i in 0 ..< count {
			src := &c.buffers[list[first + i]]
			if cmd == 0x66 {
				out := route_sector(c, dst, src.data[:], src.fad)
				src.part = out // 0xFF frees the buffer
				if out != 0xFF { c.order += 1; src.order = c.order }
			} else {
				out := route_sector(c, dst, src.data[:], src.fad)
				if out != 0xFF {
					if slot := free_slot(c); slot >= 0 {
						c.buffers[slot] = src^
						c.order += 1
						c.buffers[slot].part, c.buffers[slot].order = out, c.order
					}
				}
			}
		}
		buffers_freed(c)
		status_report(c)
		if free_buffers(c) == 0 { raise(s, HIRQ_BFUL) }
		raise(s, HIRQ_ECPY)
	case 0x67: set_res(c, u16(c.status) << 8, 0, 0, 0) // get copy error: copies finish instantly
	case 0x70, 0x71: // change / read directory
		fid := u32(cr[2] & 0xFF) << 16 | u32(cr[3])
		if !c.fs_loaded || fid == 0xFFFFFF || fid == 0 {
			load_root(c)
		} else if fid < c.file_count && c.files[fid].is_dir {
			d := c.files[fid]
			load_directory(c, d.lba, d.size)
		}
		status_report(c)
		raise(s, HIRQ_EFLS)
	case 0x72: // get file system scope
		if !c.fs_loaded { load_root(c) }
		set_res(c, u16(c.status) << 8, u16(c.file_count), 0x0100, 2)
		raise(s, HIRQ_EFLS)
	case 0x73: // get file info
		if !c.fs_loaded { load_root(c) }
		fid := u32(cr[2] & 0xFF) << 16 | u32(cr[3])
		if fid == 0xFFFFFF {
			c.dt_kind, c.dt_pos, c.dt_words, c.dt_total = 3, 0, c.file_count * 6, 0
			set_res(c, u16(c.status | CDB_STAT_DTREQ) << 8, u16(c.file_count * 6), 0, 0)
		} else if fid < c.file_count {
			// Single entry: expose just that record through the same reader.
			c.files[0] = c.files[fid]
			c.dt_kind, c.dt_pos, c.dt_words, c.dt_total = 3, 0, 6, 0
			set_res(c, u16(c.status | CDB_STAT_DTREQ) << 8, 6, 0, 0)
		}
		raise(s, HIRQ_DRDY)
	case 0x74: // read file
		if !c.fs_loaded { load_root(c) }
		fid := u32(cr[2] & 0xFF) << 16 | u32(cr[3])
		offset := u32(cr[0] & 0xFF) << 16 | u32(cr[1])
		if fid < c.file_count && c.disc != nil {
			f := &c.files[fid]
			c.cur_fad = f.fad + offset
			c.play_end = f.fad + (f.size + 2047) / 2048
			c.cd_filter = part if part < NUM_FILTERS else c.cd_filter
			c.status = CDB_STAT_PLAY
			c.line_count, c.stalled = 0, false
		}
		status_report(c)
		raise(s, HIRQ_EFLS)
	case 0x75: // abort file
		c.stalled = false
		c.status = CDB_STAT_PAUSE if c.disc != nil else CDB_STAT_NODISC
		status_report(c)
		raise(s, HIRQ_EFLS)
	case 0xE0: // authenticate device: reads sector 0 and classifies the disc
		if part >= NUM_FILTERS {
			set_res(c, 0xFF00, 0xFFFF, 0xFFFF, 0xFFFF) // rejected
			break
		}
		c.auth_type = 0
		if c.disc != nil {
			sec: [2352]u8
			c.auth_type = 2
			if !c.disc.tracks[0].is_data {
				c.auth_type = 1
			} else if c.disc.read_sector(c.disc.userdata, 0, raw_data(sec[:])) &&
			   matches(sec[:], int(c.user_off), SATURN_MAGIC) {
				c.auth_type = 4
			}
			// The real block parks the connection the way a finished auth leaves it.
			c.cd_filter = 0xFF
			c.filters[part] = {true_out = part, false_out = 0xFF}
			c.cur_fad, c.status, c.stalled = FAD_START, CDB_STAT_PAUSE, false
		}
		status_report(c)
		raise(s, HIRQ_EFLS)
	case 0xE1: set_res(c, u16(c.status) << 8, u16(c.auth_type), 0, 0) // get device authentication status
	case 0xE2: set_res(c, u16(c.status) << 8, 0, 0, 0) // MPEG status: no card
	case: status_report(c)
	}
	raise(s, HIRQ_CMOK)
	trace_command(s, cr)
}

// One log line per command: what the host sent, what the block answered, and
// the interrupt state afterwards. The host prints it only under `emu -v`. This is
// the quickest way to see where a BIOS boot stops.
@(private = "file")
trace_command :: proc "contextless" (s: ^Saturn, cr: [4]u16) {
	c := &s.cdb
	if diag_cdb_poll_hidden(s, cr[0] >> 8) { return }
	key: [9]u16
	for i in 0 ..< 4 { key[i], key[4 + i] = cr[i], c.res[i] }
	key[8] = c.hirq
	if diag_cdb_repeat(s, key) { return }
	l: Log_Buf
	lb_str(&l, "cdb cmd ")
	for i in 0 ..< 4 { lb_hex(&l, u32(cr[i]), 4); lb_str(&l, " ") }
	lb_str(&l, "-> ")
	for i in 0 ..< 4 { lb_hex(&l, u32(c.res[i]), 4); lb_str(&l, " ") }
	lb_str(&l, "hirq=")
	lb_hex(&l, u32(c.hirq), 4)
	lb_str(&l, "/")
	lb_hex(&l, u32(c.hirq_mask), 4)
	lb_str(&l, " f=")
	lb_dec(&l, s.frame)
	log_flush(s, .Info, &l)
}
