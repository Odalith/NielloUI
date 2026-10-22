// twowin_smoke — multi-window M2 verification, NOT a pattern to copy.
//
// The shipped glue (niello/sdl's run) is still single-window until M3.
// This example hand-rolls a minimal two-window loop directly on the
// M1/M2 primitives to prove them end to end on real surfaces:
//
//   - two SDL windows, two engine Contexts (M1), two backend
//     nui_windows on ONE shared device/context/recorder (M2);
//   - events routed by SDL windowID; each window frames, lays out,
//     and presents independently (window B's counter advances even
//     while window A sits idle, and vice versa);
//   - units are minted ONCE, globally — both windows show the same
//     `chip` unit; one group_set recolors it in both (fork 5).
//
// M3 replaces this loop with the real window table in the glue; M5's
// multiwindow example will use that. Delete this once M5 lands.
package main

import "core:fmt"
import sdl "vendor:sdl3"
import niello "../../"
import glue "../../sdl"

Win :: struct {
	sdl_win:  ^sdl.Window,
	id:       sdl.WindowID,
	ctx:      ^niello.Context,
	nui:      glue.Window,
	px_w:     i32,
	px_h:     i32,
	log_w:    i32,
	log_h:    i32,
	scale:    f32,
	mouse:    [2]f32,
	mouse_ok: bool,
	down:     niello.Buttons,
	pressed:  niello.Buttons,
	released: niello.Buttons,
	alive:    bool,
}

// ---- the shared, globally minted units (fork 5) ----
root_a, panel_a, chip, label_a: niello.Unit
root_b, row_b, counter_u: niello.Unit
theme: niello.Group
frame_no: int

declare_a :: proc() {
	niello.show(root_a)
	if _, open := niello.begin(root_a); open {
		niello.show(panel_a)
		if _, open2 := niello.begin(panel_a); open2 {
			niello.show(chip)
			niello.show(label_a, 0, {text = "Window A — hello tree"})
		}
	}
}

declare_b :: proc() {
	niello.show(root_b)
	if _, open := niello.begin(root_b); open {
		niello.show(chip) // the SAME unit as window A shows
		buf: [32]u8
		txt := fmt.bprintf(buf[:], "B frame %d", frame_no)
		niello.show(counter_u, 0, {text = txt})
	}
}

make_win :: proc(title: cstring, w, h: i32, ctx: ^niello.Context) -> (Win, bool) {
	sw := sdl.CreateWindow(title, w, h, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if sw == nil {
		fmt.println("CreateWindow failed:", sdl.GetError())
		return {}, false
	}
	handles := glue.native_handles_for_window(sw)
	px_w, px_h: i32
	sdl.GetWindowSizeInPixels(sw, &px_w, &px_h)
	nui := glue.create_window(&handles, u32(max(px_w, 0)), u32(max(px_h, 0)))
	if nui == nil {
		fmt.println("nui_create_window failed")
		return {}, false
	}
	win := Win{
		sdl_win = sw, id = sdl.GetWindowID(sw), ctx = ctx, nui = nui,
		px_w = px_w, px_h = px_h, log_w = w, log_h = h,
		scale = sdl.GetWindowDisplayScale(sw), alive = true,
	}
	display := sdl.GetDisplayForWindow(sw)
	if display != 0 {
		if mode := sdl.GetCurrentDisplayMode(display); mode != nil && mode.refresh_rate > 0 {
			glue.set_refresh_rate(nui, mode.refresh_rate)
		}
	}
	return win, true
}

frame_win :: proc(win: ^Win, declare: proc()) {
	input := niello.Input{
		viewport      = {f32(win.log_w), f32(win.log_h)},
		mouse         = win.mouse,
		mouse_valid   = win.mouse_ok,
		buttons_down  = win.down,
		buttons_pressed = win.pressed,
		buttons_released = win.released,
		window_focused = true,
	}
	niello.frame_begin(win.ctx, input, 1.0 / 60.0)
	declare()
	res := niello.frame_end()
	win.pressed = {}
	win.released = {}
	cmds := niello.draw_list()
	if res.changed {
		glue.render(win.nui, raw_data(cmds), i32(len(cmds)), nil, 0, win.scale)
	} else {
		glue.present_cached(win.nui)
	}
}

main :: proc() {
	if !sdl.Init({.VIDEO}) {
		fmt.println("SDL_Init failed:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	niello.measure_word_hook = glue.hook_measure_word
	niello.line_height_hook = glue.hook_line_height

	// Global minting, once, before any window exists (fork 5).
	niello.mint(&root_a, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.Size{niello.percent(1), niello.percent(1)}, color = niello.Color{24, 24, 32, 255}, padding = [4]u16{16, 16, 16, 16}, gap = 12})
	niello.mint(&panel_a, niello.NO_UNIT, {layout = .Left_To_Right, size = niello.Size{niello.percent(1), niello.fixed(64)}, color = niello.Color{38, 38, 52, 255}, padding = [4]u16{12, 12, 12, 12}, gap = 12, corner_radius = 8})
	niello.mint(&chip, niello.NO_UNIT, {size = niello.Size{niello.fixed(40), niello.fixed(40)}, color = niello.Color{90, 160, 250, 255}, corner_radius = 8})
	niello.mint(&label_a, niello.NO_UNIT, {font_size = 15, font_color = niello.Color{230, 230, 240, 255}})
	niello.mint(&root_b, niello.NO_UNIT, {layout = .Left_To_Right, size = niello.Size{niello.percent(1), niello.percent(1)}, color = niello.Color{30, 22, 18, 255}, padding = [4]u16{16, 16, 16, 16}, gap = 12})
	niello.mint(&counter_u, niello.NO_UNIT, {font_size = 15, font_color = niello.Color{240, 220, 200, 255}})
	theme = niello.group_new("theme")
	niello.group_add(theme, chip)

	if glue.init() != 0 {
		fmt.println("nui_init failed")
		return
	}
	defer glue.shutdown()

	ctx_a := niello.context_create()
	ctx_b := niello.context_create()
	defer niello.context_destroy(ctx_a)
	defer niello.context_destroy(ctx_b)

	win_a, ok_a := make_win("Niello smoke — A", 560, 360, ctx_a)
	win_b, ok_b := make_win("Niello smoke — B", 460, 240, ctx_b)
	if !ok_a || !ok_b {
		return
	}
	wins := [2]^Win{&win_a, &win_b}
	declares := [2]proc(){declare_a, declare_b}

	// One broadcast, both windows recolor next frame (fork 5's
	// no-surprises rule, exercised at t=0 with a different color
	// than the mint so the change is visible if frames are live).
	niello.group_set(theme, .Color, niello.Color{250, 170, 60, 255})

	running := true
	for running {
		ev: sdl.Event
		for sdl.PollEvent(&ev) {
			#partial switch ev.type {
			case .QUIT:
				running = false
			case .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED:
				for win in wins {
					if win.alive && ev.window.windowID == win.id {
						sdl.GetWindowSize(win.sdl_win, &win.log_w, &win.log_h)
						sdl.GetWindowSizeInPixels(win.sdl_win, &win.px_w, &win.px_h)
						win.scale = sdl.GetWindowDisplayScale(win.sdl_win)
						glue.resize(win.nui, u32(max(win.px_w, 0)), u32(max(win.px_h, 0)))
					}
				}
			case .WINDOW_CLOSE_REQUESTED:
				for win in wins {
					if win.alive && ev.window.windowID == win.id {
						glue.destroy_window(win.nui)
						sdl.DestroyWindow(win.sdl_win)
						win.alive = false
					}
				}
				if !win_a.alive && !win_b.alive {
					running = false
				}
			case .MOUSE_MOTION:
				for win in wins {
					if win.alive && ev.motion.windowID == win.id {
						win.mouse = {ev.motion.x, ev.motion.y}
						win.mouse_ok = true
					}
				}
			case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
				for win in wins {
					if win.alive && ev.button.windowID == win.id {
						if ev.button.button == 1 { // SDL_BUTTON_LEFT (the glue maps 1/2/3 the same way)
							if ev.button.down {
								win.down += {.Left}
								win.pressed += {.Left}
							} else {
								win.down -= {.Left}
								win.released += {.Left}
							}
						}
					}
				}
			}
		}
		frame_no += 1
		for win, i in wins {
			if win.alive {
				frame_win(win, declares[i])
			}
		}
		sdl.Delay(16)
	}
}
