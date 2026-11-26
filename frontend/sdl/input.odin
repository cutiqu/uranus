package frontend_sdl

// Input: keyboard bindings from config, and game controllers.
//
// A Steam Deck presents itself to SDL as an ordinary game controller (Steam
// Input emulates an Xbox pad), so controller support is the primary path
// there; the keyboard is for desktops.

import "core:c"
import "core:strings"
import sdl "vendor:sdl2"
import api "../../api"
import "../../config"

// --------------------------------------------------------------- keyboard ---

Keymap :: [api.Button][dynamic]sdl.Scancode

keymap_from_config :: proc(cfg: ^config.Config) -> (km: Keymap) {
	for b in api.Button {
		for name in cfg.keys[b] {
			sc := sdl.GetScancodeFromName(strings.clone_to_cstring(name, context.temp_allocator))
			if sc == .UNKNOWN {
				append(&cfg.warnings, strings.concatenate({"unknown key name \"", name, "\" in [input.keyboard]"}))
				continue
			}
			append(&km[b], sc)
		}
	}
	return
}

keymap_destroy :: proc(km: ^Keymap) {
	for &list in km { delete(list) }
}

read_keyboard :: proc(km: ^Keymap) -> (b: api.Buttons) {
	keys := sdl.GetKeyboardStateAsSlice()
	for button in api.Button {
		for sc in km[button] {
			if keys[int(sc)] != 0 { b += {button}; break }
		}
	}
	return
}

// ------------------------------------------------------------- controllers ---

// What the controller is doing right now, in SDL's layout-neutral names
// (south = the A button on an Xbox pad, east = B, and so on).
Raw_Pad :: struct {
	up, down, left, right:         bool,
	south, east, west, north:      bool,
	back, start:                   bool,
	left_shoulder, right_shoulder: bool,
	left_trigger, right_trigger:   bool, // analogue triggers past TRIGGER_THRESHOLD
	stick_x, stick_y:              i16,
}

// How far an analogue trigger (0..32767) must be pulled to count as pressed.
TRIGGER_THRESHOLD :: 8000

Hotkey :: enum { Quit, Save_State, Load_State, Reset }
Hotkeys :: bit_set[Hotkey]

// Translate one controller into console buttons plus hotkey chords.
//
// Buttons are reported by position, and a core says what its own buttons are
// (api.Pad_Label). Face buttons follow the Nintendo layout, not the Xbox one: the
// east button is the generic A and the south button is B, which is where a Game
// Boy player's thumbs expect them. The Saturn core, whose pad has six face
// buttons, reads south as its A, east as its B, and the bumpers as C and Z; see
// cores/saturn/interface.odin. Triggers are L2 / R2.
//
// Hotkeys use the common EmuDeck convention: hold Back (Select), then
//   Start = quit, Right shoulder = save state, Left shoulder = load state,
//   North (Y) = reset.
// While Back is held with one of those, the chord's buttons are withheld
// from the game so a save doesn't also press R in-game.
map_pad :: proc(raw: Raw_Pad, cfg: ^config.Config) -> (b: api.Buttons, hk: Hotkeys) {
	if raw.back {
		if raw.start          { hk += {.Quit} }
		if raw.right_shoulder { hk += {.Save_State} }
		if raw.left_shoulder  { hk += {.Load_State} }
		if raw.north          { hk += {.Reset} }
	}
	chord := hk != {}

	up, down, left, right := raw.up, raw.down, raw.left, raw.right
	if cfg.stick_as_dpad {
		dz := i32(cfg.stick_deadzone)
		if i32(raw.stick_x) < -dz { left = true }
		if i32(raw.stick_x) >  dz { right = true }
		if i32(raw.stick_y) < -dz { up = true }
		if i32(raw.stick_y) >  dz { down = true }
	}

	if up    { b += {.Up} }
	if down  { b += {.Down} }
	if left  { b += {.Left} }
	if right { b += {.Right} }
	if raw.east  { b += {.A} }
	if raw.south { b += {.B} }
	if raw.west  { b += {.X} }
	if !chord {
		if raw.north          { b += {.Y} }
		if raw.start          { b += {.Start} }
		if raw.back           { b += {.Select} }
		if raw.left_shoulder  { b += {.L} }
		if raw.right_shoulder { b += {.R} }
	}
	if raw.left_trigger  { b += {.L2} }
	if raw.right_trigger { b += {.R2} }
	return
}

read_raw :: proc(gc: ^sdl.GameController) -> Raw_Pad {
	down :: proc(gc: ^sdl.GameController, b: sdl.GameControllerButton) -> bool {
		return sdl.GameControllerGetButton(gc, b) != 0
	}
	return {
		up = down(gc, .DPAD_UP), down = down(gc, .DPAD_DOWN),
		left = down(gc, .DPAD_LEFT), right = down(gc, .DPAD_RIGHT),
		south = down(gc, .A), east = down(gc, .B), west = down(gc, .X), north = down(gc, .Y),
		back = down(gc, .BACK), start = down(gc, .START),
		left_shoulder = down(gc, .LEFTSHOULDER), right_shoulder = down(gc, .RIGHTSHOULDER),
		left_trigger = sdl.GameControllerGetAxis(gc, .TRIGGERLEFT) > TRIGGER_THRESHOLD,
		right_trigger = sdl.GameControllerGetAxis(gc, .TRIGGERRIGHT) > TRIGGER_THRESHOLD,
		stick_x = sdl.GameControllerGetAxis(gc, .LEFTX),
		stick_y = sdl.GameControllerGetAxis(gc, .LEFTY),
	}
}

MAX_PADS :: 8

Pads :: struct {
	list:  [MAX_PADS]^sdl.GameController,
	count: int,
}

pads_open_existing :: proc(p: ^Pads) {
	for i in 0 ..< sdl.NumJoysticks() {
		if sdl.IsGameController(i) { pads_add(p, i) }
	}
}

pads_add :: proc(p: ^Pads, device_index: c.int) {
	if p.count >= MAX_PADS { return }
	gc := sdl.GameControllerOpen(device_index)
	if gc != nil {
		p.list[p.count] = gc
		p.count += 1
	}
}

pads_remove :: proc(p: ^Pads, instance_id: sdl.JoystickID) {
	gone := sdl.GameControllerFromInstanceID(instance_id)
	for i in 0 ..< p.count {
		if p.list[i] == gone {
			sdl.GameControllerClose(gone)
			p.list[i] = p.list[p.count - 1]
			p.count -= 1
			return
		}
	}
}

pads_close :: proc(p: ^Pads) {
	for i in 0 ..< p.count { sdl.GameControllerClose(p.list[i]) }
	p.count = 0
}

// All connected controllers OR'd together: any pad can play player one.
read_pads :: proc(p: ^Pads, cfg: ^config.Config) -> (b: api.Buttons, hk: Hotkeys) {
	for i in 0 ..< p.count {
		pb, ph := map_pad(read_raw(p.list[i]), cfg)
		b += pb
		hk += ph
	}
	return
}
