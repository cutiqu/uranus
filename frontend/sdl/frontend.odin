// SDL2 frontend: a window, real key and controller events, real audio.
//
// Pacing: the AUDIO DEVICE is the clock. The device drains a ring buffer at
// exactly its sample rate; whenever the buffer holds less than the configured
// latency of sound, we run another core frame and push its samples. Video and
// audio therefore can't drift apart, and the core's 59.7275 fps needn't match
// the monitor's refresh rate. With no audio device we fall back to a timer.
package frontend_sdl

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:time"
import sdl "vendor:sdl2"
import api "../../api"
import "../../config"
import "../../host"

// ------------------------------------------------------------- core hooks ---

// What the core's `userdata` points at. The core never looks inside it.
Pad :: struct {
	buttons: api.Buttons, // fresh state, written by the main loop before every run_frame
	verbose: bool,
}

// One line per save/load, always naming the file, so "where did it go" is never a
// question. The reason for a failure is printed just above by the host or the core.
state_report :: proc(what: string, ok: bool, path: string) {
	if ok {
		fmt.eprintfln("%s state: ok (%s)", what, path)
	} else {
		fmt.eprintfln("%s state: failed (%s)", what, path)
	}
}

input_callback :: proc "c" (userdata: rawptr, port: u32) -> api.Buttons {
	if port != 0 { return {} }
	return (^Pad)(userdata).buttons
}

// Quiet by default: a launcher-started game should print nothing unless
// something is wrong. --verbose shows the informational messages too.
log_callback :: proc "c" (userdata: rawptr, level: api.Log_Level, msg: cstring) {
	context = runtime.default_context()
	if level >= .Warn || (^Pad)(userdata).verbose {
		fmt.eprintfln("[core %v] %s", level, msg)
	}
}

// ------------------------------------------------------------------ audio ---

Audio :: struct {
	dev:       sdl.AudioDeviceID,
	ring:      host.Ring,
	underruns: int, // written by the audio thread, read at exit for the report
	started:   bool,
	ok:        bool,
}

// Runs on SDL's audio thread, with the device lock already held by SDL.
audio_callback :: proc "c" (userdata: rawptr, stream: [^]u8, length: c.int) {
	a := (^Audio)(userdata)
	out := ([^]i16)(stream)[:int(length) / 2]
	n := host.ring_pop(&a.ring, out)
	if n < len(out) {
		for i in n ..< len(out) { out[i] = 0 } // never play stale memory
		a.underruns += 1
	}
}

audio_open :: proc(a: ^Audio, rate: int) {
	want := sdl.AudioSpec{
		freq     = c.int(rate),
		format   = sdl.AUDIO_S16SYS,
		channels = 2,
		samples  = 512, // device buffer in frames (~10 ms at 48 kHz)
		callback = audio_callback,
		userdata = a,
	}
	have: sdl.AudioSpec
	// allowed_changes = {}: SDL converts to whatever the hardware wants, so
	// the core's own rate is kept.
	a.dev = sdl.OpenAudioDevice(nil, false, &want, &have, {})
	if a.dev == 0 {
		fmt.eprintfln("audio disabled: %s", sdl.GetError())
		return
	}
	a.ring = host.ring_make(rate * 2 / 4) // 250 ms of stereo samples, far more than we queue
	a.ok = true
}

audio_close :: proc(a: ^Audio) {
	if !a.ok { return }
	sdl.CloseAudioDevice(a.dev)
	host.ring_destroy(&a.ring)
}

audio_push :: proc(a: ^Audio, samples: []i16) {
	sdl.LockAudioDevice(a.dev)
	_ = host.ring_push(&a.ring, samples)
	sdl.UnlockAudioDevice(a.dev)
}

audio_buffered_frames :: proc(a: ^Audio) -> int {
	sdl.LockAudioDevice(a.dev)
	n := a.ring.count / 2
	sdl.UnlockAudioDevice(a.dev)
	return n
}

// ------------------------------------------------------------------ video ---

Video :: struct {
	window:     ^sdl.Window,
	renderer:   ^sdl.Renderer,
	texture:    ^sdl.Texture,
	tex_w:      i32,
	tex_h:      i32,
	fullscreen: bool,
	integer:    bool,
	aspect:     f32, // pixel width/height to display with (1 = square)
}

video_open :: proc(v: ^Video, w, h: u32, aspect: f32, cfg: ^config.Config) -> bool {
	v.aspect = aspect if cfg.pixel_aspect && aspect > 0 else 1
	flags: sdl.WindowFlags = {.RESIZABLE}
	if cfg.fullscreen {
		flags = sdl.WINDOW_FULLSCREEN_DESKTOP
		v.fullscreen = true
	}
	v.window = sdl.CreateWindow("uranus", sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED,
		c.int(f32(int(w) * cfg.scale) * v.aspect), c.int(int(h) * cfg.scale), flags)
	if v.window == nil {
		fmt.eprintfln("cannot create window: %s", sdl.GetError())
		return false
	}
	if v.fullscreen { sdl.ShowCursor(0) } // a launcher-started game has no use for a mouse pointer

	sdl.SetHint(sdl.HINT_RENDER_SCALE_QUALITY, "nearest") // crisp pixels, no blur
	rflags: sdl.RendererFlags = {.ACCELERATED, .PRESENTVSYNC} if cfg.vsync else {.ACCELERATED}
	v.renderer = sdl.CreateRenderer(v.window, -1, rflags)
	if v.renderer == nil { v.renderer = sdl.CreateRenderer(v.window, -1, {.ACCELERATED}) }
	if v.renderer == nil { v.renderer = sdl.CreateRenderer(v.window, -1, {.SOFTWARE}) }
	if v.renderer == nil {
		fmt.eprintfln("cannot create renderer: %s", sdl.GetError())
		return false
	}
	v.integer = cfg.integer_scale
	return true
}

video_close :: proc(v: ^Video) {
	if v.texture  != nil { sdl.DestroyTexture(v.texture) }
	if v.renderer != nil { sdl.DestroyRenderer(v.renderer) }
	if v.window   != nil { sdl.DestroyWindow(v.window) }
}

// Upload the core's frame. 0x00RRGGBB is exactly SDL's XRGB8888 (RGB888),
// so this is a straight copy to the GPU: no per-pixel conversion.
video_upload :: proc(v: ^Video, f: api.Video_Frame) {
	if v.texture == nil || v.tex_w != i32(f.width) || v.tex_h != i32(f.height) {
		if v.texture != nil { sdl.DestroyTexture(v.texture) }
		v.texture = sdl.CreateTexture(v.renderer, .RGB888, .STREAMING, i32(f.width), i32(f.height))
		v.tex_w, v.tex_h = i32(f.width), i32(f.height)
		// The logical size is what the picture is *displayed* as; with a
		// non-square pixel it is wider than the texture and SDL stretches to fit.
		sdl.RenderSetLogicalSize(v.renderer, i32(f32(v.tex_w) * v.aspect + 0.5), v.tex_h)
		sdl.RenderSetIntegerScale(v.renderer, v.integer ? true : false)
	}
	sdl.UpdateTexture(v.texture, nil, f.pixels, c.int(f.pitch * 4))
}

video_present :: proc(v: ^Video) {
	sdl.SetRenderDrawColor(v.renderer, 0, 0, 0, 255)
	sdl.RenderClear(v.renderer)
	sdl.RenderCopy(v.renderer, v.texture, nil, nil)
	sdl.RenderPresent(v.renderer)
}

toggle_fullscreen :: proc(v: ^Video) {
	v.fullscreen = !v.fullscreen
	sdl.SetWindowFullscreen(v.window, sdl.WINDOW_FULLSCREEN_DESKTOP if v.fullscreen else {})
	sdl.ShowCursor(0 if v.fullscreen else 1)
}

// -------------------------------------------------------------------- run ---

// Runs until the user quits (or `seconds` of wall-clock time pass, if > 0:
// used by automated tests). Returns the process exit code.
run :: proc(core: api.Core, rom_path: string, cfg: ^config.Config, seconds: int) -> int {
	pad := Pad{verbose = cfg.verbose}
	callbacks := api.Host{userdata = &pad, input_state = input_callback, log = log_callback}
	sav, state := config.game_paths(cfg, rom_path)
	s: host.Session
	if !host.session_open(&s, core, rom_path, {sav = sav, state = state, system_dir = cfg.system_dir}, &callbacks) { return 1 }
	defer host.session_close(&s)

	if sdl.Init({.VIDEO, .GAMECONTROLLER}) != 0 {
		fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
		return 1
	}
	defer sdl.Quit()

	// Audio is optional: a machine with no working sound system should still
	// get a picture, paced by the timer fallback.
	audio_wanted := cfg.audio_enabled
	if audio_wanted && sdl.InitSubSystem({.AUDIO}) != 0 {
		fmt.eprintfln("audio disabled: %s", sdl.GetError())
		audio_wanted = false
	}

	video: Video
	if !video_open(&video, s.av.width, s.av.height, s.av.pixel_aspect, cfg) { return 1 }
	defer video_close(&video)

	audio: Audio
	if audio_wanted { audio_open(&audio, int(s.av.sample_rate)) }
	defer audio_close(&audio)

	keymap := keymap_from_config(cfg)
	defer keymap_destroy(&keymap)
	for w in cfg.warnings { fmt.eprintfln("config: %s", w) }
	clear(&cfg.warnings)

	pads: Pads
	pads_open_existing(&pads)
	defer pads_close(&pads)

	// Keep `latency_ms` of sound queued (on top of the device's own ~10 ms).
	target_buffered := int(s.av.sample_rate) * cfg.latency_ms / 1000

	frame_samples := int(f64(s.av.sample_rate) / s.av.fps) // sample frames of audio per core frame
	frame_time := time.Duration(f64(time.Second) / s.av.fps)
	deadline   := time.tick_now() // used only when there is no audio clock
	start      := time.tick_now()
	last_title := time.tick_now()

	total_frames, title_frames: int
	running, muted := true, !audio_wanted
	prev_hotkeys: Hotkeys

	for running {
		// ---- events (one-shot keyboard hotkeys, controller hot-plug) -------
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				running = false
			case .CONTROLLERDEVICEADDED:
				pads_add(&pads, ev.cdevice.which)
			case .CONTROLLERDEVICEREMOVED:
				pads_remove(&pads, sdl.JoystickID(ev.cdevice.which))
			case .KEYDOWN:
				if ev.key.repeat != 0 { break }
				#partial switch ev.key.keysym.scancode {
				case .ESCAPE: running = false
				case .F5:  state_report("save", host.session_save_state(&s), s.paths.state)
				case .F7:  state_report("load", host.session_load_state(&s), s.paths.state)
				case .F1:  s.emu.reset()
				case .F11: toggle_fullscreen(&video)
				case .M:   muted = !muted
				}
			}
		}
		if seconds > 0 && time.duration_seconds(time.tick_since(start)) >= f64(seconds) { break }

		// ---- input ---------------------------------------------------------
		pad_buttons, hotkeys := read_pads(&pads, cfg)
		pad.buttons = read_keyboard(&keymap) + pad_buttons

		pressed := hotkeys - prev_hotkeys // act on the moment a chord completes
		prev_hotkeys = hotkeys
		if .Quit       in pressed { running = false }
		if .Save_State in pressed { state_report("save", host.session_save_state(&s), s.paths.state) }
		if .Load_State in pressed { state_report("load", host.session_load_state(&s), s.paths.state) }
		if .Reset      in pressed { s.emu.reset() }

		// ---- decide how many frames to run ---------------------------------
		frames_to_run := 0
		fast := sdl.GetKeyboardStateAsSlice()[int(sdl.Scancode.TAB)] != 0
		switch {
		case fast:
			frames_to_run = 4
		case audio.ok:
			// One frame in steady state; more after a hitch so the buffer can recover
			// (see host/pacing.odin for why a fixed one-per-iteration cannot).
			frames_to_run = host.pace_audio_frames(audio_buffered_frames(&audio), target_buffered, frame_samples)
		case:
			now := time.tick_now()
			if time.tick_diff(deadline, now) >= 0 {
				frames_to_run = 1
				deadline = time.tick_add(deadline, frame_time)
				if time.tick_diff(deadline, now) > 100 * time.Millisecond { deadline = now } // fell far behind
			}
		}

		ran := 0
		for _ in 0 ..< frames_to_run {
			s.emu.run_frame()
			ran += 1
			total_frames += 1
			title_frames += 1

			if audio.ok && !fast {
				a: api.Audio_Buffer
				s.emu.get_audio(&a)
				samples := a.samples[:a.frames * 2]
				if muted {
					silent := make([]i16, len(samples))
					audio_push(&audio, silent)
					delete(silent)
				} else {
					audio_push(&audio, samples)
				}
			}
		}

		// Start the device once the buffer has its cushion, not before: that
		// avoids counting a startup underrun.
		if audio.ok && !audio.started && audio_buffered_frames(&audio) >= target_buffered {
			sdl.PauseAudioDevice(audio.dev, false)
			audio.started = true
		}

		if ran > 0 {
			f: api.Video_Frame
			s.emu.get_video(&f)
			video_upload(&video, f)
			video_present(&video)
		} else {
			sdl.Delay(1) // nothing due yet; don't spin the CPU
		}

		// ---- window title: live fps + buffer ------------------------------
		if time.duration_seconds(time.tick_since(last_title)) >= 1 {
			secs := time.duration_seconds(time.tick_since(last_title))
			buf_ms := audio_buffered_frames(&audio) * 1000 / int(s.av.sample_rate) if audio.ok else 0
			title := fmt.ctprintf("%s | %.1f fps | audio buffer %d ms%s", s.info.name, f64(title_frames) / secs, buf_ms, " | MUTED" if muted else "")
			sdl.SetWindowTitle(video.window, title)
			title_frames = 0
			last_title = time.tick_now()
		}

		host.session_tick(&s, ran)
	}

	elapsed := time.duration_seconds(time.tick_since(start))
	if seconds > 0 { // test runs report; normal runs stay silent
		fmt.eprintfln("sdl: %d frames in %.2f s = %.2f fps (core nominal %.2f) | audio underruns: %d",
			total_frames, elapsed, f64(total_frames) / elapsed, s.av.fps, audio.underruns)
	}
	return 0
}
