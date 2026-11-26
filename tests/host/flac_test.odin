package host_tests

// The FLAC decoder behind the CHD "cdfl" hunks, against streams made by the
// reference encoder (flac 1.4.3) from one stereo signal: a two-tone with a noisy
// side channel, silence, full-scale noise and a full-scale square wave, 4704
// samples (8 CD sectors). The streams are headerless runs of frames as in a CHD.
//   a: -8, one 4704 block (high-order LPC, adaptive stereo)
//   b: -0, 1152 blocks (fixed predictors / verbatim)
//   c: -5, 576 blocks, independent channels
//   d: -8 with 32-order LPC

import host "../../host"
import "core:testing"

@(private = "file")
EXPECT_DATA := #load("flac/expect.raw")

@(private = "file")
check_vector :: proc(t: ^testing.T, name: string, stream: []byte) {
	out := make([]i16, 4704 * 2)
	defer delete(out)
	testing.expectf(t, host.flac_decode_stereo16(stream, out, 4704), "%s: decode failed", name)
	bad := 0
	for i in 0 ..< len(out) {
		want := i16(u16(EXPECT_DATA[i * 2]) | u16(EXPECT_DATA[i * 2 + 1]) << 8)
		if out[i] != want {
			if bad == 0 {testing.expectf(t, false, "%s: first mismatch at sample %d: got %d, want %d", name, i, out[i], want)}
			bad += 1
		}
	}
	testing.expectf(t, bad == 0, "%s: %d samples differ", name, bad)
}

@(test)
flac_high_order_lpc :: proc(t: ^testing.T) {check_vector(t, "a", #load("flac/a.bin"))}

@(test)
flac_fixed_predictors :: proc(t: ^testing.T) {check_vector(t, "b", #load("flac/b.bin"))}

@(test)
flac_independent_channels :: proc(t: ^testing.T) {check_vector(t, "c", #load("flac/c.bin"))}

@(test)
flac_order_32_lpc :: proc(t: ^testing.T) {check_vector(t, "d", #load("flac/d.bin"))}

@(test)
flac_truncated_stream_fails_cleanly :: proc(t: ^testing.T) {
	stream := #load("flac/a.bin")
	out := make([]i16, 4704 * 2)
	defer delete(out)
	testing.expect(t, !host.flac_decode_stereo16(stream[:len(stream) / 2], out, 4704))
	garbage := []byte{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect(t, !host.flac_decode_stereo16(garbage, out, 4704))
}
