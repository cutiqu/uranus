// Headless runner: no window, no terminal, no pacing. Runs N frames as fast
// as possible and can capture the last frame (PPM) and all audio (WAV).
// This is the regression-test and debugging tool.
package frontend_headless

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:time"
import api "../../api"
import "../../config"
import "../../host"

log_callback :: proc "c" (userdata: rawptr, level: api.Log_Level, msg: cstring) {
	context = runtime.default_context()
	fmt.eprintfln("[core %v] %s", level, msg)
}

no_input :: proc "c" (userdata: rawptr, port: u32) -> api.Buttons { return {} }

// ---- conformance checks that apply to EVERY core -------------------------

fnv :: proc(h: u64, data: []byte) -> u64 {
	h := h
	for b in data { h = (h ~ u64(b)) * 0x100000001b3 }
	return h
}

// Hash of everything the frontend can observe from one frame: pixels + audio.
frame_hash :: proc(s: ^host.Session) -> u64 {
	h: u64 = 0xcbf29ce484222325
	v: api.Video_Frame
	s.emu.get_video(&v)
	h = fnv(h, ([^]byte)(v.pixels)[:int(v.pitch * v.height) * 4])
	a: api.Audio_Buffer
	s.emu.get_audio(&a)
	return fnv(h, ([^]byte)(a.samples)[:int(a.frames) * 4])
}

snapshot :: proc(s: ^host.Session) -> []byte {
	size := s.emu.state_size()
	buf := make([]byte, size)
	if !s.emu.save_state(raw_data(buf), size) { delete(buf); return nil }
	return buf
}

restore :: proc(s: ^host.Session, state: []byte) -> bool {
	return s.emu.load_state(raw_data(state), uint(len(state)))
}

// Run PRE frames, snapshot, run POST frames recording a hash per frame,
// restore the snapshot, run the same POST frames again. A complete save state
// makes the two runs identical, down to the last audio sample.
check_determinism :: proc(s: ^host.Session, pre, post: int) -> bool {
	for _ in 0 ..< pre { s.emu.run_frame() }
	base := snapshot(s)
	if base == nil { fmt.eprintln("FAIL: save_state refused"); return false }
	defer delete(base)

	run :: proc(s: ^host.Session, n: int) -> []u64 {
		h := make([]u64, n)
		for i in 0 ..< n { s.emu.run_frame(); h[i] = frame_hash(s) }
		return h
	}

	a := run(s, post)
	defer delete(a)
	end_a := snapshot(s)
	defer delete(end_a)

	if !restore(s, base) { fmt.eprintln("FAIL: load_state rejected its own state"); return false }
	again := snapshot(s)
	defer delete(again)
	round_trip := bytes.equal(again, base)

	b := run(s, post)
	defer delete(b)
	end_b := snapshot(s)
	defer delete(end_b)

	first_diff := -1
	for i in 0 ..< post { if a[i] != b[i] { first_diff = i; break } }
	end_same := bytes.equal(end_a, end_b)

	fmt.eprintfln("state: %d bytes | save(load(x)) == x: %v | frames identical: %v | end state identical: %v",
		len(base), round_trip, first_diff < 0, end_same)
	if first_diff >= 0 { fmt.eprintfln("first divergence at frame %d after the snapshot", first_diff) }
	return round_trip && first_diff < 0 && end_same
}

// A state file is untrusted input. Mutate a good state many ways; the core
// must accept or reject each one without crashing or hanging.
fuzz_state :: proc(s: ^host.Session, count: int) {
	base := snapshot(s)
	if base == nil { return }
	defer delete(base)

	rng: u64 = 0x2545F4914F6CDD1D
	next :: proc(r: ^u64) -> u64 { r^ ~= r^ << 13; r^ ~= r^ >> 7; r^ ~= r^ << 17; return r^ }

	accepted, rejected: int
	for i in 0 ..< count {
		buf := make([]byte, len(base))
		copy(buf, base)
		m := buf
		switch i % 5 {
		case 0: m[int(next(&rng) % u64(len(m)))] ~= u8(1 << (next(&rng) % 8))        // one bit
		case 1: for _ in 0 ..< 8 { m[int(next(&rng) % u64(len(m)))] = u8(next(&rng)) } // 8 random bytes
		case 2: for j in 0 ..< 64 { m[j] = u8(next(&rng)) }                            // scramble header + CPU/regs
		case 3: for j in 0 ..< 64 { m[8 + int(next(&rng) % 200)] = 0xFF; _ = j }       // saturate a register region
		case 4: m = m[:len(m) - 1 - int(next(&rng) % u64(len(m) / 2))]                // truncate
		}
		if restore(s, m) {
			accepted += 1
			s.emu.run_frame() // an accepted state must be safe to run
			s.emu.run_frame()
		} else {
			rejected += 1
		}
		delete(buf)
	}
	_ = restore(s, base)
	fmt.eprintfln("fuzz: %d mutated states: %d accepted (and ran 2 frames each), %d rejected, no crash or hang", count, accepted, rejected)
}

Options :: struct {
	frames:     int,    // run this many frames (0 with a check = checks only)
	dump_path:  string, // write the final frame here as a PPM
	wav_path:   string, // write all audio here as 16-bit stereo WAV
	check:      bool,   // run the save-state determinism check
	check_pre:  int,
	check_post: int,
	fuzz:       int,    // after the check, mutate the state this many ways
}

// No window, no terminal, no pacing: run as fast as possible. Returns the
// process exit code (non-zero when a conformance check fails).
run :: proc(core: api.Core, rom_path: string, cfg: ^config.Config, opt: Options) -> int {
	callbacks := api.Host{input_state = no_input, log = log_callback}

	// Tests must not touch the user's real saves: keep battery RAM and states
	// next to the ROM only when the config says so; otherwise use the config dirs.
	sav, state := config.game_paths(cfg, rom_path)
	s: host.Session
	if !host.session_open(&s, core, rom_path, {sav = sav, state = state, system_dir = cfg.system_dir}, &callbacks) { return 1 }
	defer host.session_close(&s)

	if opt.check {
		ok := check_determinism(&s, opt.check_pre, opt.check_post)
		if opt.fuzz > 0 { fuzz_state(&s, opt.fuzz) }
		fmt.eprintln("determinism:", "PASS" if ok else "FAIL")
		return 0 if ok else 1
	}

	pcm: [dynamic]i16
	defer delete(pcm)
	audio_frames: u64

	start := time.tick_now()
	for _ in 0 ..< opt.frames {
		s.emu.run_frame()
		audio: api.Audio_Buffer
		s.emu.get_audio(&audio)
		audio_frames += u64(audio.frames)
		if opt.wav_path != "" { append(&pcm, ..audio.samples[:audio.frames * 2]) }
	}

	if opt.wav_path != "" { _ = host.write_wav(opt.wav_path, pcm[:], u32(s.av.sample_rate)) }
	if opt.dump_path != "" {
		video: api.Video_Frame
		s.emu.get_video(&video)
		_ = host.write_ppm(opt.dump_path, video)
	}
	secs := time.duration_seconds(time.tick_since(start))
	fmt.eprintfln("headless: %d frames, %d audio frames, %.2f s = %.0f frames/s (60 is real time)", opt.frames, audio_frames, secs, f64(opt.frames) / secs)
	return 0
}
