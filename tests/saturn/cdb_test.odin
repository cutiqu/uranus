package saturn_tests

// The CD block against a fake disc, driven through its register interface the
// way the BIOS does: write CR1-CR4, read the answer, pull data from the port.
//
// The fake disc has two tracks: data on LBA 0..59 (sector n's user bytes are
// (n*31 + i*7), sector 0 starts with the Saturn header) and audio from LBA 60
// to the lead-out at 80.

import api "../../api"
import sat "../../core"
import "core:testing"

DATA_END :: 60
LEAD_OUT :: 80

@(private = "file")
fake_read :: proc "c" (_: rawptr, lba: u32, out: [^]byte) -> bool {
	if lba >= LEAD_OUT {return false}
	sec := out[:2352]
	for i in 0 ..< 2352 {sec[i] = 0}
	if lba >= DATA_END {
		for i in 0 ..< 2352 {sec[i] = u8(int(lba) + i)}
		return true
	}
	sec[1], sec[2], sec[3], sec[4], sec[5], sec[6], sec[7], sec[8], sec[9], sec[10] = 255, 255, 255, 255, 255, 255, 255, 255, 255, 255
	sec[15] = 1
	for i in 0 ..< 2048 {sec[16 + i] = u8(int(lba) * 31 + i * 7)}
	if lba == 0 {
		magic := "SEGA SEGASATURN "
		for i in 0 ..< len(magic) {sec[16 + i] = magic[i]}
	}
	return true
}

@(private = "file")
fake_disc :: proc() -> api.Disc {
	d := api.Disc {
		track_count = 2,
		lead_out    = LEAD_OUT,
		read_sector = fake_read,
	}
	d.tracks[0] = {true, 0}
	d.tracks[1] = {false, DATA_END}
	return d
}

@(private = "file")
with_disc :: proc(disc: ^api.Disc) -> ^sat.Saturn {
	s := new(sat.Saturn)
	sat.cdb_reset(&s.cdb)
	if disc != nil {
		assert(sat.cdb_set_disc(&s.cdb, disc))
		sat.cdb_reset(&s.cdb) // as a system reset would
	}
	return s
}

// Sends a command and returns CR1-CR4 as the host reads them back.
@(private = "file")
cmd :: proc(s: ^sat.Saturn, c1, c2, c3, c4: u16) -> [4]u16 {
	sat.cdb_write16(s, 6, c1)
	sat.cdb_write16(s, 7, c2)
	sat.cdb_write16(s, 8, c3)
	sat.cdb_write16(s, 9, c4)
	return {sat.cdb_read16(s, 6), sat.cdb_read16(s, 7), sat.cdb_read16(s, 8), sat.cdb_read16(s, 9)}
}

@(private = "file")
status_of :: proc(r: [4]u16) -> int {return int(r[0] >> 8) & 0x0F}

// Runs the drive for `lines` scanlines (a sector arrives every 105 at 2x).
@(private = "file")
spin :: proc(s: ^sat.Saturn, lines: int) {
	for _ in 0 ..< lines {sat.cdb_line(s)}
}

// Routes the CD drive into partition 0 through filter 0.
@(private = "file")
connect_cd_to_partition_0 :: proc(s: ^sat.Saturn) {
	cmd(s, 0x4601, 0x0000, 0x0000, 0) // filter 0: matching sectors -> partition 0
	cmd(s, 0x3000, 0x0000, 0x0000, 0) // CD device -> filter 0
}

@(private = "file")
sectors_in_partition_0 :: proc(s: ^sat.Saturn) -> int {
	return int(cmd(s, 0x5100, 0, 0x0000, 0)[3])
}

@(test)
saturn_disc_is_recognised_and_others_declined :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	disc := fake_disc()
	testing.expect(t, sat.cdb_set_disc(&s.cdb, &disc))
	ip, ok := sat.cdb_ip_bin(&s.cdb)
	testing.expect(t, ok && string(ip[:16]) == "SEGA SEGASATURN ")

	testing.expect(t, !sat.cdb_set_disc(&s.cdb, nil))
	_, has := sat.cdb_ip_bin(&s.cdb)
	testing.expect(t, !has) // a rejected disc leaves nothing behind

	audio_first := fake_disc()
	audio_first.tracks[0].is_data = false
	testing.expect(t, !sat.cdb_set_disc(&s.cdb, &audio_first))

	no_header := fake_disc()
	no_header.read_sector = proc "c" (_: rawptr, lba: u32, out: [^]byte) -> bool {
		for i in 0 ..< 2352 {out[i] = 0}
		return true
	}
	testing.expect(t, !sat.cdb_set_disc(&s.cdb, &no_header)) // e.g. a bare BIOS offered as a disc

	tiny := fake_disc()
	tiny.lead_out = 4
	testing.expect(t, !sat.cdb_set_disc(&s.cdb, &tiny))
}

@(test)
status_reflects_whether_a_disc_is_present :: proc(t: ^testing.T) {
	empty := with_disc(nil)
	defer free(empty)
	testing.expect_value(t, status_of(cmd(empty, 0x0000, 0, 0, 0)), 0x07) // no disc

	disc := fake_disc()
	loaded := with_disc(&disc)
	defer free(loaded)
	r := cmd(loaded, 0x0000, 0, 0, 0)
	testing.expect_value(t, status_of(r), 0x01) // paused
	testing.expect_value(t, r[2] & 0xFF, 0)
	testing.expect_value(t, r[3], 150) // at the start of the disc
}

@(test)
toc_lists_every_track :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	r := cmd(s, 0x0200, 0, 0, 0)
	testing.expect_value(t, r[1], 0xCC) // 204 words = 102 entries
	words: [204]u16
	for i in 0 ..< 204 {words[i] = sat.cdb_read16(s, 0)}
	entry :: proc(w: [204]u16, i: int) -> u32 {return u32(w[i * 2]) << 16 | u32(w[i * 2 + 1])}
	testing.expect_value(t, entry(words, 0), 0x41000000 | 150) // data track at FAD 150
	testing.expect_value(t, entry(words, 1), 0x01000000 | (DATA_END + 150)) // audio track
	for i in 2 ..< 99 {testing.expect_value(t, entry(words, i), 0xFFFFFFFF)}
	testing.expect_value(t, entry(words, 99), 0x41010000) // first track: 1
	testing.expect_value(t, entry(words, 100), 0x01020000) // last track: 2, audio
	testing.expect_value(t, entry(words, 101), 0x01000000 | (LEAD_OUT + 150)) // lead-out
}

@(test)
session_info_reports_the_lead_out :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	r := cmd(s, 0x0300, 0, 0, 0)
	testing.expect_value(t, r[3], LEAD_OUT + 150)
	testing.expect_value(t, r[2] >> 8, 1) // one session
}

@(test)
playing_a_fad_range_fills_the_selected_partition :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	// Play 4 sectors from FAD 150 (FAD positions have bit 23 set; the end is a count).
	r := cmd(s, 0x1080, 150, 0x0080, 4)
	testing.expect_value(t, status_of(r), 0x03) // playing
	spin(s, 105 * 3)
	testing.expect_value(t, sectors_in_partition_0(s), 3)
	spin(s, 105 * 3)
	testing.expect_value(t, sectors_in_partition_0(s), 4) // stops at the end of the range
	testing.expect_value(t, status_of(cmd(s, 0x0000, 0, 0, 0)), 0x01)
	testing.expect(t, sat.cdb_read16(s, 2) & sat.HIRQ_PEND != 0)
}

@(test)
sector_data_comes_out_of_the_data_port :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 150, 0x0080, 3)
	spin(s, 105 * 4)

	r := cmd(s, 0x6100, 0x0000, 0x0000, 3) // get sector data: from 0, partition 0, 3 sectors
	testing.expect(t, status_of(r) & 0x0F == 0x01)
	words := make([]u16, 3 * 1024)
	defer delete(words)
	for i in 0 ..< len(words) {words[i] = sat.cdb_read16(s, 0)}
	testing.expect_value(t, string([]byte{u8(words[0] >> 8), u8(words[0]), u8(words[1] >> 8), u8(words[1])}), "SEGA")
	// Sector n, user byte i is (n*31 + i*7): check the start of sectors 1 and 2.
	for n in 1 ..< 3 {
		w := words[n * 1024]
		testing.expect_value(t, w, u16(u8(n * 31)) << 8 | u16(u8(n * 31 + 7)))
	}
	end := cmd(s, 0x0600, 0, 0, 0)
	testing.expect_value(t, end[1], 3 * 1024) // words moved

	// The sectors stay buffered until deleted.
	testing.expect_value(t, sectors_in_partition_0(s), 3)
	cmd(s, 0x6200, 0x0000, 0x0000, 0xFFFF)
	testing.expect_value(t, sectors_in_partition_0(s), 0)
}

@(test)
play_by_track_number_covers_the_whole_track :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	// Start: track 1, index 1. End: track 1 (through the end of the track).
	cmd(s, 0x1000, 0x0101, 0x0000, 0x0101)
	spin(s, 105 * (DATA_END + 5))
	testing.expect_value(t, sectors_in_partition_0(s), DATA_END)
	testing.expect_value(t, status_of(cmd(s, 0x0000, 0, 0, 0)), 0x01)
}

@(test)
audio_tracks_play_without_filling_buffers :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	r := cmd(s, 0x1000, 0x0201, 0x0000, 0x0000) // track 2 to the end of the disc
	testing.expect_value(t, status_of(r), 0x03)
	spin(s, 105 * 5)
	testing.expect_value(t, sectors_in_partition_0(s), 0) // CDDA is not data
	pos := cmd(s, 0x0000, 0, 0, 0)
	testing.expect(t, pos[3] > DATA_END + 150) // but time passes
	// CD audio plays in real time, paced by the SCSP draining the FIFO (2.8 frames a
	// line); with nothing draining it the drive would wait.
	for _ in 0 ..< 210 * (LEAD_OUT - DATA_END + 2) {
		spin(s, 1)
		for _ in 0 ..< 4 { sat.cdb_cdda_pop(&s.cdb) }
	}
	testing.expect_value(t, status_of(cmd(s, 0x0000, 0, 0, 0)), 0x01) // finished
}

@(test)
play_positions_below_the_first_sector_are_clamped :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 0x0010, 0x0080, 2) // FAD 16: before the disc's first sector
	spin(s, 105 * 3)
	testing.expect_value(t, sectors_in_partition_0(s), 2) // played from FAD 150, no crash
}

@(test)
unreadable_sectors_arrive_as_zeros :: proc(t: ^testing.T) {
	disc := fake_disc()
	disc.read_sector = proc "c" (_: rawptr, lba: u32, out: [^]byte) -> bool {
		if lba == 0 {return fake_read(nil, 0, out)}
		for i in 0 ..< 2352 {out[i] = 0xAA}
		return false // a scratched disc
	}
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 151, 0x0080, 1)
	spin(s, 105 * 2)
	cmd(s, 0x6100, 0, 0, 1)
	for _ in 0 ..< 1024 {testing.expect_value(t, sat.cdb_read16(s, 0), 0)}
}

// ---------------------------------------------------------------------------
// Behaviour the BIOS depends on (checked against Mednafen's CD block).
// ---------------------------------------------------------------------------

@(private = "file")
hirq :: proc(s: ^sat.Saturn) -> u16 {return sat.cdb_read16(s, 2)}

@(private = "file")
clear_hirq :: proc(s: ^sat.Saturn, bits: u16) {sat.cdb_write16(s, 2, ~bits)}

@(test)
filters_feed_their_own_partition_by_default :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	// No Set Filter Connection: only route the drive to filter 3.
	cmd(s, 0x3000, 0x0000, 0x0300, 0)
	cmd(s, 0x1080, 150, 0x0080, 2)
	spin(s, 105 * 3)
	r := cmd(s, 0x5100, 0, 0x0300, 0) // sectors in partition 3
	testing.expect_value(t, r[3], 2)
	testing.expect_value(t, cmd(s, 0x5100, 0, 0x0000, 0)[3], 0) // and none in partition 0
}

@(test)
end_data_transfer_raises_ehst_for_sector_data_only :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 150, 0x0080, 1)
	spin(s, 105 * 2)

	clear_hirq(s, sat.HIRQ_EHST | sat.HIRQ_DRDY)
	cmd(s, 0x6300, 0, 0x0000, 1) // get then delete sector data
	testing.expect(t, hirq(s) & sat.HIRQ_DRDY != 0)
	for _ in 0 ..< 1024 {sat.cdb_read16(s, 0)}
	testing.expect(t, hirq(s) & sat.HIRQ_EHST == 0) // not before the host says it is done
	cmd(s, 0x0600, 0, 0, 0)
	testing.expect(t, hirq(s) & sat.HIRQ_EHST != 0)
	testing.expect_value(t, sectors_in_partition_0(s), 0) // "then delete" happened

	// A TOC transfer ends without EHST.
	cmd(s, 0x0200, 0, 0, 0)
	for _ in 0 ..< 204 {sat.cdb_read16(s, 0)}
	clear_hirq(s, sat.HIRQ_EHST)
	cmd(s, 0x0600, 0, 0, 0)
	testing.expect(t, hirq(s) & sat.HIRQ_EHST == 0)
}

@(test)
authentication_classifies_the_disc :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	testing.expect_value(t, cmd(s, 0xE100, 0, 0, 0)[1], 0) // nothing authenticated yet
	clear_hirq(s, sat.HIRQ_EFLS)
	cmd(s, 0xE000, 0, 0x0000, 0)
	testing.expect(t, hirq(s) & sat.HIRQ_EFLS != 0)
	testing.expect_value(t, cmd(s, 0xE100, 0, 0, 0)[1], 4) // a Saturn disc
	// A filter number outside 0..23 is rejected.
	testing.expect_value(t, cmd(s, 0xE000, 0, 0x1800, 0)[0], 0xFF00)
}

// The whole disc-boot read as the BIOS performs it: init, authenticate, route
// the drive to a partition, play the first 16 sectors, wait for them, pull them
// out with an SCU DMA from the data port, end the transfer, wait for EHST.
@(test)
bios_style_ip_bin_read_through_scu_dma :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)

	cmd(s, 0x0400, 0, 0, 0) // init (no reset)
	cmd(s, 0xE000, 0, 0x0000, 0) // authenticate
	testing.expect_value(t, cmd(s, 0xE100, 0, 0, 0)[1], 4)
	cmd(s, 0x3000, 0, 0x0000, 0) // drive -> filter 0 (default wiring: partition 0)
	cmd(s, 0x6000, 0x0000, 0x0000, 0) // 2048-byte sectors
	clear_hirq(s, sat.HIRQ_CSCT | sat.HIRQ_EHST)
	cmd(s, 0x1080, 150, 0x0080, 16) // play 16 sectors from FAD 150
	spin(s, 105 * 17)
	testing.expect(t, hirq(s) & sat.HIRQ_CSCT != 0)
	testing.expect_value(t, sectors_in_partition_0(s), 16)

	cmd(s, 0x6300, 0, 0x0000, 16) // get then delete, 16 sectors
	// SCU DMA channel 0: data port (A-bus, no read increment) -> work RAM high.
	sat.scu_write32(s, 0x00, 0x05818000)
	sat.scu_write32(s, 0x04, 0x06004000)
	sat.scu_write32(s, 0x08, 16 * 2048)
	sat.scu_write32(s, 0x0C, 0x0002) // read add 0, write add 4
	sat.scu_write32(s, 0x14, 0x0007) // direct mode, immediate start factor
	sat.scu_write32(s, 0x10, 0x0101) // enable + go

	testing.expect_value(t, sat.mem_read32(s, 0x06004000), 0x53454741) // "SEGA"
	// Sector n begins with byte (n*31): sector 5 starts 5*2048 bytes in.
	testing.expect_value(t, u8(sat.mem_read32(s, 0x06004000 + 5 * 2048) >> 24), u8(5 * 31))
	cmd(s, 0x0600, 0, 0, 0)
	testing.expect(t, hirq(s) & sat.HIRQ_EHST != 0)
	testing.expect_value(t, sectors_in_partition_0(s), 0)
}

@(test)
reset_selector_flags_each_reset_one_thing :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x4601, 0x0500, 0x0000, 0) // filter 0 now feeds partition 5
	cmd(s, 0x1080, 150, 0x0080, 2)
	spin(s, 105 * 3)
	testing.expect_value(t, cmd(s, 0x5100, 0, 0x0500, 0)[3], 2)

	// Flag 0x04 only empties partitions: the drive connection and wiring stay.
	cmd(s, 0x4804, 0, 0, 0)
	testing.expect_value(t, cmd(s, 0x5100, 0, 0x0500, 0)[3], 0)
	testing.expect_value(t, cmd(s, 0x3100, 0, 0, 0)[2] >> 8, 0) // drive still on filter 0
	testing.expect_value(t, cmd(s, 0x4700, 0, 0x0000, 0)[1] >> 8, 5) // filter 0 still -> partition 5

	// Flag 0x40 puts every true output back on its own partition.
	cmd(s, 0x4840, 0, 0, 0)
	testing.expect_value(t, cmd(s, 0x4700, 0, 0x0000, 0)[1] >> 8, 0)
	testing.expect_value(t, cmd(s, 0x4700, 0, 0x0700, 0)[1] >> 8, 7)

	// Flag 0x20 disconnects the drive.
	cmd(s, 0x4820, 0, 0, 0)
	testing.expect_value(t, cmd(s, 0x3100, 0, 0, 0)[2] >> 8, 0xFF)

	// Flags 0: empty one partition; an out-of-range number is refused.
	testing.expect_value(t, cmd(s, 0x4800, 0, 0x1800, 0)[0], 0xFF00)
}

// A host that issues Get Status and then spins on CR1-CR4 (as the BIOS CD player
// does) must see the registers change by themselves: the block refreshes them
// about 75 times a second with the PERIODIC flag set, which the command reply
// does not have.
@(test)
periodic_refresh_changes_the_registers_after_the_reply_is_read :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	reply := cmd(s, 0x0000, 0, 0, 0)
	testing.expect_value(t, reply[0] >> 8 & u16(sat.CDB_STAT_PERIODIC), 0)

	// cmd() has read CR1-CR4, so the next refresh is allowed to replace the reply.
	spin(s, 300)
	cr1 := sat.cdb_read16(s, 6)
	testing.expect(t, cr1 >> 8 & u16(sat.CDB_STAT_PERIODIC) != 0)
	testing.expect_value(t, cr1 >> 8 & 0x0F, u16(reply[0] >> 8 & 0x0F)) // same drive status underneath
	testing.expect_value(t, sat.cdb_read16(s, 7), reply[1]) // same position fields
}

@(test)
periodic_refresh_waits_for_an_unread_reply :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	sat.cdb_write16(s, 6, 0x0100) // Get Hardware Info
	sat.cdb_write16(s, 7, 0)
	sat.cdb_write16(s, 8, 0)
	sat.cdb_write16(s, 9, 0)
	spin(s, 600) // two refresh periods pass with the reply still unread
	testing.expect_value(t, sat.cdb_read16(s, 7), 0x0002) // CR2 still belongs to the command
	testing.expect_value(t, sat.cdb_read16(s, 9), 0x0600) // CR4 read: the reply is now consumed
	spin(s, 300)
	testing.expect(t, sat.cdb_read16(s, 6) >> 8 & u16(sat.CDB_STAT_PERIODIC) != 0)
}

// ---------------------------------------------------------------------------
// Selector commands a game library uses right after Initialize. Hexen (and any
// SGL title) sends Set Filter Mode, then Set Filter Subheader Conditions, and
// waits for ESEL after each; an unhandled 0x42 meant the wait never ended.
// ---------------------------------------------------------------------------

@(test)
set_filter_subheader_raises_esel_and_reads_back :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)

	clear_hirq(s, sat.HIRQ_ESEL)
	r := cmd(s, 0x4205, 0x0A0B, 0x0003, 0x0C0D) // channel 5, masks 0A/0B, file 3, values 0C/0D (filter 0)
	testing.expect_value(t, r[0] >> 8, 0x01) // plain status, not a rejection
	testing.expect(t, hirq(s) & sat.HIRQ_ESEL != 0)

	r = cmd(s, 0x4300, 0, 0x0000, 0)
	testing.expect_value(t, r[0] & 0xFF, 0x05)
	testing.expect_value(t, r[1], 0x0A0B)
	testing.expect_value(t, r[2], 0x0003)
	testing.expect_value(t, r[3], 0x0C0D)

	// Filter numbers past 23 are rejected, and do not raise ESEL.
	clear_hirq(s, sat.HIRQ_ESEL)
	testing.expect_value(t, cmd(s, 0x4200, 0, 0x1800, 0)[0], 0xFF00)
	testing.expect(t, hirq(s) & sat.HIRQ_ESEL == 0)
}

// Get Filter Range/Mode/Connection echo the filter number in CR3; Get Buffer
// Size reports free blocks, selector count and total blocks in CR2/CR3/CR4.
@(test)
selector_query_layouts :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)

	cmd(s, 0x4000, 0x0123, 0x0500, 0x0456) // range of filter 5
	r := cmd(s, 0x4100, 0, 0x0500, 0)
	testing.expect_value(t, r[1], 0x0123)
	testing.expect_value(t, r[2], 0x0500 | 0x00)
	testing.expect_value(t, r[3], 0x0456)

	cmd(s, 0x4415, 0, 0x0500, 0) // mode 0x15 on filter 5
	r = cmd(s, 0x4500, 0, 0x0500, 0)
	testing.expect_value(t, r[0] & 0xFF, 0x15)
	testing.expect_value(t, r[2], 0x0500)

	r = cmd(s, 0x4700, 0, 0x0500, 0)
	testing.expect_value(t, r[1], 0x0500 | 0xFF) // true -> partition 5, false -> none
	testing.expect_value(t, r[2], 0x0500)

	r = cmd(s, 0x5000, 0, 0, 0)
	testing.expect_value(t, r[1], 200) // every buffer free
	testing.expect_value(t, r[2], 0x1800)
	testing.expect_value(t, r[3], 200)
}

@(private = "file")
fake_read_xa :: proc "c" (_: rawptr, lba: u32, out: [^]byte) -> bool {
	if lba >= LEAD_OUT {return false}
	sec := out[:2352]
	for i in 0 ..< 2352 {sec[i] = 0}
	sec[15] = 2 // mode 2: subheader at 16..19, user data from 24
	sec[16], sec[17], sec[18], sec[19] = u8(lba & 1), 0, 0x08, 0 // file number alternates
	for i in 0 ..< 2048 {sec[24 + i] = u8(int(lba) * 31 + i * 7)}
	if lba == 0 {
		magic := "SEGA SEGASATURN "
		for i in 0 ..< len(magic) {sec[24 + i] = magic[i]}
	}
	return true
}

// Sectors are routed by their subheader: matches go to the filter's partition,
// misses continue down the false-output chain.
@(test)
filter_chain_routes_by_file_number :: proc(t: ^testing.T) {
	disc := fake_disc()
	disc.read_sector = fake_read_xa
	disc.tracks[1] = {true, DATA_END}
	s := with_disc(&disc)
	defer free(s)

	cmd(s, 0x4401, 0, 0x0000, 0)      // filter 0: select by file number
	cmd(s, 0x4200, 0, 0x0001, 0)      // ... file 1
	cmd(s, 0x4602, 0x0001, 0x0000, 0) // filter 0: miss -> filter 1
	cmd(s, 0x3000, 0, 0x0000, 0)      // CD -> filter 0 (filter 1 keeps its default: everything -> partition 1)
	cmd(s, 0x1080, 150, 0x0080, 6)    // play sectors 0..5
	spin(s, 105 * 8)

	testing.expect_value(t, cmd(s, 0x5100, 0, 0x0000, 0)[3], 3) // odd sectors: file 1
	testing.expect_value(t, cmd(s, 0x5100, 0, 0x0100, 0)[3], 3) // even sectors fell through
	testing.expect_value(t, cmd(s, 0x3200, 0, 0, 0)[2] >> 8, 0) // sector 5 is odd: its last stop was partition 0
}

// Copy Sector Data pushes buffers from a partition through another filter.
@(test)
copy_and_move_sector_data :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 150, 0x0080, 4)
	spin(s, 105 * 5)
	testing.expect_value(t, sectors_in_partition_0(s), 4)

	cmd(s, 0x4601, 0x0200, 0x0300, 0) // filter 3: true -> partition 2
	clear_hirq(s, sat.HIRQ_ECPY)
	cmd(s, 0x6503, 0, 0x0000, 2) // copy 2 sectors, partition 0 -> filter 3
	testing.expect(t, hirq(s) & sat.HIRQ_ECPY != 0)
	testing.expect_value(t, sectors_in_partition_0(s), 4) // copies leave the source
	testing.expect_value(t, cmd(s, 0x5100, 0, 0x0200, 0)[3], 2)

	cmd(s, 0x6603, 0, 0x0000, 0xFFFF) // move the rest
	testing.expect_value(t, sectors_in_partition_0(s), 0)
	testing.expect_value(t, cmd(s, 0x5100, 0, 0x0200, 0)[3], 6)
}

// Get Sector Info returns the subheader fields; FAD search finds the nearest sector at or before a FAD.
@(test)
sector_info_and_fad_search :: proc(t: ^testing.T) {
	disc := fake_disc()
	disc.read_sector = fake_read_xa
	disc.tracks[1] = {true, DATA_END}
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 150, 0x0080, 4)
	spin(s, 105 * 5)

	r := cmd(s, 0x5400, 1, 0x0000, 0) // second sector in partition 0
	testing.expect_value(t, r[1], 151)
	testing.expect_value(t, r[2], 0x0100) // file 1, channel 0
	testing.expect_value(t, r[3], 0x0800) // submode 8, coding info 0

	clear_hirq(s, sat.HIRQ_ESEL)
	cmd(s, 0x5500, 0, 0x0000, 152) // search from the start for FAD 152
	testing.expect(t, hirq(s) & sat.HIRQ_ESEL != 0)
	r = cmd(s, 0x5600, 0, 0, 0)
	testing.expect_value(t, r[1], 2)
	testing.expect_value(t, r[3], 152)

	testing.expect_value(t, cmd(s, 0x5400, 9, 0x0000, 0)[0], 0xFF00) // past the end: rejected
}

@(private = "file")
fake_read_long :: proc "c" (_: rawptr, lba: u32, out: [^]byte) -> bool {
	if lba >= 1000 {return false}
	sec := out[:2352]
	for i in 0 ..< 2352 {sec[i] = 0}
	sec[15] = 1
	for i in 0 ..< 2048 {sec[16 + i] = u8(int(lba) * 31 + i * 7)}
	if lba == 0 {
		magic := "SEGA SEGASATURN "
		for i in 0 ..< len(magic) {sec[16 + i] = magic[i]}
	}
	return true
}

// With every buffer full the drive pauses (the host sees PAUSE, with BFUL), and
// it carries on by itself once the host frees a sector. Before this it kept
// reporting PLAY at a frozen position forever.
@(test)
full_buffers_pause_the_drive_until_freed :: proc(t: ^testing.T) {
	disc := fake_disc()
	disc.read_sector = fake_read_long
	disc.tracks[1] = {true, 1000}
	disc.lead_out = 1000
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 150, 0x0080, 0x3E0) // a long play
	spin(s, 105 * 210)
	testing.expect_value(t, sectors_in_partition_0(s), 200)
	testing.expect(t, hirq(s) & sat.HIRQ_BFUL != 0)
	testing.expect_value(t, cmd(s, 0x0000, 0, 0, 0)[0] >> 8, 0x01) // PAUSE, not PLAY
	fad := cmd(s, 0x0000, 0, 0, 0)[3]
	spin(s, 105 * 4)
	testing.expect_value(t, cmd(s, 0x0000, 0, 0, 0)[3], fad) // not moving

	cmd(s, 0x6200, 0, 0x0000, 1) // delete one sector
	testing.expect_value(t, cmd(s, 0x0000, 0, 0, 0)[0] >> 8, 0x03) // playing again
	spin(s, 105 * 3)
	testing.expect_value(t, sectors_in_partition_0(s), 200) // and refilled
}

// Seek with 0xFFFFFF pauses in place (position kept); play with start 0xFFFFFF
// resumes from there.
@(test)
pause_keeps_position_and_play_resumes :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	connect_cd_to_partition_0(s)
	cmd(s, 0x1080, 150, 0x0080, 40)
	spin(s, 105 * 10)
	r := cmd(s, 0x11FF, 0xFFFF, 0, 0)
	testing.expect_value(t, r[0] >> 8, 0x01) // PAUSE
	fad := r[3]
	testing.expect(t, fad >= 150 + 8 && fad <= 150 + 12) // where it was, not 0x7FFFFF
	spin(s, 105 * 5)
	testing.expect_value(t, cmd(s, 0x0000, 0, 0, 0)[3], fad) // and it stays

	cmd(s, 0x10FF, 0xFFFF, 0x00FF, 0xFFFF) // resume with the old range
	testing.expect_value(t, cmd(s, 0x0000, 0, 0, 0)[0] >> 8, 0x03)
	spin(s, 105 * 4)
	testing.expect(t, cmd(s, 0x0000, 0, 0, 0)[3] > fad)
}

// CD audio is read in real time into a FIFO the SCSP drains one frame per sample,
// and stops the moment the drive pauses.
@(test)
cd_audio_fills_the_fifo_and_pauses :: proc(t: ^testing.T) {
	disc := fake_disc()
	s := with_disc(&disc)
	defer free(s)
	cmd(s, 0x1080, 150 + DATA_END, 0x0080, 8) // play 8 audio sectors
	spin(s, 4)
	testing.expect(t, s.cdb.cdda_n >= sat.CDDA_FRAMES)
	f := sat.cdb_cdda_pop(&s.cdb)
	// Sector 60 holds bytes (60 + i): little-endian 16-bit stereo frames.
	testing.expect_value(t, f[0], 0x3D3C)
	testing.expect_value(t, f[1], 0x3F3E)

	cmd(s, 0x11FF, 0xFFFF, 0, 0) // pause
	spin(s, 1)
	testing.expect_value(t, s.cdb.cdda_n, 0)
	testing.expect_value(t, sat.cdb_cdda_pop(&s.cdb), [2]i16{0, 0})
}
