// niello/sdl — SDL3 app glue + FFI bindings to the native render backend.
//
// The native side (see ../../native/nui.h) is a static library exposing a small C
// API: nui_init / nui_resize / nui_set_refresh_rate / nui_render /
// nui_register_font / nui_measure_word / nui_line_height / nui_destroy.
//
// This package type-checks standalone; linking needs the prebuilt native
// backend for your platform (see ../../third_party/native/README.md).
package sdl

import "core:c"
import niello "../"

// Draw_Cmd's memory layout IS the FFI ABI (../../native/nui.h mirrors it as
// UiDrawCmd with a static_assert). This fires at compile time if the struct
// ever drifts, so the two sides cannot silently disagree.
#assert(size_of(niello.Draw_Cmd) == 72, "niello.Draw_Cmd must stay 72 bytes: it is the FFI ABI")
#assert(size_of(niello.Rect) == 16, "niello.Rect must stay 16 bytes: it is the FFI ABI")
#assert(size_of(Native_Handles) == size_of(rawptr) * 8, "Native_Handles must match UiNativeHandles")

// System libraries the native backend needs on every platform.
// The static lib itself (nui_render) comes from
// third_party/native/<platform>/lib — see tools/fetch-native.sh — and is
// found via -extra-linker-flags:"-L<path>".
foreign import native {
	"system:nui_render",
	"system:SDL3",
	"system:vulkan",
	"system:freetype",
	"system:fontconfig",
}

// Native window handles for nui_init. Mirrors UiNativeHandles in
// ../../native/nui.h (field order is the ABI). The Odin side queries these
// via SDL_GetWindowProperties; the C++ side never touches SDL.
Native_Handles :: struct {
	driver:         cstring, // "wayland", "x11", "windows", "cocoa"
	wl_display:    rawptr,
	wl_surface:    rawptr,
	x11_display:   rawptr,
	x11_window:    u64,
	win32_hwnd:      rawptr,
	win32_hinstance: rawptr,
	cocoa_layer:   rawptr,
}

@(default_calling_convention = "c", link_prefix = "nui_")
foreign native {
	// Lifecycle. handles carries the platform window handles (see above);
	// width_px/height_px is the initial swapchain size. The Odin side owns
	// the window and the event loop. Returns 0 on success.
	init             :: proc(handles: ^Native_Handles, width_px, height_px: u32) -> c.int ---
	resize           :: proc(width_px, height_px: u32) ---
	set_refresh_rate :: proc(hz: f32) ---
	destroy          :: proc() ---

	// Per frame. cmds/damage borrow the caller's memory and are valid until
	// the next niello.frame_begin (the backend replays them synchronously,
	// and caches the pointers for the Wayland immediate resize render).
	// damage may be nil when n_damage == 0.
	render :: proc(
		cmds: [^]niello.Draw_Cmd, n_cmds: i32,
		damage: [^]niello.Rect, n_damage: i32,
		content_scale: f32, // device pixels per DIP point
	) ---

	// Fonts. Families are registered once, cold; the backend caches
	// (family, weight, slant, size) -> SkFont internally. Family 0 is the
	// platform default and needs no registration.
	register_font        :: proc(family: u32, path: cstring) --- // bundled file
	register_font_family :: proc(family: u32, name: cstring) --- // system family via the font manager

	// Text measurement through SkShaper. weight is 100-900 (Font_Weight),
	// slant is 0=upright, 1=italic, 2=oblique (Font_Slant order).
	measure_word :: proc(family: u32, weight: i32, slant: i32, size_px: f32, text: [^]u8, len: i64) -> f32 ---
	line_height  :: proc(family: u32, weight: i32, slant: i32, size_px: f32) -> f32 ---
}

// hook_measure_word / hook_line_height adapt the C measurement procs to
// niello's backend-hook signature. The app wires them once at startup:
//
//   niello.measure_word_hook = sdl.hook_measure_word
//   niello.line_height_hook  = sdl.hook_line_height
hook_measure_word :: proc(font: niello.Font_Handle, weight: niello.Font_Weight, slant: niello.Font_Slant, size: f32, text: string) -> f32 {
	return measure_word(u32(font), i32(weight), i32(slant), size, raw_data(text), i64(len(text)))
}

hook_line_height :: proc(font: niello.Font_Handle, weight: niello.Font_Weight, slant: niello.Font_Slant, size: f32) -> f32 {
	return line_height(u32(font), i32(weight), i32(slant), size)
}
