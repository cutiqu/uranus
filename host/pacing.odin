package host

// Frame pacing for audio-clocked frontends.
//
// The audio device is the clock: whenever fewer than `target` sample frames are
// queued, the core runs and pushes more. The simple form of that (exactly one core
// frame per loop iteration, followed by a vsync-blocking present) has a cliff. A
// single slow frame leaves the buffer short, but the loop can run at most one
// frame per display refresh, so on a 60 Hz panel it can never win the time back;
// and once a frame costs slightly more than one refresh, every present waits for
// the *next* vblank and the whole thing halves to ~30 fps with audio underruns.
//
// pace_audio_frames sizes each iteration by the deficit instead: after a hitch it
// runs as many frames as the buffer is short (bounded by PACE_MAX_CATCHUP), so the
// vsync wait is paid once per burst rather than once per frame and the buffer
// recovers. In steady state the deficit is under one frame and it runs one.

PACE_MAX_CATCHUP :: 3

// buffered, target and frame_samples are in sample frames; one core frame of audio
// is about sample_rate / fps of them. Returns how many core frames to run now.
pace_audio_frames :: proc "contextless" (buffered, target, frame_samples: int) -> int {
	if buffered >= target { return 0 }
	per := max(frame_samples, 1)
	return clamp((target - buffered + per - 1) / per, 1, PACE_MAX_CATCHUP)
}
