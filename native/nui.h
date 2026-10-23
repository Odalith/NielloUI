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
    uint8_t  interp;          // sampling quality: 0 cubic+mips, 1 linear+mips,
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

// Shared teardown. Destroy all windows first. Does NOT destroy the
// SDL windows (Odin owns them).
void nui_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif // NIELLO_UI_H
