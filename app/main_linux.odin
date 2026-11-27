#+build !linux:android
package main

import "core:os"
import api "../api"
import "../config"
import frontend_headless "../frontend/headless"
import frontend_sdl "../frontend/sdl"
import frontend_tui "../frontend/tui"

run_platform :: proc(core: api.Core, rom_path: string, cfg: ^config.Config, frontend: Frontend, hl: frontend_headless.Options, seconds: int, scale: int) {
	switch frontend {
	case .SDL:      os.exit(frontend_sdl.run(core, rom_path, cfg, seconds))
	case .TUI:      os.exit(frontend_tui.run(core, rom_path, cfg, scale))
	case .Headless:
		if hl.frames == 0 && !hl.check { die_usage("--headless needs a frame count") }
		os.exit(frontend_headless.run(core, rom_path, cfg, hl))
	}
}
