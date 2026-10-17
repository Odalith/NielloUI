// niello/sdl — SDL3 app glue + FFI bindings to the native render backend.
//
// The native side (see skiasdl/nui.h) is a static library exposing a small C
// API: nui_init / nui_resize / nui_set_refresh_rate / nui_render /
// nui_register_font / nui_measure_word / nui_line_height / nui_destroy.
//
// This package type-checks standalone; linking needs the prebuilt native
// backend for your platform (see ../../third_party/native/README.md).
package sdl

import "core:c"
import niello "../"

// Draw_Cmd's memory layout IS the FFI ABI (skiasdl/nui.h mirrors it as
// UiDrawCmd with a _Static_assert). This fires at compile time if the struct
// ever drifts, so the two sides cannot silently disagree.
#assert(size_of(niello.Draw_Cmd) == 64, "niello.Draw_Cmd must stay 64 bytes: it is the FFI ABI")
#assert(size_of(niello.Rect) == 16, "niello.Rect must stay 16 bytes: it is the FFI ABI")

// System libraries the native backend needs on every platform.
// The static lib itself (nui_render) comes from
// third_party/native/<platform>/lib — see tools/fetch-native.sh — and is
// found via -extra-linker-flags:"-L<path>".
foreign import native {
	"nui_render",
	"SDL3",
	"vulkan",
	"freetype",
	"fontconfig",
}

@(default_calling_convention = "c", link_prefix = "nui_")
foreign native {
	// Lifecycle. sdl_window is the borrowed ^sdl.Window, passed through as an
	// opaque pointer; the backend reads its native handle via
	// SDL_GetWindowProperties. Returns 0 on success.
	init             :: proc(sdl_window: rawptr) -> c.int ---
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

	// Text. The app wires measure_word/line_height into niello's word cache;
	// they fire on the C++ side through SkShaper, only on cache miss.
	register_font :: proc(handle: u32, path: cstring) ---
	measure_word  :: proc(font: u32, text: [^]u8, len: i64) -> f32 ---
	line_height   :: proc(font: u32) -> f32 ---
}
