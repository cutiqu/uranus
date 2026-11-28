package host

import "base:intrinsics"
import "core:time"

// The pacer's clock: monotonic nanoseconds since the frontend started.

Clock :: struct {
	origin: time.Tick,
}

clock_make :: proc() -> Clock {
	return {origin = time.tick_now()}
}

clock_ns :: proc "contextless" (c: ^Clock) -> i64 {
	return i64(time.tick_diff(c.origin, time.tick_now()))
}

// Sleeps with the OS to just before the deadline, then spins; the spin margin adapts
// to how late sleeps wake.
Sleeper :: struct {
	margin_ns: i64, // the OS sleep stops this far before the deadline
}

SLEEP_MARGIN_START :: 1_000_000 //   1 ms
SLEEP_MARGIN_MIN   ::   200_000 // 0.2 ms
SLEEP_MARGIN_MAX   :: 4_000_000 //   4 ms

// Blocks until deadline_ns, never early. Returns how late it woke, in ns.
sleep_until :: proc(c: ^Clock, s: ^Sleeper, deadline_ns: i64) -> i64 {
	if s.margin_ns == 0 { s.margin_ns = SLEEP_MARGIN_START }
	for {
		now := clock_ns(c)
		remaining := deadline_ns - now
		if remaining <= 0 { return -remaining }

		if remaining > s.margin_ns {
			ask := remaining - s.margin_ns
			time.sleep(time.Duration(ask))
			over := clock_ns(c) - (now + ask) // sleep overshoot
			want := clamp(over + 150_000, SLEEP_MARGIN_MIN, SLEEP_MARGIN_MAX)
			if want > s.margin_ns {
				s.margin_ns = want
			} else {
				s.margin_ns -= (s.margin_ns - want) / 16
			}
		} else {
			intrinsics.cpu_relax()
		}
	}
}
