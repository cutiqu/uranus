package host

import "core:math"

// Frame pacing: frames fall due on a fixed timeline of the monotonic clock, one per
// 1/fps; neither audio nor the display decides when a frame starts. Audio is trimmed
// to match (rate_update, resample.odin); a slow loop moves game speed only if the
// clock mismatch outlasts the trim. Late frames: up to CATCHUP_MAX run back to back
// and only the last is presented; later than RESYNC_FRAMES the lost time is dropped.

CATCHUP_MAX   :: 3
RESYNC_FRAMES :: 6

Timeline :: struct {
	period_ns: f64, // current frame period
	base_ns:   f64, // the core's own period
	next_ns:   f64, // when the next frame falls due
}

timeline_make :: proc "contextless" (fps: f64, now_ns: i64) -> Timeline {
	return {period_ns = 1e9 / fps, base_ns = 1e9 / fps, next_ns = f64(now_ns)}
}

// Run `speed` faster than the core's rate (0.01 = 1% fast).
timeline_set_speed :: proc "contextless" (t: ^Timeline, speed: f64) {
	t.period_ns = t.base_ns / (1 + speed)
}

// Restart from now_ns without running frames to catch up.
timeline_reset :: proc "contextless" (t: ^Timeline, now_ns: i64) {
	t.next_ns = f64(now_ns)
}

// ns until the next frame is due (0 if due).
timeline_wait_ns :: proc "contextless" (t: ^Timeline, now_ns: i64) -> i64 {
	return max(0, i64(math.ceil(t.next_ns - f64(now_ns))))
}

Due :: struct {
	frames:   int,  // core frames to run now (0: not due)
	resynced: bool, // gave up on lost time; the audio device ran dry
}

// Claim the frames due at now_ns and advance the timeline.
timeline_due :: proc "contextless" (t: ^Timeline, now_ns: i64) -> (d: Due) {
	now := f64(now_ns)
	if now < t.next_ns { return }

	late := now - t.next_ns
	if late > f64(RESYNC_FRAMES) * t.period_ns {
		t.next_ns = now
		late = 0
		d.resynced = true
	}
	d.frames = 1 + min(int(late / t.period_ns), CATCHUP_MAX - 1)
	t.next_ns += f64(d.frames) * t.period_ns
	return
}

// ------------------------------------------------------------ audio trim ---

RATE_MAX_TRIM  :: 0.005 // never stretch or squeeze the audio by more than 0.5%
RATE_SMOOTHING :: 0.02  // per frame
RATE_GAIN      :: 0.25  // trim per second of buffer error

// Stability: 60*RATE_SPEED_GAIN must stay below RATE_GAIN + 60*RATE_AVG_SMOOTHING.
RATE_AVG_SMOOTHING :: 1.0 / (10 * 60) // per frame (~10 s)
RATE_DEADBAND      :: 0.003           // average trim tolerated before speed moves
RATE_SPEED_GAIN    :: 0.1 / 60        // speed change per frame per unit of excess trim
RATE_MAX_SPEED     :: 0.10            // never more than 10% fast or slow

Rate_Control :: struct {
	level:    f64, // smoothed buffer level, in sample frames
	primed:   bool,
	trim_avg: f64, // trim averaged over ~10 s
	speed:    f64, // timeline speed offset; usually 0
}

// The ring was emptied on purpose: forget its level, keep the learned clock error.
rate_reprime :: proc "contextless" (c: ^Rate_Control) {
	c.primed = false
	c.level = 0
}

// Per core frame: the audio resample ratio that holds `target`. Apply c.speed with
// timeline_set_speed afterwards.
rate_update :: proc "contextless" (c: ^Rate_Control, buffered, target, sample_rate: int) -> f64 {
	if !c.primed {
		c.level = f64(buffered)
		c.primed = true
	} else {
		c.level += RATE_SMOOTHING * (f64(buffered) - c.level)
	}
	error_s := (c.level - f64(target)) / f64(max(sample_rate, 1)) // seconds above target
	trim := clamp(-RATE_GAIN * error_s, -RATE_MAX_TRIM, RATE_MAX_TRIM)

	// slow loop: moves speed only if the average trim leaves the dead-band
	c.trim_avg += RATE_AVG_SMOOTHING * (trim - c.trim_avg)
	excess := 0.0
	if c.trim_avg > RATE_DEADBAND {
		excess = c.trim_avg - RATE_DEADBAND
	} else if c.trim_avg < -RATE_DEADBAND {
		excess = c.trim_avg + RATE_DEADBAND
	}
	c.speed = clamp(c.speed + RATE_SPEED_GAIN * excess, -RATE_MAX_SPEED, RATE_MAX_SPEED)
	return 1 + trim
}
