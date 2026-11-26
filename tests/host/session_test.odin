package host_tests

// Battery RAM and save states through the real host Session and the real Saturn
// core: what a game writes to backup RAM must reach the .sav file, survive a
// restart, and never be rolled back or blanked by anything else.
//
// The Saturn core is a singleton (like a libretro core), so all of this runs
// as one test, one session at a time.

import api "../../api"
import sat "../../cores/saturn"
import host "../../host"
import "core:fmt"
import "core:os"
import "core:testing"

@(private = "file")
no_input :: proc "c" (userdata: rawptr, port: u32) -> api.Buttons {
	return {}
}

// A BIOS-sized file that is just a loop (reset vector 0x10: add #1,r0 / bra / nop).
@(private = "file")
write_bios :: proc(path: string) -> bool {
	b := make([]byte, 512 * 1024)
	defer delete(b)
	b[3] = 0x10 // reset PC = 0x0000_0010 (big-endian)
	b[4], b[5] = 0x06, 0x10 // reset SP = 0x0610_0000
	code := [?]u8{0x70, 0x01, 0xAF, 0xFD, 0x00, 0x09}
	for c, i in code { b[0x10 + i] = c }
	return os.write_entire_file(path, b) == nil
}

@(private = "file")
open_session :: proc(s: ^host.Session, hostcb: ^api.Host, bios, dir, sav: string) -> bool {
	paths := host.Paths{sav = sav, state = fmt.tprintf("%s/game.state", dir), system_dir = dir}
	return host.session_open(s, sat.interface(), bios, paths, hostcb)
}

@(private = "file")
file_size :: proc(path: string) -> int {
	info, err := os.stat(path, context.temp_allocator)
	return int(info.size) if err == nil else -1
}

@(test)
saturn_backup_ram_and_states_persist :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/emu_session_test_%d", os.get_pid())
	testing.expect(t, os.make_directory_all(dir) == nil)
	defer os.remove_all(dir)

	bios := fmt.tprintf("%s/bios.bin", dir)
	sav := fmt.tprintf("%s/game.sav", dir)
	testing.expect(t, write_bios(bios))
	hostcb := api.Host{input_state = no_input}

	// ---- 1. a game saves; the file follows within a second, with no clean exit --
	{
		s: host.Session
		testing.expect(t, open_session(&s, &hostcb, bios, dir, sav))
		testing.expect_value(t, s.sram.size, 0x8000)
		for _ in 0 ..< 3 { s.emu.run_frame() } // the first frame formats a blank image

		sram := s.sram.data[:s.sram.size]
		testing.expect_value(t, string(sram[:4]), "Back") // formatted, header in place
		sram[0x100], sram[0x101], sram[0x7FFF] = 0xA1, 0xB2, 0xC3 // the game saves

		host.session_tick(&s, 59)
		host.session_tick(&s, 1) // a second of play later
		testing.expect_value(t, file_size(sav), 0x8000)
		disk, _ := os.read_entire_file(sav, context.temp_allocator)
		testing.expect(t, len(disk) == 0x8000 && disk[0x100] == 0xA1 && disk[0x7FFF] == 0xC3)

		// ...and a later save that has not been polled yet is caught on close.
		sram[0x200] = 0xD4
		host.session_close(&s)
		disk2, _ := os.read_entire_file(sav, context.temp_allocator)
		testing.expect(t, len(disk2) == 0x8000 && disk2[0x200] == 0xD4 && disk2[0x100] == 0xA1)
		testing.expect_value(t, file_size(fmt.tprintf("%s.tmp", sav)), -1) // no temp file left
	}

	// ---- 2. restart: everything is still there, and was not reformatted -----
	{
		s: host.Session
		testing.expect(t, open_session(&s, &hostcb, bios, dir, sav))
		for _ in 0 ..< 3 { s.emu.run_frame() }
		sram := s.sram.data[:s.sram.size]
		testing.expect_value(t, sram[0x100], 0xA1)
		testing.expect_value(t, sram[0x200], 0xD4)
		testing.expect_value(t, sram[0x7FFF], 0xC3)
		testing.expect_value(t, string(sram[:4]), "Back")

		// ---- 3. save states: F5 / F7 -----------------------------------------
		state_path := fmt.tprintf("%s/game.state", dir)
		testing.expect(t, !host.session_load_state(&s)) // nothing saved yet: says so, no crash
		testing.expect(t, host.session_save_state(&s))
		testing.expect_value(t, file_size(state_path), int(s.emu.state_size()))
		for _ in 0 ..< 5 { s.emu.run_frame() }

		// The game saves again AFTER the state was taken...
		sram[0x300] = 0xE5
		sram[0x100] = 0x11
		testing.expect(t, host.session_load_state(&s))
		// ...and loading the earlier state must not take that save away.
		testing.expect_value(t, sram[0x300], 0xE5)
		testing.expect_value(t, sram[0x100], 0x11)
		for _ in 0 ..< 2 { s.emu.run_frame() }
		host.session_close(&s)
	}

	// The save made after the state, then a load, is what the next boot sees.
	{
		disk, _ := os.read_entire_file(sav, context.temp_allocator)
		testing.expect(t, len(disk) == 0x8000 && disk[0x300] == 0xE5 && disk[0x100] == 0x11)
	}

	// ---- 4. a save file of the wrong size is set aside, not silently eaten ---
	{
		odd := fmt.tprintf("%s/odd.sav", dir)
		testing.expect(t, os.write_entire_file(odd, []byte{1, 2, 3, 4, 5}) == nil)
		s: host.Session
		testing.expect(t, open_session(&s, &hostcb, bios, dir, odd))
		for _ in 0 ..< 2 { s.emu.run_frame() }
		testing.expect_value(t, string(s.sram.data[:4]), "Back") // fresh, formatted
		host.session_close(&s)
		testing.expect_value(t, file_size(fmt.tprintf("%s.old", odd)), 5) // the original is kept
		testing.expect_value(t, file_size(odd), 0x8000)
	}

	// ---- 5. an unwritable save path is survivable, and not silent -----------
	{
		bad := fmt.tprintf("%s/no/such/dir/game.sav", dir)
		s: host.Session
		testing.expect(t, open_session(&s, &hostcb, bios, dir, bad))
		for _ in 0 ..< 2 { s.emu.run_frame() }
		host.session_tick(&s, 60)
		testing.expect(t, s.sram_write_failed) // reported (once), game keeps running
		host.session_tick(&s, 60)
		s.emu.run_frame()
		host.session_close(&s)
	}
}
