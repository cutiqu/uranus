// uranus: one executable. Cores and frontends are compiled in; the only thing
// connecting them is api.Core, a struct of procedure pointers.
//
// Built to be launched by something else (EmuDeck, EmulationStation, Steam
// ROM Manager): `uranus game.img` boots straight into the game, prints nothing
// unless something is wrong, and reports failure through its exit code.
//
//   exit 0  normal exit            exit 1  could not run (bad ROM, no core, ...)
//   exit 2  bad command line
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import api "../api"
import "../config"
import frontend_headless "../frontend/headless"
import "../host"
import "../registry"

VERSION :: "0.1.0"

Frontend :: enum { SDL, TUI, Headless }

usage :: proc(to_stderr := true) {
	text := `usage: uranus [options] <rom>

  Runs <rom> with the emulation core chosen by its file extension.

options:
  -c, --core ID        use this core instead (see --list-cores)
      --config FILE    config file (default: ~/.config/uranus/config.ini)
  -f, --fullscreen     start fullscreen          -w, --windowed   start in a window
      --scale N        window size multiplier
      --no-vsync       don't wait for the monitor's refresh
      --mute           no audio
      --frame-stats    print frame-pacing statistics on exit (SDL frontend)
  -v, --verbose        also show the core's informational messages
      --tui            draw in the terminal instead of a window

information:
      --list-cores     list the built-in cores and their file types
      --print-config   print the effective configuration and exit
      --write-config   write a default config file (if none exists) and exit
  -h, --help           this text            --version

testing (no window):
      --headless N         run N frames without any UI
      --dump FILE.ppm      with --headless: save the last frame
      --wav FILE.wav       with --headless: save the audio
      --check-determinism PRE POST    save-state conformance check
      --fuzz-state N       with --check-determinism: also mutate the state N ways
      --seconds N          window frontend: exit after N seconds
`
	if to_stderr { fmt.eprint(text) } else { fmt.print(text) }
}

die_usage :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("uranus: ")
	fmt.eprintfln(format, ..args)
	fmt.eprintln("try 'uranus --help'")
	os.exit(2)
}

list_cores :: proc() {
	for i in 0 ..< registry.count() {
		_, info := registry.at(i)
		ext, _ := strings.replace_all(string(info.extensions), "|", " .", context.temp_allocator)
		fmt.printfln("%-8s %-22s .%s", info.id, info.name, ext)
	}
}

// The generic configuration plus a keyboard section for every core that has a
// pad of its own.
full_config_text :: proc(cfg: ^config.Config) -> string {
	sb: strings.Builder
	strings.write_string(&sb, config.to_text(cfg))
	for i in 0 ..< registry.count() {
		core, _ := registry.at(i)
		strings.write_string(&sb, config.layout_text(cfg, core))
	}
	return strings.to_string(sb)
}

main :: proc() {
	// ---- command line -----------------------------------------------------
	rom_path, core_id, config_path, dump_path, wav_path: string
	cfg_overrides: struct { fullscreen, windowed, no_vsync, mute, verbose, frame_stats: bool, scale: int }
	frontend := Frontend.SDL
	hl := frontend_headless.Options{}
	seconds: int
	want_list, want_print, want_write: bool

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		value :: proc(args: []string, i: ^int, flag: string) -> string {
			i^ += 1
			if i^ >= len(args) { die_usage("%s needs a value", flag) }
			return args[i^]
		}
		number :: proc(args: []string, i: ^int, flag: string) -> int {
			s := value(args, i, flag)
			n, ok := host.parse_uint(s)
			if !ok { die_usage("%s needs a whole number, got %q", flag, s) }
			return n
		}

		switch arg {
		case "-h", "--help":   usage(false); return
		case "--version":      fmt.println("uranus", VERSION); return
		case "--list-cores":   want_list = true
		case "--print-config": want_print = true
		case "--write-config": want_write = true
		case "-c", "--core":   core_id = value(args, &i, arg)
		case "--config":       config_path = value(args, &i, arg)
		case "-f", "--fullscreen": cfg_overrides.fullscreen = true
		case "-w", "--windowed":   cfg_overrides.windowed = true
		case "--no-vsync":     cfg_overrides.no_vsync = true
		case "--mute":         cfg_overrides.mute = true
		case "--frame-stats":  cfg_overrides.frame_stats = true
		case "-v", "--verbose": cfg_overrides.verbose = true
		case "--scale":        cfg_overrides.scale = number(args, &i, arg)
		case "--tui":          frontend = .TUI
		case "--seconds":      seconds = number(args, &i, arg)
		case "--headless":
			frontend = .Headless
			hl.frames = number(args, &i, arg)
		case "--dump":         dump_path = value(args, &i, arg)
		case "--wav":          wav_path = value(args, &i, arg)
		case "--check-determinism":
			frontend = .Headless
			hl.check = true
			hl.check_pre = number(args, &i, arg)
			hl.check_post = number(args, &i, arg)
		case "--fuzz-state":   hl.fuzz = number(args, &i, arg)
		case:
			if strings.has_prefix(arg, "-") { die_usage("unknown option %q", arg) }
			if rom_path != "" { die_usage("more than one ROM given (%q and %q)", rom_path, arg) }
			rom_path = arg
		}
	}
	hl.dump_path, hl.wav_path = dump_path, wav_path

	if want_list { list_cores(); return }

	// ---- configuration: defaults < config file < command line ---------------
	cfg := config.defaults()
	explicit := config_path != ""
	if !explicit { config_path = config.default_path() }

	if want_write {
		if os.exists(config_path) {
			fmt.eprintfln("uranus: %s already exists; not overwriting", config_path)
			os.exit(1)
		}
		_ = os.make_directory_all(filepath.dir(config_path))
		if err := os.write_entire_file(config_path, transmute([]byte)full_config_text(&cfg)); err != nil {
			fmt.eprintfln("uranus: cannot write %s: %v", config_path, err)
			os.exit(1)
		}
		fmt.println("wrote", config_path)
		return
	}

	if !config.load_file(&cfg, config_path, must_exist = explicit) && explicit {
		for w in cfg.warnings { fmt.eprintfln("uranus: %s", w) }
		os.exit(1)
	}
	if cfg_overrides.fullscreen { cfg.fullscreen = true }
	if cfg_overrides.windowed   { cfg.fullscreen = false }
	if cfg_overrides.no_vsync   { cfg.vsync = false }
	if cfg_overrides.mute       { cfg.audio_enabled = false }
	if cfg_overrides.verbose    { cfg.verbose = true }
	if cfg_overrides.frame_stats { cfg.frame_stats = true }
	if cfg_overrides.scale > 0  { cfg.scale = cfg_overrides.scale }

	for w in cfg.warnings { fmt.eprintfln("uranus: config: %s", w) }
	clear(&cfg.warnings)
	if want_print { fmt.print(full_config_text(&cfg)); return }

	// ---- pick the core --------------------------------------------------------
	if rom_path == "" { usage(); os.exit(2) }

	core: api.Core
	found: bool
	if core_id != "" {
		core, found = registry.find_by_id(core_id)
		if !found { die_usage("no core named %q (see --list-cores)", core_id) }
	} else {
		ext := strings.to_lower(strings.trim_prefix(filepath.ext(rom_path), "."), context.temp_allocator)
		core, found = registry.find_by_extension(ext)
		if !found {
			fmt.eprintfln("uranus: no built-in core handles %q files (see --list-cores, or pick one with --core)", filepath.ext(rom_path))
			os.exit(1)
		}
	}

	// A core with its own pad (a Saturn has six face buttons) gets its buttons on
	// the keys it suggests, unless the config file says otherwise.
	config.apply_core(&cfg, core)
	for w in cfg.warnings { fmt.eprintfln("uranus: config: %s", w) }
	clear(&cfg.warnings)

	// ---- run ------------------------------------------------------------------
	run_platform(core, rom_path, &cfg, frontend, hl, seconds, cfg_overrides.scale)
}
