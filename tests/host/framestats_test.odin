package host_tests

import "core:testing"
import "../../host"

@(test)
series_summary_uses_nearest_rank_percentiles :: proc(t: ^testing.T) {
	s: host.Series
	defer host.series_destroy(&s)
	for i in 1 ..= 1000 { host.series_add(&s, f64(i)) }
	sum := host.series_summary(&s)
	testing.expect_value(t, sum.count, 1000)
	testing.expect_value(t, sum.min, 1.0)
	testing.expect_value(t, sum.max, 1000.0)
	testing.expect_value(t, sum.mean, 500.5)
	testing.expect_value(t, sum.p50, 501.0)
	testing.expect_value(t, sum.p99, 991.0)
	testing.expect_value(t, sum.p999, 1000.0)
}

@(test)
series_empty_and_single :: proc(t: ^testing.T) {
	s: host.Series
	defer host.series_destroy(&s)
	testing.expect_value(t, host.series_summary(&s), host.Summary{})
	testing.expect_value(t, host.series_share_off(&s, 1, 1), 0.0)
	host.series_add(&s, 7)
	sum := host.series_summary(&s)
	testing.expect_value(t, sum.p50, 7.0)
	testing.expect_value(t, sum.p999, 7.0)
}

@(test)
series_share_off_counts_both_directions :: proc(t: ^testing.T) {
	s: host.Series
	defer host.series_destroy(&s)
	for v in ([?]f64{16, 16.5, 15.5, 20, 10, 16.1}) { host.series_add(&s, v) }
	// Within 2 of 16: 16, 16.5, 15.5, 16.1. Outside: 20 and 10.
	testing.expect_value(t, host.series_share_off(&s, 16, 2), 2.0 / 6.0)
}
