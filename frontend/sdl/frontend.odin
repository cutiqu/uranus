// SDL2 frontend: a window, real key and controller events, real audio.
//
// Pacing: frames fall due on the monotonic clock (host/pacing.odin) and audio is
// trimmed to match. Vsync only affects present().
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

	asked, got: sdl.AudioSpec,
	cb_frames:  int, // frames per callback
	perf_freq:  u64,
	last_cb:    u64,
	gap_min:    u64,
	gap_max:    u64,
	gap_sum:    u64,
	gap_count:  int,
}

// Runs on SDL's audio thread, with the device lock already held by SDL.
audio_callback :: proc "c" (userdata: rawptr, stream: [^]u8, length: c.int) {
	a := (^Audio)(userdata)
	now := sdl.GetPerformanceCounter()
	if a.last_cb != 0 {
		gap := now - a.last_cb
		a.gap_min = min(a.gap_min, gap)
		a.gap_max = max(a.gap_max, gap)
		a.gap_sum += gap
		a.gap_count += 1
	}
	a.last_cb = now
	a.cb_frames = int(length) / 4 // stereo 16-bit
	out := ([^]i16)(stream)[:int(length) / 2]
	n := host.ring_pop(&a.ring, out)
	if n < len(out) {
		for i in n ..< len(out) { out[i] = 0 } // never play stale memory
		a.underruns += 1
	}
}

// Frames per audio callback; override with -define:URANUS_AUDIO_FRAMES=N.
AUDIO_DEVICE_FRAMES :: #config(URANUS_AUDIO_FRAMES, 512)

audio_open :: proc(a: ^Audio, rate: int) {
	want := sdl.AudioSpec{
		freq     = c.int(rate),
		format   = sdl.AUDIO_S16SYS,
		channels = 2,
		samples  = AUDIO_DEVICE_FRAMES, // device buffer in frames (~10 ms at 48 kHz)
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
	a.asked, a.got = want, have
	a.perf_freq = sdl.GetPerformanceFrequency()
	a.gap_min = max(u64)
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

// Pause and empty the ring, then refill before resuming (after a resync or fast-forward).
audio_reprime :: proc(a: ^Audio) {
	if !a.ok || !a.started { return }
	sdl.PauseAudioDevice(a.dev, true)
	sdl.LockAudioDevice(a.dev)
	a.ring.read, a.ring.count = 0, 0
	sdl.UnlockAudioDevice(a.dev)
	a.started = false
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

// ------------------------------------------------------------------ stats ---

Stats :: struct {
	on:        bool,
	interval:  host.Series, // ms between presents
	cost:      host.Series, // ms to run frames and upload the picture
	present:   host.Series, // ms inside present()
	wake_late: host.Series, // us the sleep woke after its deadline
	buffer:    host.Series, // ms queued before each push
	trim:      host.Series, // % the audio was stretched (+) or squeezed (-)
	catchups:  int,
	resyncs:   int,
	reprimes:  int,
}

stats_destroy :: proc(st: ^Stats) {
	host.series_destroy(&st.interval)
	host.series_destroy(&st.cost)
	host.series_destroy(&st.present)
	host.series_destroy(&st.wake_late)
	host.series_destroy(&st.buffer)
	host.series_destroy(&st.trim)
}

stats_line :: proc(name, unit: string, s: ^host.Series) {
	sum := host.series_summary(s)
	if sum.count == 0 {
		fmt.eprintfln("  %-24s (no samples)", name)
		return
	}
	fmt.eprintfln("  %-24s mean %8.3f  p50 %8.3f  p99 %8.3f  p99.9 %8.3f  max %8.3f  %s",
		name, sum.mean, sum.p50, sum.p99, sum.p999, sum.max, unit)
}

stats_report :: proc(st: ^Stats, a: ^Audio, v: ^Video, fps: f64, sample_rate: int, seconds: f64, speed: f64) {
	period_ms := 1000.0 / fps
	fmt.eprintfln("frame-stats: %d pictures in %.1f s | core %.4f fps = %.3f ms per frame",
		len(st.interval.values) + 1, seconds, fps, period_ms)

	info: sdl.RendererInfo
	_ = sdl.GetRendererInfo(v.renderer, &info)
	mode: sdl.DisplayMode
	hz := 0
	if sdl.GetCurrentDisplayMode(0, &mode) == 0 { hz = int(mode.refresh_rate) }
	fmt.eprintfln("  video: %s, renderer %s, vsync granted: %v, display %d Hz (SDL2 reports whole Hz only)",
		sdl.GetCurrentVideoDriver(), info.name, .PRESENTVSYNC in info.flags, hz)
	if a.ok {
		fmt.eprintfln("  audio: %s, asked %d frames per callback, SDL says %d, callbacks deliver %d @ %d Hz",
			sdl.GetCurrentAudioDriver(), a.asked.samples, a.got.samples, a.cb_frames, a.got.freq)
		if a.gap_count > 0 && a.perf_freq > 0 {
			to_ms := 1000.0 / f64(a.perf_freq)
			avg_ms := f64(a.gap_sum) / f64(a.gap_count) * to_ms
			fmt.eprintfln("         callbacks every %.2f ms on average (shortest %.2f, longest %.2f), underruns: %d",
				avg_ms, f64(a.gap_min) * to_ms, f64(a.gap_max) * to_ms, a.underruns)
			device_rate := f64(a.cb_frames) / avg_ms * 1000
			fmt.eprintfln("         device consumed %.0f frames/s for a nominal %d: its clock reads %+.2f%% off",
				device_rate, a.got.freq, (device_rate / f64(a.got.freq) - 1) * 100)
		}
	} else {
		fmt.eprintfln("  audio: off")
	}

	stats_line("picture interval", "ms", &st.interval)
	fmt.eprintfln("  %-24s %.1f%% of intervals are more than 2 ms from the ideal %.3f ms",
		"", host.series_share_off(&st.interval, period_ms, 2.0) * 100, period_ms)
	stats_line("frame cost", "ms", &st.cost)
	stats_line("present() call", "ms", &st.present)
	stats_line("timeline wake lateness", "us", &st.wake_late)
	if a.ok {
		stats_line("audio queued before push", "ms", &st.buffer)
		stats_line("audio rate trim", "%", &st.trim)
		fmt.eprintfln("  game speed vs the core's own rate: %+.2f%% (non-zero only if the audio clock is too far off to trim away)", speed * 100)
	}
	fmt.eprintfln("  catch-up bursts: %d | timeline resyncs: %d | audio re-primes: %d",
		st.catchups, st.resyncs, st.reprimes)
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

	// Catch non-fatal X11 errors (e.g. the GLX BadValue that makes SDL's
	// accelerated renderer fail on NVIDIA) so Xlib doesn't exit before the
	// software fallback can take over.
	install_x_error_handler()

	if sdl.Init({.VIDEO, .GAMECONTROLLER}) != 0 {
		fmt.eprintfln("SDL_Init failed: %s", sdl.GetError())
		return 1
	}
	defer sdl.Quit()

	// Audio is optional: a machine with no working sound system should still
	// get a picture.
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

	clock := host.clock_make()
	sleeper: host.Sleeper
	timeline := host.timeline_make(s.av.fps, 0)
	rate: host.Rate_Control
	resampler: host.Resampler
	scratch: [dynamic]i16 // resampled audio for one frame
	defer delete(scratch)

	stats := Stats{on = cfg.frame_stats}
	defer stats_destroy(&stats)
	last_present := i64(-1)

	start      := time.tick_now()
	last_title := time.tick_now()
	last_status := time.tick_now()
	status_underruns := 0

	total_frames, title_frames: int
	running, muted := true, !audio_wanted
	fast, was_fast := false, false
	prev_hotkeys: Hotkeys

	for running {
		// ---- wait for the next frame ---------------------------------------
		if !fast {
			now := host.clock_ns(&clock)
			if wait := host.timeline_wait_ns(&timeline, now); wait > 0 {
				late := host.sleep_until(&clock, &sleeper, now + wait)
				if stats.on { host.series_add(&stats.wake_late, f64(late) / 1000) }
			}
		}

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
		fast = sdl.GetKeyboardStateAsSlice()[int(sdl.Scancode.TAB)] != 0
		frames_to_run := 0
		now := host.clock_ns(&clock)
		if fast {
			frames_to_run = 4
			was_fast = true
		} else {
			if was_fast { // leaving fast-forward
				host.timeline_reset(&timeline, now)
				audio_reprime(&audio)
				host.rate_reprime(&rate)
				stats.reprimes += 1
				was_fast = false
			}
			due := host.timeline_due(&timeline, now)
			frames_to_run = due.frames
			if due.frames > 1 { stats.catchups += 1 }
			if due.resynced { // ring ran dry
				audio_reprime(&audio)
				host.rate_reprime(&rate)
				stats.resyncs += 1
				stats.reprimes += 1
			}
		}
		if frames_to_run == 0 { continue } // woke early

		// ---- run -----------------------------------------------------------
		t_run := host.clock_ns(&clock)
		ran := 0
		for _ in 0 ..< frames_to_run {
			s.emu.run_frame()
			ran += 1
			total_frames += 1
			title_frames += 1

			if audio.ok && !fast {
				a: api.Audio_Buffer
				s.emu.get_audio(&a)

				buffered := audio_buffered_frames(&audio)
				ratio := 1.0
				if audio.started {
					ratio = host.rate_update(&rate, buffered, target_buffered, int(s.av.sample_rate))
					host.timeline_set_speed(&timeline, rate.speed)
					if stats.on {
						host.series_add(&stats.buffer, f64(buffered) * 1000 / f64(s.av.sample_rate))
						host.series_add(&stats.trim, (ratio - 1) * 100)
					}
				}
				clear(&scratch)
				host.resample_stereo(&resampler, a.samples[:a.frames * 2], ratio, &scratch)
				if muted {
					for i in 0 ..< len(scratch) { scratch[i] = 0 }
				}
				audio_push(&audio, scratch[:])
			}
		}

		// Start the device once the buffer has its cushion, not before: that
		// avoids counting a startup underrun.
		if audio.ok && !audio.started && audio_buffered_frames(&audio) >= target_buffered {
			sdl.PauseAudioDevice(audio.dev, false)
			audio.started = true
		}

		// ---- present -------------------------------------------------------
		f: api.Video_Frame
		s.emu.get_video(&f)
		video_upload(&video, f)
		t_uploaded := host.clock_ns(&clock)
		video_present(&video)
		t_presented := host.clock_ns(&clock)
		if stats.on {
			if last_present >= 0 { host.series_add(&stats.interval, f64(t_presented - last_present) / 1e6) }
			host.series_add(&stats.cost, f64(t_uploaded - t_run) / 1e6)
			host.series_add(&stats.present, f64(t_presented - t_uploaded) / 1e6)
		}
		last_present = t_presented

		// ---- window title: live fps + buffer ------------------------------
		if time.duration_seconds(time.tick_since(last_title)) >= 1 {
			secs := time.duration_seconds(time.tick_since(last_title))
			buf_ms := audio_buffered_frames(&audio) * 1000 / int(s.av.sample_rate) if audio.ok else 0
			title := fmt.ctprintf("%s | %.1f fps | audio buffer %d ms%s", s.info.name, f64(title_frames) / secs, buf_ms, " | MUTED" if muted else "")
			sdl.SetWindowTitle(video.window, title)
			title_frames = 0
			last_title = time.tick_now()
		}

		// ---- --frame-stats progress ----------------------------------------
		if stats.on && time.duration_seconds(time.tick_since(last_status)) >= 30 {
			fmt.eprintfln("frame-stats %4.0f s: audio underruns in the last 30 s: %d | game speed %+.2f%% | audio queued %.0f ms",
				time.duration_seconds(time.tick_since(start)), audio.underruns - status_underruns, rate.speed * 100,
				f64(audio_buffered_frames(&audio)) * 1000 / f64(s.av.sample_rate) if audio.ok else 0.0)
			status_underruns = audio.underruns
			last_status = time.tick_now()
		}

		host.session_tick(&s, ran)
	}

	elapsed := time.duration_seconds(time.tick_since(start))
	if seconds > 0 { // test runs report; normal runs stay silent
		fmt.eprintfln("sdl: %d frames in %.2f s = %.2f fps (core nominal %.2f) | audio underruns: %d",
			total_frames, elapsed, f64(total_frames) / elapsed, s.av.fps, audio.underruns)
	}
	if stats.on { stats_report(&stats, &audio, &video, s.av.fps, int(s.av.sample_rate), elapsed, rate.speed) }
	return 0
}
