// niello/sdl/app — SDL3 application scaffolding for NielloUI apps.
//
// This is the window layer. It owns the SDL windows and event loop,
// drives the niello frame pipeline per window (frame_begin → declare →
// frame_end → draw_list → nui_render), wires the text-measurement
// hooks to the native backend, and sleeps when the UI is idle. An app
// provides one UI declaration proc per window; this package handles
// everything else.
//
// Multi-window (M3): the app creates one engine Context per window
// and hands it over — the glue never creates or destroys contexts.
// Units and groups are global (mint once at startup); each window's
// context instances them independently.
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
//       ctx := niello.context_create()
//       defer niello.context_destroy(ctx)
//       niello_sdl.run(ctx, {title = "My App", width = 800, height = 600}, declare)
//   }
//
//   // More windows, from inside any declare proc or anywhere else:
//   //   inspector := niello_sdl.open_window(ctx2, {title = "Inspector"}, declare2)
//   //   niello_sdl.close_window(inspector)
package sdl

import "core:fmt"
import "core:os"
import "core:strings"
import "base:runtime"
import sdl "vendor:sdl3"
import niello "../"

// App_Config describes a window. Fields not set get sensible defaults.
App_Config :: struct {
	title:  string, // window title
	width:  i32,    // initial width in pixels (DIP at scale 1)
	height: i32,    // initial height in pixels (DIP at scale 1)
	flags:  sdl.WindowFlags,
}

// Declare_Proc is a window's UI: it runs between frame_begin and
// frame_end, with that window's context bound.
Declare_Proc :: #type proc()

// Window_Id identifies a glue window: the main window from run() and
// every open_window() result. Glue-issued, stable for the window's
// life; pass it back to close_window().
Window_Id :: distinct u32

// Glue_Window is one window's full glue state: everything that used
// to be a package-level g_* for the single window, per window now.
@(private)
Glue_Window :: struct {
	id:       Window_Id,
	sdl_win:  ^sdl.Window,
	sdl_id:   sdl.WindowID,
	ctx:      ^niello.Context,
	title:    string, // the config title (window_list's label)
	nui:      Window, // backend handle (ffi.odin)
	declare:  Declare_Proc,
	// input accumulators, consumed by this window's next frame
	mouse:         niello.Vec2,
	mouse_valid:   bool, // cursor over the window; set by motion/button/wheel, cleared on leave
	focused:       bool, // SDL keyboard focus; assumed true until SDL says otherwise
	buttons_down:     niello.Buttons,
	buttons_pressed:  niello.Buttons, // edges latched since the last frame
	buttons_released: niello.Buttons,
	wheel:         niello.Vec2, // accumulated since the last frame
	keys:          [16]niello.Key_Event,
	key_count:     int,
	text_buf:      [dynamic]u8, // committed text since the last frame (UTF-8)
	// sizing + presentation
	pixel_width:   i32,
	pixel_height:  i32,
	pending_size:  bool,
	content_scale: f32,
	wayland:       bool,
	force_render:  bool,
	// loop bookkeeping
	last_changed:   bool, // last frame_end's changed; idle windows are not framed
	last_next_wake: u32,  // last frame_end's next_wake_ms
	last_frame_ns:  u64,  // when this window last framed (its own dt source)
	targeted:       bool, // an event arrived for this window since its last frame
	dead:           bool, // close requested; teardown at the next safe point
	cursor_applied: niello.Cursor_Kind,
	trace_focused:  bool,
}

// Package state, owned by the loop below.
@(private)
g_windows: [dynamic]^Glue_Window

// Window_Info is one live window as tooling sees it: its engine
// context and its title.
Window_Info :: struct {
	ctx:   ^niello.Context,
	title: string,
}

@(private)
g_window_infos: [dynamic]Window_Info

// window_list returns the live windows in creation order
// (closing ones excluded) as borrowed scratch — valid until the
// next call. Its consumer is the debugger (niello/debugui):
// targets are WINDOWS, not contexts. A closed window's context
// can outlive it in the engine registry (contexts are the app's
// to destroy), and the debugger must stop offering the window
// the moment it closes.
window_list :: proc() -> []Window_Info {
	clear(&g_window_infos)
	for win in g_windows {
		if !win.dead {
			append(&g_window_infos, Window_Info{ctx = win.ctx, title = win.title})
		}
	}
	return g_window_infos[:]
}
@(private)
Pending_Open :: struct {
	id:      Window_Id,
	ctx:     ^niello.Context,
	config:  App_Config,
	declare: Declare_Proc,
}
@(private)
g_pending_open: [dynamic]Pending_Open
@(private)
g_pending_close: [dynamic]Window_Id
@(private)
g_next_id: Window_Id = 1
@(private)
g_cursors: [niello.Cursor_Kind]^sdl.Cursor // lazily created system cursors (process-wide)
@(private)
g_input_trace: bool // NUI_INPUT_TRACE: log button edges + focus flips
@(private)
g_wake_event_type: u32 = max(u32) // SDL user event type for context_wake

// content_scale computes device pixels per DIP point for a window.
@(private)
content_scale :: proc(win: ^Glue_Window) -> f32 {
	px_w, px_h: i32
	sdl.GetWindowSizeInPixels(win.sdl_win, &px_w, &px_h)
	pt_w, pt_h: i32
	sdl.GetWindowSize(win.sdl_win, &pt_w, &pt_h)
	if pt_w > 0 && px_w > 0 {
		return f32(px_w) / f32(pt_w)
	}
	return 1
}

// native_handles_for_window queries the platform window handles via
// SDL_GetWindowProperties. The C++ backend takes these instead of the
// SDL_Window, so it never links or includes SDL. Exported: embedders
// driving their own loop (see examples/twowin_smoke) need it too.
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
find_sdl :: proc(id: sdl.WindowID) -> ^Glue_Window {
	for win in g_windows {
		if win.sdl_id == id {
			return win
		}
	}
	return nil
}

@(private)
find_id :: proc(id: Window_Id) -> ^Glue_Window {
	for win in g_windows {
		if win.id == id {
			return win
		}
	}
	return nil
}

// create_window_now builds one window end to end (SDL window, backend
// surface, text input) and adds it to the table.
@(private)
create_window_now :: proc(id: Window_Id, ctx: ^niello.Context, config: App_Config, declare: Declare_Proc) -> bool {
	title := config.title if config.title != "" else "Niello App"
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	w := config.width if config.width > 0 else 800
	h := config.height if config.height > 0 else 600
	flags := config.flags + {.RESIZABLE}
	sdl_win := sdl.CreateWindow(ctitle, w, h, flags)
	if sdl_win == nil {
		fmt.printf("sdl.CreateWindow failed: %s\n", sdl.GetError())
		return false
	}

	// Text input on, always (desktop): without it, SDL never sends
	// TEXT_INPUT — and dead keys never compose. The core routes the
	// committed text to the focused instance (§3.17).
	_ = sdl.StartTextInput(sdl_win)

	handles := native_handles_for_window(sdl_win)
	px_w, px_h: i32
	sdl.GetWindowSizeInPixels(sdl_win, &px_w, &px_h)
	nui := create_window(&handles, u32(max(px_w, 0)), u32(max(px_h, 0)))
	if nui == nil {
		fmt.println("nui_create_window failed")
		sdl.DestroyWindow(sdl_win)
		return false
	}

	win := new(Glue_Window)
	win^ = Glue_Window{
		id             = id,
		title          = title,
		sdl_win        = sdl_win,
		sdl_id         = sdl.GetWindowID(sdl_win),
		ctx            = ctx,
		nui            = nui,
		declare        = declare,
		focused        = true,
		pixel_width    = px_w,
		pixel_height   = px_h,
		wayland        = handles.driver == "wayland",
		force_render   = true,
		last_changed   = true,
		last_next_wake = max(u32),
		last_frame_ns  = sdl.GetTicksNS(),
		cursor_applied = .Arrow,
		trace_focused  = true,
	}
	win.content_scale = content_scale(win)

	// Seed the refresh rate for the backend's present pacing.
	display := sdl.GetDisplayForWindow(sdl_win)
	if display != 0 {
		mode := sdl.GetCurrentDisplayMode(display)
		if mode != nil && mode.refresh_rate > 0 {
			set_refresh_rate(nui, mode.refresh_rate)
		}
	}

	append(&g_windows, win)
	return true
}

// destroy_window_now tears one window down (backend surface first,
// then the SDL window). The engine context is the APP's — the glue
// never destroys it.
@(private)
destroy_window_now :: proc(win: ^Glue_Window) {
	destroy_window(win.nui)
	sdl.DestroyWindow(win.sdl_win)
	delete(win.text_buf)
	for w, i in g_windows {
		if w == win {
			ordered_remove(&g_windows, i)
			break
		}
	}
	free(win)
}

// apply_pending runs the deferred open/close queues: opens first (a
// window opened and closed in the same pass still dies correctly),
// then closes + close-requested deaths. Called at the top of every
// iterate, so a declare proc can open/close windows mid-frame and
// the table only changes between frame passes.
@(private)
apply_pending :: proc() {
	for p in g_pending_open {
		create_window_now(p.id, p.ctx, p.config, p.declare)
	}
	clear(&g_pending_open)
	for id in g_pending_close {
		if win := find_id(id); win != nil {
			win.dead = true
		}
	}
	clear(&g_pending_close)
	// Sweep the dead, back to front (destroy mutates the table).
	for i := len(g_windows) - 1; i >= 0; i -= 1 {
		if g_windows[i].dead {
			destroy_window_now(g_windows[i])
		}
	}
}

// open_window queues a new window with its own context and declare
// proc. The window is created at the next loop pass — calling this
// from inside a declare proc is the intended use (a button that
// opens an inspector). The returned id is valid immediately.
open_window :: proc(ctx: ^niello.Context, config: App_Config, declare: Declare_Proc) -> Window_Id {
	id := g_next_id
	g_next_id += 1
	append(&g_pending_open, Pending_Open{id = id, ctx = ctx, config = config, declare = declare})
	return id
}

// close_window queues a window's teardown. Default close policy: an
// OS close request closes that window; when the last window goes,
// run() returns.
close_window :: proc(id: Window_Id) {
	append(&g_pending_close, id)
}

@(private)
sdl_init :: proc() -> sdl.AppResult {
	if !sdl.SetAppMetadata("Niello App", "1.0", "com.niello.app") {
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

	// Wire text measurement to the native backend (Skia), then init
	// the shared device side. Windows create their surfaces on it
	// per window (M2).
	// Backend hooks are wired at package init (ffi.odin), so
	// image loads work before run().
	if init() != 0 {
		fmt.println("nui_init failed")
		return .FAILURE
	}

	// context_wake plumbing: a user event type the wake hook pushes
	// from any thread to interrupt the loop's event wait. Registration
	// failing leaves wake_hook nil — a wake then only flags the core
	// and discovery waits for the next natural wake.
	g_wake_event_type = sdl.RegisterEvents(1)
	if g_wake_event_type != max(u32) {
		niello.wake_hook = glue_wake
	}

	return .CONTINUE
}

// window_due decides whether a window frames this pass: it was
// event-targeted, its last frame changed something (animations,
// glides), a resize is pending, a render is forced, its engine
// deadline has arrived, or a context_wake is outstanding. An idle
// window that is not due costs nothing — it is not framed at all.
@(private)
window_due :: proc(win: ^Glue_Window, now_ns: u64) -> bool {
	if win.force_render || win.pending_size || win.last_changed || win.targeted {
		return true
	}
	if niello.wake_pending(win.ctx) {
		return true
	}
	if win.last_next_wake != max(u32) {
		elapsed_ms := (now_ns - win.last_frame_ns) / 1_000_000
		if elapsed_ms >= u64(win.last_next_wake) {
			return true
		}
	}
	return false
}

// frame_window runs one window's frame pass (the old single-window
// app_iterate body, parameterized).
@(private)
frame_window :: proc(win: ^Glue_Window, now_ns: u64) {
	// Events only retain the latest size; layout follows the single reconfiguration.
	if win.pending_size {
		resize(win.nui, u32(max(win.pixel_width, 0)), u32(max(win.pixel_height, 0)))
		win.content_scale = content_scale(win)
		win.pending_size = false
		win.force_render = true
	}
	if win.pixel_width <= 0 || win.pixel_height <= 0 || .MINIMIZED in sdl.GetWindowFlags(win.sdl_win) {
		// Nothing can change while minimized; the loop wakes on the
		// restore/resize event.
		win.last_changed = false
		win.targeted = false
		return
	}

	dt := f32(now_ns - win.last_frame_ns) / 1e9
	win.last_frame_ns = now_ns

	pt_w, pt_h: i32
	sdl.GetWindowSize(win.sdl_win, &pt_w, &pt_h)
	input := niello.Input{
		viewport         = {f32(pt_w), f32(pt_h)},
		mouse            = win.mouse,
		mouse_valid      = win.mouse_valid,
		buttons_down     = win.buttons_down,
		buttons_pressed  = win.buttons_pressed,
		buttons_released = win.buttons_released,
		wheel            = win.wheel,
		keys             = win.keys,
		key_count        = win.key_count,
		text             = string(win.text_buf[:]),
		window_focused   = win.focused,
	}
	if g_input_trace &&
	   (input.buttons_pressed != {} ||
		   input.buttons_released != {} ||
		   input.window_focused != win.trace_focused) {
		fmt.printf(
			"input-trace[%d]: focused=%v valid=%v pressed=%v released=%v mouse=(%.0f,%.0f)\n",
			u32(win.id),
			input.window_focused,
			input.mouse_valid,
			input.buttons_pressed,
			input.buttons_released,
			input.mouse.x,
			input.mouse.y,
		)
		win.trace_focused = input.window_focused
	}

	// Edges and accumulations are per-frame: this frame_begin consumes them.
	win.buttons_pressed = {}
	win.buttons_released = {}
	win.wheel = {}
	win.key_count = 0
	win.targeted = false

	niello.frame_begin(win.ctx, input, dt)
	// frame_begin copied the committed text into the core's own
	// buffer; the accumulation starts over.
	clear(&win.text_buf)
	win.declare()
	result := niello.frame_end()

	// The cursor is process-global in SDL: only the window currently
	// holding the pointer gets to set it.
	if win.mouse_valid && result.cursor != win.cursor_applied {
		apply_cursor(result.cursor)
		win.cursor_applied = result.cursor
	}

	if result.changed || win.force_render {
		cmds := niello.draw_list()
		win.force_render = render(win.nui, raw_data(cmds), i32(len(cmds)), nil, 0, win.content_scale) == 0
	} else if win.wayland {
		if present_cached(win.nui) == 0 {
			// Retry through a complete current frame after a failed update/acquire.
			win.force_render = true
		}
	}
	// No idle delay here: an unchanged frame makes run()'s loop block
	// on events until the nearest deadline across windows (§3.3).

	win.last_changed = result.changed
	win.last_next_wake = result.next_wake_ms
}

@(private)
app_iterate :: proc() -> sdl.AppResult {
	apply_pending()
	if len(g_windows) == 0 {
		return .FAILURE // the last window closed: run() returns
	}
	now_ns := sdl.GetTicksNS()
	for win in g_windows {
		if window_due(win, now_ns) {
			frame_window(win, now_ns)
		}
	}
	return .CONTINUE
}

// route returns the window an event belongs to (nil for app-level
// events), marking it targeted: any event aimed at a window makes
// that window due a frame.
@(private)
route :: proc(event: ^sdl.Event) -> ^Glue_Window {
	id: sdl.WindowID
	#partial switch event.type {
	case .WINDOW_SHOWN, .WINDOW_HIDDEN, .WINDOW_EXPOSED, .WINDOW_MOVED,
	     .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_MINIMIZED,
	     .WINDOW_MAXIMIZED, .WINDOW_RESTORED, .WINDOW_MOUSE_ENTER,
	     .WINDOW_MOUSE_LEAVE, .WINDOW_FOCUS_GAINED, .WINDOW_FOCUS_LOST,
	     .WINDOW_CLOSE_REQUESTED, .WINDOW_DISPLAY_CHANGED,
	     .WINDOW_DISPLAY_SCALE_CHANGED:
		id = event.window.windowID
	case .MOUSE_MOTION:
		id = event.motion.windowID
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		id = event.button.windowID
	case .MOUSE_WHEEL:
		id = event.wheel.windowID
	case .KEY_DOWN, .KEY_UP:
		id = event.key.windowID
	case .TEXT_INPUT:
		id = event.text.windowID
	case:
		return nil
	}
	win := find_sdl(id)
	if win != nil {
		win.targeted = true
	}
	return win
}

@(private)
event_callback :: proc(event: ^sdl.Event) -> sdl.AppResult {
	if g_wake_event_type != max(u32) &&
	   transmute(u32)(event.type) == g_wake_event_type {
		// context_wake() from another thread: the frames it asked for
		// are due-checked in the iterate that follows this batch
		// (wake_pending). Nothing else to do.
		if g_input_trace {
			fmt.println("input-trace: wake event")
		}
		return .CONTINUE
	}

	if event.type == .QUIT {
		return .FAILURE
	}

	win := route(event)
	if win == nil {
		return .CONTINUE // app-level or a window already gone
	}

	#partial switch event.type {
	case .MOUSE_MOTION:
		// Mouse is in DIP points, matching the viewport niello sees.
		win.mouse = {event.motion.x, event.motion.y}
		win.mouse_valid = true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		if b, ok := mouse_button(event.button.button); ok {
			// Button events carry the position too; keep it fresh even
			// when no motion event preceded the click.
			win.mouse = {event.button.x, event.button.y}
			win.mouse_valid = true
			if event.button.down {
				win.buttons_down += {b}
				win.buttons_pressed += {b}
			} else {
				win.buttons_down -= {b}
				win.buttons_released += {b}
			}
		}
	case .MOUSE_WHEEL:
		x, y := event.wheel.x, event.wheel.y
		if event.wheel.direction == .FLIPPED {
			x, y = -x, -y
		}
		win.wheel += {x, y}
		win.mouse = {event.wheel.mouse_x, event.wheel.mouse_y}
		win.mouse_valid = true
	case .TEXT_INPUT:
		// Committed text (typing, dead-key results, IME commits),
		// accumulated for the next frame's Input.text. Capped: a
		// frame's worth of typing is small; the cap only stops a
		// pathological flood.
		if event.text.text != nil {
			ptr := cast([^]u8)event.text.text
			for j := 0; ptr[j] != 0 && len(win.text_buf) < 1024; j += 1 {
				append(&win.text_buf, ptr[j])
			}
		}
	case .KEY_DOWN, .KEY_UP:
		// Debug summon (TODO #18): in a NIELLO_DEBUG build, F12
		// opens (or retargets) the debugger window for THIS
		// window's context and is consumed — the app never sees
		// it. The hook is niello.debug_summon_hook, set by
		// niello/debugui's install(); with no debugger installed
		// the key is an ordinary key.
		summoned := false
		when niello.NIELLO_DEBUG {
			if event.key.down && !event.key.repeat &&
			   event.key.scancode == .F12 &&
			   niello.debug_summon_hook != nil {
				niello.debug_summon_hook(win.ctx)
				summoned = true
			}
		}
		// Collected now, consumed by the focus pass later. Overflow past
		// the ring is dropped: 16 key events in one frame is a flood, and
		// the oldest are the ones that matter.
		if !summoned && win.key_count < len(win.keys) {
			win.keys[win.key_count] = niello.Key_Event{
				scancode = u32(event.key.scancode),
				keycode  = u32(event.key.key),
				mods     = transmute(u16)(event.key.mod),
				down     = event.key.down,
				repeat   = event.key.repeat,
			}
			win.key_count += 1
		}
	case .WINDOW_MOUSE_ENTER:
		win.mouse_valid = true
	case .WINDOW_MOUSE_LEAVE:
		win.mouse_valid = false
	case .WINDOW_FOCUS_GAINED:
		win.focused = true
	case .WINDOW_FOCUS_LOST:
		win.focused = false
	case .WINDOW_CLOSE_REQUESTED:
		// Default close policy: close this window; run() returns when
		// the table empties. Teardown happens in apply_pending, never
		// mid-event.
		win.dead = true
	case .WINDOW_PIXEL_SIZE_CHANGED:
		win.pixel_width, win.pixel_height = event.window.data1, event.window.data2
		win.pending_size = true
	case .WINDOW_DISPLAY_SCALE_CHANGED, .WINDOW_RESTORED, .WINDOW_EXPOSED:
		sdl.GetWindowSizeInPixels(win.sdl_win, &win.pixel_width, &win.pixel_height)
		win.pending_size = true
	case .WINDOW_DISPLAY_CHANGED:
		sdl.GetWindowSizeInPixels(win.sdl_win, &win.pixel_width, &win.pixel_height)
		win.pending_size = true
		display := sdl.GetDisplayForWindow(win.sdl_win)
		if display != 0 {
			mode := sdl.GetCurrentDisplayMode(display)
			if mode != nil && mode.refresh_rate > 0 {
				set_refresh_rate(win.nui, mode.refresh_rate)
			}
		}
	}

	return .CONTINUE
}

@(private)
app_quit :: proc() {
	// Copy the table: destroy_window_now mutates it.
	wins := make([]^Glue_Window, len(g_windows))
	copy(wins, g_windows[:])
	for win in wins {
		destroy_window_now(win)
	}
	delete(wins)
	shutdown()
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

// loop_timeout: how long run()'s loop may block before the next
// iterate. 0 = iterate immediately (some window is hot, or work is
// queued), -1 = block until an event arrives (every window idle with
// no deadline), otherwise the nearest window deadline.
@(private)
loop_timeout :: proc() -> i32 {
	if len(g_pending_open) > 0 || len(g_pending_close) > 0 {
		return 0
	}
	now_ns := sdl.GetTicksNS()
	best: i32 = -1
	for win in g_windows {
		if win.pending_size || win.force_render || win.last_changed || win.targeted || win.dead {
			return 0
		}
		if niello.wake_pending(win.ctx) {
			return 0
		}
		if win.last_next_wake != max(u32) {
			elapsed_ms := (now_ns - win.last_frame_ns) / 1_000_000
			remaining: u64 = 0
			if elapsed_ms < u64(win.last_next_wake) {
				remaining = u64(win.last_next_wake) - elapsed_ms
			}
			r := i32(min(remaining, u64(max(i32))))
			if best < 0 || r < best {
				best = r
			}
		}
	}
	return best
}

// run opens the main window (on the app's context) and drives the
// frame loop until the last window closes or the app quits.
//
// The loop is hand-driven — the SDL_App* entry points, restructured
// as plain procs called from here instead of EnterAppMainCallbacks —
// so the idle path can BLOCK: when every window's last frame changed
// nothing and no resize is pending, the loop waits in
// SDL_WaitEventTimeout until the next OS event or the nearest engine
// deadline across windows, so idle windows sit at ~0% CPU (§3.3). Any
// event, including the wake user event, cuts the wait short. Desktop
// targets only: platforms where SDL must own main() (web, consoles)
// are not NielloUI targets.
run :: proc(ctx: ^niello.Context, config: App_Config, declare: Declare_Proc) {
	if sdl_init() != .CONTINUE {
		sdl.Quit()
		return
	}
	main_id := g_next_id
	g_next_id += 1
	if !create_window_now(main_id, ctx, config, declare) {
		app_quit()
		sdl.Quit()
		return
	}

	res := sdl.AppResult.CONTINUE
	ev: sdl.Event
	for res == .CONTINUE {
		timeout := loop_timeout()
		if timeout < 0 {
			if sdl.WaitEvent(&ev) {
				res = event_callback(&ev)
			}
		} else if timeout > 0 {
			if sdl.WaitEventTimeout(&ev, timeout) {
				res = event_callback(&ev)
			}
		}
		// Drain whatever else is queued — on EVERY pass, including
		// timeout == 0, where nothing was waited on. This drain used to
		// run only after a blocking wait returned an event, so a streak
		// of changed frames never pumped the queue at all: animations
		// hold `changed` true for their whole duration, and mouse input
		// (hover, clicks) starved until the streak ended.
		for res == .CONTINUE && sdl.PollEvent(&ev) {
			res = event_callback(&ev)
		}
		if res == .CONTINUE {
			res = app_iterate()
		}
	}
	app_quit()
}
