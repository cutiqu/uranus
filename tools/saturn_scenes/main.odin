// Times and hashes the seeded VDP1/VDP2 scenes in scenes/.
//
//   saturn_scenes          hashes (N = full: 250 VDP1 scenes per class, 60 VDP2 per mode)
//   saturn_scenes quick    the same with the smaller N that tests/saturn/golden_test.odin pins
//   saturn_scenes time     ms per scene instead of hashes
//
// To regenerate the golden values, run `quick` against a checkout whose renderers
// are known good. Build: odin build tools/saturn_scenes -o:speed -out:build/saturn_scenes
package saturn_scenes

import "core:fmt"
import "core:os"
import "core:time"
import sat "../../core"
import "scenes"

main :: proc() {
	timing := len(os.args) > 1 && os.args[1] == "time"
	quick  := len(os.args) > 1 && os.args[1] == "quick"
	n1, n2 := 250, 60
	if quick { n1, n2 = scenes.QUICK_VDP1, scenes.QUICK_VDP2 }
	s := new(sat.Saturn)
	defer free(s)
	names := [?]string{"normal", "huge", "offscreen", "clipped", "lines"}
	modes := [?]string{"plain", "hires", "4xNBG", "chaos"}
	total := scenes.HASH_START
	for class in scenes.Class {
		t0 := time.tick_now()
		h := scenes.vdp1_class_hash(s, class, n1)
		ms := time.duration_milliseconds(time.tick_since(t0)) / f64(n1)
		if timing { fmt.printfln("vdp1 %-10s %8.3f ms/scene", names[class], ms) } else { fmt.printfln("vdp1 %-10s %016x", names[class], h) }
		total = scenes.fnv(total, h)
	}
	for m in 0 ..< 4 {
		t0 := time.tick_now()
		h := scenes.vdp2_mode_hash(s, m, n2)
		ms := time.duration_milliseconds(time.tick_since(t0)) / f64(n2)
		if timing { fmt.printfln("vdp2 %-10s %8.3f ms/frame", modes[m], ms) } else { fmt.printfln("vdp2 %-10s %016x", modes[m], h) }
		total = scenes.fnv(total, h)
	}
	if !timing { fmt.printfln("all  %016x", total) }
}
