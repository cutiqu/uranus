// Package emu_api is the ENTIRE contract between a Core and a Frontend.
//
// Rules for this package:
//   * Types and constants only. No procedures with bodies, no imports.
//   * Every type is plain data with a stable layout: safe to pass over a C ABI.
//   * Nothing here may mention files, windows, audio devices, or keyboards.
//
// Both sides import this package; neither side imports the other.
package emu_api

// Bump when any struct or exported procedure below changes incompatibly.
API_VERSION :: 6

// ---------------------------------------------------------------- input ----

// A generic gamepad. A core maps whatever it needs from this; a frontend maps
// whatever it has (keyboard, SDL joystick, ...) onto it.
Button :: enum u32 {
	Up, Down, Left, Right,
	A, B, X, Y,
	Start, Select,
	L, R,
	C, Z,   // the third button of each face row on a six-button pad (Saturn, Mega Drive)
	L2, R2, // triggers, for pads that have shoulder buttons *and* triggers
}
Buttons :: distinct bit_set[Button; u32]

// How one core's own controller sits on the generic one above. Buttons are
// positional: a frontend reports a pad's south button as B, east as A, west as
// X, north as Y, shoulders as L / R and triggers as L2 / R2, whatever the
// console calls them. A core that has a differently shaped pad (a Saturn has
// six face buttons) says here which generic button each of its own buttons is
// read from, so the frontend can name them the console's way in the config file
// and pick a sensible keyboard layout.
PAD_LABELS_MAX :: 24
Pad_Label :: struct {
	name:   cstring, // the console's name for the button: "a", "start", "l"
	button: Button,  // the generic button the core reads it from
	keys:   cstring, // default keyboard keys, SDL key names, "|"-separated ("Z|J"); "" = none
}

// ----------------------------------------------------------- host -> core ---
// Everything the core is allowed to ask of the outside world. This is the
// *only* channel by which the core reaches out.

Log_Level :: enum u32 { Debug, Info, Warn, Error }

// Core asks: "which buttons are held on this controller port right now?"
// Called from inside core_run_frame, once per port the core cares about.
Input_State_Proc :: #type proc "c" (userdata: rawptr, port: u32) -> Buttons

// Core says: "I want to tell you something." The core never prints.
Log_Proc :: #type proc "c" (userdata: rawptr, level: Log_Level, msg: cstring)

Host :: struct {
	userdata:    rawptr,            // opaque to the core; passed back verbatim
	input_state: Input_State_Proc,  // required
	log:         Log_Proc,          // optional (may be nil)
}

// ----------------------------------------------------------- core -> host ---

// ---- CD images -------------------------------------------------------------
// The host owns the disc files and every image format (cue/bin, chd, iso). A
// core that reads discs sees only a table of contents and a raw-sector reader,
// like a drive. LBA 0 is the first sector of the disc (MSF 00:02:00).

MAX_DISC_TRACKS  :: 99
DISC_SECTOR_SIZE :: 2352

Disc_Track :: struct {
	is_data:   bool,
	start_lba: u32, // where the track's INDEX 01 is
}

Disc :: struct {
	userdata:    rawptr,
	track_count: u32,
	tracks:      [MAX_DISC_TRACKS]Disc_Track,
	lead_out:    u32, // LBA one past the last sector
	// Reads sector `lba` (0 .. lead_out - 1) into `out` as DISC_SECTOR_SIZE raw
	// bytes: data tracks with sync and header, audio tracks as PCM. False if the
	// sector is unreadable (the buffer is zeroed).
	read_sector: proc "c" (userdata: rawptr, lba: u32, out: [^]byte) -> bool,
}

Core_Info :: struct {
	api_version: u32,     // must equal API_VERSION
	id:          cstring, // short, stable, lower-case: "gb". Used by --core and the registry
	name:        cstring,
	version:     cstring,
	extensions:  cstring, // "nes|unf" -- hint only; the core never sees a path
	firmware:    cstring, // "sega_101.bin|sega_100a.bin": BIOS files the host should look for
	                      // (first hit wins) and pass to load_firmware. "" = needs none
}

AV_Info :: struct {
	width, height: u32,   // framebuffer dimensions
	fps:           f64,   // frames per second the core wants to be run at
	sample_rate:   f64,   // audio sample rate in Hz
	pixel_aspect:  f32,   // width / height of one pixel as displayed: 1.0 = square,
	                      // NES = 8/7. 0 is treated as 1.0 (cores may leave it unset)
}

// Borrowed view of the core's framebuffer. Valid until the next run_frame /
// reset / unload_game / deinit. The frontend must copy if it needs it longer.
Video_Frame :: struct {
	pixels: [^]u32,       // 0x00RRGGBB, row-major
	width:  u32,
	height: u32,
	pitch:  u32,          // pixels (not bytes) between row starts
}

// Borrowed view of the audio produced by the LAST run_frame. Interleaved
// stereo signed 16-bit. Valid until the next run_frame.
Audio_Buffer :: struct {
	samples: [^]i16,
	frames:  uint,        // stereo frames, i.e. len(samples) == frames*2
}

// Which block of core memory the frontend wants to see.
Memory_Kind :: enum u32 {
	Save_RAM, // battery-backed cartridge RAM; the frontend persists it as <rom>.sav
}

// Borrowed view into core memory. size == 0 means "this core has none".
// The frontend may write into data (e.g. to restore a .sav) right after
// core_load_game, before the first run_frame.
Memory_Region :: struct {
	data: [^]byte,
	size: uint,
}

// ------------------------------------------------------------------------
// THE BOUNDARY: a core is a bundle of procedure pointers.
//
// Everything a frontend can ask of a core is a field of this struct; there is
// no other way in. Cores are linked into the same executable as the frontend,
// but the frontend never imports a core package: it only receives one of
// these structs from the registry. The same struct is what a libretro shim
// would wrap, so adding libretro later means writing one translation file.
//
// Procedures use the "c" convention so the struct is ABI-stable and a shim
// can export them as retro_* functions without adapters.
//
// Lifecycle:  init -> [load_firmware] -> load_game | load_disc -> (run_frame ...) -> unload_game -> deinit
Core :: struct {
	api_version: proc "c" () -> u32,
	get_info:    proc "c" (out: ^Core_Info),                          // valid before init
	init:        proc "c" (host: ^Host) -> bool,
	deinit:      proc "c" (),
	load_firmware: proc "c" (data: [^]byte, size: uint) -> bool,     // OPTIONAL (nil when the core needs
	                                                                  // none). After init, before load_game;
	                                                                  // core COPIES the bytes
	load_game:   proc "c" (data: [^]byte, size: uint) -> bool,        // core COPIES the bytes
	load_disc:   proc "c" (disc: ^Disc) -> bool,                       // OPTIONAL (nil for cartridge cores).
	                                                                  // A CD image instead of ROM bytes; the
	                                                                  // core may keep the pointer until
	                                                                  // unload_game. Returning false means
	                                                                  // "not a disc I can use": the host then
	                                                                  // falls back to load_game
	unload_game: proc "c" (),
	reset:       proc "c" (),
	get_av_info: proc "c" (out: ^AV_Info),
	run_frame:   proc "c" (),
	get_video:   proc "c" (out: ^Video_Frame),
	get_audio:   proc "c" (out: ^Audio_Buffer),
	get_memory:  proc "c" (kind: Memory_Kind, out: ^Memory_Region),
	get_pad_layout: proc "c" (out: [^]Pad_Label, capacity: u32) -> u32, // OPTIONAL (nil = the generic
	                                                                  // pad as it is). Fills `out`, returns
	                                                                  // how many labels; valid before init
	state_size:  proc "c" () -> uint,
	save_state:  proc "c" (buf: [^]byte, size: uint) -> bool,         // frontend owns buf
	load_state:  proc "c" (buf: [^]byte, size: uint) -> bool,
}
