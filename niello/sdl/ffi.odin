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
#assert(size_of(A11y_FFI_Node) == 96, "A11y_FFI_Node must match UiA11yNode in ../../native/nui.h (96 bytes)")

// The native backend ships as ONE fat archive per platform
// (nui_native + Skia + Dawn, merged per tools/build-native.md §6),
// fetched by tools/fetch-native.sh into third_party/native/<platform>/.
// Each platform names its archive by path relative to THIS file, so a
// consumer links with a plain `odin run` — no -L flag, no --start-group,
// no symlink. Foreign imports are file-scoped on this Odin vintage, so
// the import must live in this file, next to the `foreign native` block
// below; the platform choice is the `when` chain here, not separate
// files. The system libs are the ones each platform needs beyond the
// archive. Linux keeps the proven set — the codec libs (z/png/jpeg/
// webp/webpdemux) are here because Skia's codec modules reference
// them; they stayed latent until image decode (#13) first pulled the
// codec objects into a link. macOS links the C++ runtime as libc++
// plus the Metal frameworks the archive references (mirroring
// native/CMakeLists.txt); Windows links the D3D12/DirectWrite system
// libs the same way. One exception: on Windows, SDL3 is named by
// relative path like the archive — Odin's system: search there
// matches the sdl3 DIRECTORY in its search path and aborts with
// Error (002): unknown file format "sdl3" (seen on dev-2026-11a), so
// fetch-native.ps1 stages the import library from SDL's official
// devel zip into third_party/sdl3/windows-x64/lib/. The SDK libs
// keep system: but WITH the .lib extension — the form Odin's own
// vendor/directx bindings use — because a bare stem (system:d3d12)
// hits the same directory-matching failure on vendor directx/d3d12.
// onecore.lib rides along for Dawn's OneCore-family Win32 calls
// (CompareObjectHandles, from its D3D12 shared-fence code) — SDK
// 10.0.26100 does not carry that symbol in kernel32.lib. The
// macOS/Windows sets are unproven until the first link on those
// platforms.
when ODIN_OS == .Linux {
	foreign import native {
		"../../third_party/native/linux-x64/lib/libniello_native.a",
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
} else when ODIN_OS == .Darwin {
	foreign import native {
		"../../third_party/native/macos-arm64/lib/libniello_native.a",
		"system:SDL3",
		"system:c++",
		"framework:Metal",
		"framework:Foundation",
		"framework:QuartzCore",
		"framework:CoreGraphics",
		"framework:IOKit",
	}
} else when ODIN_OS == .Windows {
	foreign import native {
		"../../third_party/native/windows-x64/lib/niello_native.lib",
		"../../third_party/sdl3/windows-x64/lib/SDL3.lib",
		"system:d3d12.lib",
		"system:dxgi.lib",
		"system:dxguid.lib",
		"system:dwrite.lib",
		"system:onecore.lib",
	}
}

// Window is the opaque per-window backend handle (nui_window* in C).
@(private)
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

// The raw nui_* bindings are the glue's own: private to this package.
@(default_calling_convention = "c", link_prefix = "nui_", private)
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
	@(link_name = "nui_gpu_cache_bytes")
	ffi_gpu_cache_bytes :: proc() -> u64 ---
	@(link_name = "nui_purge_gpu_cache")
	ffi_purge_gpu_cache :: proc() ---

	// Accessibility export (TODO #23 M2, Linux only): the native
	// AT-SPI exporter (native/atspi.cpp). Foreign declarations
	// alone emit no references, so non-Linux links stay clean;
	// the call sites in app.odin are `when ODIN_OS == .Linux`
	// guarded. The native library must be rebuilt after pulling
	// this (new objects in the static archive).
	atspi_start         :: proc(app_name: cstring) -> c.int ---
	atspi_stop          :: proc() ---
	atspi_sync          :: proc(ctx_id: i32, nodes: [^]A11y_FFI_Node, count: i32, window_title: cstring, win_x, win_y, win_w, win_h, win_focused: i32) ---
	atspi_remove_window :: proc(ctx_id: i32) ---
}

// A11y_FFI_Node is the FFI projection of one mirror node for the
// AT-SPI exporter. Field order IS the ABI (UiA11yNode in
// ../../native/nui.h, statically asserted above). Strings borrow
// the mirror's owned storage: valid until the next frame_end, and
// sync runs inside the same frame pass, so borrowing is sound on
// LIFETIME only — the strings are not NUL-terminated, so each
// pointer's length rides beside it (name_len and friends,
// appended 2026-11-04, audit BL-1) and the native side reads
// pointer + length, never pointer alone.
// Flags/state are built explicitly by the helpers below — a
// bit_set's backing layout is not ABI, so it is never transmuted.
@(private)
A11y_FFI_Node :: struct {
	id:          u64,
	parent:      i32,
	role:        u32, // Odin A11y_Role ordinal (Avalonia order)
	name:        cstring,
	description: cstring,
	flags:       u32, // A11y_Flag bit positions (ORDER IS ABI)
	state:       u32, // A11y_State_Flag bit positions (ORDER IS ABI)
	x, y, w, h:  f32, // DIP, window-relative
	has_value:   i32,
	value_num:   f32,
	value_min:   f32,
	value_max:   f32,
	value_text:  cstring,
	name_len:        u32, // bytes at name (0 when nil)
	description_len: u32, // bytes at description (0 when nil)
	value_text_len:  u32, // bytes at value_text (0 when nil)
}

// a11y_ffi_str_ptr returns the string's data pointer typed as a
// cstring for the ABI struct. It is NOT a C string: no terminator
// is added or promised (audit BL-1). The matching *_len field
// carries the byte count; the native side must use both.
@(private)
a11y_ffi_str_ptr :: proc(s: string) -> cstring {
	if len(s) == 0 {
		return nil
	}
	return cstring(raw_data(s))
}

@(private)
a11y_ffi_flags :: proc(flags: niello.A11y_Flags) -> u32 {
	bits: u32
	if .Checked in flags {
		bits |= 1 << 0
	}
	if .Selected in flags {
		bits |= 1 << 1
	}
	if .Expanded in flags {
		bits |= 1 << 2
	}
	if .ReadOnly in flags {
		bits |= 1 << 3
	}
	if .Required in flags {
		bits |= 1 << 4
	}
	if .Multiline in flags {
		bits |= 1 << 5
	}
	return bits
}

@(private)
a11y_ffi_state :: proc(state: niello.A11y_State) -> u32 {
	bits: u32
	if .Disabled in state {
		bits |= 1 << 0
	}
	if .Focused in state {
		bits |= 1 << 1
	}
	if .Offscreen in state {
		bits |= 1 << 2
	}
	if .Scroll_X in state {
		bits |= 1 << 3
	}
	if .Scroll_Y in state {
		bits |= 1 << 4
	}
	if .Focusable in state {
		bits |= 1 << 5
	}
	return bits
}

// The backend hooks are wired at package init — assignment only,
// no FFI calls — so app code can use hook-backed core services
// (notably image_load, which decodes immediately) before run().
@(private)
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
@(private)
hook_measure_word :: proc(font: niello.Font_Handle, weight: niello.Font_Weight, slant: niello.Font_Slant, size: f32, text: string) -> f32 {
	return measure_word(u32(font), i32(weight), i32(slant), size, raw_data(text), i64(len(text)))
}

@(private)
hook_line_height :: proc(font: niello.Font_Handle, weight: niello.Font_Weight, slant: niello.Font_Slant, size: f32) -> f32 {
	return line_height(u32(font), i32(weight), i32(slant), size)
}

// hook_decode_image / hook_release_image adapt the C image procs
// to niello's image hooks (wired next to the measure hooks in
// app.odin's startup).
@(private)
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

@(private)
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
	niello.fonts_changed() // the core's word cache must re-measure under the new binding
}

// register_font_family binds a font family id to a SYSTEM font family by
// name ("Inter", "Segoe UI", ...), resolved through the platform font
// manager. Same timing and fallback rules as register_font.
register_font_family :: proc(family: niello.Font_Handle, name: string) {
	ffi_register_font_family(u32(family), strings.clone_to_cstring(name, context.temp_allocator))
	niello.fonts_changed() // the core's word cache must re-measure under the new binding
}

// gpu_cache_bytes is how many bytes the renderer's GPU resource cache holds
// (textures, buffers), shared by every window. A diagnostic: with
// purge_gpu_cache it separates resources still cached (evictable) from
// resources actually leaked.
gpu_cache_bytes :: proc() -> u64 {
	return ffi_gpu_cache_bytes()
}

// purge_gpu_cache frees every GPU resource the renderer can free (after the
// submitted work has drained). A diagnostic, for leak hunting; the cache
// manages itself in normal use.
purge_gpu_cache :: proc() {
	ffi_purge_gpu_cache()
}
