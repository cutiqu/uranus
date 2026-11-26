package frontend_tui

// Platform-independent terminal pieces: keyboard -> virtual gamepad, and
// framebuffer -> ANSI text. Nothing in here is visible to the core.

import "core:fmt"
import "core:os"
import "core:strings"
import api "../../api"

term_write :: proc(s: string) {
	os.write_string(os.stdout, s)
}

// ------------------------------------------------------------------ input ---
//
// Terminals report key PRESSES (and auto-repeat) but never key RELEASES, so a
// "held" button is faked: every press arms a countdown, and the button counts
// as down until the countdown expires. Expect a stutter between the first
// press and the OS auto-repeat kicking in; a windowed frontend (SDL/Raylib)
// has real key-up events and doesn't need this.

HOLD_FRAMES :: 8

Input :: struct {
	hold:  [api.Button]int,
	quit:  bool,
	save:  bool,
	load:  bool,
	reset: bool,
}

input_press :: proc(inp: ^Input, b: api.Button) {
	inp.hold[b] = HOLD_FRAMES
}

input_feed :: proc(inp: ^Input, bytes: []byte) {
	i := 0
	for i < len(bytes) {
		// Arrow keys arrive as ESC [ A/B/C/D
		if bytes[i] == 0x1b && i + 2 < len(bytes) && bytes[i+1] == '[' {
			switch bytes[i+2] {
			case 'A': input_press(inp, .Up)
			case 'B': input_press(inp, .Down)
			case 'C': input_press(inp, .Right)
			case 'D': input_press(inp, .Left)
			}
			i += 3
			continue
		}

		switch bytes[i] {
		case 'w', 'W': input_press(inp, .Up)
		case 's', 'S': input_press(inp, .Down)
		case 'a', 'A': input_press(inp, .Left)
		case 'd', 'D': input_press(inp, .Right)
		case 'j', 'J': input_press(inp, .A)
		case 'k', 'K': input_press(inp, .B)
		case 'g', 'G': input_press(inp, .Select)
		case '\r', '\n': input_press(inp, .Start)
		case 'p', 'P': inp.save  = true
		case 'o', 'O': inp.load  = true
		case 'r', 'R': inp.reset = true
		case 'q', 'Q', 0x03: inp.quit = true // 0x03 = Ctrl-C (ISIG still on, belt and braces)
		}
		i += 1
	}
}

// Call once per emulated frame, after the core has run.
input_tick :: proc(inp: ^Input) {
	for &h in inp.hold {
		if h > 0 { h -= 1 }
	}
}

// The callback handed to the core. This is where "is A pressed?" becomes a
// lookup into frontend-owned state.
host_input_state :: proc "c" (userdata: rawptr, port: u32) -> api.Buttons {
	result: api.Buttons
	if port != 0 { return result }
	inp := (^Input)(userdata)
	for b in api.Button {
		if inp.hold[b] > 0 { result += {b} }
	}
	return result
}

// ----------------------------------------------------------------- video ----

// Average the colour of a w*h block of the framebuffer (clipped to its edges).
@(private="file")
block_average :: proc(v: api.Video_Frame, x0, y0, w, h: u32) -> (rgb: u32, valid: bool) {
	r, g, b, n: u32
	for y in y0 ..< min(y0 + h, v.height) {
		for x in x0 ..< min(x0 + w, v.width) {
			px := v.pixels[y * v.pitch + x]
			r += (px >> 16) & 0xFF
			g += (px >> 8) & 0xFF
			b += px & 0xFF
			n += 1
		}
	}
	if n == 0 { return 0, false }
	return (r / n) << 16 | (g / n) << 8 | (b / n), true
}

// Smallest integer downscale at which the frame fits the terminal, leaving
// `reserved_rows` for the status lines. One cell is `scale` px wide and
// `2*scale` px tall (two half-block pixels stacked).
choose_scale :: proc(w, h: u32, cols, rows, reserved_rows: int) -> u32 {
	for s in u32(1) ..< 64 {
		cells_w := int((w + s - 1) / s)
		cells_h := int((h + 2 * s - 1) / (2 * s))
		if cells_w <= cols && cells_h + reserved_rows <= rows { return s }
	}
	return 64
}

// Two (scaled) framebuffer rows per terminal row using the upper-half-block
// glyph: foreground colour = top block, background colour = bottom block.
render_frame :: proc(sb: ^strings.Builder, v: api.Video_Frame, scale: u32) {
	strings.write_string(sb, "\x1b[H")

	last_top, last_bot: u32 = max(u32), max(u32) // impossible colour = force first emit
	for y := u32(0); y < v.height; y += 2 * scale {
		for x := u32(0); x < v.width; x += scale {
			top, _ := block_average(v, x, y, scale, scale)
			bot, has_bot := block_average(v, x, y + scale, scale, scale)
			if !has_bot { bot = top }

			if top != last_top {
				fmt.sbprintf(sb, "\x1b[38;2;%d;%d;%dm", (top >> 16) & 0xFF, (top >> 8) & 0xFF, top & 0xFF)
				last_top = top
			}
			if bot != last_bot {
				fmt.sbprintf(sb, "\x1b[48;2;%d;%d;%dm", (bot >> 16) & 0xFF, (bot >> 8) & 0xFF, bot & 0xFF)
				last_bot = bot
			}
			strings.write_string(sb, "▀")
		}
		strings.write_string(sb, "\x1b[0m\x1b[K\n")
		last_top, last_bot = max(u32), max(u32)
	}
}
