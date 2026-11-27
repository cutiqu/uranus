// The list of cores compiled into this executable. Adding a core means one
// import and one line here; nothing else in the program names a core.
package registry

import api "../api"
import saturn "../core"
import "core:strings"

// Constructors, in display order.
@(private)
CONSTRUCTORS := [?]proc() -> api.Core{saturn.interface}

count :: proc() -> int {return len(CONSTRUCTORS)}

at :: proc(i: int) -> (core: api.Core, info: api.Core_Info) {
	core = CONSTRUCTORS[i]()
	core.get_info(&info)
	return
}

find_by_id :: proc(id: string) -> (core: api.Core, ok: bool) {
	for i in 0 ..< count() {
		c, info := at(i)
		if strings.equal_fold(string(info.id), id) {return c, true}
	}
	return {}, false
}

// `ext` is a file extension without the dot, any case ("cue", "chd").
find_by_extension :: proc(ext: string) -> (core: api.Core, ok: bool) {
	for i in 0 ..< count() {
		c, info := at(i)
		list := string(info.extensions)
		for candidate in strings.split_iterator(&list, "|") {
			if strings.equal_fold(candidate, ext) {return c, true}
		}
	}
	return {}, false
}
