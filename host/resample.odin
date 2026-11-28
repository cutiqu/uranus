package host

import "core:math"

// Streaming stereo linear resampler for ratios near 1: exact at 1.0, and state carries
// across blocks.

Resampler :: struct {
	pos:    f64,     // next output position, in input frames from the next block's start
	prev:   [2]i16,  // last input frame of the previous block
	primed: bool,
}

// Appends one interleaved stereo block to `out`; ratio = output/input samples.
// The output lags one frame.
resample_stereo :: proc(r: ^Resampler, input: []i16, ratio: f64, out: ^[dynamic]i16) {
	frames := len(input) / 2
	if frames == 0 { return }
	if !r.primed {
		r.prev = {input[0], input[1]}
		r.pos = 0
		r.primed = true
	}
	step := 1.0 / clamp(ratio, 0.5, 2.0)
	reserve(out, len(out) + int(f64(frames) / step) + 4)

	// stop before the last frame; the remainder carries over
	limit := f64(frames - 1)
	for r.pos < limit {
		i := int(math.floor(r.pos))
		frac := r.pos - f64(i)

		l0, r0: i16 // frame i; the previous block's last when i == -1
		if i < 0 {
			l0, r0 = r.prev[0], r.prev[1]
		} else {
			l0, r0 = input[i * 2], input[i * 2 + 1]
		}
		l1, r1 := input[(i + 1) * 2], input[(i + 1) * 2 + 1]

		append(out, lerp16(l0, l1, frac), lerp16(r0, r1, frac))
		r.pos += step
	}
	r.pos -= f64(frames)
	r.prev = {input[(frames - 1) * 2], input[(frames - 1) * 2 + 1]}
}

@(private = "file")
lerp16 :: proc "contextless" (a, b: i16, t: f64) -> i16 {
	v := f64(a) + (f64(b) - f64(a)) * t
	return i16(clamp(math.round(v), -32768, 32767))
}
