// niello/sdl — SDL3 app glue + FFI bindings to the native render backend.
//
// The native side (see ../../native/nui.h) is a static library exposing a small C
// API: nui_init / nui_create_window / nui_resize / nui_set_refresh_rate /
// nui_render / nui_present_cached / nui_register_font / nui_measure_word /
// nui_line_height / nui_destroy_window / nui_shutdown / nui_gpu_cache_bytes /
// nui_purge_gpu_cache. Multi-window (M2):
// the device + Graphite context are shared; each window renders through
// its own opaque Window handle.
//
// This package type-checks standalone; linking needs the prebuilt native
// backend for your platform (see ../../third_party/native/README.md).
package sdl

import "core:c"
import "core:strings"
import niello "../"

// Draw_Cmd's memory layout IS the FFI ABI (../../native/nui.h mirrors it as
// UiDrawCmd with a static_assert). This fires at compile time if the struct
// ever drifts, so the two sides cannot silently disagree.
#assert(size_of(niello.Draw_Cmd) == 96, "niello.Draw_Cmd must stay 96 bytes: it is the FFI ABI")
#assert(size_of(niello.Rect) == 16, "niello.Rect must stay 16 bytes: it is the FFI ABI")
#assert(size_of(Native_Handles) == size_of(rawptr) * 8, "Native_Handles must match UiNativeHandles")

// System libraries the native backend needs. The static libs
// (nui_render + Skia + Dawn) come from third_party/native/<platform>/
// — see tools/fetch-native.sh — and are found via
// -extra-linker-flags:"-L<path> --start-group ..." until TODO #11's
// merged archive lets this import name the one file by path.
// The codec libs (z/png/jpeg/webp/webpdemux) are here because
// Skia's codec modules reference them; they stayed latent until
// image decode (#13) first pulled the codec objects into a link.
foreign import native {
	"system:nui_render",
	"system:SDL3",
	"system:vulkan",
	"system:freetype",
	"system:fontconfig",
	"system:stdc++",
	"system:z",
	"system:png",
	"system:jpeg",
	"system:webp",
	"system:webpdemux",
}

// Window is the opaque per-window backend handle (nui_window* in C).
Window :: distinct rawptr

// Native window handles for nui_create_window. Mirrors UiNativeHandles in
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
	// Lifecycle (M2): init brings up the SHARED device/context once;
	// create_window makes one window's surface + pixel cache on it. The
	// Odin side owns the OS windows and the event loop.
	init             :: proc() -> c.int ---
	shutdown         :: proc() ---
	create_window    :: proc(handles: ^Native_Handles, width_px, height_px: u32) -> Window ---
	destroy_window   :: proc(win: Window) ---
	resize           :: proc(win: Window, width_px, height_px: u32) ---
	set_refresh_rate :: proc(win: Window, hz: f32) ---
	is_resizing      :: proc(win: Window) -> c.int ---

	present_cached   :: proc(win: Window) -> c.int ---

	// Fully rebuild the window's owned pixel cache. Borrowed commands
	// are never retained.
	render :: proc(
		win: Window,
		cmds: [^]niello.Draw_Cmd, n_cmds: i32,
		damage: [^]niello.Rect, n_damage: i32,
		content_scale: f32, // device pixels per DIP point
	) -> c.int ---

	// Fonts. Families are registered once, cold; the backend caches
	// (family, weight, slant, size) -> SkFont internally. Family 0 is the
	// platform default and needs no registration. The user-facing API is
	// register_font / register_font_family below the foreign block; these
	// raw bindings stay FFI-shaped (u32 + cstring).
	@(link_name = "nui_register_font")
	ffi_register_font        :: proc(family: u32, path: cstring) --- // bundled file
	@(link_name = "nui_register_font_family")
	ffi_register_font_family :: proc(family: u32, name: cstring) --- // system family via the font manager

	// Text measurement through SkShaper. weight is 100-900 (Font_Weight),
	// slant is 0=upright, 1=italic, 2=oblique (Font_Slant order).
	measure_word :: proc(family: u32, weight: i32, slant: i32, size_px: f32, text: [^]u8, len: i64) -> f32 ---
	line_height  :: proc(family: u32, weight: i32, slant: i32, size_px: f32) -> f32 ---

	// Images (TODO #13): decode encoded bytes to a backend image
	// id (0 = failure); release drops it. Ids are never reused.
	image_decode  :: proc(data: [^]u8, len: i32, max_w: i32, max_h: i32, out_w: ^f32, out_h: ^f32) -> u32 ---
	image_release :: proc(id: u32) ---

	// GPU resource cache diagnostics: bytes the shared Graphite
	// context currently counts against its cache budget, and a
	// purge of every purgeable resource (after draining submitted
	// work). For leak hunting: purge between measurements to
	// separate "still cached, evictable" from "actually leaked".
	gpu_cache_bytes :: proc() -> u64 ---
	purge_gpu_cache :: proc() ---
}

// The backend hooks are wired at package init — assignment only,
// no FFI calls — so app code can use hook-backed core services
// (notably image_load, which decodes immediately) before run().
@(init)
wire_backend_hooks :: proc "contextless" () {
	niello.measure_word_hook = hook_measure_word
	niello.line_height_hook = hook_line_height
	niello.decode_image_hook = hook_decode_image
	niello.release_image_hook = hook_release_image
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

// hook_decode_image / hook_release_image adapt the C image procs
// to niello's image hooks (wired next to the measure hooks in
// app.odin's startup).
hook_decode_image :: proc(data: []byte, max_w, max_h: int) -> (backend: u32, w, h: f32, ok: bool) {
	if len(data) == 0 {
		return 0, 0, 0, false
	}
	ow, oh: f32
	id := image_decode(raw_data(data), i32(len(data)), i32(max_w), i32(max_h), &ow, &oh)
	if id == 0 {
		return 0, 0, 0, false
	}
	return id, ow, oh, true
}

hook_release_image :: proc(backend: u32) {
	image_release(backend)
}

// register_font binds a font family id to a font FILE on disk (a bundled
// .ttf/.otf — one file may hold several faces; the backend picks the best
// weight/slant match per use). Use the id as Style.font:
//
//	Inter: niello.Font_Handle = 1
//	niello_sdl.register_font(Inter, "assets/Inter.ttf")
//	niello.mint(&u, niello.NO_UNIT, {font = Inter})
//
// Call before run(), or at least before the family is first measured or
// drawn; registering again replaces the binding. Family 0 is the platform
// default and needs no registration. An unregistered family — or a file
// that fails to load (the backend reports it on stderr) — falls back to
// the default face.
register_font :: proc(family: niello.Font_Handle, path: string) {
	ffi_register_font(u32(family), strings.clone_to_cstring(path, context.temp_allocator))
}

// register_font_family binds a font family id to a SYSTEM font family by
// name ("Inter", "Segoe UI", ...), resolved through the platform font
// manager. Same timing and fallback rules as register_font.
register_font_family :: proc(family: niello.Font_Handle, name: string) {
	ffi_register_font_family(u32(family), strings.clone_to_cstring(name, context.temp_allocator))
}
