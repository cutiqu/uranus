package frontend_sdl

import "base:runtime"
import "core:fmt"
import xlib "vendor:x11/xlib"

when ODIN_OS == .Linux {
	xlib_error_handler :: proc "c" (display: ^xlib.Display, event: ^xlib.XErrorEvent) -> i32 {
		// Returning non-zero tells Xlib the error was handled: do not exit.
		context = runtime.default_context()
		fmt.eprintfln("x11: X error caught (non-fatal) -- ignoring")
		return 1
	}
}

install_x_error_handler :: proc() {
	when ODIN_OS == .Linux {
		xlib.OpenDisplay(nil)
		xlib.SetErrorHandler(xlib_error_handler)
	}
}
