// The Saturn core's side of the boundary: a thin forwarding layer from
// api.Core's procedure pointers to the core's own procedures. One core
// instance per program (like libretro); the state lives in `g`.
package saturn_core

import api "../../api"

@(private)
g: Saturn

// Bytes needed from the host: a Saturn BIOS image is exactly this size.
@(private)
FIRMWARE_NAMES :: "sega_101.bin|mpr-17933.bin|sega_100a.bin|sega_100.bin|mpr-18811-mx.ic1"

core_api_version :: proc "c" () -> u32 {
	return api.API_VERSION
}

core_get_info :: proc "c" (out: ^api.Core_Info) {
	out^ = {
		api_version = api.API_VERSION,
		id          = "saturn",
		name        = "Sega Saturn",
		version     = "0.2.0",
		extensions  = "cue|chd|iso|bin|img",
		firmware    = FIRMWARE_NAMES,
	}
}

core_init :: proc "c" (host: ^api.Host) -> bool {
	g = {}
	g.host = host
	g.out_w, g.out_h = 320, 224
	backup_format(&g)
	vdp2_reset(&g.vdp2)
	return true
}

core_deinit :: proc "c" () {
	g.host = nil
}

// The BIOS image is copied: it is small and needed for the whole session.
core_load_firmware :: proc "c" (data: [^]byte, size: uint) -> bool {
	if data == nil || size != BIOS_SIZE {
		log_msg(&g, .Error, "saturn: BIOS must be exactly 512 KiB")
		return false
	}
	for i in 0 ..< BIOS_SIZE { g.bios[i] = data[i] }
	g.bios_loaded = true
	return true
}

// A disc, presented by the host (cue/bin, chd or iso: the core neither knows
// nor cares). The pointer is kept until unload_game. A Saturn disc has the
// "SEGA SEGASATURN " header in its first sector; anything else is declined so
// the host can offer the same file to load_game (a bare BIOS).
core_load_disc :: proc "c" (disc: ^api.Disc) -> bool {
	if !g.bios_loaded {
		log_msg(&g, .Error, "saturn: no BIOS loaded; put a Saturn BIOS (e.g. sega_101.bin) in the system directory")
		return false
	}
	if !cdb_set_disc(&g.cdb, disc) {
		log_msg(&g, .Debug, "saturn: not a Saturn disc (no SEGA SEGASATURN header in the first sector)")
		return false
	}
	pick_area(&g)
	system_reset(&g)
	log_disc(&g, disc)
	return true
}

// One line saying what was loaded, so a run with -v shows at a glance that the
// disc image itself was read correctly.
@(private = "file")
log_disc :: proc "contextless" (s: ^Saturn, disc: ^api.Disc) {
	ip, _ := cdb_ip_bin(&s.cdb)
	l: Log_Buf
	lb_str(&l, "saturn: disc loaded: tracks=")
	lb_dec(&l, u64(disc.track_count))
	lb_str(&l, " lead-out=")
	lb_dec(&l, u64(disc.lead_out))
	lb_str(&l, " disc areas='")
	for i in 0x40 ..< 0x4A { if ip[i] > 32 && ip[i] < 127 { l.b[l.n] = ip[i]; l.n += 1 } }
	lb_str(&l, "' console area=0x")
	lb_hex(&l, u32(s.smpc.area), 1)
	lb_str(&l, " title='")
	for i in 0x60 ..< 0x80 { if ip[i] >= 32 && ip[i] < 127 && l.n < len(l.b) - 2 { l.b[l.n] = ip[i]; l.n += 1 } }
	lb_str(&l, "'")
	log_flush(s, .Info, &l)
}

// Cartridge-style loading is only used for a bare BIOS image, which boots to the
// BIOS's own CD-player screen with no disc.
core_load_game :: proc "c" (data: [^]byte, size: uint) -> bool {
	if data == nil || size != BIOS_SIZE {
		log_msg(&g, .Error, "saturn: not a Saturn disc (no SEGA SEGASATURN header) and not a 512 KiB BIOS image")
		return false
	}
	if !core_load_firmware(data, size) { return false }
	g.cdb.disc = nil
	system_reset(&g)
	return true
}

core_unload_game :: proc "c" () {
	g.cdb.disc = nil
	g.backup_checked = false
}

core_reset :: proc "c" () {
	system_reset(&g)
}

core_get_av_info :: proc "c" (out: ^api.AV_Info) {
	out^ = {
		width        = 320,
		height       = 224,
		fps          = 59.94,
		pixel_aspect = 1.0,
		sample_rate  = 44100,
	}
}

// The Saturn pad: D-pad, Start, six face buttons in two rows (A B C below, X Y Z
// above) and two shoulder triggers L and R. The host reports positions, not
// names, so this table is what makes it a Saturn pad: it follows the RetroPad
// convention for the Saturn (as Beetle Saturn and Mednafen's defaults do), which
// keeps the three bottom buttons under the right thumb and the top row under the
// left one on an ordinary four-face-button pad:
//
//      Saturn   A       B       C       X       Y       Z       L        R
//      pad      south   east    R1      west    north   L1      L2       R2
//
// `bit` is the button's position in the SMPC report (Mednafen's bit order).
@(private)
Pad_Map :: struct {
	name:   cstring,
	button: api.Button,
	keys:   cstring,
	bit:    u32,
}

@(private)
PAD_MAP := [?]Pad_Map{
	{"up",    .Up,    "Up",     0},
	{"down",  .Down,  "Down",   1},
	{"left",  .Left,  "Left",   2},
	{"right", .Right, "Right",  3},
	{"start", .Start, "Return", 4},
	{"a",     .B,     "Z",      5},  // south
	{"b",     .A,     "X",      6},  // east
	{"c",     .R,     "C",      7},  // right bumper
	{"x",     .X,     "A",      8},  // west
	{"y",     .Y,     "S",      9},  // north
	{"z",     .L,     "D",      10}, // left bumper
	{"l",     .L2,    "Q",      11}, // left trigger
	{"r",     .R2,    "E",      12}, // right trigger
}

@(private)
pad_bits :: proc "contextless" (b: api.Buttons) -> u16 {
	v: u16
	for m in PAD_MAP { if m.button in b { v |= 1 << m.bit } }
	return v
}

core_get_pad_layout :: proc "c" (out: [^]api.Pad_Label, capacity: u32) -> u32 {
	n := u32(0)
	for m in PAD_MAP {
		if n >= capacity { break }
		out[n] = {name = m.name, button = m.button, keys = m.keys}
		n += 1
	}
	return n
}

core_run_frame :: proc "c" () {
	if !g.backup_checked {
		g.backup_checked = true
		backup_ensure_formatted(&g) // after the host has loaded any saved copy
	}
	if g.host != nil && g.host.input_state != nil {
		for port in u32(0) ..< 2 {
			g.smpc.pad[port] = pad_bits(g.host.input_state(g.host.userdata, port))
		}
		// Refresh what direct-mode pad reads would see.
		smpc_write(&g, 0x3A, g.smpc.ports[0].data_out)
		smpc_write(&g, 0x3B, g.smpc.ports[1].data_out)
	}
	run_frame(&g)
}

core_get_video :: proc "c" (out: ^api.Video_Frame) {
	out^ = {
		pixels = raw_data(g.vdp2.pix[:]),
		width  = g.out_w,
		height = g.out_h,
		pitch  = SCREEN_MAX_W,
	}
}

core_get_audio :: proc "c" (out: ^api.Audio_Buffer) {
	out^ = {
		samples = raw_data(g.audio[:]),
		frames  = g.audio_frames,
	}
}

// The internal backup RAM is what a Saturn "saves" to; the host persists it.
core_get_memory :: proc "c" (kind: api.Memory_Kind, out: ^api.Memory_Region) {
	out^ = {}
	if kind == .Save_RAM { out^ = {data = raw_data(g.backup[:]), size = len(g.backup)} }
}

// Save states: see state.odin for what is and is not in one. Backup RAM is not:
// it is the game's save file and the host persists it on its own.
core_state_size :: proc "c" () -> uint {
	return state_size(&g)
}

core_save_state :: proc "c" (buf: [^]byte, size: uint) -> bool {
	if buf == nil { return false }
	if save_state(&g, buf[:size]) { return true }
	log_state_refusal(&g, "save")
	return false
}

// Says in the log why a state was refused, so "failed" is never all the user gets.
@(private = "file")
log_state_refusal :: proc "contextless" (s: ^Saturn, what: string) {
	why, line := state_reject_reason()
	l: Log_Buf
	lb_str(&l, "saturn: state ")
	lb_str(&l, what)
	lb_str(&l, " refused: ")
	lb_str(&l, why if why != "" else "unknown reason")
	if line != 0 {
		lb_str(&l, " (state.odin line ")
		lb_dec(&l, u64(line))
		lb_str(&l, ")")
	}
	log_flush(s, .Warn, &l)
}

core_load_state :: proc "c" (buf: [^]byte, size: uint) -> bool {
	if buf == nil { return false }
	if load_state(&g, buf[:size]) { return true }
	log_state_refusal(&g, "load")
	return false
}

// What the registry hands to frontends. This is the only symbol a frontend
// needs from this package.
interface :: proc() -> api.Core {
	return {
		api_version   = core_api_version,
		get_info      = core_get_info,
		init          = core_init,
		deinit        = core_deinit,
		load_firmware = core_load_firmware,
		load_game     = core_load_game,
		load_disc     = core_load_disc,
		unload_game   = core_unload_game,
		reset         = core_reset,
		get_av_info   = core_get_av_info,
		run_frame     = core_run_frame,
		get_video     = core_get_video,
		get_audio     = core_get_audio,
		get_memory    = core_get_memory,
		get_pad_layout = core_get_pad_layout,
		state_size    = core_state_size,
		save_state    = core_save_state,
		load_state    = core_load_state,
	}
}
