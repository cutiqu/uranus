package input_tests

import "core:os"
import "core:testing"
import sdl "vendor:sdl2"
import api "../../api"
import "../../config"
import fsdl "../../frontend/sdl"
import saturn "../../core"
import "core:strings"
import "core:sync"

cfg :: proc() -> config.Config { return config.defaults() }

free_cfg :: proc(c: ^config.Config) { config.destroy(c) }

@(test)
generic_face_button_layout :: proc(t: ^testing.T) {
	c := cfg()
	defer free_cfg(&c)
	b, _ := fsdl.map_pad({east = true}, &c)
	testing.expect_value(t, b, api.Buttons{.A})      // east button = console A
	b, _ = fsdl.map_pad({south = true}, &c)
	testing.expect_value(t, b, api.Buttons{.B})      // south button = console B
}

@(test)
left_stick_acts_as_dpad_outside_the_deadzone :: proc(t: ^testing.T) {
	c := cfg()
	defer free_cfg(&c)
	b, _ := fsdl.map_pad({stick_x = -20000, stick_y = 20000}, &c)
	testing.expect_value(t, b, api.Buttons{.Left, .Down})
	b, _ = fsdl.map_pad({stick_x = 5000, stick_y = -5000}, &c)  // drift inside the deadzone
	testing.expect_value(t, b, api.Buttons{})
	c.stick_as_dpad = false
	b, _ = fsdl.map_pad({stick_x = -30000}, &c)
	testing.expect_value(t, b, api.Buttons{})
}

@(test)
back_alone_is_select_and_start_alone_is_start :: proc(t: ^testing.T) {
	c := cfg()
	defer free_cfg(&c)
	b, hk := fsdl.map_pad({back = true}, &c)
	testing.expect_value(t, b, api.Buttons{.Select})
	testing.expect_value(t, hk, fsdl.Hotkeys{})
	b, hk = fsdl.map_pad({start = true}, &c)
	testing.expect_value(t, b, api.Buttons{.Start})
	testing.expect_value(t, hk, fsdl.Hotkeys{})
}

@(test)
back_chords_fire_hotkeys_and_are_withheld_from_the_game :: proc(t: ^testing.T) {
	c := cfg()
	defer free_cfg(&c)
	b, hk := fsdl.map_pad({back = true, start = true}, &c)
	testing.expect_value(t, hk, fsdl.Hotkeys{.Quit})
	testing.expect_value(t, b, api.Buttons{})          // neither Start nor Select reaches the game

	b, hk = fsdl.map_pad({back = true, right_shoulder = true}, &c)
	testing.expect_value(t, hk, fsdl.Hotkeys{.Save_State})
	testing.expect(t, .R not_in b)

	b, hk = fsdl.map_pad({back = true, left_shoulder = true}, &c)
	testing.expect_value(t, hk, fsdl.Hotkeys{.Load_State})

	b, hk = fsdl.map_pad({back = true, north = true}, &c)
	testing.expect_value(t, hk, fsdl.Hotkeys{.Reset})

	// d-pad and A/B still work while a chord is held
	b, hk = fsdl.map_pad({back = true, start = true, east = true, right = true}, &c)
	testing.expect_value(t, b, api.Buttons{.A, .Right})
}

// The real SDL path: an SDL *virtual* controller, read through the same
// open/poll code the frontend uses, with no hardware attached.
//
// Both of these tests Init and Quit the global SDL state, which is not
// thread-safe, so they must not overlap.
@(private = "file")
sdl_lock: sync.Mutex

@(test)
virtual_controller_through_real_sdl :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_lock)
	if sdl.Init({.GAMECONTROLLER}) != 0 {
		testing.fail_now(t, "SDL_Init failed")
	}
	defer sdl.Quit()

	index := sdl.JoystickAttachVirtual(.GAMECONTROLLER, 6, 15, 0)
	testing.expect(t, index >= 0)
	defer sdl.JoystickDetachVirtual(index)
	testing.expect(t, bool(sdl.IsGameController(index)))

	joy := sdl.JoystickOpen(index)
	testing.expect(t, joy != nil)
	defer sdl.JoystickClose(joy)

	pads: fsdl.Pads
	fsdl.pads_open_existing(&pads)
	defer fsdl.pads_close(&pads)
	testing.expect_value(t, pads.count, 1)

	c := cfg()
	defer free_cfg(&c)
	// SDL's default virtual-controller button order: A B X Y BACK GUIDE START
	// LSTICK RSTICK LSHOULDER RSHOULDER DPAD_UP DPAD_DOWN DPAD_LEFT DPAD_RIGHT
	press :: proc(joy: ^sdl.Joystick, button: c_int) { sdl.JoystickSetVirtualButton(joy, button, 1); sdl.JoystickUpdate() }
	release_all :: proc(joy: ^sdl.Joystick) { for i in 0 ..< 15 { sdl.JoystickSetVirtualButton(joy, c_int(i), 0) }; sdl.JoystickUpdate() }

	b, hk := fsdl.read_pads(&pads, &c)
	testing.expect_value(t, b, api.Buttons{})

	press(joy, 13) // DPAD_LEFT
	b, hk = fsdl.read_pads(&pads, &c)
	testing.expect_value(t, b, api.Buttons{.Left})
	release_all(joy)

	press(joy, 1)  // B (east)
	b, hk = fsdl.read_pads(&pads, &c)
	testing.expect_value(t, b, api.Buttons{.A})
	release_all(joy)

	sdl.JoystickSetVirtualButton(joy, 4, 1)  // BACK
	sdl.JoystickSetVirtualButton(joy, 6, 1)  // START
	sdl.JoystickUpdate()
	b, hk = fsdl.read_pads(&pads, &c)
	testing.expect_value(t, hk, fsdl.Hotkeys{.Quit})
	testing.expect_value(t, b, api.Buttons{})
	release_all(joy)

	sdl.JoystickSetVirtualAxis(joy, 0, -30000) // left stick hard left
	sdl.JoystickUpdate()
	b, hk = fsdl.read_pads(&pads, &c)
	testing.expect_value(t, b, api.Buttons{.Left})
	sdl.JoystickSetVirtualAxis(joy, 0, 0)

	// Analogue triggers (axes 4 and 5): past the threshold they are L2 / R2.
	// (SDL maps a trigger's whole axis range, -32768..32767, onto 0..32767.)
	sdl.JoystickSetVirtualAxis(joy, 4, -30000) // a light touch is nothing
	sdl.JoystickUpdate()
	b, hk = fsdl.read_pads(&pads, &c)
	testing.expect_value(t, b, api.Buttons{})
	sdl.JoystickSetVirtualAxis(joy, 4, 30000)
	sdl.JoystickSetVirtualAxis(joy, 5, 30000)
	sdl.JoystickUpdate()
	b, hk = fsdl.read_pads(&pads, &c)
	testing.expect_value(t, b, api.Buttons{.L2, .R2})
}

c_int :: i32

// The window the frontend opens for a non-square-pixel console: with aspect
// correction on, a 256x240 picture at scale 2 is 8/7 wider; off, it is not.
@(test)
pixel_aspect_widens_the_window :: proc(t: ^testing.T) {
	sync.mutex_guard(&sdl_lock)
	os.set_env("SDL_VIDEODRIVER", "dummy")
	if sdl.Init({.VIDEO}) != 0 { testing.fail_now(t, "SDL_Init failed") }
	defer sdl.Quit()

	size_for :: proc(correct: bool) -> (w, h: c_int) {
		c := cfg()
		defer free_cfg(&c)
		c.scale = 2
		c.pixel_aspect = correct
		v: fsdl.Video
		defer fsdl.video_close(&v)
		if !fsdl.video_open(&v, 256, 240, 8.0 / 7.0, &c) { return 0, 0 }
		sdl.GetWindowSize(v.window, &w, &h)
		return
	}

	w, h := size_for(false)
	testing.expect_value(t, w, c_int(512))   // square pixels: exactly 2x
	testing.expect_value(t, h, c_int(480))

	w, h = size_for(true)
	testing.expect_value(t, w, c_int(585))   // 512 * 8/7 = 585.14
	testing.expect_value(t, h, c_int(480))   // height never changes
}

// ------------------------------------------------------- the Saturn's own pad ---

@(private = "file")
saturn_labels :: proc() -> (core: api.Core, labels: []api.Pad_Label) {
	core = saturn.interface()
	buf := make([]api.Pad_Label, api.PAD_LABELS_MAX, context.temp_allocator)
	n := core.get_pad_layout(raw_data(buf), api.PAD_LABELS_MAX)
	return core, buf[:n]
}

// The console's name for whatever the pad is pressing, through the whole chain:
// pad position -> generic button -> the Saturn's own button.
@(private = "file")
saturn_button :: proc(t: ^testing.T, raw: fsdl.Raw_Pad) -> string {
	c := cfg()
	defer free_cfg(&c)
	_, labels := saturn_labels()
	b, _ := fsdl.map_pad(raw, &c)
	names := make([dynamic]string, context.temp_allocator)
	for l in labels { if l.button in b { append(&names, string(l.name)) } }
	return strings.join(names[:], "+", context.temp_allocator)
}

@(test)
analogue_triggers_are_buttons_and_never_part_of_a_chord :: proc(t: ^testing.T) {
	c := cfg()
	defer free_cfg(&c)
	b, _ := fsdl.map_pad({left_trigger = true}, &c)
	testing.expect_value(t, b, api.Buttons{.L2})
	b, _ = fsdl.map_pad({right_trigger = true}, &c)
	testing.expect_value(t, b, api.Buttons{.R2})
	hk: fsdl.Hotkeys
	b, hk = fsdl.map_pad({back = true, start = true, left_trigger = true}, &c)
	testing.expect_value(t, hk, fsdl.Hotkeys{.Quit})
	testing.expect_value(t, b, api.Buttons{.L2})
}

@(test)
saturn_pad_has_its_six_face_buttons_and_two_triggers :: proc(t: ^testing.T) {
	// Bottom row A B C under the right thumb, top row X Y Z under the left, the
	// triggers L and R on the triggers (the RetroPad convention for the Saturn).
	testing.expect_value(t, saturn_button(t, {south = true}), "a")
	testing.expect_value(t, saturn_button(t, {east = true}), "b")
	testing.expect_value(t, saturn_button(t, {right_shoulder = true}), "c")
	testing.expect_value(t, saturn_button(t, {west = true}), "x")
	testing.expect_value(t, saturn_button(t, {north = true}), "y")
	testing.expect_value(t, saturn_button(t, {left_shoulder = true}), "z")
	testing.expect_value(t, saturn_button(t, {left_trigger = true}), "l")
	testing.expect_value(t, saturn_button(t, {right_trigger = true}), "r")
	testing.expect_value(t, saturn_button(t, {start = true}), "start")
	testing.expect_value(t, saturn_button(t, {up = true, left = true}), "up+left")
	// Select is the emulator's hotkey button and means nothing to a Saturn.
	testing.expect_value(t, saturn_button(t, {back = true}), "")
}

@(test)
saturn_layout_is_complete_and_unambiguous :: proc(t: ^testing.T) {
	_, labels := saturn_labels()
	testing.expect_value(t, len(labels), 13)
	seen_button: [api.Button]bool
	for l in labels {
		testing.expectf(t, !seen_button[l.button], "two Saturn buttons read from generic %v", l.button)
		seen_button[l.button] = true
	}
	for want in ([]string{"up", "down", "left", "right", "start", "a", "b", "c", "x", "y", "z", "l", "r"}) {
		found := false
		for l in labels { if string(l.name) == want { found = true } }
		testing.expectf(t, found, "no Saturn button %q", want)
	}
}

@(test)
saturn_keyboard_is_laid_out_like_the_pad :: proc(t: ^testing.T) {
	c := cfg()
	defer free_cfg(&c)
	core, _ := saturn_labels()
	config.apply_core(&c, core)

	key :: proc(c: ^config.Config, b: api.Button) -> string { return strings.join(c.keys[b][:], "|", context.temp_allocator) }
	// A B C on J L M, X Y Z on H K Z, L R on Q E: two rows under the fingers like the pad.
	testing.expect_value(t, key(&c, .B), "J")  // Saturn a
	testing.expect_value(t, key(&c, .A), "L")  // Saturn b
	testing.expect_value(t, key(&c, .R), "M")  // Saturn c
	testing.expect_value(t, key(&c, .X), "H")  // Saturn x
	testing.expect_value(t, key(&c, .Y), "K")  // Saturn y
	testing.expect_value(t, key(&c, .L), "Z")  // Saturn z
	testing.expect_value(t, key(&c, .L2), "Q") // Saturn l
	testing.expect_value(t, key(&c, .R2), "E") // Saturn r
	testing.expect_value(t, key(&c, .Start), "Return")
	// D-pad is WASD + arrows.
	testing.expect_value(t, key(&c, .Up), "W|Up")
	testing.expect_value(t, key(&c, .Left), "A|Left")

	// And every key name is a real SDL key.
	km := fsdl.keymap_from_config(&c)
	defer fsdl.keymap_destroy(&km)
	testing.expect_value(t, len(c.warnings), 0)
}

@(test)
the_users_own_keys_win_over_a_cores_suggestions :: proc(t: ^testing.T) {
	core, _ := saturn_labels()
	key :: proc(c: ^config.Config, b: api.Button) -> string { return strings.join(c.keys[b][:], "|", context.temp_allocator) }

	// A generic [input.keyboard] entry pins the button the core reads from.
	c := cfg()
	config.apply_text(&c, "[input.keyboard]\nb = [\"K\"]\n")
	config.apply_core(&c, core)
	testing.expect_value(t, key(&c, .B), "K")  // Saturn a: pinned by the user
	testing.expect_value(t, key(&c, .A), "L")  // Saturn b: still the core's suggestion
	free_cfg(&c)

	// The console's own names in [input.keyboard.saturn] win over everything.
	c = cfg()
	config.apply_text(&c, "[input.keyboard]\nb = [\"K\"]\n[input.keyboard.saturn]\na = [\"J\", \"M\"]\nz = []\n")
	config.apply_core(&c, core)
	testing.expect_value(t, key(&c, .B), "J|M")
	testing.expect_value(t, key(&c, .L), "")   // z explicitly unbound
	testing.expect_value(t, len(c.warnings), 0)
	free_cfg(&c)

	// A button the core does not have is reported; other cores' sections are not its business.
	c = cfg()
	config.apply_text(&c, "[input.keyboard.saturn]\nturbo = [\"T\"]\n[input.keyboard.demo]\na = [\"N\"]\n")
	config.apply_core(&c, core)
	testing.expect_value(t, len(c.warnings), 1)
	if len(c.warnings) == 1 { testing.expect(t, strings.contains(c.warnings[0], "turbo")) }
	free_cfg(&c)
}

// What --print-config shows for the Saturn is itself a valid config that gives the same keys.
@(test)
the_saturn_section_round_trips :: proc(t: ^testing.T) {
	core, _ := saturn_labels()
	a := cfg()
	defer free_cfg(&a)
	config.apply_text(&a, "[input.keyboard.saturn]\nc = [\"V\"]\n")
	text := config.layout_text(&a, core)
	testing.expect(t, strings.contains(text, "[input.keyboard.saturn]"))
	testing.expect(t, strings.contains(text, "c = [\"V\"]"))
	testing.expect(t, strings.contains(text, "start = [\"Return\"]"))

	b := cfg()
	defer free_cfg(&b)
	config.apply_text(&b, text)
	config.apply_core(&b, core)
	config.apply_core(&a, core)
	for btn in api.Button {
		testing.expect_value(t, strings.join(b.keys[btn][:], "|", context.temp_allocator), strings.join(a.keys[btn][:], "|", context.temp_allocator))
	}
}

// A config written by --write-config lists every default key. That must not count as
// the user having chosen them, or no core's layout would ever be used.
@(test)
a_written_out_default_config_does_not_block_a_cores_layout :: proc(t: ^testing.T) {
	core, _ := saturn_labels()
	first := cfg()
	text := config.to_text(&first)
	defer delete(text)
	free_cfg(&first)

	c := cfg()
	defer free_cfg(&c)
	config.apply_text(&c, text)
	config.apply_core(&c, core)
	testing.expect_value(t, strings.join(c.keys[.B][:], "|", context.temp_allocator), "J")
	testing.expect_value(t, strings.join(c.keys[.L2][:], "|", context.temp_allocator), "Q")
	testing.expect_value(t, strings.join(c.keys[.Left][:], "|", context.temp_allocator), "A|Left") // D-pad is WASD + arrows

	// A key the user actually changed in that file still wins.
	c2 := cfg()
	defer free_cfg(&c2)
	config.apply_text(&c2, strings.concatenate({text, "\n[input.keyboard]\nb = [\"K\"]\n"}, context.temp_allocator))
	config.apply_core(&c2, core)
	testing.expect_value(t, strings.join(c2.keys[.B][:], "|", context.temp_allocator), "K")
}
