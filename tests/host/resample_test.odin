package host_tests

import "core:math"
import "core:testing"
import "../../host"

// The streaming resampler (host/resample.odin).

@(private = "file")
noise :: proc(frames: int) -> []i16 {
	out := make([]i16, frames * 2, context.temp_allocator)
	seed: u32 = 99
	for i in 0 ..< len(out) {
		seed = seed * 1664525 + 1013904223
		out[i] = i16(seed >> 16)
	}
	return out
}

// A 1 kHz tone at 48 kHz, different phase per channel.
@(private = "file")
tone :: proc(frames: int, amp: f64) -> []i16 {
	out := make([]i16, frames * 2, context.temp_allocator)
	w := 2 * math.PI * 1000.0 / 48000.0
	for i in 0 ..< frames {
		out[i * 2]     = i16(math.round(amp * math.sin(w * f64(i))))
		out[i * 2 + 1] = i16(math.round(amp * math.sin(w * f64(i) + 1.0)))
	}
	return out
}

@(private = "file")
run_in_blocks :: proc(input: []i16, block_frames: []int, ratio_for_block: proc(i: int) -> f64) -> [dynamic]i16 {
	r: host.Resampler
	out := make([dynamic]i16, context.temp_allocator)
	at, k := 0, 0
	for at < len(input) / 2 {
		n := min(block_frames[k % len(block_frames)], len(input) / 2 - at)
		host.resample_stereo(&r, input[at * 2:][:n * 2], ratio_for_block(k), &out)
		at += n
		k += 1
	}
	return out
}

@(test)
resample_ratio_one_is_bit_exact_whatever_the_blocks :: proc(t: ^testing.T) {
	input := noise(20_000)
	out := run_in_blocks(input, {799, 800, 1, 1000, 2, 733}, proc(i: int) -> f64 { return 1.0 })
	// Everything but the last frame, which waits for a successor to interpolate toward.
	testing.expect_value(t, len(out), len(input) - 2)
	for i in 0 ..< len(out) {
		if out[i] != input[i] { testing.expectf(t, false, "sample %d: %d != %d", i, out[i], input[i]); return }
	}
}

@(test)
resample_does_not_depend_on_how_the_input_is_cut :: proc(t: ^testing.T) {
	input := tone(48_000, 20000)
	ratio :: proc(i: int) -> f64 { return 1.0037 }
	whole := run_in_blocks(input, {48_000}, ratio)
	cut := run_in_blocks(input, {799, 800, 1, 1000, 17, 733}, ratio)
	testing.expect(t, abs(len(whole) - len(cut)) <= 2, "lengths differ by more than a frame")
	worst := 0
	for i in 0 ..< min(len(whole), len(cut)) { worst = max(worst, abs(int(whole[i]) - int(cut[i]))) }
	testing.expectf(t, worst <= 1, "block boundaries changed a sample by %d", worst)
}

@(test)
resample_output_length_follows_the_ratio :: proc(t: ^testing.T) {
	input := noise(800 * 600)
	for ratio in ([?]f64{0.995, 1.0, 1.003, 1.005}) {
		r: host.Resampler
		out := make([dynamic]i16, context.temp_allocator)
		for b in 0 ..< 600 { host.resample_stereo(&r, input[b * 1600:][:1600], ratio, &out) }
		want := 800.0 * 600.0 * ratio
		testing.expectf(t, abs(f64(len(out) / 2) - want) <= 2, "ratio %v: %d frames, wanted %.1f", ratio, len(out) / 2, want)
	}
}

@(test)
resample_reproduces_a_stretched_tone_accurately :: proc(t: ^testing.T) {
	AMP :: 20000.0
	input := tone(48_000, AMP)
	ratio := 1.004
	out := run_in_blocks(input, {800}, proc(i: int) -> f64 { return 1.004 })
	w := 2 * math.PI * 1000.0 / 48000.0
	step := 1.0 / ratio
	worst := 0.0
	for k in 0 ..< len(out) / 2 {
		ideal_l := AMP * math.sin(w * f64(k) * step)
		ideal_r := AMP * math.sin(w * f64(k) * step + 1.0)
		worst = max(worst, abs(f64(out[k * 2]) - ideal_l), abs(f64(out[k * 2 + 1]) - ideal_r))
	}
	// Linear interpolation at 1 kHz / 48 kHz is good to about amp * (w^2 / 8) = 0.2%.
	testing.expectf(t, worst < 0.003 * AMP, "worst error %.1f of %.0f", worst, AMP)
}

@(test)
resample_changing_the_ratio_between_blocks_makes_no_click :: proc(t: ^testing.T) {
	AMP :: 20000.0
	input := tone(48_000, AMP)
	out := run_in_blocks(input, {800}, proc(i: int) -> f64 { return 1.005 if i % 2 == 0 else 0.995 })
	// A tone moves at most amp * w per sample; a click would be a much bigger step.
	max_step := AMP * 2 * math.PI * 1000.0 / 48000.0
	worst := 0
	for k in 1 ..< len(out) / 2 {
		worst = max(worst, abs(int(out[k * 2]) - int(out[(k - 1) * 2])))
	}
	testing.expectf(t, f64(worst) <= max_step + 100, "step of %d between samples (a tone allows %.0f)", worst, max_step)
}

@(test)
resample_edge_cases_are_harmless :: proc(t: ^testing.T) {
	r: host.Resampler
	out := make([dynamic]i16, context.temp_allocator)
	host.resample_stereo(&r, nil, 1.0, &out)
	testing.expect_value(t, len(out), 0)

	silence := make([]i16, 1600, context.temp_allocator)
	host.resample_stereo(&r, silence, 1.004, &out)
	for s in out { if s != 0 { testing.expect(t, false, "silence became sound"); break } }

	// An absurd ratio is clamped rather than looping forever or allocating wildly.
	out2 := make([dynamic]i16, context.temp_allocator)
	r2: host.Resampler
	host.resample_stereo(&r2, noise(800), 1e9, &out2)
	testing.expect(t, len(out2) <= 800 * 2 * 2 + 16)
}
