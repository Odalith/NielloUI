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
    uint8_t  _pad3[6];
} UiDrawCmd;

#ifdef __cplusplus
static_assert(sizeof(UiDrawCmd) == 72, "UiDrawCmd must match Odin Draw_Cmd (72 bytes)");
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

// Lifecycle. handles carries the platform window handles (see above);
// width_px/height_px is the initial swapchain size. The Odin side owns the
// window and the event loop. Returns 0 on success.
int32_t nui_init(const UiNativeHandles* handles, uint32_t width_px, uint32_t height_px);

// Swapchain reconfiguration. Called from the Odin event callback on
// WINDOW_PIXEL_SIZE_CHANGED. Keeps the Mailbox-during-resize behavior; on
// Linux immediately replays the last frame so the Wayland configure cycle
// stays smooth.
void nui_resize(uint32_t width_px, uint32_t height_px);

// Display refresh rate in Hz (0 = keep current). The Odin side calls this at
// startup and on display changes; it drives the resize-debounce pacing.
void nui_set_refresh_rate(float hz);

// Render one frame: pacing sleep, Draw_Cmd replay onto a Skia Graphite canvas,
// present. cmds/damage borrow the caller's memory (valid until the next
// frame_begin); the backend replays them synchronously and caches the pointers
// for the resize immediate-render. damage may be NULL when n_damage == 0.
// content_scale is device pixels per DIP point.
void nui_render(const UiDrawCmd* cmds, int32_t n_cmds,
                const UiRect* damage, int32_t n_damage,
                float content_scale);

// Fonts. Families are registered once, cold; the backend caches
// (family, weight, slant, size) -> SkFont internally. Family 0 is the
// platform default and needs no registration. Registration is idempotent.
void  nui_register_font(uint32_t family, const char* path);  // bundled file
void  nui_register_font_family(uint32_t family, const char* name); // system family
float nui_measure_word(uint32_t family, int32_t weight, int32_t slant, float size_px,
                       const uint8_t* text, int64_t len);
float nui_line_height(uint32_t family, int32_t weight, int32_t slant, float size_px);

// Wayland configure-cycle pump. See nui.cpp for the full explanation.
// Call on idle frames (when skipping render) to unblock pending resizes.
// No-op on non-Wayland platforms.
void nui_wayland_pump(void);

// Teardown. Does NOT destroy the SDL window (Odin owns it).
void nui_destroy(void);

#ifdef __cplusplus
}
#endif

#endif // NIELLO_UI_H
