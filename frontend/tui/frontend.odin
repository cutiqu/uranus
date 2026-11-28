// Terminal frontend. Presentation only: ANSI video, keyboard input. Everything
// about cores, files, battery RAM and save states lives in package host.
// (No audio device in a terminal: sound is counted, not played.)
package frontend_tui

import "core:fmt"
import "core:strings"
import api "../../api"
import "../../config"
import "../../host"

// What the core's `userdata` points at. The core never looks inside it.
Ctx :: struct {
	input:        Input,
	last_log:     [96]u8,
	last_log_len: int,
}

log_callback :: proc "c" (userdata: rawptr, level: api.Log_Level, msg: cstring) {
	ctx := (^Ctx)(userdata)
	ctx.last_log_len = copy(ctx.last_log[:], string(msg)) // shown on the status line
}

// Returns the process exit code. `scale_opt` 0 = pick the largest that fits.
run :: proc(core: api.Core, rom_path: string, cfg: ^config.Config, scale_opt: int) -> int {
	ctx := Ctx{}
	callbacks := api.Host{userdata = &ctx, input_state = host_input_state, log = log_callback}
	sav, state := config.game_paths(cfg, rom_path)
	s: host.Session
	if !host.session_open(&s, core, rom_path, {sav = sav, state = state, system_dir = cfg.system_dir}, &callbacks) { return 1 }
	defer host.session_close(&s)

	if !term_init() {
		fmt.eprintln("stdin is not a terminal")
		return 1
	}
	defer term_shutdown()

	STATUS_ROWS :: 3
	scale := u32(scale_opt)
	if scale == 0 {
		cols, rows, ok := term_size()
		scale = choose_scale(s.av.width, s.av.height, cols, rows, STATUS_ROWS) if ok else 1
	}

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	clock := host.clock_make()
	sleeper: host.Sleeper
	timeline := host.timeline_make(s.av.fps, host.clock_ns(&clock))
	key_buf:      [64]byte
	frames:       u64
	audio_frames: u64

	for !ctx.input.quit {
		now := host.clock_ns(&clock)
		if wait := host.timeline_wait_ns(&timeline, now); wait > 0 {
			host.sleep_until(&clock, &sleeper, now + wait)
		}

		n := term_read(key_buf[:])
		input_feed(&ctx.input, key_buf[:n])

		if ctx.input.reset { ctx.input.reset = false; s.emu.reset() }
		if ctx.input.save  { ctx.input.save  = false; _ = host.session_save_state(&s) }
		if ctx.input.load  { ctx.input.load  = false; _ = host.session_load_state(&s) }

		s.emu.run_frame()
		input_tick(&ctx.input)
		frames += 1

		video: api.Video_Frame
		s.emu.get_video(&video)
		audio: api.Audio_Buffer
		s.emu.get_audio(&audio)
		audio_frames += u64(audio.frames) // a terminal has no sound card; see emu-sdl

		strings.builder_reset(&sb)
		render_frame(&sb, video, scale)
		fmt.sbprintf(&sb, "%s %s | frame %d | audio frames %d (terminal: not played) | 1/%dx\x1b[K\n",
			s.info.name, s.info.version, frames, audio_frames, scale)
		fmt.sbprintf(&sb, "WASD/arrows move  J=A  K=B  Enter=Start  G=Select  P save  O load  R reset  Q quit\x1b[K\n")
		fmt.sbprintf(&sb, "core log: %s\x1b[K", string(ctx.last_log[:ctx.last_log_len]))
		term_write(strings.to_string(sb))

		host.session_tick(&s, 1)

		host.timeline_due(&timeline, host.clock_ns(&clock))
	}
	return 0
}
