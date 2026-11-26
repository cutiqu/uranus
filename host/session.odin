package host

// A Session is "one core running one game" plus everything the frontend owns
// on its behalf: the ROM bytes, battery RAM and save-state files. Every
// frontend (window, terminal, headless) drives the core through this, so none
// of them re-implement file handling.

import "core:bytes"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import api "../api"

// Where this game's files live. Decided by the caller (from config), because
// ROM folders are often read-only (SD cards, network shares).
Paths :: struct {
	sav:        string, // battery RAM
	state:      string, // save state
	system_dir: string, // where firmware (BIOS) files are looked for
}

Session :: struct {
	emu:        api.Core,
	info:       api.Core_Info,
	av:         api.AV_Info,
	sram:       api.Memory_Region,
	rom:        []byte, // ROM image (cartridge cores, or a small file a disc core rejected as a disc)
	disc:       ^Disc_Image, // CD image (disc cores)
	paths:      Paths, // owned copies

	// What has been set up, so session_close can undo exactly that much.
	core_inited: bool,
	game_loaded: bool,

	// Battery RAM bookkeeping. `sram_disk` is a copy of what the .sav file holds
	// (or nil if we have never read or written it), so a flush only touches the
	// disk when the game has actually changed something.
	sram_disk:         []byte,
	sram_polled:       int, // frames since the last check
	sram_write_failed: bool, // already told the user; don't repeat every second
}

// How often (in emulated frames) the running game's battery RAM is compared with
// the file. The comparison is 32 KB and the write happens only on a change, so
// this is cheap; it bounds what a crash or a kill can cost to about a second.
SRAM_POLL_FRAMES :: 60

// `callbacks` must outlive the session (the core keeps its userdata pointer).
session_open :: proc(s: ^Session, core: api.Core, rom_path: string, paths: Paths, callbacks: ^api.Host) -> bool {
	s.emu = core
	s.emu.get_info(&s.info)

	// Disc cores read sectors on demand through the disc layer. cue/chd must
	// open as discs; a raw .iso/.bin/.img that is not a disc the core accepts is
	// still offered to it as plain bytes (that is how a bare BIOS boots).
	if s.emu.load_disc != nil && is_disc_path(rom_path) {
		s.disc, _ = disc_open(rom_path)
		if s.disc == nil && !is_raw_image(rom_path) {
			fmt.eprintfln("cannot open disc image %q", rom_path)
			return false
		}
	}
	if s.disc == nil && !read_rom(s, rom_path) {return false}

	if !s.emu.init(callbacks) {
		fmt.eprintln("core_init failed")
		session_close(s)
		return false
	}
	s.core_inited = true

	// Cores that need a BIOS get it before the game, from the system directory.
	if s.emu.load_firmware != nil && s.info.firmware != nil {
		load_firmware(s, paths.system_dir)
	}

	loaded := false
	if s.disc != nil {
		loaded = s.emu.load_disc(&s.disc.disc)
		if !loaded && is_raw_image(rom_path) {
			disc_close(s.disc)
			s.disc = nil
			if read_rom(s, rom_path) {loaded = s.emu.load_game(raw_data(s.rom), uint(len(s.rom)))}
		}
	} else {
		loaded = s.emu.load_game(raw_data(s.rom), uint(len(s.rom)))
	}
	if !loaded {
		fmt.eprintfln("the %s core rejected %q", s.info.name, rom_path)
		session_close(s)
		return false
	}
	s.game_loaded = true
	s.emu.get_av_info(&s.av)

	s.paths = {
		sav        = strings.clone(paths.sav),
		state      = strings.clone(paths.state),
		system_dir = strings.clone(paths.system_dir),
	}

	// Battery RAM: the core exposes the region, the frontend owns the file.
	s.emu.get_memory(.Save_RAM, &s.sram)
	if s.sram.size > 0 {
		if data, rerr := os.read_entire_file(s.paths.sav, context.allocator); rerr == nil {
			if uint(len(data)) == s.sram.size {
				copy(s.sram.data[:s.sram.size], data)
				s.sram_disk = data // what the file holds; owned from here on
			} else {
				// Not this core's format (or damaged). Never overwrite someone's
				// save without a trace: set it aside and say so.
				old := fmt.tprintf("%s.old", s.paths.sav)
				fmt.eprintfln(
					"uranus: %q is %d bytes but this core's save RAM is %d; keeping it as %q and starting fresh",
					s.paths.sav, len(data), s.sram.size, old,
				)
				_ = os.rename(s.paths.sav, old)
				delete(data)
			}
		}
	}
	return true
}

session_close :: proc(s: ^Session) {
	if s.game_loaded {
		session_flush_sram(s)
		s.emu.unload_game()
	}
	if s.core_inited { s.emu.deinit() }
	disc_close(s.disc)
	delete(s.rom)
	delete(s.sram_disk)
	delete(s.paths.sav)
	delete(s.paths.state)
	delete(s.paths.system_dir)
	s^ = {}
}

// A missing or rejected BIOS is reported, not fatal: whether the core can run
// without one is the core's call (load_game says no if it cannot).
@(private)
load_firmware :: proc(s: ^Session, system_dir: string) {
	hint := string(s.info.firmware)
	data, path, ok := read_firmware(system_dir, hint)
	if !ok {
		fmt.eprintfln("uranus: no firmware found in %q (looked for: %s)", system_dir, hint)
		return
	}
	defer delete(data)
	defer delete(path)
	if s.emu.load_firmware(raw_data(data), uint(len(data))) {
		fmt.eprintfln("uranus: firmware %s", path)
	} else {
		fmt.eprintfln("uranus: the %s core rejected firmware %q", s.info.name, path)
	}
}

// Writes `data` so that `path` is always either the old file or the new one,
// never half of each: a crash or a kill mid-write cannot corrupt a save.
@(private)
write_atomic :: proc(path: string, data: []byte) -> os.Error {
	tmp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(tmp, data); err != nil { return err }
	if err := os.rename(tmp, path); err != nil {
		_ = os.remove(tmp)
		return err
	}
	return nil
}

// Makes the .sav file match the game's battery RAM. Does nothing when they
// already match. A failure is reported once (so it is never silent) and retried
// at the next call.
session_flush_sram :: proc(s: ^Session) {
	if s.sram.size == 0 { return }
	cur := s.sram.data[:s.sram.size]
	if s.sram_disk != nil && bytes.equal(cur, s.sram_disk) { return }

	if err := write_atomic(s.paths.sav, cur); err != nil {
		if !s.sram_write_failed {
			fmt.eprintfln("uranus: cannot write save file %q: %v (your game progress is NOT being saved)", s.paths.sav, err)
			s.sram_write_failed = true
		}
		return
	}
	if s.sram_write_failed { fmt.eprintfln("uranus: save file %q is writable again", s.paths.sav) }
	s.sram_write_failed = false
	delete(s.sram_disk)
	s.sram_disk = bytes.clone(cur)
}

// Frontends call this once per loop with the number of frames just run.
session_tick :: proc(s: ^Session, frames: int) {
	s.sram_polled += frames
	if s.sram_polled >= SRAM_POLL_FRAMES {
		s.sram_polled = 0
		session_flush_sram(s)
	}
}

session_save_state :: proc(s: ^Session) -> bool {
	size := s.emu.state_size()
	if size == 0 {
		fmt.eprintfln("save state: the %s core does not support save states", s.info.name)
		return false
	}
	buf := make([]byte, size)
	defer delete(buf)
	if !s.emu.save_state(raw_data(buf), size) { return false } // the core says why in its log
	if err := write_atomic(s.paths.state, buf); err != nil {
		fmt.eprintfln("save state: cannot write %q: %v", s.paths.state, err)
		return false
	}
	return true
}

session_load_state :: proc(s: ^Session) -> bool {
	if !os.exists(s.paths.state) {
		fmt.eprintfln("load state: nothing saved yet at %q (save one first)", s.paths.state)
		return false
	}
	data, err := os.read_entire_file(s.paths.state, context.allocator)
	if err != nil {
		fmt.eprintfln("load state: cannot read %q: %v", s.paths.state, err)
		return false
	}
	defer delete(data)
	return s.emu.load_state(raw_data(data), uint(len(data))) // the core says why in its log
}

parse_uint :: proc(s: string) -> (n: int, ok: bool) {
	if len(s) == 0 { return 0, false }
	for ch in s {
		if ch < '0' || ch > '9' { return 0, false }
		n = n * 10 + int(ch - '0')
	}
	return n, true
}

// Raw single-track images are the ones a core may reasonably reject as a disc
// and then accept as bytes; cue and chd are always discs.
@(private)
is_raw_image :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return ext == ".iso" || ext == ".bin" || ext == ".img"
}

// Reads the whole file into s.rom. Refuses huge files: a core that wants a big
// medium should be taking it as a disc.
@(private)
read_rom :: proc(s: ^Session, path: string) -> bool {
	MAX_ROM_FILE :: 64 * 1024 * 1024
	if info, err := os.stat(path, context.temp_allocator); err == nil && info.size > MAX_ROM_FILE {
		fmt.eprintfln("%q is too large to load as a ROM", path)
		return false
	}
	err: os.Error
	s.rom, err = os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read ROM %q: %v", path, err)
		return false
	}
	return true
}
