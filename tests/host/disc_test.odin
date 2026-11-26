package host_tests

// CD image formats. The fixtures are a two-track disc (see
// make_disc_fixtures.py): 16 data sectors, then an audio track whose 16-sector
// pregap is stored in the file, then 6 audio sectors. chdman built the CHDs
// from the same files, so they are ground truth for the CHD reader.

import host "../../host"
import "core:fmt"
import "core:os"
import "core:testing"

FIXTURES :: #directory + "fixtures/"

DATA_SECTORS :: 16
PREGAP :: 16
AUDIO_SECTORS :: 6
AUDIO_START :: DATA_SECTORS + PREGAP // lba of track 2's INDEX 01
LEAD_OUT :: AUDIO_START + AUDIO_SECTORS

@(private = "file")
Sector :: [2352]u8

@(private = "file")
read :: proc(d: ^host.Disc_Image, lba: u32) -> (s: Sector, ok: bool) {
	ok = d.disc.read_sector(d.disc.userdata, lba, raw_data(s[:]))
	return
}

@(private = "file")
open :: proc(t: ^testing.T, name: string) -> ^host.Disc_Image {
	d, ok := host.disc_open(fmt.tprintf("%s%s", FIXTURES, name))
	testing.expectf(t, ok, "could not open %s", name)
	return d
}

@(private = "file")
bcd :: proc(v: int) -> u8 {return u8((v / 10) << 4 | v % 10)}

// What the fixture generator wrote at data sector n, up to the EDC/ECC area.
@(private = "file")
expect_data_sector :: proc(t: ^testing.T, s: Sector, n: int, check_edc := false, loc := #caller_location) {
	sync := [12]u8{0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0}
	for i in 0 ..< 12 {if s[i] != sync[i] {testing.fail_now(t, "bad sync", loc)}}
	fad := n + 150
	testing.expect_value(t, s[12], bcd(fad / 4500), loc = loc)
	testing.expect_value(t, s[13], bcd(fad / 75 % 60), loc = loc)
	testing.expect_value(t, s[14], bcd(fad % 75), loc = loc)
	testing.expect_value(t, s[15], 1, loc = loc)
	for i in 0 ..< 2048 {
		want := u8(n * 31 + i * 7)
		if n == 0 && i < 0x80 {
			head := "SEGA SEGASATURN TEST DISC"
			want = head[i] if i < len(head) else ' '
		}
		if s[16 + i] != want {
			testing.expectf(t, false, "sector %d user byte %d: 0x%02X, want 0x%02X", n, i, s[16 + i], want, loc = loc)
			return
		}
	}
	if !check_edc {return}
	// The EDC covers sync, header and data; a correct one proves the stripped
	// error-correction data was regenerated (CHD stores it removed).
	crc: u32
	table: [256]u32
	for i in 0 ..< 256 {
		j := u32(i)
		for _ in 0 ..< 8 {j = (j >> 1) ~ (0xD8018001 if j & 1 != 0 else 0)}
		table[i] = j
	}
	for i in 0 ..< 0x810 {crc = (crc >> 8) ~ table[(crc ~ u32(s[i])) & 0xFF]}
	stored := u32(s[0x810]) | u32(s[0x811]) << 8 | u32(s[0x812]) << 16 | u32(s[0x813]) << 24
	testing.expect_value(t, stored, crc, loc = loc)
}

@(private = "file")
audio_sector_ok :: proc(s: Sector, m: int) -> bool {
	for i in 0 ..< 2352 {if s[i] != u8(m * 5 + i) {return false}}
	return true
}

@(private = "file")
is_silence :: proc(s: Sector) -> bool {
	for b in s {if b != 0 {return false}}
	return true
}

@(private = "file")
expect_fixture_toc :: proc(t: ^testing.T, d: ^host.Disc_Image, loc := #caller_location) {
	testing.expect_value(t, d.disc.track_count, 2, loc = loc)
	testing.expect(t, d.disc.tracks[0].is_data, loc = loc)
	testing.expect_value(t, d.disc.tracks[0].start_lba, 0, loc = loc)
	testing.expect(t, !d.disc.tracks[1].is_data, loc = loc)
	testing.expect_value(t, d.disc.tracks[1].start_lba, AUDIO_START, loc = loc)
	testing.expect_value(t, d.disc.lead_out, LEAD_OUT, loc = loc)
}

// ------------------------------------------------------------------ cue ----

@(test)
cue_with_one_file_per_track :: proc(t: ^testing.T) {
	d := open(t, "disc.cue")
	if d == nil {return}
	defer host.disc_close(d)
	expect_fixture_toc(t, d)
	for n in 0 ..< DATA_SECTORS {
		s, ok := read(d, u32(n))
		testing.expect(t, ok)
		expect_data_sector(t, s, n, true)
	}
	for lba in DATA_SECTORS ..< AUDIO_START { // the pregap stored in the file
		s, ok := read(d, u32(lba))
		testing.expect(t, ok && is_silence(s))
	}
	for m in 0 ..< AUDIO_SECTORS {
		s, ok := read(d, u32(AUDIO_START + m))
		testing.expect(t, ok && audio_sector_ok(s, m), "audio sector")
	}
}

@(test)
reads_past_the_end_fail_and_return_zeros :: proc(t: ^testing.T) {
	d := open(t, "disc.cue")
	if d == nil {return}
	defer host.disc_close(d)
	s, ok := read(d, LEAD_OUT)
	testing.expect(t, !ok && is_silence(s))
	s, ok = read(d, 1_000_000)
	testing.expect(t, !ok && is_silence(s))
}

// Scratch directory with a few files, removed afterwards.
@(private = "file")
Scratch :: struct {
	dir: string,
}

@(private = "file")
scratch_make :: proc() -> Scratch {
	dir, _ := os.make_directory_temp("", "emu_disc_test_*", context.allocator)
	return {dir}
}

@(private = "file")
scratch_free :: proc(s: Scratch) {
	os.remove_all(s.dir)
	delete(s.dir)
}

@(private = "file")
put :: proc(s: Scratch, name: string, data: []byte) -> string {
	path := fmt.aprintf("%s/%s", s.dir, name)
	_ = os.write_entire_file(path, data)
	return path
}

@(private = "file")
put_text :: proc(s: Scratch, name, text: string) -> string {
	return put(s, name, transmute([]byte)text)
}

@(private = "file")
raw_data_sector :: proc(n: int) -> Sector {
	s: Sector
	sync := [12]u8{0, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 0}
	for i in 0 ..< 12 {s[i] = sync[i]}
	fad := n + 150
	s[12], s[13], s[14], s[15] = bcd(fad / 4500), bcd(fad / 75 % 60), bcd(fad % 75), 1
	for i in 0 ..< 2048 {s[16 + i] = u8(n * 31 + i * 7)}
	return s
}

@(private = "file")
audio_sector :: proc(m: int) -> Sector {
	s: Sector
	for i in 0 ..< 2352 {s[i] = u8(m * 5 + i)}
	return s
}

@(test)
single_bin_with_pregap_command_and_odd_syntax :: proc(t: ^testing.T) {
	sc := scratch_make()
	defer scratch_free(sc)
	// One file holds both tracks; track 2 has a PREGAP that is not stored.
	// Lower-case commands, a quoted name with a space, Windows paths and CRLF.
	bin := make([dynamic]u8)
	defer delete(bin)
	for n in 0 ..< DATA_SECTORS {s := raw_data_sector(n); append(&bin, ..s[:])}
	for m in 0 ..< AUDIO_SECTORS {s := audio_sector(m); append(&bin, ..s[:])}
	put(sc, "my disc.bin", bin[:])
	cue := put_text(
		sc,
		"game.cue",
		"REM comment\r\nfile \"C:\\old\\path\\my disc.bin\" BINARY\r\n  track 01 mode1/2352\r\n    index 01 00:00:00\r\n" +
		"  track 02 audio\r\n    pregap 00:00:10\r\n    index 01 00:00:16\r\n",
	)
	d, ok := host.disc_open(cue)
	if !ok {testing.fail_now(t, "cue did not open")}
	defer host.disc_close(d)
	testing.expect_value(t, d.disc.track_count, 2)
	testing.expect_value(t, d.disc.tracks[1].start_lba, 26) // 16 data + 10 silent
	testing.expect_value(t, d.disc.lead_out, 32)
	s, rok := read(d, 5)
	testing.expect(t, rok)
	expect_data_sector(t, s, 5)
	for lba in 16 ..< 26 { // the unstored pregap is silence
		z, zok := read(d, u32(lba))
		testing.expect(t, zok && is_silence(z))
	}
	for m in 0 ..< AUDIO_SECTORS {
		a, aok := read(d, u32(26 + m))
		testing.expect(t, aok && audio_sector_ok(a, m))
	}
}

@(test)
mode1_2048_tracks_get_a_synthesized_raw_sector :: proc(t: ^testing.T) {
	sc := scratch_make()
	defer scratch_free(sc)
	iso := make([]u8, 20 * 2048)
	defer delete(iso)
	for n in 0 ..< 20 {for i in 0 ..< 2048 {iso[n * 2048 + i] = u8(n * 31 + i * 7)}}
	put(sc, "cooked.iso", iso)
	cue := put_text(sc, "c.cue", "FILE \"cooked.iso\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\n")
	for path in ([]string{cue, fmt.tprintf("%s/cooked.iso", sc.dir)}) { // as a cue, and as a bare .iso
		d, ok := host.disc_open(path)
		if !ok {testing.fail_now(t, "did not open")}
		testing.expect_value(t, d.disc.lead_out, 20)
		s, rok := read(d, 7)
		testing.expect(t, rok)
		expect_data_sector(t, s, 7) // sync, header, mode 1 and the user data
		host.disc_close(d)
	}
}

@(test)
bare_bin_is_detected_as_raw_2352 :: proc(t: ^testing.T) {
	sc := scratch_make()
	defer scratch_free(sc)
	bin := make([dynamic]u8)
	defer delete(bin)
	for n in 0 ..< 20 {s := raw_data_sector(n); append(&bin, ..s[:])}
	path := put(sc, "disc.bin", bin[:])
	d, ok := host.disc_open(path)
	if !ok {testing.fail_now(t, "did not open")}
	defer host.disc_close(d)
	testing.expect_value(t, d.disc.lead_out, 20)
	s, rok := read(d, 19)
	testing.expect(t, rok)
	expect_data_sector(t, s, 19)
}

@(test)
bad_cue_sheets_are_rejected :: proc(t: ^testing.T) {
	sc := scratch_make()
	defer scratch_free(sc)
	put(sc, "a.bin", make([]u8, 4 * 2352))
	cases := [?]struct {
		name, text: string,
	} {
		{"missing file", "FILE \"nope.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\n"},
		{"no index 01", "FILE \"a.bin\" BINARY\nTRACK 01 MODE1/2352\n"},
		{"unsupported type", "FILE \"a.bin\" BINARY\nTRACK 01 CDG\nINDEX 01 00:00:00\n"},
		{"track before file", "TRACK 01 MODE1/2352\nINDEX 01 00:00:00\n"},
		{"no tracks", "FILE \"a.bin\" BINARY\n"},
		{"bad msf", "FILE \"a.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 zz\n"},
		{"wav audio file", "FILE \"a.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 00:00:00\nFILE \"a.wav\" WAVE\nTRACK 02 AUDIO\nINDEX 01 00:00:00\n"},
		{"empty track", "FILE \"a.bin\" BINARY\nTRACK 01 MODE1/2352\nINDEX 01 01:00:00\n"},
	}
	for c in cases {
		path := put_text(sc, "bad.cue", c.text)
		d, ok := host.disc_open(path)
		testing.expectf(t, !ok && d == nil, "'%s' was accepted", c.name)
		if d != nil {host.disc_close(d)}
	}
}

// ------------------------------------------------------------------ chd ----

// Every sector of every CHD must match what the cue/bin reader returns for the
// same disc, byte for byte, including the regenerated ECC.
@(test)
chd_matches_the_bin_it_was_made_from :: proc(t: ^testing.T) {
	ref := open(t, "disc.cue")
	if ref == nil {return}
	defer host.disc_close(ref)

	// disc_default.chd is the one whose audio hunk is "cdfl" (FLAC); it has to
	// decode to exactly the audio in the bin like the rest.
	for name in ([]string{"disc_cdlz.chd", "disc_cdzl.chd", "disc_none.chd", "disc_default.chd"}) {
		d := open(t, name)
		if d == nil {continue}
		expect_fixture_toc(t, d)
		for lba in 0 ..< LEAD_OUT {
			want, _ := read(ref, u32(lba))
			got, ok := read(d, u32(lba))
			testing.expectf(t, ok, "%s: lba %d unreadable", name, lba)
			if got != want {
				first := 0
				for first < 2352 && got[first] == want[first] {first += 1}
				testing.expectf(t, false, "%s: lba %d differs from the bin at byte %d (got 0x%02X, want 0x%02X)", name, lba, first, got[first], want[first])
			}
		}
		host.disc_close(d)
	}
}

@(test)
chd_reads_out_of_order :: proc(t: ^testing.T) {
	d := open(t, "disc_cdlz.chd")
	if d == nil {return}
	defer host.disc_close(d)
	for lba in ([]u32{15, 0, 13, 1, 12, 14, 2}) { // jumping between hunks, back and forth
		s, ok := read(d, lba)
		testing.expect(t, ok)
		expect_data_sector(t, s, int(lba), true)
	}
}

@(test)
corrupt_chds_are_rejected :: proc(t: ^testing.T) {
	sc := scratch_make()
	defer scratch_free(sc)
	good, err := os.read_entire_file(fmt.tprintf("%sdisc_cdlz.chd", FIXTURES), context.allocator)
	if err != nil {testing.fail_now(t, "no fixture")}
	defer delete(good)

	testing.expect(t, !(func_open(put_text(sc, "empty.chd", ""))))
	testing.expect(t, !(func_open(put_text(sc, "text.chd", "this is not a chd file at all, sorry"))))
	bad_version := clone(good)
	bad_version[15] = 4 // version 4
	testing.expect(t, !(func_open(put(sc, "v4.chd", bad_version))))
	delete(bad_version)
	truncated := good[:len(good) / 2] // map and metadata sit at the end
	testing.expect(t, !(func_open(put(sc, "trunc.chd", truncated))))
}

@(private = "file")
clone :: proc(b: []byte) -> []byte {
	c := make([]byte, len(b))
	copy(c, b)
	return c
}

@(private = "file")
func_open :: proc(path: string) -> bool {
	d, ok := host.disc_open(path)
	if d != nil {host.disc_close(d)}
	return ok
}

// A CHD that opens but whose data is damaged must fail the read, not crash or
// return stale bytes.
@(test)
damaged_hunk_data_fails_the_read :: proc(t: ^testing.T) {
	sc := scratch_make()
	defer scratch_free(sc)
	good, err := os.read_entire_file(fmt.tprintf("%sdisc_cdlz.chd", FIXTURES), context.allocator)
	if err != nil {testing.fail_now(t, "no fixture")}
	defer delete(good)
	bad := clone(good)
	defer delete(bad)
	for i in 124 ..< 124 + 400 {bad[i] = 0xFF} // the first compressed hunk starts right after the header
	d, ok := host.disc_open(put(sc, "damaged.chd", bad))
	if !ok {return} // refusing to open is also acceptable
	defer host.disc_close(d)
	_, rok := read(d, 0)
	testing.expect(t, !rok)
}
