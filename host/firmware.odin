package host

// Firmware (BIOS) lookup for cores that need it. A core names the files it
// accepts in Core_Info.firmware ("sega_101.bin|sega_100a.bin"); the frontend
// looks for them in the configured system directory and hands the bytes to
// Core.load_firmware. The core itself never sees a path.

import "core:os"
import "core:path/filepath"
import "core:strings"

// Reads the first of `hint`'s '|'-separated names that exists in `dir`.
// The caller owns `data` and `path`.
read_firmware :: proc(dir, hint: string) -> (data: []byte, path: string, ok: bool) {
	if dir == "" || hint == "" { return }
	rest := hint // split_iterator needs an addressable string
	for part in strings.split_iterator(&rest, "|") {
		name := strings.trim_space(part)
		if name == "" { continue }
		full, jerr := filepath.join({dir, name}, context.allocator)
		if jerr != nil { continue }
		if bytes, err := os.read_entire_file(full, context.allocator); err == nil {
			return bytes, full, true
		}
		delete(full)
	}
	return
}
