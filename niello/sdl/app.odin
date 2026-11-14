// Package sdl is NielloUI's host for desktop windows, on SDL3: it opens
// windows, runs the event loop, drives each window's frames (input,
// declare, layout, draw) and renders them through the native Skia backend.
// When nothing changes it sleeps, using no CPU.
//
//	import niello "niello:."
//	import niello_sdl "niello:sdl"
//
//	declare :: proc() {
//		// niello.begin / niello.show …
//	}
//
//	main :: proc() {
//		ctx := niello.context_create()
//		defer niello.shutdown()
//		niello_sdl.run(ctx, {title = "My app", width = 800, height = 600}, declare)
//	}
//
// run's typed form hands your app's state to declare every frame:
// run(ctx, config, declare_app, &app), with
// `declare_app :: proc(app: ^App)`.
// Every window has its own niello context; open_window and close_window add
// and remove windows from anywhere, declare procs included. Closing the main
// window ends the app (App_Settings.independent_windows changes that).
// Importing this package also connects the core's text measurement, image
// decoding and clipboard to the backend and the system.
//
// The app and its windows:
//
//	niello_sdl.set_app_settings({name = "Notes", id = "com.example.notes"})
//	niello_sdl.run(ctx, {title = "Notes", icon = #load("icon.png"), confirm_close = true}, declare)
//
// The id is how the desktop recognises the app (on Wayland it must match
// the app's .desktop file). A window's title, icon, size and state change
// through set_window_title, set_window_icon, maximize_window and the rest;
// window_state reads it back. With confirm_close, closing a window is a
// request the app answers (close_requested, then close_window), so it can
// ask about unsaved work first.
//
// Linking needs the prebuilt native backend for your platform (see
// third_party/native/README.md).
package sdl

import "core:fmt"
import "core:os"
import "core:strings"
import "base:runtime"
import sdl "vendor:sdl3"
import niello "../"

// App_Config describes a window. Fields not set get sensible defaults.
App_Config :: struct {
	title:         string, // the window's title (default "Niello App")
	width, height: i32,    // initial size in DIP (default 800 × 600)
	min_width:     i32,    // the smallest the user can make it, in DIP;
	min_height:    i32,    // 0: no minimum
	fixed_size:    bool,   // the user cannot resize it
	maximized:     bool,   // it opens maximized
	fullscreen:    bool,   // it opens fullscreen
	icon:          []byte, // its icon, as PNG bytes (#load("icon.png")); see
	                       // set_window_icon
	confirm_close: bool,   // a close request (the close button, Alt+F4, the
	                       // app quitting) does not close it: close_requested
	                       // reports the request and the app calls
	                       // close_window when it is ready
}

// App_Settings describes the app as a whole, to the desktop and to
// assistive technology. Set it with set_app_settings before run.
App_Settings :: struct {
	name:    string, // the app's name; unset, the main window's title
	id:      string, // a reverse-DNS id, like "com.example.notes". On Wayland
	                 // it is the app id the desktop matches to the app's
	                 // .desktop file (its taskbar icon and grouping), so it must
	                 // equal that file's name; X11 uses it as the window class.
	                 // Unset, the executable's name.
	version: string,
	// independent_windows: closing the main window leaves the others open,
	// and run returns when the last window closes. By default (false),
	// closing the main window closes every window and run returns.
	independent_windows: bool,
}

// Window_State is a fact about a window the desktop controls.
Window_State :: enum u8 {
	Maximized,
	Minimized,
	Fullscreen,
	Focused, // it has keyboard focus
}

// Window_States is a set of Window_State.
Window_States :: bit_set[Window_State]

// Declare_Proc is a window's UI: it runs between frame_begin and
// frame_end, with that window's context bound. Apps that keep their
// state in a struct instead of package globals pass a typed
// declare proc plus a pointer to the state — see run / open_window.
Declare_Proc :: #type proc()

// Declare is a window's declare proc as the glue stores it: either a
// plain proc, or a typed proc erased to rawptr together with its
// state pointer.
@(private)
Declare :: struct {
	plain: Declare_Proc,
	with:  proc(state: rawptr),
	state: rawptr,
}

@(private)
call_declare :: proc(d: Declare) {
	if d.with != nil {
		d.with(d.state)
	} else if d.plain != nil {
		d.plain()
	}
}

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
	title:    string, // owned; window_list's label and the AT-SPI window name
	nui:      Window, // backend handle (ffi.odin)
	declare:  Declare,
	// input accumulators, consumed by this window's next frame
	mouse:         niello.Vec2,
	mouse_valid:   bool, // cursor over the window; set by motion/button/wheel, cleared on leave
	focused:       bool, // SDL keyboard focus; assumed true until SDL says otherwise
	buttons_down:     niello.Buttons,
	buttons_pressed:  niello.Buttons, // edges latched since the last frame
	buttons_released: niello.Buttons,
	clicks:        u8, // click count of the last left press since the last frame
	wheel:         niello.Vec2, // accumulated since the last frame
	keys:          [dynamic]niello.Key_Event, // key events since the last frame
	text_buf:      [dynamic]u8, // committed text since the last frame (UTF-8)
	// sizing + presentation
	pixel_width:   i32,
	pixel_height:  i32,
	pending_size:  bool,
	content_scale: f32,
	wayland:       bool,
	force_render:  bool,
	was_minimized: bool, // the minimized early-return ran; the first
	                     // live frame after restore re-arms force_render
	render_fails:     int,  // consecutive render failures
	partial_ok:       bool, // the backend honours damage (it said so last render)
	render_retry_ns:  u64,  // backoff: no render attempt before this tick
	// loop bookkeeping
	last_changed:   bool, // last frame_end's changed; idle windows are not framed
	last_next_wake: u32,  // last frame_end's next_wake_ms
	last_frame_ns:  u64,  // when this window last framed (its own dt source)
	targeted:       bool, // an event arrived for this window since its last frame
	dead:           bool, // close requested; teardown at the next safe point
	cursor_applied: niello.Cursor_Kind,
	trace_focused:  bool,
	// close requests (confirm_close)
	confirm_close:  bool,
	close_pending:  bool, // a request arrived; reported by the next frame
	close_reported: bool, // close_requested answers true this frame
	// what this window last sent the AT-SPI exporter
	a11y_sent:      bool,
	a11y_sent_gen:  u64,
	a11y_sent_geom: [4]i32, // x, y, w, h
	a11y_sent_foc:  bool,
	a11y_sent_ttl:  string, // owned
	a11y_sent_ns:   u64,
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

// window_list returns the open windows, in the order they were opened. The
// slice is valid until the next call.
window_list :: proc() -> []Window_Info {
	clear(&g_window_infos)
	for win in g_windows {
		if !win.dead {
			append(&g_window_infos, Window_Info{ctx = win.ctx, title = win.title})
		}
	}
	return g_window_infos[:]
}
// Pending_Open is a window queued by open_window, created at the next
// loop pass. Its config's title and icon are owned copies.
@(private)
Pending_Open :: struct {
	id:      Window_Id,
	ctx:     ^niello.Context,
	config:  App_Config,
	declare: Declare,
}

@(private)
g_app: App_Settings // set_app_settings; strings owned
@(private)
g_main_id: Window_Id // run's window
@(private)
g_current_id: Window_Id // the window whose declare is running
@(private)
g_quit: bool // quit() was called
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
@(private)
g_atspi_live: bool // the AT-SPI exporter is connected (Linux); else nothing reads the mirror

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
@(private)
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
create_window_now :: proc(id: Window_Id, ctx: ^niello.Context, config: App_Config, declare: Declare) -> bool {
	title := config.title if config.title != "" else "Niello App"
	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	w := config.width if config.width > 0 else 800
	h := config.height if config.height > 0 else 600
	flags: sdl.WindowFlags
	if !config.fixed_size {
		flags += {.RESIZABLE}
	}
	if config.maximized {
		flags += {.MAXIMIZED}
	}
	if config.fullscreen {
		flags += {.FULLSCREEN}
	}
	sdl_win := sdl.CreateWindow(ctitle, w, h, flags)
	if sdl_win == nil {
		fmt.printf("sdl.CreateWindow failed: %s\n", sdl.GetError())
		return false
	}
	if config.min_width > 0 || config.min_height > 0 {
		_ = sdl.SetWindowMinimumSize(sdl_win, config.min_width, config.min_height)
	}
	if len(config.icon) > 0 && !apply_icon(sdl_win, config.icon) {
		fmt.println("niello_sdl: the window icon is not a PNG it can decode")
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
		title          = strings.clone(title),
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
		confirm_close  = config.confirm_close,
	}
	win.content_scale = content_scale(win)
	// The accessibility mirror costs upkeep every frame: build it only
	// where an exporter reads it.
	niello.set_a11y(ctx, g_atspi_live)

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
	when ODIN_OS == .Linux {
		atspi_remove_window(i32(u32(win.id)))
	}
	if win.nui != nil {
		destroy_window(win.nui)
	}
	sdl.DestroyWindow(win.sdl_win)
	delete(win.text_buf)
	delete(win.keys)
	delete(win.title)
	delete(win.a11y_sent_ttl)
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
		free_pending(p)
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
//
// Two forms, like run: a plain proc(), or a typed proc(^T) with the
// state pointer it receives every frame. The state must outlive the
// window.
open_window :: proc{open_window_plain, open_window_with}

// open_window_plain is open_window's plain form (a proc declare).
open_window_plain :: proc(ctx: ^niello.Context, config: App_Config, declare: Declare_Proc) -> Window_Id {
	return queue_open(ctx, config, Declare{plain = declare})
}

// open_window_with is open_window's typed form (declare receives ^T every frame).
open_window_with :: proc(ctx: ^niello.Context, config: App_Config, declare: proc(state: ^$T), state: ^T) -> Window_Id {
	return queue_open(ctx, config, Declare{with = transmute(proc(state: rawptr))declare, state = state})
}

@(private)
queue_open :: proc(ctx: ^niello.Context, config: App_Config, declare: Declare) -> Window_Id {
	id := g_next_id
	g_next_id += 1
	owned := config
	owned.title = strings.clone(config.title)
	owned.icon = clone_bytes(config.icon)
	append(&g_pending_open, Pending_Open{id = id, ctx = ctx, config = owned, declare = declare})
	return id
}

@(private)
free_pending :: proc(p: Pending_Open) {
	delete(p.config.title)
	delete(p.config.icon)
}

@(private)
clone_bytes :: proc(b: []byte) -> []byte {
	if len(b) == 0 {
		return nil
	}
	out := make([]byte, len(b))
	copy(out, b)
	return out
}

// close_window closes a window at the next loop pass. Closing the main
// window closes every window and ends run, unless the app set
// independent_windows (App_Settings); then run ends when the last window
// closes.
close_window :: proc(id: Window_Id) {
	append(&g_pending_close, id)
}

@(private)
sdl_init :: proc(main_title: string) -> sdl.AppResult {
	// Unset id: SDL derives one from the executable's name.
	name := app_name(main_title)
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	cversion: cstring = nil
	if g_app.version != "" {
		cversion = strings.clone_to_cstring(g_app.version, context.temp_allocator)
	}
	cid: cstring = nil
	if g_app.id != "" {
		cid = strings.clone_to_cstring(g_app.id, context.temp_allocator)
	}
	if !sdl.SetAppMetadata(cname, cversion, cid) {
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

// atspi_sync_window publishes one window's semantics mirror to
// the native AT-SPI exporter (TODO #23 M2, Linux only; no-op
// elsewhere and while the exporter is inert). Runs after every
// frame_end: the mirror strings borrow entry storage valid until
// the next frame_end, and the exporter copies what it keeps, so
// borrowing across this call is sound. Screen position is
// best-effort: Wayland does not report it, so screen-coordinate
// answers degrade to window-relative there (window coordinates
// stay exact).
@(private)
atspi_sync_window :: proc(win: ^Glue_Window) {
	when ODIN_OS == .Linux {
		if !g_atspi_live {
			return
		}
		// Send only what changed: the tree (its generation), the
		// window's title, geometry or focus. The exporter re-publishes
		// from scratch after it reconnects to a restarted bus, and it
		// attempts that reconnect inside a sync at most every 5 s, so an
		// unchanged window still syncs that often while it frames.
		wx0, wy0, w0, h0: i32
		sdl.GetWindowPosition(win.sdl_win, &wx0, &wy0)
		sdl.GetWindowSize(win.sdl_win, &w0, &h0)
		geom := [4]i32{wx0, wy0, w0, h0}
		gen := niello.a11y_generation(win.ctx)
		now := sdl.GetTicksNS()
		if win.a11y_sent && win.a11y_sent_gen == gen && win.a11y_sent_geom == geom &&
		   win.a11y_sent_foc == win.focused && win.a11y_sent_ttl == win.title &&
		   now - win.a11y_sent_ns < 5_000_000_000 {
			return
		}
		win.a11y_sent = true
		win.a11y_sent_gen = gen
		win.a11y_sent_geom = geom
		win.a11y_sent_foc = win.focused
		win.a11y_sent_ns = now
		if win.a11y_sent_ttl != win.title {
			delete(win.a11y_sent_ttl)
			win.a11y_sent_ttl = strings.clone(win.title)
		}
		nodes := niello.a11y_tree(win.ctx)
		rows := make([]A11y_FFI_Node, len(nodes), context.temp_allocator)
		for node, i in nodes {
			rows[i] = A11y_FFI_Node{
				id          = u64(node.instance),
				parent      = i32(node.parent),
				role        = u32(node.role),
				name        = a11y_ffi_str_ptr(node.name),
				description = a11y_ffi_str_ptr(node.description),
				flags       = a11y_ffi_flags(node.flags),
				state       = a11y_ffi_state(node.state),
				x           = node.rect.pos.x,
				y           = node.rect.pos.y,
				w           = node.rect.size.x,
				h           = node.rect.size.y,
				has_value   = 1 if node.value.has_num else 0,
				value_num   = node.value.num,
				value_min   = node.value.min,
				value_max   = node.value.max,
				value_text  = a11y_ffi_str_ptr(node.value.text),
				name_len        = u32(len(node.name)),
				description_len = u32(len(node.description)),
				value_text_len  = u32(len(node.value.text)),
			}
		}
		wx, wy: i32
		_ = sdl.GetWindowPosition(win.sdl_win, &wx, &wy)
		pt_w, pt_h: i32
		sdl.GetWindowSize(win.sdl_win, &pt_w, &pt_h)
		title := strings.clone_to_cstring(win.title, context.temp_allocator)
		atspi_sync(i32(u32(win.id)), raw_data(rows), i32(len(rows)), title, wx, wy, pt_w, pt_h, 1 if win.focused else 0)
	}
}

// window_minimized reports whether a window can paint at all right
// now: no pixels, or the OS says minimized.
@(private)
window_minimized :: proc(win: ^Glue_Window) -> bool {
	return win.pixel_width <= 0 || win.pixel_height <= 0 || .MINIMIZED in sdl.GetWindowFlags(win.sdl_win)
}

// frame_window runs one window's frame pass (the old single-window
// app_iterate body, parameterized).
@(private)
frame_window :: proc(win: ^Glue_Window, now_ns: u64) {
	if window_minimized(win) {
		// Nothing can change while minimized; the loop wakes on the
		// restore/resize event. A pending size is dropped, not
		// consumed: it is stale by restore time and the restore
		// brings fresh size events. force_render is cleared too —
		// left armed it kept window_due true and loop_timeout at 0
		// for the whole minimization: a busy spin.
		// The first live frame after restore re-arms it below (a
		// restored window must repaint regardless), and the frame
		// clock restarts there, so dt never spans the minimization.
		win.pending_size = false
		win.force_render = false
		win.last_changed = false
		win.targeted = false
		win.was_minimized = true
		win.last_frame_ns = now_ns
		return
	}
	if win.was_minimized {
		win.was_minimized = false
		win.force_render = true
		win.last_frame_ns = now_ns
	}
	// Events only retain the latest size; layout follows the single reconfiguration.
	if win.pending_size {
		resize(win.nui, u32(max(win.pixel_width, 0)), u32(max(win.pixel_height, 0)))
		win.content_scale = content_scale(win)
		win.pending_size = false
		win.force_render = true
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
		clicks           = win.clicks,
		wheel            = win.wheel,
		keys             = win.keys[:],
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
	win.clicks = 0
	win.wheel = {}
	win.targeted = false

	niello.frame_begin(win.ctx, input, dt)
	// frame_begin copied the keys and the committed text into the
	// core's own buffers; the accumulation starts over.
	clear(&win.keys)
	clear(&win.text_buf)
	win.close_reported = win.close_pending
	win.close_pending = false
	g_current_id = win.id
	call_declare(win.declare)
	g_current_id = 0
	win.close_reported = false
	result := niello.frame_end()
	atspi_sync_window(win)

	// The cursor is process-global in SDL: only the window currently
	// holding the pointer gets to set it.
	if win.mouse_valid && result.cursor != win.cursor_applied {
		apply_cursor(result.cursor)
		win.cursor_applied = result.cursor
	}

	// Changed, but nothing visible to repaint (everything that changed is
	// clipped away or off the window): a backend that keeps its pixels
	// needs no frame at all.
	nothing_visible := result.changed && !win.force_render && win.partial_ok && len(result.repaint) == 0
	if (result.changed || win.force_render) && !nothing_visible {
		// During a render-failure backoff the frame still runs;
		// only the backend call waits for its deadline.
		if now_ns >= win.render_retry_ns {
			// Partial repaint: only what changed, over the backend's
			// cache, once the backend has said it honours damage, and
			// never when a full frame is owed (first frame, resize,
			// expose, a failed render).
			rects: []niello.Rect
			if win.partial_ok && !win.force_render && len(result.repaint) > 0 {
				rects = result.repaint
			}
			cmds := niello.draw_list(rects)
			rc := render(win.nui, raw_data(cmds), i32(len(cmds)), raw_data(rects), i32(len(rects)), win.content_scale)
			if rc == RENDER_NEED_FULL {
				// The backend lost its cache: send everything now.
				cmds = niello.draw_list()
				rc = render(win.nui, raw_data(cmds), i32(len(cmds)), nil, 0, win.content_scale)
			}
			win.partial_ok = rc == RENDER_PRESENTED_DAMAGE
			if rc == RENDER_PRESENTED || rc == RENDER_PRESENTED_DAMAGE {
				win.force_render = false
				win.render_fails = 0
				win.render_retry_ns = 0
			} else {
				win.force_render = true
				note_render_failure(win, now_ns)
			}
		}
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

	// Settle frame: this frame consumed input edges (a click, a
	// key, wheel, committed text). Handlers run during declare —
	// clicked() and friends — and the app state they mutate only
	// takes visual effect in the NEXT declare. If this frame
	// itself changed nothing, nothing else schedules that next
	// frame: the loop sleeps until an unrelated event arrives,
	// and the click's effect sits invisible until the cursor
	// moves (seen in the a11y and popups demos, 2026-11-04). Re-arm
	// targeted for exactly one follow-up frame; that frame
	// consumes no new edges, so the chain ends there. Motion is
	// deliberately excluded: hover is same-frame state, and a
	// motion stream keeps the loop awake on its own.
	if input.buttons_pressed != {} || input.buttons_released != {} ||
	   input.wheel != {0, 0} || len(input.keys) > 0 || len(input.text) > 0 {
		win.targeted = true
	}
}

// RENDER_FAIL_LIMIT: consecutive render failures tolerated before
// the run ends (ruling F4(a) AS AMENDED 2026-11-04).
@(private)
RENDER_FAIL_LIMIT :: 5

// note_render_failure advances one window's failure escalation:
// exponential backoff from 100 ms capped at 1 s between attempts;
// at the limit the failure is terminal — the window dies and run()
// reports Render_Failed rather than spinning on a permanently
// broken renderer.
//
// The original F4(a) ladder had a backend recreate between the
// backoff and the terminal step. His popups gate run (2026-11-04)
// proved it fatal on Wayland: the recreate destroyed the backend
// window and created a new one on the same SDL window, and KWin
// killed the connection — "surface already exists" from the
// linux-drm-syncobj manager, because the old surface was still
// compositor-registered when the new one asked for its syncobj
// surface. It was also mis-aimed: nui_create_window refuses when
// the device tier is latched, so the recreate could only ever
// succeed while the device was healthy and the failure local or
// transient — exactly what backoff-and-retry already covers. On
// that basis the recreate is gone; the surface tier's own in-place
// recreation (native) remains the window-local recovery.
@(private)
note_render_failure :: proc(win: ^Glue_Window, now_ns: u64) {
	win.render_fails += 1
	if win.render_fails >= RENDER_FAIL_LIMIT {
		fmt.printfln("nui_sdl: render failed %d times in a row; ending the run", RENDER_FAIL_LIMIT)
		g_run_error = .Render_Failed
		win.dead = true
		return
	}
	delay_ms := u64(min(100 << u32(win.render_fails - 1), 1000))
	fmt.printfln("nui_sdl: render failed (%d/%d); retrying in %d ms", win.render_fails, RENDER_FAIL_LIMIT, delay_ms)
	win.render_retry_ns = now_ns + delay_ms * 1_000_000
}

@(private)
app_iterate :: proc() -> sdl.AppResult {
	apply_pending()
	// quit(), or the main window closed (unless windows are independent):
	// every window goes and run returns.
	if g_quit || (!g_app.independent_windows && find_id(g_main_id) == nil) {
		for win in g_windows {
			win.dead = true
		}
		apply_pending()
		return .FAILURE
	}
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
		// The app is asked to quit (the dock or taskbar, session end,
		// Ctrl+C): a close request on the main window, or on every
		// window when they are independent. confirm_close holds as for
		// any other request.
		for win in g_windows {
			if g_app.independent_windows || win.id == g_main_id {
				request_close(win)
			}
		}
		return .CONTINUE
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
				if b == .Left {
					win.clicks = event.button.clicks
				}
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
		// accumulated for the next frame's Input.text. Nothing is
		// dropped: a paste-sized IME commit arrives whole.
		if event.text.text != nil {
			append(&win.text_buf, string(event.text.text))
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
		// Collected now, consumed by the next frame's focus pass.
		// Nothing is dropped, however many arrive between frames.
		if !summoned {
			append(&win.keys, key_event(event.key))
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
		// Teardown happens in apply_pending, never mid-event.
		request_close(win)
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
	when ODIN_OS == .Linux {
		atspi_stop()
	}
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
		// A minimized window contributes nothing:
		// not a 0 (its force_render/wake state would spin the
		// loop) and not a deadline (its frame clock is frozen).
		// The restore event wakes the loop itself.
		if window_minimized(win) {
			continue
		}
		if win.pending_size || win.last_changed || win.targeted || win.dead {
			return 0
		}
		if win.force_render {
			// Armed but backing off: the retry
			// deadline is a wake time, not a spin.
			if now_ns >= win.render_retry_ns {
				return 0
			}
			remaining_ms := (win.render_retry_ns - now_ns) / 1_000_000
			r := i32(min(remaining_ms, u64(max(i32))))
			if best < 0 || r < best {
				best = r
			}
			continue
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

// live_resize_watch — SDL event watch, Windows only.
//
// During a border drag, Windows runs a modal size/move loop inside
// SDL's event pump, so run()'s loop is blocked inside WaitEvent and
// the resize events pile up in the queue: the OS stretches the last
// frame and the window repaints once, on release. SDL's
// countermeasure is that the modal loop emits WINDOW_EXPOSED on a
// 10 ms timer, flagged data1 == 1 for these live-resize exposes —
// and event watches run synchronously as an event is pushed, i.e.
// inside the modal loop. Framing the dragged window from here is
// SDL's documented pattern for traditional loops (wiki:
// AppFreezeDuringDrag). The watched event still lands in the queue
// afterwards; the post-drag pass frames once more at the final size
// through the normal path, which is harmless.
//
// The watch fires for every pushed event, so it stays narrow: only
// a live-resize expose, and a frame only when the pixel size
// actually moved. The size is read back from SDL rather than taken
// from event data: WM_SIZE has already updated it, and a mid-drag
// DPI change (same logical size, new pixels) arrives through the
// same read.
@(private)
live_resize_watch :: proc "c" (userdata: rawptr, event: ^sdl.Event) -> bool {
	context = runtime.default_context()
	if event.type != .WINDOW_EXPOSED || event.window.data1 != 1 {
		return true
	}
	win := find_sdl(event.window.windowID)
	if win == nil || win.dead {
		return true
	}
	px_w, px_h: i32
	sdl.GetWindowSizeInPixels(win.sdl_win, &px_w, &px_h)
	if px_w != win.pixel_width || px_h != win.pixel_height {
		win.pixel_width, win.pixel_height = px_w, px_h
		win.pending_size = true
	}
	if win.pending_size {
		frame_window(win, sdl.GetTicksNS())
	}
	return true
}

// Run_Error is why run stopped when it could not keep going. None is
// every normal exit (the last window closed, the app quit).
Run_Error :: enum {
	None,
	Init_Failed,   // SDL or the main window/backend did not come up
	Render_Failed, // rendering failed through the whole backoff
	               // ladder (the recreate step was
	               // dropped — see note_render_failure)
}

// Set by the loop when it ends abnormally; run() returns it.
@(private)
g_run_error: Run_Error

// run opens the main window for ctx and runs the app until its last window
// closes or the app quits, returning why it stopped (None for a normal
// exit). Each frame it applies the window's input, calls declare, lays the
// window out and draws what changed; when nothing changes it sleeps until
// input arrives or the UI needs a frame (an animation, a timer, a
// context_wake), so an idle app uses no CPU.
//
// Two forms. The plain form takes a proc, and the app keeps its state in
// package variables:
//
//	niello_sdl.run(ctx, config, declare)
//
// The typed form hands a pointer to the app's state to declare every frame:
//
//	App :: struct { count: int }
//	declare :: proc(app: ^App) { … }
//	app: App
//	niello_sdl.run(ctx, config, declare, &app)
run :: proc{run_plain, run_with}

// run_plain is run's plain form (a proc declare).
run_plain :: proc(ctx: ^niello.Context, config: App_Config, declare: Declare_Proc) -> Run_Error {
	return run_impl(ctx, config, Declare{plain = declare})
}

// run_with is run's typed form (declare receives ^T every frame).
run_with :: proc(ctx: ^niello.Context, config: App_Config, declare: proc(state: ^$T), state: ^T) -> Run_Error {
	return run_impl(ctx, config, Declare{with = transmute(proc(state: rawptr))declare, state = state})
}

@(private)
run_impl :: proc(ctx: ^niello.Context, config: App_Config, declare: Declare) -> Run_Error {
	g_run_error = .None
	g_quit = false
	if sdl_init(config.title) != .CONTINUE {
		sdl.Quit()
		return .Init_Failed
	}
	when ODIN_OS == .Linux {
		// Start the AT-SPI exporter (inert when no accessibility bus
		// answers) before the main window: windows build their
		// accessibility mirror only while it is live.
		g_atspi_live = atspi_start(strings.clone_to_cstring(app_name(config.title), context.temp_allocator)) == 1
	}
	main_id := g_next_id
	g_next_id += 1
	g_main_id = main_id
	if !create_window_now(main_id, ctx, config, declare) {
		app_quit()
		sdl.Quit()
		return .Init_Failed
	}
	when ODIN_OS == .Windows {
		// Framing during border drags happens in this watch: the
		// main loop is blocked inside the drag's modal loop then.
		_ = sdl.AddEventWatch(live_resize_watch, nil)
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
		// Reset the temp allocator every iteration:
		// the glue allocates from it per frame — the AT-SPI rows
		// array and window-title cstring in atspi_sync_window, the
		// window title at creation — and nothing reset it, so those
		// allocations accumulated for the process lifetime. Every
		// temp allocation that crosses the FFI is consumed or
		// copied synchronously by the native side (atspi_start and
		// register_font_family copy into std::string,
		// register_font loads the file before returning, and the
		// exporter copies what it keeps from atspi_sync), so
		// nothing borrowed from temp storage escapes an iteration.
		free_all(context.temp_allocator)
	}
	when ODIN_OS == .Windows {
		sdl.RemoveEventWatch(live_resize_watch, nil)
	}
	app_quit()
	return g_run_error
}

// The system clipboard behind niello.clipboard_text / set_clipboard_text
// (text only). Wired at package init like the backend hooks; the calls
// happen during frames, after run has started SDL's video subsystem.
@(private)
@(init)
wire_clipboard_hooks :: proc "contextless" () {
	niello.clipboard_get_hook = hook_clipboard_get
	niello.clipboard_set_hook = hook_clipboard_set
}

@(private)
hook_clipboard_get :: proc(allocator: runtime.Allocator) -> string {
	raw := sdl.GetClipboardText()
	if raw == nil {
		return ""
	}
	defer sdl.free(raw)
	return strings.clone(string(cstring(raw)), allocator)
}

@(private)
hook_clipboard_set :: proc(text: string) {
	ctext := strings.clone_to_cstring(text, context.temp_allocator)
	_ = sdl.SetClipboardText(ctext)
}
