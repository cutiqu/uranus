package host_tests

import "core:testing"
import "../../host"

// sleep_until never wakes early; how late it wakes is machine-dependent.

@(test)
sleep_until_never_wakes_early :: proc(t: ^testing.T) {
	c := host.clock_make()
	s: host.Sleeper
	for ms in ([?]i64{0, 1, 3, 7}) {
		deadline := host.clock_ns(&c) + ms * 1_000_000
		late := host.sleep_until(&c, &s, deadline)
		testing.expect(t, host.clock_ns(&c) >= deadline, "woke before the deadline")
		testing.expect(t, late >= 0)
		testing.expectf(t, late < 100_000_000, "woke %d ms late", late / 1_000_000) // 100 ms: only a sanity bound
	}
}

@(test)
sleep_until_a_past_deadline_returns_at_once_and_says_how_late :: proc(t: ^testing.T) {
	c := host.clock_make()
	s: host.Sleeper
	_ = host.sleep_until(&c, &s, 5_000_000) // let some time pass
	now := host.clock_ns(&c)
	late := host.sleep_until(&c, &s, now - 2_000_000)
	testing.expect(t, late >= 2_000_000 && late < 100_000_000)
}

@(test)
sleep_margin_stays_within_its_bounds :: proc(t: ^testing.T) {
	c := host.clock_make()
	s: host.Sleeper
	for _ in 0 ..< 20 { _ = host.sleep_until(&c, &s, host.clock_ns(&c) + 2_000_000) }
	testing.expect(t, s.margin_ns >= host.SLEEP_MARGIN_MIN && s.margin_ns <= host.SLEEP_MARGIN_MAX)
}
