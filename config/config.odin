// User configuration: one struct, filled from defaults, then the config file,
// then command-line flags (the app applies those last).
//
// FILE FORMAT. `[section]` headers, `key = value` lines, `#` comments, quoted
// strings, bare ints/bools, and `["a", "b"]` lists. That subset is valid TOML
// as well as INI, so moving to a real TOML parser later won't change any
// user's file. (Deliberately not used yet: nested tables, dates, multi-line
// strings, inline tables.)
package config

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import api "../api"

Config :: struct {
	// [paths]
	saves_dir:  string, // battery RAM. "@rom" means next to the ROM
	states_dir: string, // save states
	system_dir: string, // BIOS / firmware (cores that need them)

	// [video]
	fullscreen:    bool,
	scale:         int,  // initial window = native size * scale
	vsync:         bool,
	integer_scale: bool, // only whole-number scale factors (crisp pixels)
	pixel_aspect:  bool, // stretch to the console's real pixel shape (NES 8:7)

	// [audio]
	audio_enabled: bool,
	latency_ms:    int,  // how much sound to keep queued; lower = more responsive, less safe

	// [input.keyboard]: SDL key names per generic button. These are *positional*
	// (south / east / west / north face buttons, shoulders, triggers); a console's
	// own names for its buttons are used in [input.keyboard.<core>], below.
	keys:      [api.Button][dynamic]string,
	keys_user: [api.Button]bool, // set explicitly in [input.keyboard]: a core's defaults must not replace it

	// [input.keyboard.<core id>]: keys by the console's own button names ("a", "z",
	// "start"...). Kept as written until a core is chosen and says what they mean.
	core_keys: [dynamic]Core_Key,

	// [input.gamepad]
	stick_as_dpad:  bool,
	stick_deadzone: int, // 0..32767

	// Runtime only (command line): also show the core's informational messages.
	verbose: bool,

	// Problems found while loading; the app prints them.
	warnings: [dynamic]string,
}

Core_Key :: struct {
	core:  string,
	label: string,
	keys:  [dynamic]string,
}

// ------------------------------------------------------------- locations ---

@(private)
join :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}

@(private)
env :: proc(key: string) -> string {
	v, _ := os.lookup_env(key, context.temp_allocator) // scratch: callers copy what they keep
	return v
}

home_dir :: proc() -> string { return env("HOME") }

// $XDG_CONFIG_HOME/uranus, else ~/.config/uranus
config_dir :: proc() -> string {
	base := env("XDG_CONFIG_HOME")
	if base == "" { base = join({home_dir(), ".config"}) }
	return join({base, "uranus"})
}

// $XDG_DATA_HOME/uranus, else ~/.local/share/uranus
data_dir :: proc() -> string {
	base := env("XDG_DATA_HOME")
	if base == "" { base = join({home_dir(), ".local", "share"}) }
	return join({base, "uranus"})
}

default_path :: proc() -> string { return join({config_dir(), "config.ini"}) }

// "~" and "~/x" expand to the home directory.
expand :: proc(p: string) -> string {
	if p == "~" { return home_dir() }
	if strings.has_prefix(p, "~/") { return join({home_dir(), p[2:]}) }
	return p
}

// ------------------------------------------------------------- defaults ---

@(private)
BUTTON_NAMES := [api.Button]string{
	.Up = "up", .Down = "down", .Left = "left", .Right = "right",
	.A = "a", .B = "b", .X = "x", .Y = "y",
	.Start = "start", .Select = "select", .L = "l", .R = "r",
	.C = "c", .Z = "z", .L2 = "l2", .R2 = "r2",
}

@(private)
set_keys :: proc(c: ^Config, b: api.Button, names: ..string) {
	for old in c.keys[b] { delete(old) }
	clear(&c.keys[b])
	for n in names { append(&c.keys[b], strings.clone(n)) }
}

defaults :: proc() -> (c: Config) {
	data := data_dir()
	c.saves_dir  = strings.clone(join({data, "saves"}))
	c.states_dir = strings.clone(join({data, "states"}))
	c.system_dir = strings.clone(join({data, "system"}))

	c.fullscreen, c.scale, c.vsync, c.integer_scale = false, 4, true, true
	c.pixel_aspect = false
	c.audio_enabled, c.latency_ms = true, 40
	c.stick_as_dpad, c.stick_deadzone = true, 12000

	// SDL key names (what SDL_GetScancodeFromName understands).
	set_keys(&c, .Up, "Up", "W")
	set_keys(&c, .Down, "Down", "S")
	set_keys(&c, .Left, "Left", "A")
	set_keys(&c, .Right, "Right", "D")
	set_keys(&c, .A, "X", "J")
	set_keys(&c, .B, "Z", "K")
	set_keys(&c, .X, "V")
	set_keys(&c, .Y, "C")
	set_keys(&c, .Start, "Return")
	set_keys(&c, .Select, "Right Shift", "Backspace", "G")
	set_keys(&c, .L, "Q")
	set_keys(&c, .R, "E")
	return
}

// Free everything the config owns. (The app lets the OS reclaim it at exit;
// tests call this so the leak tracker can verify the rest.)
destroy :: proc(c: ^Config) {
	delete(c.saves_dir); delete(c.states_dir); delete(c.system_dir)
	for &list in c.keys {
		for k in list { delete(k) }
		delete(list)
	}
	for e in c.core_keys {
		delete(e.core); delete(e.label)
		for k in e.keys { delete(k) }
		delete(e.keys)
	}
	delete(c.core_keys)
	for w in c.warnings { delete(w) }
	delete(c.warnings)
	c^ = {}
}

// ---------------------------------------------------------------- loading ---

@(private)
warn :: proc(c: ^Config, format: string, args: ..any) {
	append(&c.warnings, fmt.aprintf(format, ..args))
}

// `value  # comment` -> `value`. A # inside quotes is part of the value.
@(private)
strip_comment :: proc(s: string) -> string {
	in_quote := false
	for i in 0 ..< len(s) {
		switch s[i] {
		case '"': in_quote = !in_quote
		case '#': if !in_quote { return strings.trim_space(s[:i]) }
		}
	}
	return strings.trim_space(s)
}

@(private)
unquote :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' { return s[1:len(s) - 1] }
	return s
}

// Replace a string field with an owned copy. Values parsed from the file are
// slices of a buffer that is freed after parsing, so they must never be kept
// directly.
@(private)
set_string :: proc(dst: ^string, v: string) {
	delete(dst^)
	dst^ = strings.clone(v)
}

// "x", "[\"a\", \"b\"]" or "a" -> list of (owned) strings
@(private)
parse_list :: proc(value: string) -> (out: [dynamic]string) {
	v := strings.trim_space(value)
	if len(v) >= 2 && v[0] == '[' && v[len(v) - 1] == ']' {
		v = v[1:len(v) - 1]
		for part in strings.split_iterator(&v, ",") {
			item := unquote(strings.trim_space(part))
			if item != "" { append(&out, strings.clone(item)) }
		}
	} else if item := unquote(v); item != "" {
		append(&out, strings.clone(item))
	}
	return
}

@(private)
parse_bool :: proc(c: ^Config, key, value: string, dst: ^bool) {
	switch value {
	case "true":  dst^ = true
	case "false": dst^ = false
	case: warn(c, "%s: expected true or false, got %q", key, value)
	}
}

@(private)
parse_int :: proc(c: ^Config, key, value: string, dst: ^int, lo, hi: int) {
	n, ok := 0, len(value) > 0
	for ch in value {
		if ch < '0' || ch > '9' { ok = false; break }
		n = n * 10 + int(ch - '0')
	}
	if !ok || n < lo || n > hi {
		warn(c, "%s: expected a whole number from %d to %d, got %q", key, lo, hi, value)
		return
	}
	dst^ = n
}

apply_text :: proc(c: ^Config, src: string) {
	// What the file says is only the user's choice if it differs from the built-in
	// defaults: --write-config lists every default, and a config written that way
	// must not stop a core's own layout from being used.
	base := defaults()
	defer destroy(&base)
	it := ini.iterator_from_string(src, ini.Options{comment = "#"})
	for {
		key, raw_with_comment, ok := ini.iterate(&it)
		if !ok { break }
		raw := strip_comment(raw_with_comment)
		section := it.section
		value := unquote(raw)
		full := fmt.tprintf("[%s] %s", section, key)

		switch section {
		case "paths":
			switch key {
			case "saves":  set_string(&c.saves_dir,  expand(value))
			case "states": set_string(&c.states_dir, expand(value))
			case "system": set_string(&c.system_dir, expand(value))
			case: warn(c, "unknown setting %s", full)
			}
		case "video":
			switch key {
			case "fullscreen":    parse_bool(c, full, value, &c.fullscreen)
			case "scale":         parse_int(c, full, value, &c.scale, 1, 32)
			case "vsync":         parse_bool(c, full, value, &c.vsync)
			case "integer_scale": parse_bool(c, full, value, &c.integer_scale)
			case "pixel_aspect":  parse_bool(c, full, value, &c.pixel_aspect)
			case: warn(c, "unknown setting %s", full)
			}
		case "audio":
			switch key {
			case "enabled":    parse_bool(c, full, value, &c.audio_enabled)
			case "latency_ms": parse_int(c, full, value, &c.latency_ms, 10, 500)
			case: warn(c, "unknown setting %s", full)
			}
		case "input.keyboard":
			matched := false
			for b in api.Button {
				if BUTTON_NAMES[b] == key {
					for old in c.keys[b] { delete(old) }
					delete(c.keys[b])
					c.keys[b] = parse_list(raw)
					c.keys_user[b] = !same_keys(c.keys[b][:], base.keys[b][:])
					matched = true
				}
			}
			if !matched { warn(c, "unknown button %s", full) }
		case "input.gamepad":
			switch key {
			case "stick_as_dpad":  parse_bool(c, full, value, &c.stick_as_dpad)
			case "stick_deadzone": parse_int(c, full, value, &c.stick_deadzone, 0, 32767)
			case: warn(c, "unknown setting %s", full)
			}
		case:
			if strings.has_prefix(section, "input.keyboard.") {
				set_core_keys(c, strings.trim_prefix(section, "input.keyboard."), key, parse_list(raw))
			} else {
				warn(c, "unknown section [%s] (key %q)", section, key)
			}
		}
	}
}

// A missing file is not an error: defaults apply. An unreadable one is.
load_file :: proc(c: ^Config, path: string, must_exist: bool) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		if !must_exist && !os.exists(path) { return true }
		warn(c, "cannot read config %q: %v", path, err)
		return false
	}
	defer delete(data)
	apply_text(c, string(data))
	return true
}

// ----------------------------------------------------------------- output ---

// The effective configuration as a config file. Used for --print-config and
// --write-config, so users get a documented starting point.
to_text :: proc(c: ^Config) -> string {
	sb: strings.Builder
	w :: fmt.sbprintfln
	w(&sb, "# uranus configuration. Lines starting with # are comments.")
	w(&sb, "# Command-line flags override this file.\n")

	w(&sb, "[paths]")
	w(&sb, "# Battery saves (.sav). \"@rom\" keeps them next to the ROM.")
	w(&sb, "saves = %q", c.saves_dir)
	w(&sb, "states = %q", c.states_dir)
	w(&sb, "system = %q\n", c.system_dir)

	w(&sb, "[video]")
	w(&sb, "fullscreen = %v", c.fullscreen)
	w(&sb, "scale = %d            # initial window size multiplier", c.scale)
	w(&sb, "vsync = %v", c.vsync)
	w(&sb, "integer_scale = %v    # only whole-number scaling: crisp pixels, black bars", c.integer_scale)
	w(&sb, "pixel_aspect = %v     # true: stretch to the console's real pixel shape (NES: 8:7)\n", c.pixel_aspect)

	w(&sb, "[audio]")
	w(&sb, "enabled = %v", c.audio_enabled)
	w(&sb, "latency_ms = %d       # lower is more responsive, higher is safer on slow machines\n", c.latency_ms)

	w(&sb, "[input.keyboard]")
	w(&sb, "# SDL key names: https://wiki.libsdl.org/SDL2/SDL_Scancode")
	w(&sb, "# These are the generic pad, named by position: a = east face button, b = south,")
	w(&sb, "# x = west, y = north, l / r = shoulders, l2 / r2 = triggers. A console with a pad")
	w(&sb, "# of its own has a section below, [input.keyboard.<console>], that names its")
	w(&sb, "# buttons the way the console does and takes priority.")
	for b in api.Button {
		names := make([dynamic]string, context.temp_allocator)
		for n in c.keys[b] { append(&names, fmt.tprintf("%q", n)) }
		w(&sb, "%s = [%s]", BUTTON_NAMES[b], strings.join(names[:], ", ", context.temp_allocator))
	}

	w(&sb, "\n[input.gamepad]")
	w(&sb, "stick_as_dpad = %v", c.stick_as_dpad)
	w(&sb, "stick_deadzone = %d", c.stick_deadzone)
	return strings.to_string(sb)
}


// ------------------------------------------------- a core's own button names ---

@(private)
same_keys :: proc(a, b: []string) -> bool {
	if len(a) != len(b) { return false }
	for i in 0 ..< len(a) { if a[i] != b[i] { return false } }
	return true
}

// Remember `[input.keyboard.<core>] label = [...]`. A later line for the same
// button replaces an earlier one.
@(private)
set_core_keys :: proc(c: ^Config, core, label: string, keys: [dynamic]string) {
	for &e in c.core_keys {
		if e.core == core && e.label == label {
			for k in e.keys { delete(k) }
			delete(e.keys)
			e.keys = keys
			return
		}
	}
	append(&c.core_keys, Core_Key{core = strings.clone(core), label = strings.clone(label), keys = keys})
}

@(private)
split_keys :: proc(keys: cstring, allocator := context.temp_allocator) -> []string {
	if keys == "" { return nil }
	return strings.split(string(keys), "|", allocator)
}

@(private)
core_layout :: proc(core: api.Core) -> (id: string, labels: []api.Pad_Label) {
	if core.get_pad_layout == nil || core.get_info == nil { return }
	info: api.Core_Info
	core.get_info(&info)
	buf := make([]api.Pad_Label, api.PAD_LABELS_MAX, context.temp_allocator)
	n := core.get_pad_layout(raw_data(buf), api.PAD_LABELS_MAX)
	return string(info.id), buf[:min(n, api.PAD_LABELS_MAX)]
}

// Dress the keyboard for this core. A core that describes its own pad
// (api.Pad_Label) gets its buttons on the keys it suggests, unless the user said
// otherwise: first `[input.keyboard.<core>]` by the console's button name, then
// a generic `[input.keyboard]` entry for the button it is read from.
apply_core :: proc(c: ^Config, core: api.Core) {
	id, labels := core_layout(core)
	if len(labels) == 0 { return }
	for l in labels {
		if over, found := find_core_keys(c, id, string(l.name)); found {
			set_keys(c, l.button, ..over.keys[:])
		} else if !c.keys_user[l.button] {
			set_keys(c, l.button, ..split_keys(l.keys))
		}
	}
	for e in c.core_keys {
		if e.core != id { continue }
		known := false
		for l in labels { if string(l.name) == e.label { known = true } }
		if !known { warn(c, "unknown button [input.keyboard.%s] %s", id, e.label) }
	}
}

@(private)
find_core_keys :: proc(c: ^Config, core, label: string) -> (e: ^Core_Key, ok: bool) {
	for &k in c.core_keys {
		if k.core == core && k.label == label { return &k, true }
	}
	return
}

// The core's own section of the config file, with the keys that would be used.
// Empty when the core has the plain generic pad. Lives in the temp allocator.
layout_text :: proc(c: ^Config, core: api.Core) -> string {
	id, labels := core_layout(core)
	if len(labels) == 0 { return "" }
	info: api.Core_Info
	core.get_info(&info)
	sb := strings.builder_make(context.temp_allocator) // short-lived: the caller prints it
	w :: fmt.sbprintfln
	w(&sb, "\n[input.keyboard.%s]", id)
	w(&sb, "# %s buttons, by the console's own names. These win over [input.keyboard].", info.name)
	for l in labels {
		names := make([dynamic]string, context.temp_allocator)
		keys: []string
		if over, found := find_core_keys(c, id, string(l.name)); found {
			keys = over.keys[:]
		} else if !c.keys_user[l.button] {
			keys = split_keys(l.keys)
		} else {
			keys = c.keys[l.button][:]
		}
		for n in keys { append(&names, fmt.tprintf("%q", n)) }
		w(&sb, "%s = [%s]", l.name, strings.join(names[:], ", ", context.temp_allocator))
	}
	return strings.to_string(sb)
}

// --------------------------------------------------------------- per game ---

// Where this ROM's battery RAM and save state go. Creates the directories.
game_paths :: proc(c: ^Config, rom_path: string) -> (sav, state: string) {
	stem := filepath.stem(filepath.base(rom_path))
	rom_dir := filepath.dir(rom_path)

	pick :: proc(c: ^Config, dir, rom_dir: string) -> string {
		if dir == "@rom" || dir == "" { return rom_dir }
		if !os.exists(dir) {
			if err := os.make_directory_all(dir); err != nil {
				warn(c, "cannot create %q (%v); using the ROM's folder instead", dir, err)
				return rom_dir
			}
		}
		return dir
	}

	sav   = join({pick(c, c.saves_dir, rom_dir),  fmt.tprintf("%s.sav", stem)})
	state = join({pick(c, c.states_dir, rom_dir), fmt.tprintf("%s.state", stem)})
	return
}
