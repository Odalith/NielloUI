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
import "core:os"
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
g_ctx:      ^niello.Context // the window's engine context (M1; the app
                            // supplies it instead from M3 on)
@(private)
g_nui_win:  Window          // the window's backend handle (M2)
@(private)
g_window:   ^sdl.Window
@(private)
g_mouse:    niello.Vec2
@(private)
g_mouse_valid: bool // cursor is over the window; set by motion/button/wheel, cleared on leave
@(private)
g_window_focused: bool = true // assumed until SDL says otherwise
@(private)
g_buttons_down:     niello.Buttons
@(private)
g_buttons_pressed:  niello.Buttons // edges latched since the last frame
@(private)
g_buttons_released: niello.Buttons
@(private)
g_wheel: niello.Vec2 // accumulated since the last frame
@(private)
g_keys:      [16]niello.Key_Event
@(private)
g_key_count: int
@(private)
g_text_buf: [dynamic]u8 // committed text since the last frame (UTF-8)
@(private)
g_cursors: [niello.Cursor_Kind]^sdl.Cursor // lazily created system cursors
@(private)
g_cursor_applied: niello.Cursor_Kind = .Arrow
@(private)
g_last_ns:  u64
@(private)
g_content_scale: f32 = 1
@(private)
g_input_trace: bool // NUI_INPUT_TRACE: log button edges + focus flips
@(private)
g_trace_focused: bool = true

@(private)
g_wake_event_type: u32 = max(u32) // SDL user event type for wake(); set in sdl_init
@(private)
g_last_changed: bool = true // last frame_end's changed; the loop sleeps only when false
@(private)
g_last_next_wake: u32 = max(u32) // last frame_end's next_wake_ms

@(private)
g_wayland: bool
@(private)
g_pending_size: bool
@(private)
g_pixel_width, g_pixel_height: i32
@(private)
g_force_render: bool = true

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

// native_handles_for_window queries the platform window handles via
// SDL_GetWindowProperties. The C++ backend takes these instead of the
// SDL_Window, so it never links or includes SDL. Exported: the M3
// window table calls it per window, and embedders driving their own
// loop (see examples/twowin_smoke) need it too.
native_handles_for_window :: proc(window: ^sdl.Window) -> Native_Handles {
	handles := Native_Handles{}
	props := sdl.GetWindowProperties(window)
	if props == 0 {
		return handles
	}
	driver := sdl.GetCurrentVideoDriver()
	handles.driver = driver
	if driver == "wayland" {
		handles.wl_display = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nil)
		handles.wl_surface = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WAYLAND_SURFACE_POINTER, nil)
	} else if driver == "x11" {
		handles.x11_display = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_X11_DISPLAY_POINTER, nil)
		handles.x11_window = u64(sdl.GetNumberProperty(props, sdl.PROP_WINDOW_X11_WINDOW_NUMBER, 0))
	} else if driver == "windows" {
		handles.win32_hwnd = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
		handles.win32_hinstance = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_INSTANCE_POINTER, nil)
	} else if driver == "cocoa" {
		handles.cocoa_layer = sdl.GetPointerProperty(props, sdl.PROP_WINDOW_COCOA_WINDOW_POINTER, nil)
	}
	return handles
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

	// Deliver the click that activates the window, not just the focus:
	// without this hint, SDL drops the activating press on several
	// platforms and the first click on an unfocused window is eaten
	// before the app ever sees it.
	_ = sdl.SetHint(sdl.HINT_MOUSE_FOCUS_CLICKTHROUGH, "1")
	if v, found := os.lookup_env("NUI_INPUT_TRACE", context.temp_allocator); found {
		g_input_trace = v != "" && v != "0"
	}

	w := g_config.width if g_config.width > 0 else 800
	h := g_config.height if g_config.height > 0 else 600
	flags := g_config.flags + {.RESIZABLE}
	g_window = sdl.CreateWindow(ctitle, w, h, flags)
	if g_window == nil {
		fmt.printf("sdl.CreateWindow failed: %s\n", sdl.GetError())
		return .FAILURE
	}

	// One engine context for this window (M1 transitional wiring:
	// multi-window glue gives every window its own at M3).
	g_ctx = niello.context_create()

	// Wire text measurement to the native backend (Skia), then init it.
	// The C++ side takes raw platform handles, not the SDL_Window: query
	// them here so the native lib never touches SDL.
	niello.measure_word_hook = hook_measure_word
	niello.line_height_hook = hook_line_height

	// Text input on, always (desktop): without it, SDL never sends
	// TEXT_INPUT — and dead keys never compose. The core routes the
	// committed text to the focused instance (§3.17).
	_ = sdl.StartTextInput(g_window)

	// context_wake plumbing: a user event type the wake hook pushes
	// from any thread to interrupt the loop's event wait. Registration
	// failing leaves wake_hook nil — a wake then only flags the core and
	// discovery waits for the next natural wake.
	g_wake_event_type = sdl.RegisterEvents(1)
	if g_wake_event_type != max(u32) {
		niello.wake_hook = glue_wake
	}
	handles := native_handles_for_window(g_window)
	px_w, px_h: i32
	sdl.GetWindowSizeInPixels(g_window, &px_w, &px_h)
	if init() != 0 {
		fmt.println("nui_init failed")
		return .FAILURE
	}
	g_nui_win = create_window(&handles, u32(px_w), u32(px_h))
	if g_nui_win == nil {
		fmt.println("nui_create_window failed")
		return .FAILURE
	}

	g_wayland = handles.driver == "wayland"
	g_pixel_width, g_pixel_height = px_w, px_h
	g_content_scale = content_scale()
	g_last_ns = sdl.GetTicksNS()

	// Seed the refresh rate for the backend's resize pacing.
	display := sdl.GetDisplayForWindow(g_window)
	if display != 0 {
		mode := sdl.GetCurrentDisplayMode(display)
		if mode != nil && mode.refresh_rate > 0 {
			set_refresh_rate(g_nui_win, mode.refresh_rate)
		}
	}

	return .CONTINUE
}

@(private)
app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = runtime.default_context()

	// Events only retain the latest size; layout follows the single reconfiguration.
	if g_pending_size {
		resize(g_nui_win, u32(max(g_pixel_width, 0)), u32(max(g_pixel_height, 0)))
		g_content_scale = content_scale()
		g_pending_size = false
		g_force_render = true
	}
	if g_pixel_width <= 0 || g_pixel_height <= 0 || .MINIMIZED in sdl.GetWindowFlags(g_window) {
		// Nothing can change while minimized; let the loop sleep until
		// an event (restore, resize) arrives.
		g_last_changed = false
		sdl.Delay(8)
		return .CONTINUE
	}

	// dt in seconds for animations (none in this build, but the slot is here).
	now_ns := sdl.GetTicksNS()
	dt := f32(now_ns - g_last_ns) / 1e9
	g_last_ns = now_ns

	// Viewport in DIP: roots fill it unless FIXED/PERCENT.
	pt_w, pt_h: i32
	sdl.GetWindowSize(g_window, &pt_w, &pt_h)
	input := niello.Input{
		viewport         = {f32(pt_w), f32(pt_h)},
		mouse            = g_mouse,
		mouse_valid      = g_mouse_valid,
		buttons_down     = g_buttons_down,
		buttons_pressed  = g_buttons_pressed,
		buttons_released = g_buttons_released,
		wheel            = g_wheel,
		keys             = g_keys,
		key_count        = g_key_count,
		text             = string(g_text_buf[:]),
		window_focused   = g_window_focused,
	}
	if g_input_trace &&
	   (input.buttons_pressed != {} ||
		   input.buttons_released != {} ||
		   input.window_focused != g_trace_focused) {
		fmt.printf(
			"input-trace: focused=%v valid=%v pressed=%v released=%v mouse=(%.0f,%.0f)\n",
			input.window_focused,
			input.mouse_valid,
			input.buttons_pressed,
			input.buttons_released,
			input.mouse.x,
			input.mouse.y,
		)
		g_trace_focused = input.window_focused
	}

	// Edges and accumulations are per-frame: this frame_begin consumes them.
	g_buttons_pressed = {}
	g_buttons_released = {}
	g_wheel = {}
	g_key_count = 0

	niello.frame_begin(g_ctx, input, dt)
	// frame_begin copied the committed text into the core's own
	// buffer; the accumulation starts over.
	clear(&g_text_buf)
	g_declare()
	result := niello.frame_end()

	if result.cursor != g_cursor_applied {
		apply_cursor(result.cursor)
		g_cursor_applied = result.cursor
	}

	if result.changed || g_force_render {
		cmds := niello.draw_list()
		g_force_render = render(g_nui_win, raw_data(cmds), i32(len(cmds)), nil, 0, g_content_scale) == 0
	} else if g_wayland {
		if present_cached(g_nui_win) == 0 {
			// Retry through a complete current frame after a failed update/acquire.
			g_force_render = true
		}
	}
	// No idle delay here anymore: an unchanged frame makes run()'s loop
	// block on events until the next deadline (§3.3).

	g_last_changed = result.changed
	g_last_next_wake = result.next_wake_ms
	return .CONTINUE
}

@(private)
event_callback :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = runtime.default_context()

	if g_wake_event_type != max(u32) &&
	   transmute(u32)(event.type) == g_wake_event_type {
		// niello.wake() from another thread: the frame it asked for is
		// the iterate that follows this event batch. Nothing else to do.
		if g_input_trace {
			fmt.println("input-trace: wake event")
		}
		return .CONTINUE
	}

	#partial switch event.type {
	case .QUIT:
		return .FAILURE
	case .MOUSE_MOTION:
		// Mouse is in DIP points, matching the viewport niello sees.
		g_mouse = {event.motion.x, event.motion.y}
		g_mouse_valid = true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if b, ok := mouse_button(event.button.button); ok {
			// Button events carry the position too; keep it fresh even
			// when no motion event preceded the click.
			g_mouse = {event.button.x, event.button.y}
			g_mouse_valid = true
			if event.button.down {
				g_buttons_down += {b}
				g_buttons_pressed += {b}
			} else {
				g_buttons_down -= {b}
				g_buttons_released += {b}
			}
		}
	case .MOUSE_WHEEL:
		x, y := event.wheel.x, event.wheel.y
		if event.wheel.direction == .FLIPPED {
			x, y = -x, -y
		}
		g_wheel += {x, y}
		g_mouse = {event.wheel.mouse_x, event.wheel.mouse_y}
		g_mouse_valid = true
	case .TEXT_INPUT:
		// Committed text (typing, dead-key results, IME commits),
		// accumulated for the next frame's Input.text. Capped: a
		// frame's worth of typing is small; the cap only stops a
		// pathological flood.
		if event.text.text != nil {
			ptr := cast([^]u8)event.text.text
			for j := 0; ptr[j] != 0 && len(g_text_buf) < 1024; j += 1 {
				append(&g_text_buf, ptr[j])
			}
		}
	case .KEY_DOWN, .KEY_UP:
		// Collected now, consumed by the focus pass later. Overflow past
		// the ring is dropped: 16 key events in one frame is a flood, and
		// the oldest are the ones that matter.
		if g_key_count < len(g_keys) {
			g_keys[g_key_count] = niello.Key_Event{
				scancode = u32(event.key.scancode),
				keycode  = u32(event.key.key),
				mods     = transmute(u16)(event.key.mod),
				down     = event.key.down,
				repeat   = event.key.repeat,
			}
			g_key_count += 1
		}
	case .WINDOW_MOUSE_ENTER:
		g_mouse_valid = true
	case .WINDOW_MOUSE_LEAVE:
		g_mouse_valid = false
	case .WINDOW_FOCUS_GAINED:
		g_window_focused = true
	case .WINDOW_FOCUS_LOST:
		g_window_focused = false
	case .WINDOW_PIXEL_SIZE_CHANGED:
		g_pixel_width, g_pixel_height = event.window.data1, event.window.data2
		g_pending_size = true
	case .WINDOW_DISPLAY_SCALE_CHANGED, .WINDOW_RESTORED, .WINDOW_EXPOSED:
		sdl.GetWindowSizeInPixels(g_window, &g_pixel_width, &g_pixel_height)
		g_pending_size = true
	case .WINDOW_DISPLAY_CHANGED:
		sdl.GetWindowSizeInPixels(g_window, &g_pixel_width, &g_pixel_height)
		g_pending_size = true
		display := sdl.GetDisplayForWindow(g_window)
		if display != 0 {
			mode := sdl.GetCurrentDisplayMode(display)
			if mode != nil && mode.refresh_rate > 0 {
				set_refresh_rate(g_nui_win, mode.refresh_rate)
			}
		}
	}

	return .CONTINUE
}

@(private)
app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = runtime.default_context()
	destroy_window(g_nui_win)
	shutdown()
	if g_ctx != nil {
		niello.context_destroy(g_ctx)
		g_ctx = nil
	}
}

// mouse_button maps SDL's button index (1/2/3) to niello's button enum.
@(private)
mouse_button :: proc(sdl_button: u8) -> (niello.Mouse_Button, bool) {
	switch sdl_button {
	case 1:
		return .Left, true
	case 2:
		return .Middle, true
	case 3:
		return .Right, true
	}
	return .Left, false
}

@(private)
system_cursor :: proc(kind: niello.Cursor_Kind) -> sdl.SystemCursor {
	switch kind {
	case .Arrow:
		return .DEFAULT
	case .Text:
		return .TEXT
	case .Pointer:
		return .POINTER
	case .Crosshair:
		return .CROSSHAIR
	case .Wait:
		return .WAIT
	case .Move:
		return .MOVE
	case .Resize_NS:
		return .NS_RESIZE
	case .Resize_EW:
		return .EW_RESIZE
	case .Resize_NWSE:
		return .NWSE_RESIZE
	case .Resize_NESW:
		return .NESW_RESIZE
	case .Not_Allowed:
		return .NOT_ALLOWED
	}
	return .DEFAULT
}

// apply_cursor shows the given cursor, creating its SDL system cursor on
// first use. A failed creation leaves the current cursor alone.
@(private)
apply_cursor :: proc(kind: niello.Cursor_Kind) {
	cur := g_cursors[kind]
	if cur == nil {
		cur = sdl.CreateSystemCursor(system_cursor(kind))
		g_cursors[kind] = cur
	}
	if cur != nil {
		_ = sdl.SetCursor(cur)
	}
}

// glue_wake is niello's wake_hook: pushing an event is SDL's thread-safe
// way to interrupt a WaitEventTimeout sleeping on the loop thread.
@(private)
glue_wake :: proc() {
	ev: sdl.Event
	ev.type = transmute(sdl.EventType)(g_wake_event_type)
	_ = sdl.PushEvent(&ev)
}

// loop_timeout: how long run()'s loop may block before the next iterate.
// 0 = iterate immediately (motion sustains its own cadence; the backend
// paces actual presents), -1 = until an event arrives.
@(private)
loop_timeout :: proc() -> i32 {
	if g_pending_size || g_force_render || g_last_changed {
		return 0
	}
	if g_last_next_wake == max(u32) {
		return -1
	}
	return i32(min(g_last_next_wake, u32(max(i32))))
}

// run opens the window and drives the frame loop until the app quits.
//
// The loop is hand-driven — the four SDL_App* entry points, called from
// here instead of EnterAppMainCallbacks — so the idle path can BLOCK:
// when the last frame changed nothing and no resize is pending, the loop
// waits in SDL_WaitEventTimeout until the next OS event or the engine's
// next_wake_ms deadline, so an idle window sits at ~0% CPU (§3.3). Any
// event, including the wake() user event, cuts the wait short. Desktop
// targets only: platforms where SDL must own main() (web, consoles) are
// not NielloUI targets. If WASM ever becomes one, the browser forbids
// blocking the main thread entirely — run() would hand these same four
// entry points back to EnterAppMainCallbacks and give up the blocking
// sleep; the rest of the glue is loop-agnostic by design.
run :: proc(config: App_Config, declare: Declare_Proc) {
	g_config = config
	g_declare = declare
	argv: cstring = ""
	appstate: rawptr // the callbacks keep state in this package's globals
	res := sdl_init(&appstate, 0, &argv)
	if res != .CONTINUE {
		sdl.Quit()
		return
	}
	ev: sdl.Event
	for res == .CONTINUE {
		timeout := loop_timeout()
		if timeout < 0 {
			if sdl.WaitEvent(&ev) {
				res = event_callback(nil, &ev)
			}
		} else if timeout > 0 {
			if sdl.WaitEventTimeout(&ev, timeout) {
				res = event_callback(nil, &ev)
			}
		}
		// Drain whatever else is queued — on EVERY pass, including
		// timeout == 0, where nothing was waited on. This drain used to
		// run only after a blocking wait returned an event, so a streak
		// of changed frames never pumped the queue at all: animations
		// hold `changed` true for their whole duration, and mouse input
		// (hover, clicks) starved until the streak ended.
		for res == .CONTINUE && sdl.PollEvent(&ev) {
			res = event_callback(nil, &ev)
		}
		if res == .CONTINUE {
			res = app_iterate(nil)
		}
	}
	app_quit(nil, res)
}
