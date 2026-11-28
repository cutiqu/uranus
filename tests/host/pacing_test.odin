package host_tests

import "core:math"
import "core:testing"
import "../../host"

// Timeline and audio trim (host/pacing.odin); time is passed in.

FPS    :: 60.0988
PERIOD := 1e9 / FPS // ns (a variable: Odin won't cast a constant)

// Whole-ns clock reading at or just after t (the real pacer rounds its sleeps up too).
at :: proc(t: f64) -> i64 { return i64(math.ceil(t)) }

@(test)
timeline_is_due_at_once_then_waits_a_period :: proc(t: ^testing.T) {
	tl := host.timeline_make(FPS, 0)
	testing.expect_value(t, host.timeline_wait_ns(&tl, 0), 0)
	due := host.timeline_due(&tl, 0)
	testing.expect_value(t, due.frames, 1)
	testing.expect_value(t, due.resynced, false)
	w := host.timeline_wait_ns(&tl, 0)
	testing.expect_value(t, w, i64(PERIOD) + 1) // rounded up, never early
	testing.expect_value(t, host.timeline_wait_ns(&tl, 0), w)
	testing.expect_value(t, host.timeline_due(&tl, i64(PERIOD) - 1).frames, 0)
	testing.expect_value(t, host.timeline_due(&tl, i64(PERIOD) + 1).frames, 1)
}

@(test)
timeline_a_slightly_late_frame_runs_alone :: proc(t: ^testing.T) {
	// wakes land slightly late: one frame each time
	tl := host.timeline_make(FPS, 0)
	for i in 0 ..< 500 {
		late := f64(i % 7) * 0.12 * PERIOD // 0 to 0.72 of a period late
		now := at(f64(i) * PERIOD + late)
		due := host.timeline_due(&tl, now)
		if due.frames != 1 || due.resynced { testing.expectf(t, false, "frame %d: %v", i, due); return }
	}
}

@(test)
timeline_catches_up_after_a_stall_but_only_so_far :: proc(t: ^testing.T) {
	// next is due at 1 period; waking at 2.5 owes two frames
	tl := host.timeline_make(FPS, 0)
	_ = host.timeline_due(&tl, 0)
	testing.expect_value(t, host.timeline_due(&tl, at(2.5 * PERIOD)).frames, 2)

	// 3.5 periods: three owed (the cap), then caught up
	tl = host.timeline_make(FPS, 0)
	_ = host.timeline_due(&tl, 0)
	now := at(3.5 * PERIOD)
	testing.expect_value(t, host.timeline_due(&tl, now).frames, host.CATCHUP_MAX)
	testing.expect(t, host.timeline_wait_ns(&tl, now) > 0)

	// 4.5 periods: four owed, three run; the rest is claimed on the next ask
	tl = host.timeline_make(FPS, 0)
	_ = host.timeline_due(&tl, 0)
	now = at(4.5 * PERIOD)
	testing.expect_value(t, host.timeline_due(&tl, now).frames, host.CATCHUP_MAX)
	testing.expect_value(t, host.timeline_wait_ns(&tl, now), 0)
	testing.expect_value(t, host.timeline_due(&tl, now).frames, 1)
	testing.expect_value(t, host.timeline_due(&tl, now).frames, 0) // caught up
}

@(test)
timeline_gives_up_on_hopelessly_lost_time :: proc(t: ^testing.T) {
	tl := host.timeline_make(FPS, 0)
	_ = host.timeline_due(&tl, 0)

	// just inside RESYNC_FRAMES is recovered; past it is not
	inside := PERIOD + f64(host.RESYNC_FRAMES) * PERIOD - 1000 // 1 us short of the limit
	probe := tl
	d := host.timeline_due(&probe, at(inside))
	testing.expect_value(t, d.resynced, false)
	testing.expect_value(t, d.frames, host.CATCHUP_MAX)

	now := at(PERIOD + f64(host.RESYNC_FRAMES + 3) * PERIOD)
	d = host.timeline_due(&tl, now)
	testing.expect_value(t, d.resynced, true)
	testing.expect_value(t, d.frames, 1)
	// lost time is dropped, not owed
	testing.expect_value(t, host.timeline_wait_ns(&tl, now), i64(PERIOD) + 1)
}

@(test)
timeline_reset_does_not_run_frames_to_make_up_the_gap :: proc(t: ^testing.T) {
	tl := host.timeline_make(FPS, 0)
	_ = host.timeline_due(&tl, 0)
	later := i64(5e9)
	host.timeline_reset(&tl, later)
	d := host.timeline_due(&tl, later)
	testing.expect_value(t, d.frames, 1)
	testing.expect_value(t, d.resynced, false)
}

@(test)
timeline_does_not_drift_from_the_core_rate :: proc(t: ^testing.T) {
	// An hour of jittery wakes must land on frames * period (within 100 ns).
	tl := host.timeline_make(FPS, 0)
	seed: u32 = 12345
	N :: 216_356
	for i in 0 ..< N {
		seed = seed * 1664525 + 1013904223
		jitter := 1000 + f64(seed >> 8 & 0xFFFF) / 65535.0 * 300_000 // 1 us to 0.3 ms late
		now := at(f64(i) * PERIOD + jitter)
		if host.timeline_due(&tl, now).frames != 1 { testing.expectf(t, false, "frame %d not one", i); return }
	}
	expected := f64(N) * PERIOD
	testing.expectf(t, abs(tl.next_ns - expected) < 100.0, "timeline off by %v ns after an hour", tl.next_ns - expected)
}

// ------------------------------------------------- heavy frames (Saturn) ---
// A busy Saturn frame is ~70% of a period (tools/saturn_bench), so the pacer runs near its limit.

SATURN_FPS :: 59.94

// Frame cost in ns: `mean_ms` +-15%, one frame in a hundred 2.5x heavier.
heavy_cost :: proc(seed: ^u32, mean_ms: f64) -> f64 {
	next :: proc(seed: ^u32) -> f64 {
		seed^ = seed^ * 1664525 + 1013904223
		return f64(seed^ >> 8 & 0xFFFF) / 65535.0
	}
	c := mean_ms * (1 + 0.15 * (next(seed) + next(seed) + next(seed) - 1.5) / 0.75)
	if next(seed) < 0.01 { c *= 2.5 }
	return c * 1e6
}

// Runs the timeline against heavy_cost frames with a perfect sleeper; returns frames, resyncs, largest burst, elapsed ns.
run_heavy :: proc(mean_ms, seconds: f64) -> (frames, resyncs, max_burst: int, elapsed: f64) {
	tl := host.timeline_make(SATURN_FPS, 0)
	seed: u32 = 2024
	now := 0.0
	for now < seconds * 1e9 {
		now = max(now, tl.next_ns) // sleep until the next frame is due, if early
		d := host.timeline_due(&tl, at(now))
		if d.resynced { resyncs += 1 }
		max_burst = max(max_burst, d.frames)
		for _ in 0 ..< d.frames {
			now += heavy_cost(&seed, mean_ms)
			frames += 1
		}
	}
	return frames, resyncs, max_burst, now
}

@(test)
timeline_keeps_up_with_a_heavy_but_sustainable_saturn_load :: proc(t: ^testing.T) {
	// 84% of a period on average, 1% of frames 2.5x: no resync, game speed exact
	frames, resyncs, burst, elapsed := run_heavy(14.0, 600)
	period := 1e9 / SATURN_FPS
	testing.expect_value(t, resyncs, 0)
	testing.expect(t, burst <= host.CATCHUP_MAX)
	testing.expectf(t, abs(elapsed - f64(frames) * period) < 3 * period,
		"game speed drifted: %d frames took %.2f s, should be %.2f s", frames, elapsed / 1e9, f64(frames) * period / 1e9)
}

@(test)
timeline_degrades_to_what_an_overloaded_machine_can_do :: proc(t: ^testing.T) {
	// 120% of a period can never keep up: it resyncs, bursts stay bounded, speed is what the machine allows
	frames, resyncs, burst, elapsed := run_heavy(20.0, 120)
	fps := f64(frames) / (elapsed / 1e9)
	testing.expect(t, resyncs > 0)
	testing.expect(t, burst <= host.CATCHUP_MAX)
	testing.expectf(t, fps > 46 && fps < 52, "game ran at %.1f fps (the machine can do 50)", fps)
}

// ---------------------------------------------------------------- audio trim ---

RATE :: 48000
TARGET :: 1920 // 40 ms

@(test)
rate_is_exactly_one_at_the_target :: proc(t: ^testing.T) {
	c: host.Rate_Control
	for _ in 0 ..< 100 { testing.expect_value(t, host.rate_update(&c, TARGET, TARGET, RATE), 1.0) }
}

@(test)
rate_pushes_toward_the_target_and_is_limited :: proc(t: ^testing.T) {
	high, low: host.Rate_Control
	// A full buffer asks for less sound, an empty one for more.
	r := host.rate_update(&high, TARGET + 480, TARGET, RATE)
	testing.expect(t, r < 1)
	r = host.rate_update(&low, TARGET - 480, TARGET, RATE)
	testing.expect(t, r > 1)

	// However far off, never more than the limit either way.
	big_high, big_low: host.Rate_Control
	testing.expect_value(t, host.rate_update(&big_high, 100 * TARGET, TARGET, RATE), 1 - host.RATE_MAX_TRIM)
	testing.expect_value(t, host.rate_update(&big_low, 0, 100 * TARGET, RATE), 1 + host.RATE_MAX_TRIM)
}

@(test)
rate_ignores_a_single_odd_reading :: proc(t: ^testing.T) {
	// one coarse reading can be far off
	c: host.Rate_Control
	_ = host.rate_update(&c, TARGET, TARGET, RATE)
	r := host.rate_update(&c, TARGET + 2000, TARGET, RATE) // +42 ms for one frame
	testing.expectf(t, abs(r - 1) < 0.0005, "one reading moved the ratio by %v", r - 1)
}

// ---------------------------------------------------------- closed loop ---

Loop_Result :: struct {
	underruns_after_settling: int,
	lo_ms, hi_ms, peak_ms:    f64, // buffer level before and after each push
	speed:                    f64, // final game speed
	speed_range:              f64, // largest |speed| reached
}

// Whole loop, no real time: a device clock off by `drift`, the real Timeline, rate_update and the
// slow loop, with an optional stall.
simulate_loop :: proc(drift: f64, seconds, settle_s: f64, stall_at_s := -1.0, stall_ms := 0.0) -> (r: Loop_Result) {
	CHUNK :: 512
	device_rate := f64(RATE) * (1 + drift)
	chunk_ns := f64(CHUNK) / device_rate * 1e9
	per_frame := f64(RATE) / FPS // sample frames of audio per core frame at ratio 1

	tl := host.timeline_make(FPS, 0)
	rc: host.Rate_Control
	level := f64(TARGET)
	next_pop := chunk_ns
	accum := 0.0
	stalled := false
	r.lo_ms, r.hi_ms, r.peak_ms = 1e9, 0, 0

	pop_until :: proc(level: ^f64, next_pop: ^f64, chunk_ns: f64, now: f64, after_settle: bool, r: ^Loop_Result) {
		for next_pop^ <= now {
			if level^ >= CHUNK {
				level^ -= CHUNK
			} else {
				level^ = 0
				if after_settle { r.underruns_after_settling += 1 }
			}
			next_pop^ += chunk_ns
		}
	}
	ms :: proc(frames: f64) -> f64 { return frames * 1000 / RATE }

	for tl.next_ns < seconds * 1e9 {
		now := tl.next_ns
		if !stalled && stall_at_s >= 0 && now >= stall_at_s * 1e9 { // the machine goes away for a while
			stalled = true
			now += stall_ms * 1e6
		}
		settled := now >= settle_s * 1e9
		pop_until(&level, &next_pop, chunk_ns, now, settled, &r)

		due := host.timeline_due(&tl, i64(math.ceil(now)))
		for _ in 0 ..< due.frames {
			if settled { r.lo_ms, r.hi_ms = min(r.lo_ms, ms(level)), max(r.hi_ms, ms(level)) }
			ratio := host.rate_update(&rc, int(level), TARGET, RATE)
			host.timeline_set_speed(&tl, rc.speed)
			accum += per_frame * ratio
			made := int(accum)
			accum -= f64(made)
			level += f64(made)
			if settled { r.peak_ms = max(r.peak_ms, ms(level)) }
			r.speed_range = max(r.speed_range, abs(rc.speed))
		}
	}
	r.speed = rc.speed
	return
}

@(test)
ordinary_clock_drift_is_trimmed_away_and_never_touches_game_speed :: proc(t: ^testing.T) {
	for drift_ppm in ([?]f64{-800, -300, 0, 300, 800, 2000} ) {
		r := simulate_loop(drift_ppm * 1e-6, 600, 20)
		testing.expectf(t, r.underruns_after_settling == 0, "%v ppm: %d underruns", drift_ppm, r.underruns_after_settling)
		// pre-push level is the held low-water mark; allow the proportional offset (drift / RATE_GAIN)
		offset_ms := abs(drift_ppm) * 1e-6 / host.RATE_GAIN * 1000
		testing.expectf(t, r.lo_ms > 28 - offset_ms && r.hi_ms < 50, "%v ppm: pre-push level wandered %.1f..%.1f ms around 40", drift_ppm, r.lo_ms, r.hi_ms)
		testing.expectf(t, r.peak_ms < 70, "%v ppm: peak %.1f ms", drift_ppm, r.peak_ms)
		// game speed stays exact
		testing.expectf(t, r.speed_range == 0, "%v ppm moved game speed to %v", drift_ppm, r.speed_range)
	}
}

@(test)
a_badly_off_audio_clock_is_followed_not_crackled :: proc(t: ^testing.T) {
	// 1% and the ~4% of SDL's dummy device: speed follows the mismatch, no dropouts once settled
	for drift in ([?]f64{0.01, -0.01, 0.0417, -0.0417} ) {
		r := simulate_loop(drift, 2400, 1500)
		testing.expectf(t, r.underruns_after_settling == 0, "drift %v: %d underruns after 25 minutes", drift, r.underruns_after_settling)
		// the slow loop stops inside the dead-band, on either side of the mismatch
		testing.expectf(t, abs(r.speed - drift) < host.RATE_DEADBAND + 0.0005, "drift %v: ended at speed %v", drift, r.speed)
		testing.expectf(t, (r.speed > 0) == (drift > 0), "drift %v: speed %v is the wrong way round", drift, r.speed)
	}
}

@(test)
a_single_stall_does_not_leave_the_game_running_fast :: proc(t: ^testing.T) {
	// a stall pins the trim for seconds; that must not read as a persistent mismatch
	for stall_ms in ([?]f64{30, 45, 120} ) {
		r := simulate_loop(0.0003, 300, 20, stall_at_s = 60, stall_ms = stall_ms)
		testing.expectf(t, r.speed_range < 0.001, "a %v ms stall moved game speed to %.3f%%", stall_ms, r.speed_range * 100)
	}
}

@(test)
rate_reprime_forgets_the_level_but_keeps_what_it_learned :: proc(t: ^testing.T) {
	c: host.Rate_Control
	c.speed, c.trim_avg = 0.02, 0.004
	_ = host.rate_update(&c, 5 * TARGET, TARGET, RATE)
	host.rate_reprime(&c)
	testing.expect(t, !c.primed && c.level == 0)
	testing.expect(t, c.speed > 0.0199 && c.trim_avg > 0.003)
}

@(test)
timeline_speed_changes_the_period_without_moving_the_next_frame :: proc(t: ^testing.T) {
	tl := host.timeline_make(FPS, 0)
	_ = host.timeline_due(&tl, 0)
	before := tl.next_ns
	host.timeline_set_speed(&tl, 0.10)
	testing.expect_value(t, tl.next_ns, before)
	testing.expectf(t, abs(tl.period_ns - PERIOD / 1.10) < 1e-6, "period %v", tl.period_ns)
	host.timeline_set_speed(&tl, 0)
	testing.expect_value(t, tl.period_ns, tl.base_ns)
}
