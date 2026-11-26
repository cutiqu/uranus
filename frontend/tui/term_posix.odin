#+build linux, darwin, freebsd, netbsd, openbsd
package frontend_tui

// Platform layer #1 of 2. This file is the ONLY place that knows how to put a
// POSIX terminal into raw mode. A Windows port supplies the same three procs
// (term_init / term_shutdown / term_read) in term_windows.odin using
// SetConsoleMode + ReadConsoleInput; nothing else in the frontend changes.

import "core:c"
import "core:sys/posix"

foreign import libc "system:c"

@(private="file")
foreign libc {
	// ioctl is variadic in C; #c_vararg keeps the calling convention right on
	// ABIs (Apple arm64) that pass variadic arguments differently.
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

@(private="file")
Winsize :: struct {
	rows, cols, xpixel, ypixel: u16,
}

when ODIN_OS == .Linux {
	@(private="file") TIOCGWINSZ :: 0x5413
} else {
	@(private="file") TIOCGWINSZ :: 0x40087468
}

// Terminal size in character cells. ok == false if it can't be determined.
term_size :: proc() -> (cols, rows: int, ok: bool) {
	ws: Winsize
	if ioctl(1, TIOCGWINSZ, &ws) != 0 || ws.cols == 0 || ws.rows == 0 {
		return 0, 0, false
	}
	return int(ws.cols), int(ws.rows), true
}

@(private="file")
saved_termios: posix.termios

@(private="file")
have_saved: bool

// Raw-ish mode: no line buffering, no echo, and read() returns immediately
// with whatever bytes are available (possibly zero). Output post-processing
// stays on so "\n" still behaves.
term_init :: proc() -> bool {
	if posix.tcgetattr(posix.STDIN_FILENO, &saved_termios) != .OK {
		return false
	}
	have_saved = true

	raw := saved_termios
	raw.c_lflag -= {.ICANON, .ECHO}
	raw.c_cc[.VMIN]  = 0
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw) != .OK {
		return false
	}

	// alternate screen buffer, hide cursor, clear
	term_write("\x1b[?1049h\x1b[?25l\x1b[2J")
	return true
}

term_shutdown :: proc() {
	if !have_saved { return }
	term_write("\x1b[0m\x1b[?25h\x1b[?1049l") // reset colours, show cursor, leave alt screen
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &saved_termios)
	have_saved = false
}

// Non-blocking: returns the number of bytes placed in buf (0 if no input).
term_read :: proc(buf: []byte) -> int {
	n := posix.read(posix.STDIN_FILENO, raw_data(buf), uint(len(buf)))
	return max(int(n), 0)
}
