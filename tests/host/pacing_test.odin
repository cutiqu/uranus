package host_tests

import "core:testing"
import "../../host"

FRAME :: 737 // sample frames of audio per core frame at 44.1 kHz / 59.8 fps
TARGET :: 1764 // 40 ms

@(test)
pace_steady_state_runs_one_frame :: proc(t: ^testing.T) {
	// In normal running the buffer hovers within one frame of the target.
	for buffered in TARGET - FRAME ..< TARGET {
		testing.expect_value(t, host.pace_audio_frames(buffered, TARGET, FRAME), 1)
	}
}

@(test)
pace_full_buffer_runs_nothing :: proc(t: ^testing.T) {
	testing.expect_value(t, host.pace_audio_frames(TARGET, TARGET, FRAME), 0)
	testing.expect_value(t, host.pace_audio_frames(TARGET * 2, TARGET, FRAME), 0)
}

@(test)
pace_catches_up_in_proportion_to_the_deficit :: proc(t: ^testing.T) {
	testing.expect_value(t, host.pace_audio_frames(TARGET - FRAME - 1, TARGET, FRAME), 2)
	testing.expect_value(t, host.pace_audio_frames(TARGET - 2 * FRAME - 1, TARGET, FRAME), 3)
}

@(test)
pace_burst_is_bounded :: proc(t: ^testing.T) {
	// An empty buffer, or one that is hopelessly behind, never asks for an unbounded run.
	testing.expect_value(t, host.pace_audio_frames(0, TARGET, FRAME), host.PACE_MAX_CATCHUP)
	testing.expect_value(t, host.pace_audio_frames(0, 100 * TARGET, FRAME), host.PACE_MAX_CATCHUP)
}

@(test)
pace_tolerates_degenerate_frame_size :: proc(t: ^testing.T) {
	testing.expect_value(t, host.pace_audio_frames(0, TARGET, 0), host.PACE_MAX_CATCHUP)
}
