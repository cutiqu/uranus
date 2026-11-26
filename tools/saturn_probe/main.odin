// Loads a Saturn save state and reports what VDP2 is doing with it: registers, scroll,
// line-scroll and vertical-cell-scroll tables, plus a render of the frame and of each
// layer on its own (PPM files). For chasing layer-alignment bugs from a real frame.
//
//   odin build tools/saturn_probe -o:speed -out:build/saturn_probe
//   build/saturn_probe game.state outdir
package saturn_probe

import "core:fmt"
import "core:os"
import sat "../../cores/saturn"

write_ppm :: proc(path: string, v: ^sat.VDP2) {
	w, h := int(v.width), int(v.height)
	hdr := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	buf := make([]byte, len(hdr) + w * h * 3)
	defer delete(buf)
	copy(buf, hdr)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := v.pix[y * sat.SCREEN_MAX_W + x]
			i := len(hdr) + (y * w + x) * 3
			buf[i], buf[i + 1], buf[i + 2] = u8(p >> 16), u8(p >> 8), u8(p)
		}
	}
	if os.write_entire_file(path, buf) != nil { fmt.eprintln("cannot write", path) }
}

render :: proc(s: ^sat.Saturn, path: string) {
	v := &s.vdp2
	w, h, _, _ := sat.vdp2_mode(v)
	v.width, v.height = w, h
	for y in u32(0) ..< h { sat.vdp2_draw_line(v, y, &s.vdp1.fb[1 - s.vdp1.draw]) }
	write_ppm(path, v)
}

vr32 :: proc(v: ^sat.VDP2, addr: u32) -> u32 {
	a := addr & 0x7FFFF
	return u32(v.vram[a]) << 24 | u32(v.vram[a + 1]) << 16 | u32(v.vram[a + 2]) << 8 | u32(v.vram[a + 3])
}

main :: proc() {
	if len(os.args) < 3 { fmt.eprintln("usage: saturn_probe <state> <outdir>"); os.exit(2) }
	data, rerr := os.read_entire_file(os.args[1], context.allocator)
	if rerr != nil { fmt.eprintln("cannot read state"); os.exit(1) }
	out := os.args[2]
	os.make_directory(out)
	s := new(sat.Saturn)
	if !sat.state_inspect(s, data) { fmt.eprintln("could not read the state (wrong size or not a Saturn state)"); os.exit(1) }
	v := &s.vdp2

	fmt.println("== VDP2 registers (offset: value), non-zero only")
	for i in 0 ..< 0x100 { if v.regs[i] != 0 { fmt.printf("%03X:%04X ", i * 2, v.regs[i]) } }
	fmt.println()
	r := v.regs
	fmt.printfln("TVMD=%04X BGON=%04X CHCTLA=%04X CHCTLB=%04X SCRCTL=%04X ZMCTL=%04X RAMCTL=%04X", r[0], r[0x10], r[0x14], r[0x15], r[0x50], r[0x4F], r[7])
	fmt.printfln("cycle patterns A0=%04X%04X A1=%04X%04X B0=%04X%04X B1=%04X%04X", r[8], r[9], r[0xA], r[0xB], r[0xC], r[0xD], r[0xE], r[0xF])
	fmt.printfln("PRINA=%04X PRINB=%04X CCCTL=%04X CCRNA=%04X CLOFEN=%04X", r[0x7C], r[0x7D], r[0x76], r[0x84], r[0x90])
	fmt.printfln("VCSTA=%04X.%04X LSTA0=%04X.%04X LSTA1=%04X.%04X", r[0x4E], r[0x4F], r[0x52], r[0x53], r[0x54], r[0x55])
	fmt.println("(raw dump above is authoritative; field names for scroll/zoom are in vdp2.odin)")

	vcs_addr := ((u32(r[0x4E]) << 16 | u32(r[0x4F])) & 0x7FFFE) << 1
	fmt.printfln("== vertical cell scroll table @%05X (first 48 longs)", vcs_addr)
	for i in u32(0) ..< 48 { fmt.printf("%08X ", vr32(v, vcs_addr + i * 4)); if i % 8 == 7 { fmt.println() } }
	for n in u32(0) ..< 2 {
		lsta := ((u32(r[0x52 + n * 2]) << 16 | u32(r[0x53 + n * 2])) & 0x7FFFE) << 1
		fmt.printfln("== line scroll table NBG%d @%05X (lines 0..239 step 8, 3 longs each)", n, lsta)
		for y in u32(0) ..< 30 { fmt.printf("%3d:%08X/%08X/%08X ", y * 8, vr32(v, lsta + y * 8 * 12), vr32(v, lsta + y * 8 * 12 + 4), vr32(v, lsta + y * 8 * 12 + 8)); if y % 2 == 1 { fmt.println() } }
	}

	render(s, fmt.tprintf("%s/composite.ppm", out))
	bgon := v.regs[0x10]
	names := [?]string{"nbg0", "nbg1", "nbg2", "nbg3", "rbg0"}
	for n in 0 ..< 5 {
		v.regs[0x10] = bgon & (1 << u32(n)) // that layer only (sprites still composite)
		if bgon & (1 << u32(n)) != 0 { render(s, fmt.tprintf("%s/only_%s.ppm", out, names[n])) }
	}
	v.regs[0x10] = 0
	render(s, fmt.tprintf("%s/only_sprite.ppm", out))
	v.regs[0x10] = bgon
	fmt.printfln("wrote renders to %s", out)
}
