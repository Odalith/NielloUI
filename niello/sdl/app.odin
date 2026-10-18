// niello/sdl/app — SDL3 application scaffolding for NielloUI apps.
//
// This is the "hello window" layer. It owns the SDL window and event loop,
// drives the niello frame pipeline (frame_begin → declare → frame_end →
// draw_list → nui_render), wires the text-measurement hooks to the native
// backend, and sleeps when the UI is idle. An app provides the UI
// declaration proc; this package handles everything else.
//
// Usage:
//
//   import niello_sdl "niello/sdl"
//
//   declare :: proc() {
//       // niello.show / niello.begin / niello.end ...
//   }
//
//   main :: proc() {
//       niello_sdl.run({title = "My App", width = 800, height = 600}, declare)
//   }
package sdl

import "core:fmt"
import "core:strings"
import "base:runtime"
import sdl "vendor:sdl3"
import niello "../"

// App_Config describes the window. Fields not set get sensible defaults.
App_Config :: struct {
	title:  string, // window title
	width:  i32,    // initial width in pixels (DIP at scale 1)
	height: i32,    // initial height in pixels (DIP at scale 1)
	flags:  sdl.WindowFlags,
}

// Declare_Proc is the app's UI: it runs between frame_begin and frame_end.
Declare_Proc :: #type proc()

// Package state, owned by the SDL callbacks below.
@(private)
g_config:  App_Config
@(private)
g_declare:  Declare_Proc
@(private)
g_window:   ^sdl.Window
@(private)
g_mouse:    niello.Vec2
@(private)
g_last_ns:  u64
@(private)
g_content_scale: f32 = 1

// content_scale computes device pixels per DIP point for the window.
@(private)
content_scale :: proc() -> f32 {
	px_w, px_h: i32
	sdl.GetWindowSizeInPixels(g_window, &px_w, &px_h)
	pt_w, pt_h: i32
	sdl.GetWindowSize(g_window, &pt_w, &pt_h)
	if pt_w > 0 && px_w > 0 {
		return f32(px_w) / f32(pt_w)
	}
	return 1
}

@(private)
sdl_init :: proc "c" (appstate: ^rawptr, argc: i32, argv: [^]cstring) -> sdl.AppResult {
	context = runtime.default_context()

	title := g_config.title if g_config.title != "" else "Niello App"
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	if !sdl.SetAppMetadata(ctitle, "1.0", "com.niello.app") {
		fmt.printf("sdl.SetAppMetadata failed: %s\n", sdl.GetError())
	}

	if !sdl.Init({.VIDEO}) {
		fmt.printf("sdl.Init failed: %s\n", sdl.GetError())
		return .FAILURE
	}

	w := g_config.width if g_config.width > 0 else 800
	h := g_config.height if g_config.height > 0 else 600
	flags := g_config.flags + {.RESIZABLE}
	g_window = sdl.CreateWindow(ctitle, w, h, flags)
	if g_window == nil {
		fmt.printf("sdl.CreateWindow failed: %s\n", sdl.GetError())
		return .FAILURE
	}

	// Wire text measurement to the native backend (Skia), then init it.
	niello.measure_word_hook = hook_measure_word
	niello.line_height_hook = hook_line_height
	if init(g_window) != 0 {
		fmt.println("nui_init failed")
		return .FAILURE
	}

	g_content_scale = content_scale()
	g_last_ns = sdl.GetTicksNS()

	// Seed the refresh rate for the backend's resize pacing.
	display := sdl.GetDisplayForWindow(g_window)
	if display != 0 {
		mode := sdl.GetCurrentDisplayMode(display)
		if mode != nil && mode.refresh_rate > 0 {
			set_refresh_rate(mode.refresh_rate)
		}
	}

	return .CONTINUE
}

@(private)
app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = runtime.default_context()

	// dt in seconds for animations (none in this build, but the slot is here).
	now_ns := sdl.GetTicksNS()
	dt := f32(now_ns - g_last_ns) / 1e9
	g_last_ns = now_ns

	// Viewport in DIP: roots fill it unless FIXED/PERCENT.
	pt_w, pt_h: i32
	sdl.GetWindowSize(g_window, &pt_w, &pt_h)
	input := niello.Input{
		viewport = {f32(pt_w), f32(pt_h)},
		mouse    = g_mouse,
	}

	niello.frame_begin(input, dt)
	g_declare()
	result := niello.frame_end()

	if result.changed {
		cmds := niello.draw_list()
		damage := result.damage
		render(
			raw_data(cmds), i32(len(cmds)),
			raw_data(damage), i32(len(damage)),
			g_content_scale,
		)
	} else {
		// Idle: sleep until something can change the UI. next_wake_ms is
		// ∞ in this build (no timers/animations), so input is the only
		// wake source — SDL still pumps events while we delay.
		sdl.Delay(8)
	}

	return .CONTINUE
}

@(private)
event_callback :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = runtime.default_context()

	#partial switch event.type {
	case .QUIT:
		return .FAILURE
	case .MOUSE_MOTION:
		// Mouse is in DIP points, matching the viewport niello sees.
		g_mouse = {event.motion.x, event.motion.y}
	case .WINDOW_PIXEL_SIZE_CHANGED:
		// Device pixels changed (resize or DPI move): re-query the scale
		// and let the backend rebuild its surface.
		g_content_scale = content_scale()
		resize(u32(event.window.data1), u32(event.window.data2))
	case .WINDOW_DISPLAY_CHANGED:
		display := sdl.GetDisplayForWindow(g_window)
		if display != 0 {
			mode := sdl.GetCurrentDisplayMode(display)
			if mode != nil && mode.refresh_rate > 0 {
				set_refresh_rate(mode.refresh_rate)
			}
		}
	}

	return .CONTINUE
}

@(private)
app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = runtime.default_context()
	destroy()
}

// run opens the window and enters SDL's callback-driven main loop. It does
// not return until the app quits.
run :: proc(config: App_Config, declare: Declare_Proc) {
	g_config = config
	g_declare = declare
	argv: cstring = ""
	sdl.EnterAppMainCallbacks(0, &argv, sdl_init, app_iterate, event_callback, app_quit)
}
