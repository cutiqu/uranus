package saturn_tests

// Save states: the format must cover every field of the machine, round-trip
// exactly, leave the game's backup RAM alone, and refuse anything corrupt,
// impossible or from another BIOS/disc WITHOUT touching the running machine.

import "base:runtime"
import "core:sync"
import "core:testing"
import sat "../../cores/saturn"

// ------------------------------------------------------------- coverage ----

// Fields that are deliberately not in a state (see the header of state.odin):
// the BIOS image, backup RAM (the game's save file), diagnostics and the
// rendered picture. Pointers and procedures are skipped by type below.
@(private = "file")
EXCLUDED := [?]string{
	"bios", "backup", "diag", "prof", "bios_loaded", "backup_dirty", "backup_checked",
	"audio", "audio_frames", "pix",
	"trace_on", "trace_n", "trace", "io_hist", "vec_count",
}

@(private = "file")
excluded :: proc(name: string) -> bool {
	for e in EXCLUDED { if e == name { return true } }
	return false
}

// Bytes of leaf data (integers, floats, bools, enums) inside a type, by walking
// its runtime type information, minus the excluded fields.
@(private = "file")
leaf_bytes :: proc(ti: ^runtime.Type_Info) -> int {
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Struct:
		n := 0
		for i in 0 ..< int(v.field_count) {
			if excluded(v.names[i]) { continue }
			n += leaf_bytes(v.types[i])
		}
		return n
	case runtime.Type_Info_Array:
		return v.count * leaf_bytes(v.elem)
	case runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_Boolean, runtime.Type_Info_Enum:
		return base.size
	case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer, runtime.Type_Info_Procedure:
		return 0 // wired up again on load, never saved
	}
	return -1_000_000 // a field kind the serializer doesn't understand: fail loudly
}

// If anyone adds a field to a chip and forgets to list it in state.odin, the
// serialised size stops matching and this fails: no ROM, no BIOS needed.
@(test)
state_covers_every_machine_field :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)

	header := 3 * 4 // magic, version, BIOS hash
	vdp1_draw_is_one_byte := 8 - 1 // VDP1.draw is an `int` (8 bytes in memory) saved as one byte
	expected := header + leaf_bytes(type_info_of(sat.Saturn)) - vdp1_draw_is_one_byte
	testing.expectf(
		t,
		int(sat.state_size(s)) == expected,
		"state is %d bytes but the machine holds %d: a field is missing from (or wrongly in) state.odin",
		int(sat.state_size(s)),
		expected,
	)
}

// ---------------------------------------------------------------- rig -------

// The state loader stages states in one shared buffer (the core is a singleton,
// like libretro), so tests that load must not run at the same moment.
@(private = "file")
load_lock: sync.Mutex

// The reason is captured while the lock is still held, so a concurrent test's
// load_state cannot overwrite the core's shared reject-why in between.
@(private = "file")
load :: proc(s: ^sat.Saturn, buf: []byte) -> (ok: bool, why: string) {
	sync.mutex_guard(&load_lock)
	ok = sat.load_state(s, buf)
	why, _ = sat.state_reject_reason()
	return ok, why
}

// A machine with a tiny BIOS: reset vector at 0x10, then
//     add #1,r0 ; bra back ; nop
// so the CPU does something observable every frame while every chip ticks.
@(private = "file")
boot :: proc(fill: u8 = 0) -> ^sat.Saturn {
	s := new(sat.Saturn)
	for i in 0 ..< len(s.bios) { s.bios[i] = fill }
	put32 :: proc(b: []u8, at: int, v: u32) {
		b[at], b[at + 1], b[at + 2], b[at + 3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
	}
	put32(s.bios[:], 0, 0x10)
	put32(s.bios[:], 4, 0x0610_0000)
	code := [?]u8{0x70, 0x01, 0xAF, 0xFD, 0x00, 0x09}
	for b, i in code { s.bios[0x10 + i] = b }
	s.bios_loaded = true
	s.out_w, s.out_h = 320, 224 // what core_init sets
	sat.vdp2_reset(&s.vdp2)
	sat.system_reset(s)
	return s
}

@(private = "file")
snapshot :: proc(s: ^sat.Saturn) -> []byte {
	buf := make([]byte, int(sat.state_size(s)))
	if !sat.save_state(s, buf) {
		delete(buf)
		return nil
	}
	return buf
}

// Distinctive values in every chip, all of them legal.
@(private = "file")
dirty_up :: proc(s: ^sat.Saturn) {
	for i in 0 ..< 600 { s.wram_h[i * 7] = u8(i * 13 + 1) }
	for i in 0 ..< 600 { s.wram_l[i * 11] = u8(i * 5 + 2) }
	for i in 0 ..< 300 { s.vdp1.vram[i * 17] = u8(i + 3); s.vdp2.vram[i * 19] = u8(i + 4); s.scsp.ram[i * 23] = u8(i + 5) }
	s.vdp1.fb[0][0x1234] = 0xBEEF
	s.vdp1.fb[1][0x4321] = 0xCAFE
	s.vdp1.draw = 1
	s.vdp1.sys_x, s.vdp1.loc_y = -37, -12
	s.vdp2.regs[0x10] = 0x0101
	s.vdp2.cram[0x40] = 0x7C
	s.scu.ist, s.scu.ims, s.scu.t0c = 0x1234, 0xBFFF, 99
	s.scu.dma[1] = {read = 0x06000000, write = 0x05E00000, count = 0x100, add = 4, enable = 1, mode = 7}
	s.smpc.oreg[3], s.smpc.pending_command, s.smpc.cd_on = 0x5A, 0x10, true
	s.smpc.ports[1] = {data_out = 0x40, data_dir = 0x7F, direct_mode = true, bus_state = 0x33}
	s.cpu[0].r[3], s.cpu[0].mach, s.cpu[0].sr = 0xDEAD_BEEF, 0x1234_5678, 0x0F1
	s.cpu[1].r[5], s.cpu[1].pr, s.cpu[1].sleeping = 0xCAFE_F00D, 0x0600_0123, true
	s.cpu[0].oc.frc, s.cpu[0].oc.ocra, s.cpu[0].oc.raw[0x77] = 0x4242, 0x5555, 0x99
	s.cpu[1].oc.dma[1] = {sar = 0x06000000, dar = 0x06001000, tcr = 7, chcr = 0x5A01, vcr = 0x70, drcr = 2}
	s.cpu[0].cache_ram[0x123] = 0xAA
	s.scsp.regs[0x400] = 0x77
	s.scsp.slots[5] = {cur = 0x1111, phase = 0x2222, on = true, run = true, in_loop = true, env_phase = 2, env_level = 0x200}
	s.scsp.timers[1] = {ctl = 3, reload = 0x40, counter = 9}
	s.scsp.cpu.d[2], s.scsp.cpu.a[7], s.scsp.cpu.pc, s.scsp.cpu.sr = 0x12345678, 0x4000, 0x600, 0x2700
	s.scsp.scieb, s.scsp.mcipd, s.scsp.mslc, s.scsp.lfsr = 0x7F, 0x400, 17, 0x1ABCD
	s.cdb.hirq, s.cdb.status, s.cdb.cur_fad = 0x0BE1, 0x21, 12345
	s.cdb.buffers[7].part, s.cdb.buffers[7].fad = 3, 777
	s.cdb.buffers[7].data[100], s.cdb.buffers[199].data[2351] = 0x42, 0x24
	s.cdb.filters[2] = {start = 5, count = 6, mode = 0x41, true_out = 2, false_out = 0xFF}
	s.cdb.cdda[100] = {-5, 1234}
	s.cdb.cdda_r, s.cdb.cdda_n = 100, 588
	s.cdb.files[3] = {fad = 150, size = 2048, num = 3, is_dir = true, lba = 9}
	s.cdb.file_count = 4
	s.cdb.dt_kind, s.cdb.dt_count, s.cdb.dt_words = 2, 2, 2048
	s.cdb.dt_list[0], s.cdb.dt_list[1] = 7, 199
	s.frame, s.line_start = 4242, 1820 * 263 * 3
	s.audio_frac = 0.25
	s.out_w, s.out_h = 352, 240
	for &c in s.cpu { c.cycles = s.line_start }
	s.scsp.cpu_target, s.scsp.cpu.cycles = 5000, 5002
}

// ---------------------------------------------------------------- tests -----

@(test)
round_trip_preserves_everything :: proc(t: ^testing.T) {
	a := boot()
	defer free(a)
	dirty_up(a)
	base := snapshot(a)
	defer delete(base)
	testing.expect(t, base != nil)

	// Restore into a machine that is different in every way.
	b := boot()
	defer free(b)
	for i in 0 ..< len(b.wram_h) { b.wram_h[i] = 0xEE }
	b.cpu[0].r[3], b.cdb.status, b.vdp1.draw = 1, 2, 0
	ok, _ := load(b, base)
	testing.expect(t, ok)

	again := snapshot(b)
	defer delete(again)
	testing.expect(t, again != nil && string(again) == string(base))

	testing.expect_value(t, b.cpu[0].r[3], 0xDEAD_BEEF)
	testing.expect_value(t, b.cpu[1].oc.dma[1].chcr, 0x5A01)
	testing.expect_value(t, b.scsp.slots[5].env_level, 0x200)
	testing.expect_value(t, b.scsp.cpu.pc, 0x600)
	testing.expect_value(t, b.cdb.buffers[199].data[2351], 0x24)
	testing.expect_value(t, b.cdb.cdda[100], [2]i16{-5, 1234})
	testing.expect_value(t, b.vdp1.fb[1][0x4321], 0xCAFE)
	testing.expect_value(t, b.vdp1.sys_x, -37) // negative numbers survive
	testing.expect_value(t, b.audio_frac, 0.25)
	testing.expect_value(t, b.frame, 4242)
}

// The point of a state: from the same state, the same machine produces the same
// future. Run A on, load A's earlier state into a separate machine B, run B the
// same distance, and they must end up identical down to the last byte.
@(test)
a_loaded_machine_runs_exactly_like_the_original :: proc(t: ^testing.T) {
	a := boot()
	defer free(a)
	for _ in 0 ..< 5 { sat.run_frame(a) }
	mid := snapshot(a)
	defer delete(mid)
	for _ in 0 ..< 7 { sat.run_frame(a) }
	end_a := snapshot(a)
	defer delete(end_a)

	b := boot()
	defer free(b)
	ok, _ := load(b, mid)
	testing.expect(t, ok)
	testing.expect(t, b.cpu[0].s == b && b.cpu[1].s == b) // pointers refer to B, not to A
	for _ in 0 ..< 7 { sat.run_frame(b) }
	end_b := snapshot(b)
	defer delete(end_b)

	testing.expect(t, end_a != nil && string(end_a) == string(end_b))
	testing.expect(t, a.cpu[0].r[0] == b.cpu[0].r[0] && a.cpu[0].r[0] != 0) // and it really ran
}

// Backup RAM is the game's save file. Loading a state, from before or after a
// save, must neither roll it back nor blank it, and a state does not carry it.
@(test)
backup_ram_is_not_part_of_a_state :: proc(t: ^testing.T) {
	a := boot()
	defer free(a)
	a.backup[5], a.backup[0x7FFF] = 0x11, 0x22
	st := snapshot(a)
	defer delete(st)

	b := boot()
	defer free(b)
	b.backup[5], b.backup[9] = 0x77, 0x88 // what the game has saved since
	ok, _ := load(b, st)
	testing.expect(t, ok)
	testing.expect_value(t, b.backup[5], 0x77)
	testing.expect_value(t, b.backup[9], 0x88)
	testing.expect_value(t, b.backup[0x7FFF], 0)

	// Nor is the state's size tied to the backup RAM's.
	testing.expect_value(t, int(sat.state_size(a)), len(st))
}

@(test)
bad_buffers_are_refused_and_the_machine_is_left_alone :: proc(t: ^testing.T) {
	a := boot()
	defer free(a)
	dirty_up(a)
	good := snapshot(a)
	defer delete(good)

	b := boot()
	defer free(b)
	for _ in 0 ..< 3 { sat.run_frame(b) }
	before := snapshot(b)
	defer delete(before)
	unchanged :: proc(t: ^testing.T, b: ^sat.Saturn, before: []byte, what: string) {
		now := snapshot(b)
		defer delete(now)
		testing.expectf(t, string(now) == string(before), "%s: the refused state changed the machine", what)
	}

	ok, why := load(b, good[:len(good) - 1])
	testing.expect(t, !ok)
	unchanged(t, b, before, "truncated")

	long := make([]byte, len(good) + 1)
	defer delete(long)
	copy(long, good)
	ok, why = load(b, long)
	testing.expect(t, !ok)
	unchanged(t, b, before, "trailing byte")

	ok, why = load(b, nil)
	testing.expect(t, !ok)
	ok, why = load(b, good[:3])
	testing.expect(t, !ok)
	unchanged(t, b, before, "empty")

	bad_magic := make([]byte, len(good))
	defer delete(bad_magic)
	copy(bad_magic, good)
	bad_magic[0] ~= 0xFF
	ok, why = load(b, bad_magic)
	testing.expect(t, !ok)
	testing.expect_value(t, why, "not a Saturn state of this version")
	unchanged(t, b, before, "bad magic")

	bad_version := make([]byte, len(good))
	defer delete(bad_version)
	copy(bad_version, good)
	bad_version[4] += 1
	ok, why = load(b, bad_version)
	testing.expect(t, !ok)
	unchanged(t, b, before, "bad version")
}

@(test)
a_state_from_another_bios_is_refused :: proc(t: ^testing.T) {
	a := boot()
	defer free(a)
	st := snapshot(a)
	defer delete(st)

	b := boot()
	defer free(b)
	b.bios[0x7000] ~= 0x55 // a different BIOS image
	before := snapshot(b)
	defer delete(before)
	ok, why := load(b, st)
	testing.expect(t, !ok)
	testing.expect_value(t, why, "it was saved with a different BIOS")
	after := snapshot(b)
	defer delete(after)
	testing.expect(t, string(before) == string(after))
}

@(test)
a_state_from_another_disc_is_refused :: proc(t: ^testing.T) {
	a := boot()
	defer free(a)
	a.cdb.ip[0x60] = 'A' // title area of IP.BIN
	st := snapshot(a)
	defer delete(st)

	b := boot()
	defer free(b)
	b.cdb.ip[0x60] = 'B'
	ok, why := load(b, st)
	testing.expect(t, !ok)
	testing.expect_value(t, why, "it was saved with a different disc")

	b.cdb.ip[0x60] = 'A'
	ok, why = load(b, st)
	testing.expect(t, ok) // same disc: fine
}

// Each of these would index out of range or send a scheduler loop on a very long
// catch-up if it got into the machine. Every one must be refused.
@(test)
impossible_values_are_refused :: proc(t: ^testing.T) {
	Mutator :: struct {
		what: string,
		fn:   proc(s: ^sat.Saturn),
	}
	cases := [?]Mutator{
		{"vdp1 draw buffer 2", proc(s: ^sat.Saturn) { s.vdp1.draw = 2 }},
		{"scsp monitor slot 200", proc(s: ^sat.Saturn) { s.scsp.mslc = 200 }},
		{"scsp envelope phase 9", proc(s: ^sat.Saturn) { s.scsp.slots[3].env_phase = 9 }},
		{"scsp envelope level", proc(s: ^sat.Saturn) { s.scsp.slots[3].env_level = 0xFFFF }},
		{"scsp timer shift", proc(s: ^sat.Saturn) { s.scsp.timers[0].ctl = 200 }},
		{"scsp sample accumulator", proc(s: ^sat.Saturn) { s.scsp.sample_acc = max(u64) }},
		{"68000 far ahead of its target", proc(s: ^sat.Saturn) { s.scsp.cpu_target = 1 << 60 }},
		{"68000 interrupt level", proc(s: ^sat.Saturn) { s.scsp.cpu.ipl = 9 }},
		{"sh2 status bits", proc(s: ^sat.Saturn) { s.cpu[1].sr = 0xFFFF_FFFF }},
		{"sh2 clock a lifetime behind", proc(s: ^sat.Saturn) { s.cpu[0].cycles = -(1 << 60) }},
		{"sh2 timer base in the future", proc(s: ^sat.Saturn) { s.cpu[0].oc.frt_base = 1 << 50 }},
		{"sh2 timer base absurdly old", proc(s: ^sat.Saturn) { s.cpu[1].oc.frt_base = -(1 << 50) }},
		{"sh2 irq level", proc(s: ^sat.Saturn) { s.cpu[0].irq_level = 200 }},
		{"sh2 irq source", proc(s: ^sat.Saturn) { s.cpu[0].irq_src = sat.Irq_Source(77) }},
		{"slave flag swapped", proc(s: ^sat.Saturn) { s.cpu[0].is_slave = true }},
		{"scu interrupt level", proc(s: ^sat.Saturn) { s.scu.ilevel = 99 }},
		{"smpc command", proc(s: ^sat.Saturn) { s.smpc.pending_command = 100_000 }},
		{"vdp2 width", proc(s: ^sat.Saturn) { s.vdp2.width = 99_999 }},
		{"output size zero", proc(s: ^sat.Saturn) { s.out_w = 0 }},
		{"output size huge", proc(s: ^sat.Saturn) { s.out_h = 1 << 30 }},
		{"audio fraction NaN", proc(s: ^sat.Saturn) { z := 0.0; s.audio_frac = z / z }},
		{"cd sector length zero", proc(s: ^sat.Saturn) { s.cdb.get_len = 0 }}, // a divide by zero in the transfer
		{"cd transfer list entry", proc(s: ^sat.Saturn) { s.cdb.dt_list[1] = 250 }},
		{"cd transfer longer than its list", proc(s: ^sat.Saturn) { s.cdb.dt_words = 1 << 30 }},
		{"cd transfer kind", proc(s: ^sat.Saturn) { s.cdb.dt_kind = 9 }},
		{"cd file info past the table", proc(s: ^sat.Saturn) { s.cdb.dt_kind, s.cdb.dt_words = 3, 1 << 20 }},
		{"cd file count", proc(s: ^sat.Saturn) { s.cdb.file_count = 9999 }},
		{"cd audio ring read position", proc(s: ^sat.Saturn) { s.cdb.cdda_r = 1 << 20 }},
		{"cd audio ring fill", proc(s: ^sat.Saturn) { s.cdb.cdda_n = 1 << 20 }},
		{"cd device filter", proc(s: ^sat.Saturn) { s.cdb.cd_filter = 77 }},
	}

	good := boot()
	defer free(good)
	dirty_up(good)
	live := boot()
	defer free(live)
	for _ in 0 ..< 2 { sat.run_frame(live) }
	before := snapshot(live)
	defer delete(before)

	for c in cases {
		m := boot()
		dirty_up(m)
		c.fn(m)
		// Save through the same code path a real core would (the format has no
		// idea whether a field is plausible), then try to load it.
		st := snapshot(m)
		free(m)
		ok, _ := load(live, st)
		testing.expectf(t, !ok, "%s: accepted", c.what)
		delete(st)
	}
	after := snapshot(live)
	defer delete(after)
	testing.expect(t, string(before) == string(after)) // none of that touched the machine
}

// A state that is merely different (not impossible) is accepted: the refusals
// above are about safety, not about disagreeing with what the BIOS would do.
@(test)
unusual_but_legal_values_are_accepted :: proc(t: ^testing.T) {
	a := boot()
	defer free(a)
	dirty_up(a)
	a.cpu[0].sleeping, a.cpu[1].halted = true, true
	a.cdb.dt_kind, a.cdb.dt_count, a.cdb.dt_words = 0, 0, 0
	a.cdb.get_len = 2352
	a.smpc.pending_command = -1
	a.cpu[0].oc.frt_base = a.cpu[0].cycles - (1 << 33) // a timer nobody has touched for a long while
	st := snapshot(a)
	defer delete(st)
	b := boot()
	defer free(b)
	ok, _ := load(b, st)
	testing.expect(t, ok)
}

@(test)
refusing_to_save_without_a_bios :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	buf := make([]byte, int(sat.state_size(s)))
	defer delete(buf)
	testing.expect(t, !sat.save_state(s, buf))
	ok, _ := load(s, buf)
	testing.expect(t, !ok)
	small := make([]byte, 10)
	defer delete(small)
	s.bios_loaded = true
	testing.expect(t, !sat.save_state(s, small))
}
