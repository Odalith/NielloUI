// nui.h — NielloUI native render backend: the C ABI the Odin side links against.
//
// This header is platform-independent (fixed-width C types only). The
// compiled static library is NOT: build one per platform (linux-x64,
// macos-arm64, windows-x64), each against that platform's Skia/Dawn.
//
// Mirrors the Odin Draw_Cmd layout exactly (niello/render.odin). Field order
// IS the ABI; both sides statically assert 72 bytes.
#ifndef NIELLO_UI_H
#define NIELLO_UI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum UiCmdTag {
    UI_CMD_RECT         = 0,
    UI_CMD_TEXT         = 1,
    UI_CMD_PUSH_CLIP    = 2,
    UI_CMD_POP_CLIP     = 3,
    UI_CMD_PUSH_OPACITY = 4,
    UI_CMD_POP_OPACITY  = 5,
    UI_CMD_OVERLAY      = 6,
    UI_CMD_IMAGE        = 7,
} UiCmdTag;

typedef struct UiRect {
    float x, y, w, h;
} UiRect;

typedef struct UiDrawCmd {
    uint8_t  tag;
    uint8_t  _pad0[3];
    float    bounds_x, bounds_y, bounds_w, bounds_h; // DIP
    uint8_t  color[4];        // RGBA; for Text commands this is the text color
    uint8_t  radius;          // corner radius (Rect/Overlay only)
    uint8_t  _pad1;
    uint16_t border_width;    // inset border; 0 = none
    uint8_t  border_color[4]; // RGBA
    const uint8_t* text_ptr;  // borrowed; valid until the next frame_begin
    int64_t  text_len;
    uint32_t font;            // family handle from nui_register_font(_family); 0 = default
    float    font_size;       // px in DIP
    uint16_t font_weight;     // CSS 100-900
    uint8_t  font_slant;      // 0=upright, 1=italic, 2=oblique
    uint8_t  _pad2;
    float    max_width;       // available width; trim with ellipsis when truncated
    uint8_t  truncated;
    uint8_t  opacity;         // Push_Opacity payload
    uint8_t  _pad3[2];
    // Image payload (grew the command 72 -> 96 in TODO #13; no
    // shipped release pins the old size). Offsets mirror the Odin
    // struct's computed layout exactly: src_rect @68, image @84,
    // interp @88 — verified with offset_of on the Odin side, since
    // the sizeof assert alone cannot catch a pad slip.
    float    src_x, src_y, src_w, src_h; // source rect, image pixel space
    uint32_t image;           // backend image id from nui_image_decode; 0 = none
    uint8_t  interp;          // sampling quality: 0 cubic (Mitchell), 1 linear+mips,
                              // 2 linear, 3 nearest (niello Image_Interp order)
    uint8_t  _pad4[7];
} UiDrawCmd;

#ifdef __cplusplus
static_assert(sizeof(UiDrawCmd) == 96, "UiDrawCmd must match Odin Draw_Cmd (96 bytes)");
static_assert(sizeof(UiRect) == 16, "UiRect must match Odin Rect (16 bytes)");
#endif

// Native window handles, queried by the Odin side via SDL_GetWindowProperties
// and passed in. The C++ side never touches SDL: no headers, no lib.
typedef struct UiNativeHandles {
    const char* driver;   // "wayland", "x11", "windows", "cocoa"
    // Wayland
    void* wl_display;
    void* wl_surface;
    // X11
    void* x11_display;
    uint64_t    x11_window;
    // Windows
    void* win32_hwnd;
    void* win32_hinstance;
    // macOS
    void* cocoa_layer;
} UiNativeHandles;

// Opaque per-window handle (multi-window M2). The Dawn device, the
// Graphite context, the one recorder (used sequentially — see nui.cpp),
// and the font registry are SHARED by every window; everything
// surface-shaped lives behind this handle.
typedef struct nui_window nui_window;

// Shared bring-up: Dawn instance/device + Graphite context + recorder.
// Call once, before any window exists. Returns 0 on success.
int32_t nui_init(void);

// Create one window's surface + owned pixel cache on the shared device.
// handles carries the platform window handles (see above);
// width_px/height_px is the initial swapchain size. The Odin side owns
// the OS window and the event loop. NULL on failure.
nui_window* nui_create_window(const UiNativeHandles* handles,
                              uint32_t width_px, uint32_t height_px);
void nui_destroy_window(nui_window* win);

// Reconfigure once per host iteration, before layout/render. Zero size suspends.
// A size change invalidates the window's pixel cache. Fifo is used throughout.
void nui_resize(nui_window* win, uint32_t width_px, uint32_t height_px);
void nui_set_refresh_rate(nui_window* win, float hz);
int32_t nui_is_resizing(nui_window* win); // retained ABI; always zero

// Fully repaint the window's GPU texture, then copy/present it. No pointers
// are retained. Damage is currently ignored because repaint clears the whole
// image. content_scale is device pixels per DIP. Returns 1 on presentation.
int32_t nui_render(nui_window* win, const UiDrawCmd* cmds, int32_t n_cmds,
                const UiRect* damage, int32_t n_damage, float content_scale);
// Paced copy/present only; returns 0 if unavailable or unsuccessful. No replay.
int32_t nui_present_cached(nui_window* win);

// Fonts. Families are registered once, cold; the backend caches
// (family, weight, slant, size) -> SkFont internally. Family 0 is the
// platform default and needs no registration. Registration is idempotent.
void  nui_register_font(uint32_t family, const char* path);  // bundled file
void  nui_register_font_family(uint32_t family, const char* name); // system family
float nui_measure_word(uint32_t family, int32_t weight, int32_t slant, float size_px,
                       const uint8_t* text, int64_t len);
float nui_line_height(uint32_t family, int32_t weight, int32_t slant, float size_px);

// Images. Decode takes encoded bytes (PNG/JPEG/WebP — the codec
// decides) and returns a backend image id, or 0 on failure. max_w /
// max_h ask for a smaller decode (shrink-only, aspect-preserving;
// 0 = unconstrained on that axis); out_w / out_h receive the
// decoded size in DIP. Ids are never reused. Release drops the
// decoded image; drawing an unknown id is a no-op.
uint32_t nui_image_decode(const uint8_t* data, int32_t len, int32_t max_w, int32_t max_h,
                          float* out_w, float* out_h);
void nui_image_release(uint32_t id);

// GPU resource cache (the shared Graphite context's). nui_gpu_cache_bytes
// reports the bytes the context currently counts against its cache budget
// — decoded-image textures included, once drawn. nui_purge_gpu_cache drops
// every purgeable resource immediately (after draining submitted work),
// so a caller separating "still cached, evictable" from "actually leaked"
// can purge and re-read. Diagnostic surface; call between frames.
uint64_t nui_gpu_cache_bytes(void);
void nui_purge_gpu_cache(void);

// Accessibility export (AT-SPI, Linux only — TODO #23 M2).
// The Odin side mirrors its semantics tree (niello/a11y.odin) into
// UiA11yNode rows and hands them over after every frame_end; this
// side diffs them against its shadow and serves the AT-SPI object
// tree + change signals over a hand-rolled D-Bus client (dbus.h).
// The exporter is inert when no accessibility bus answers: start
// returns 0 and sync is a no-op, so apps never pay for AT-SPI
// they don't have. The native library must be rebuilt after
// pulling this (new objects in the static archive).
//
// UiA11yNode mirrors the Odin A11y_Node's FFI projection
// (niello/sdl/ffi.odin). Field order IS the ABI: role is the Odin
// A11y_Role ordinal (Avalonia's 43-value order); flags/state are
// bit positions of the Odin A11y_Flag / A11y_State_Flag enums
// (ORDER IS ABI — append only, on both sides). Strings are
// borrowed for the call; the exporter copies what it keeps.
// parent is an index into the nodes array (-1 = child of the
// synthetic window node); rect is DIP, window-relative.
typedef struct UiA11yNode {
	uint64_t id; // Odin Instance (hash of parent, unit, key)
	int32_t  parent;
	uint32_t role;
	const char *name;        // NULL = empty
	const char *description; // NULL = empty
	uint32_t flags; // 0 Checked, 1 Selected, 2 Expanded, 3 ReadOnly, 4 Required, 5 Multiline
	uint32_t state; // 0 Disabled, 1 Focused, 2 Offscreen, 3 Scroll_X, 4 Scroll_Y, 5 Focusable
	float    x, y, w, h;
	int32_t  has_value;
	float    value_num, value_min, value_max;
	const char *value_text; // NULL = empty
} UiA11yNode;

#ifdef __cplusplus
static_assert(sizeof(UiA11yNode) == 80, "UiA11yNode must match Odin A11y_FFI_Node (80 bytes)");
#endif

// Connect to the accessibility bus and register with the AT-SPI
// registry. Returns 1 when the exporter is live, 0 when inert
// (no bus, no registry, or connection failure). Safe to call
// repeatedly; later calls are no-ops while live. app_name is the
// application name reported to assistive tools (borrowed).
int32_t nui_atspi_start(const char *app_name);
// Stop the exporter: ends the dispatch thread and closes the bus
// connection. Safe to call when never started.
void nui_atspi_stop(void);
// Publish one window's mirror. ctx_id identifies the window (the
// glue's Window_Id); nodes are in declaration order, parents
// before children; window_title is borrowed; win_x/win_y is the
// window's screen position and win_w/win_h its size in DIP (for
// the window node's extents and screen-coordinate answers). Call
// after every frame_end, per window. No-op while inert.
void nui_atspi_sync(int32_t ctx_id, const UiA11yNode *nodes, int32_t count,
                    const char *window_title, int32_t win_x, int32_t win_y,
                    int32_t win_w, int32_t win_h);
// Withdraw one window's mirror (window closed): removes its nodes
// and window object from the export. No-op while inert or unknown.
void nui_atspi_remove_window(int32_t ctx_id);

// Shared teardown. Destroy all windows first. Does NOT destroy the
// SDL windows (Odin owns them).
void nui_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif // NIELLO_UI_H
