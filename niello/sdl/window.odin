package sdl

import "core:image"
import "core:image/png"
import "core:strings"
import sdl "vendor:sdl3"

// ============ the app and its windows ============

// set_app_settings describes the app to the desktop and to assistive
// technology (see App_Settings). Call it before run; later calls do not
// reach the desktop.
//
//	niello_sdl.set_app_settings({name = "Notes", id = "com.example.notes"})
set_app_settings :: proc(s: App_Settings) {
	delete(g_app.name)
	delete(g_app.id)
	delete(g_app.version)
	g_app = s
	g_app.name = strings.clone(s.name)
	g_app.id = strings.clone(s.id)
	g_app.version = strings.clone(s.version)
}

// quit ends run at the next loop pass, closing every window. It does not
// ask: windows with confirm_close close too. To ask first, request the
// close yourself and quit once the user agrees.
quit :: proc() {
	g_quit = true
}

// main_window is the window run opened.
main_window :: proc() -> Window_Id {
	return g_main_id
}

// current_window is the window whose declare proc is running (0 outside
// one), so a component can act on the window it is declared in.
current_window :: proc() -> Window_Id {
	return g_current_id
}

// close_requested reports that the user asked to close window id (its close
// button, Alt+F4, the app quitting), for one frame. Only a window opened
// with confirm_close reports this; it stays open until the app calls
// close_window. Like a popup's dismiss_requested, the request is reported,
// never acted on by itself.
//
//	if niello_sdl.close_requested(niello_sdl.current_window()) {
//		if app.saved { niello_sdl.close_window(niello_sdl.current_window()) }
//		else { app.asking = true } // show a "discard changes?" dialog
//	}
close_requested :: proc(id: Window_Id) -> bool {
	win := find_id(id)
	return win != nil && win.close_reported
}

// set_window_title changes a window's title.
set_window_title :: proc(id: Window_Id, title: string) {
	if win := find_id(id); win != nil {
		delete(win.title)
		win.title = strings.clone(title)
		_ = sdl.SetWindowTitle(win.sdl_win, strings.clone_to_cstring(title, context.temp_allocator))
	} else if p := find_pending(id); p != nil {
		delete(p.config.title)
		p.config.title = strings.clone(title)
	}
}

// set_window_icon sets a window's icon from PNG bytes, and reports whether
// they decode. Windows and X11 show it in the title bar and taskbar. On
// Wayland the desktop takes the icon from the app's .desktop file, matched
// by App_Settings.id; a window icon shows only where the compositor
// supports per-window icons.
set_window_icon :: proc(id: Window_Id, png_bytes: []byte) -> bool {
	if win := find_id(id); win != nil {
		return apply_icon(win.sdl_win, png_bytes)
	}
	if p := find_pending(id); p != nil {
		img, err := png.load_from_bytes(png_bytes, {.info})
		if err != nil {
			return false
		}
		image.destroy(img)
		delete(p.config.icon)
		p.config.icon = clone_bytes(png_bytes)
		return true
	}
	return false
}

// maximize_window maximizes a window.
maximize_window :: proc(id: Window_Id) {
	if win := find_id(id); win != nil {
		_ = sdl.MaximizeWindow(win.sdl_win)
	} else if p := find_pending(id); p != nil {
		p.config.maximized = true
	}
}

// minimize_window minimizes a window. A window that open_window has queued
// but not yet opened is not affected.
minimize_window :: proc(id: Window_Id) {
	if win := find_id(id); win != nil {
		_ = sdl.MinimizeWindow(win.sdl_win)
	}
}

// restore_window returns a maximized or minimized window to its normal size
// and position.
restore_window :: proc(id: Window_Id) {
	if win := find_id(id); win != nil {
		_ = sdl.RestoreWindow(win.sdl_win)
	} else if p := find_pending(id); p != nil {
		p.config.maximized = false
	}
}

// set_window_fullscreen puts a window into fullscreen (on) or takes it out.
set_window_fullscreen :: proc(id: Window_Id, on: bool) {
	if win := find_id(id); win != nil {
		_ = sdl.SetWindowFullscreen(win.sdl_win, on)
	} else if p := find_pending(id); p != nil {
		p.config.fullscreen = on
	}
}

// raise_window brings a window to the front and asks for keyboard focus.
// The desktop may decline (Wayland generally does unless the app already
// has focus).
raise_window :: proc(id: Window_Id) {
	if win := find_id(id); win != nil {
		_ = sdl.RaiseWindow(win.sdl_win)
	}
}

// window_state reports a window's state: maximized, minimized, fullscreen,
// focused. For a window open_window has queued but not yet opened, it is
// what its config asks for.
window_state :: proc(id: Window_Id) -> (s: Window_States) {
	if win := find_id(id); win != nil {
		flags := sdl.GetWindowFlags(win.sdl_win)
		if .MAXIMIZED in flags {
			s += {.Maximized}
		}
		if .MINIMIZED in flags {
			s += {.Minimized}
		}
		if .FULLSCREEN in flags {
			s += {.Fullscreen}
		}
		if .INPUT_FOCUS in flags {
			s += {.Focused}
		}
	} else if p := find_pending(id); p != nil {
		if p.config.maximized {
			s += {.Maximized}
		}
		if p.config.fullscreen {
			s += {.Fullscreen}
		}
	}
	return
}

// ---- internals ----

@(private)
find_pending :: proc(id: Window_Id) -> ^Pending_Open {
	for &p in g_pending_open {
		if p.id == id {
			return &p
		}
	}
	return nil
}

// app_name is the app's name for the desktop and assistive tools.
@(private)
app_name :: proc(main_title: string) -> string {
	if g_app.name != "" {
		return g_app.name
	}
	if main_title != "" {
		return main_title
	}
	return "Niello App"
}

// request_close handles a close request for one window: with confirm_close
// it is reported to the window's next frame, otherwise the window closes.
@(private)
request_close :: proc(win: ^Glue_Window) {
	if win.confirm_close {
		win.close_pending = true
		win.targeted = true // the report needs a frame
	} else {
		win.dead = true
	}
}

// apply_icon decodes PNG bytes to 8-bit RGBA and sets them as the window's
// icon. SDL copies the pixels.
@(private)
apply_icon :: proc(win: ^sdl.Window, png_bytes: []byte) -> bool {
	img, err := png.load_from_bytes(png_bytes, {.alpha_add_if_missing})
	if err != nil {
		return false
	}
	defer image.destroy(img)
	if img.channels != 4 || img.width <= 0 || img.height <= 0 {
		return false
	}
	pixels := img.pixels.buf[:]
	if img.depth == 16 {
		// 16-bit samples, native byte order: keep the high byte
		wide := ([^]u16)(raw_data(pixels))[:len(pixels) / 2]
		narrow := make([]u8, len(wide), context.temp_allocator)
		for v, i in wide {
			narrow[i] = u8(v >> 8)
		}
		pixels = narrow
	} else if img.depth != 8 {
		return false
	}
	surface := sdl.CreateSurfaceFrom(i32(img.width), i32(img.height), .RGBA32, raw_data(pixels), i32(img.width * 4))
	if surface == nil {
		return false
	}
	defer sdl.DestroySurface(surface)
	return sdl.SetWindowIcon(win, surface)
}
