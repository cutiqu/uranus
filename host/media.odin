package host

import "core:fmt"
import "core:os"
import "core:strings"
import api "../api"

// 16-bit stereo PCM -> .wav
write_wav :: proc(path: string, pcm: []i16, rate: u32) -> bool {
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)
	u32le :: proc(sb: ^strings.Builder, v: u32) { for i in 0 ..< u32(4) { strings.write_byte(sb, u8(v >> (8 * i))) } }
	u16le :: proc(sb: ^strings.Builder, v: u16) { strings.write_byte(sb, u8(v)); strings.write_byte(sb, u8(v >> 8)) }

	data_bytes := u32(len(pcm) * 2)
	strings.write_string(&sb, "RIFF"); u32le(&sb, 36 + data_bytes); strings.write_string(&sb, "WAVEfmt ")
	u32le(&sb, 16); u16le(&sb, 1); u16le(&sb, 2); u32le(&sb, rate); u32le(&sb, rate * 4); u16le(&sb, 4); u16le(&sb, 16)
	strings.write_string(&sb, "data"); u32le(&sb, data_bytes)
	for s in pcm { u16le(&sb, u16(s)) }
	return os.write_entire_file(path, sb.buf[:]) == nil
}

// Video_Frame -> binary PPM (P6)
write_ppm :: proc(path: string, v: api.Video_Frame) -> bool {
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)
	fmt.sbprintf(&sb, "P6\n%d %d\n255\n", v.width, v.height)
	for y in 0 ..< v.height {
		for x in 0 ..< v.width {
			px := v.pixels[y * v.pitch + x]
			strings.write_byte(&sb, u8(px >> 16))
			strings.write_byte(&sb, u8(px >> 8))
			strings.write_byte(&sb, u8(px))
		}
	}
	return os.write_entire_file(path, sb.buf[:]) == nil
}
