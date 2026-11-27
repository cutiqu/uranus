package saturn_tests

// Pixel-exact regression for the VDP1 rasteriser and the VDP2 compositor.
//
// The values below are hashes of the framebuffers produced by seeded random scenes
// (tools/saturn_scenes/scenes): every VDP1 command type with flips, Gouraud, mesh,
// shadow and half-transparency, system and user clip in both modes, geometry that
// is partly or wholly off screen or thousands of pixels across; and VDP2 with random
// register files, VRAM and colour RAM in plain, hi-res and four-layer modes.
//
// They were captured from the renderers BEFORE the clipping / incremental-stepping /
// cell-cache work, so passing means those optimisations changed no pixel. If a
// change is meant to alter rendering, regenerate them with
//   odin build tools/saturn_scenes -o:speed -out:build/saturn_scenes && build/saturn_scenes quick
// and say why in the commit.

import "core:testing"
import sat "../../core"
import "../../tools/saturn_scenes/scenes"

@(private = "file")
GOLDEN_VDP1 := [scenes.Class]u64 {
	.Normal    = 0x37b4bacc69961ed2,
	.Huge      = 0x41ad9fea53eb2530,
	.Offscreen = 0x20f3bb81c6d16067,
	.Clipped   = 0x63690787554db621,
	.Lines     = 0xb59b35d2caefa9b8,
}

// Re-pinned when a vertical line-scroll value started adding to SCY instead of replacing it
// (line_scroll_y_adds_to_scroll_register). With that bit masked off the old and new
// compositor agree exactly; the VDP1 values above are still the original renderer's.
@(private = "file")
GOLDEN_VDP2 := [4]u64{0xe0cd0780d3c0ff33, 0xc10095afacc94f4d, 0x4f0e06864ed01472, 0x96ac985bc85905bc}

@(test)
vdp1_output_matches_golden :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	for class in scenes.Class {
		testing.expectf(t, scenes.vdp1_class_hash(s, class, scenes.QUICK_VDP1) == GOLDEN_VDP1[class], "VDP1 %v scenes changed output", class)
	}
}

@(test)
vdp2_output_matches_golden :: proc(t: ^testing.T) {
	s := new(sat.Saturn)
	defer free(s)
	for mode in 0 ..< 4 {
		testing.expectf(t, scenes.vdp2_mode_hash(s, mode, scenes.QUICK_VDP2) == GOLDEN_VDP2[mode], "VDP2 mode %d scenes changed output", mode)
	}
}
