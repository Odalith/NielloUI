// nui.cpp — NielloUI native render backend (static lib).
//
// Owns: the Dawn instance/device, the Skia Graphite context + recorder, the
// swapchain surface, and Draw_Cmd replay. No SDL on this side: the Odin side
// passes platform window handles (UiNativeHandles) at init. The event loop,
// window lifecycle, input, and frame pacing policy all live in Odin.

#include "nui.h"
#include "util.h"

#include <algorithm>
#include <cassert>
#include <chrono>
#include <climits>
#include <cstdio>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkPaint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTextBlob.h"
#include "include/core/SkTypeface.h"
#include "gpu/graphite/BackendTexture.h"
#include "gpu/graphite/dawn/DawnGraphiteTypes.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/dawn/DawnBackendContext.h"

// Platform font manager factory. Skia removed SkFontMgr::RefDefault() and
// SkTypeface::MakeDefault()/MakeFromFile(), so everything goes through the
// platform manager: fontconfig on Linux, CoreText on macOS, DirectWrite on
// Windows. Signatures verified against the Skia headers (the macOS/Windows
// branches can't compile-check on this Linux VM, but the declarations match).
#if defined(__linux__)
#include "include/ports/SkFontMgr_fontconfig.h"
#include "include/ports/SkFontScanner_FreeType.h"
#elif defined(__APPLE__)
#include "include/ports/SkFontMgr_mac_ct.h"
#elif defined(_WIN32)
#include "include/ports/SkTypeface_win.h"
#endif

namespace {
// One process-wide font manager, created on first use.
SkFontMgr* GetFontMgr() {
    static sk_sp<SkFontMgr> mgr;
    if (!mgr) {
#if defined(__linux__)
        mgr = SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
#elif defined(__APPLE__)
        // nullptr collection = system default (per SkFontMgr_mac_ct.h docs).
        mgr = SkFontMgr_New_CoreText(nullptr);
#elif defined(_WIN32)
        // Defaults: nullptr factory (Skia creates one) + nullptr collection.
        mgr = SkFontMgr_New_DirectWrite();
#endif
        if (!mgr) {
            printf("nui: could not create platform font manager\n");
        }
    }
    return mgr.get();
}
}  // namespace

namespace {

struct App {
    skgpu::graphite::DawnBackendContext backendContext;
    std::unique_ptr<skgpu::graphite::Context> context;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;

    wgpu::Surface surface;
    wgpu::SurfaceConfiguration surfaceConfig{};

    // Resize-debounce pacing (was driven by SDL_AppIterate).
    uint64_t targetFrameTimeNs = 1'000'000'000 / 60;
    uint64_t nextFrameTimeNs = 0;
    bool isUserResizing = false;
    bool isMailboxModeAvailable = false;
    wgpu::PresentMode presentMode = wgpu::PresentMode::Fifo;
    std::chrono::steady_clock::time_point lastResizeTime{};

    // Last frame, for the immediate resize render. Borrowed pointers: valid
    // until the next frame_begin, and nui_resize only fires between frames
    // (event callbacks run between app-iterate calls), so replaying them here
    // is sound.
    const UiDrawCmd* cachedCmds = nullptr;
    int32_t cachedCount = 0;
    float cachedScale = 1.0f;

    // Font registry. Families are registered cold (once); the (family,
    // weight, slant, size) -> SkFont cache below is filled on demand.
    // File-registered families keep the file's bytes; typefaces are created
    // per style via the font manager's makeFromData.
    struct FontFamily {
        sk_sp<SkData> data;  // from nui_register_font (file contents)
        std::string name;    // from nui_register_font_family
        bool is_name = false;
    };
    std::unordered_map<uint32_t, FontFamily> families;

    struct FontKey {
        uint32_t family;
        int32_t  weight; // 100-900
        int32_t  slant;  // 0=upright, 1=italic, 2=oblique
        float    size;
        bool operator==(const FontKey& o) const {
            return family == o.family && weight == o.weight &&
                   slant == o.slant && size == o.size;
        }
    };
    struct FontKeyHash {
        size_t operator()(const FontKey& k) const noexcept {
            size_t h = std::hash<uint32_t>{}(k.family);
            h ^= std::hash<int32_t>{}(k.weight) + 0x9e3779b9 + (h << 6) + (h >> 2);
            h ^= std::hash<int32_t>{}(k.slant)  + 0x9e3779b9 + (h << 6) + (h >> 2);
            h ^= std::hash<float>{}(k.size)     + 0x9e3779b9 + (h << 6) + (h >> 2);
            return h;
        }
    };
    std::unordered_map<FontKey, SkFont, FontKeyHash> font_cache;
};

App g_app;

uint64_t NowNs() {
    return (uint64_t)std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

SkColor ToSkColor(const uint8_t c[4]) { // RGBA -> SkColor (ARGB)
    return SkColorSetARGB(c[3], c[0], c[1], c[2]);
}

// ResolveFont returns the cached SkFont for (family, weight, slant, size),
// building and caching it on first use. Family 0 (or an unknown family)
// falls back to the platform default face via the font manager.
SkFont* ResolveFont(uint32_t family, int32_t weight, int32_t slant, float size) {
    if (weight < 100) weight = 100;
    if (weight > 900) weight = 900;
    if (slant < 0 || slant > 2) slant = 0;
    if (!(size > 0)) size = 16.0f;

    App::FontKey key{family, weight, slant, size};
    auto it = g_app.font_cache.find(key);
    if (it != g_app.font_cache.end()) return &it->second;

    SkFontMgr* mgr = GetFontMgr();
    sk_sp<SkTypeface> tf;
    if (mgr) {
        auto fit = g_app.families.find(family);
        if (fit != g_app.families.end()) {
            const App::FontFamily& fam = fit->second;
            if (fam.is_name) {
                // System family: the manager's closest-match fallback applies.
                SkFontStyle style(weight, SkFontStyle::kNormal_Width,
                                  static_cast<SkFontStyle::Slant>(slant));
                tf = mgr->matchFamilyStyle(fam.name.c_str(), style);
            } else if (fam.data) {
                // File registration: best style match by weight distance + slant.
                int best = 0, best_score = INT_MAX;
                for (int i = 0; i <= 64; i++) {
                    sk_sp<SkTypeface> face = mgr->makeFromData(fam.data, i);
                    if (!face) break;
                    SkFontStyle st = face->fontStyle();
                    int score = abs(st.weight() - weight) * 4 +
                                abs((int)st.slant() - slant);
                    if (score < best_score) { best_score = score; best = i; }
                }
                tf = mgr->makeFromData(fam.data, best);
            }
        }
        if (!tf) {
            tf = mgr->matchFamilyStyle(nullptr, SkFontStyle());
        }
    }
    if (!tf) return nullptr;
    SkFont font(tf, size);
    auto ins = g_app.font_cache.emplace(key, font);
    return &ins.first->second;
}

// ---- Draw_Cmd replay -------------------------------------------------------

bool RectHitsDamage(const UiDrawCmd& c, const UiRect* damage, int32_t n) {
    float x0 = c.bounds_x, y0 = c.bounds_y;
    float x1 = x0 + c.bounds_w, y1 = y0 + c.bounds_h;
    for (int32_t i = 0; i < n; i++) {
        float dx1 = damage[i].x + damage[i].w;
        float dy1 = damage[i].y + damage[i].h;
        if (x0 < dx1 && x1 > damage[i].x && y0 < dy1 && y1 > damage[i].y) return true;
    }
    return false;
}

void DrawRectCmd(SkCanvas* canvas, const UiDrawCmd& c) {
    SkRect r = SkRect::MakeXYWH(c.bounds_x, c.bounds_y, c.bounds_w, c.bounds_h);
    SkPaint fill;
    fill.setColor(ToSkColor(c.color));
    fill.setAntiAlias(true);
    if (c.radius > 0) {
        canvas->drawRRect(SkRRect::MakeRectXY(r, (float)c.radius, (float)c.radius), fill);
    } else {
        canvas->drawRect(r, fill);
    }
    if (c.border_width > 0) {
        // Inset border: the stroke stays inside the rect.
        float bw = (float)c.border_width;
        SkRect br = SkRect::MakeXYWH(c.bounds_x + bw / 2, c.bounds_y + bw / 2,
                                     c.bounds_w - bw, c.bounds_h - bw);
        SkPaint stroke;
        stroke.setStyle(SkPaint::kStroke_Style);
        stroke.setStrokeWidth(bw);
        stroke.setColor(ToSkColor(c.border_color));
        stroke.setAntiAlias(true);
        if (c.radius > 0) {
            float rr = std::max(0.0f, (float)c.radius - bw / 2);
            canvas->drawRRect(SkRRect::MakeRectXY(br, rr, rr), stroke);
        } else {
            canvas->drawRect(br, stroke);
        }
    }
}

void DrawTextCmd(SkCanvas* canvas, const UiDrawCmd& c) {
    SkFont* font = ResolveFont(c.font, (int32_t)c.font_weight, (int32_t)c.font_slant, c.font_size);
    if (!font || !c.text_ptr || c.text_len <= 0) return;
    const char* text = reinterpret_cast<const char*>(c.text_ptr);
    size_t len = (size_t)c.text_len;

    // Ellipsis trim when the emitter flagged truncation. Binary-search the
    // longest prefix that fits, then append "…". (Upgrade path: SkShaper for
    // complex scripts; see build-native.md.)
    std::string owned;
    const char* draw_text = text;
    size_t draw_len = len;
    if (c.truncated && c.max_width > 0) {
        float full = font->measureText(text, len, SkTextEncoding::kUTF8);
        if (full > c.max_width) {
            static const char kEllipsis[] = "\xE2\x80\xA6"; // "…"
            float ell_w = font->measureText(kEllipsis, 3, SkTextEncoding::kUTF8);
            float avail = c.max_width - ell_w;
            size_t lo = 0, hi = len;
            while (lo < hi) {
                size_t mid = lo + (hi - lo + 1) / 2;
                if (font->measureText(text, mid, SkTextEncoding::kUTF8) <= avail) lo = mid;
                else hi = mid - 1;
            }
            while (lo > 0 && (text[lo] & 0xC0) == 0x80) lo--; // don't split UTF-8
            owned.assign(text, lo);
            owned += kEllipsis;
            draw_text = owned.data();
            draw_len = owned.size();
        }
    }

    SkPaint paint;
    paint.setColor(ToSkColor(c.color));
    paint.setAntiAlias(true);
    SkFontMetrics metrics;
    font->getMetrics(&metrics);
    float baseline = c.bounds_y - metrics.fAscent; // fAscent is negative
    sk_sp<SkTextBlob> blob =
        SkTextBlob::MakeFromText(draw_text, draw_len, *font, SkTextEncoding::kUTF8);
    if (blob) canvas->drawTextBlob(blob.get(), c.bounds_x, baseline, paint);
}

void ReplayCommands(SkCanvas* canvas, const UiDrawCmd* cmds, int32_t n,
                    const UiRect* damage, int32_t n_damage, float content_scale) {
    canvas->save();
    canvas->scale(content_scale, content_scale); // DIP -> device pixels
    for (int32_t i = 0; i < n; i++) {
        const UiDrawCmd& c = cmds[i];
        // Stack ops are never damage-culled: dropping a push while keeping its
        // content would corrupt the canvas state.
        bool is_stack_op = c.tag == UI_CMD_PUSH_CLIP || c.tag == UI_CMD_POP_CLIP ||
                           c.tag == UI_CMD_PUSH_OPACITY || c.tag == UI_CMD_POP_OPACITY;
        if (!is_stack_op && n_damage > 0 && damage &&
            !RectHitsDamage(c, damage, n_damage)) {
            continue;
        }
        switch (c.tag) {
            case UI_CMD_RECT:
            case UI_CMD_OVERLAY:
                DrawRectCmd(canvas, c);
                break;
            case UI_CMD_TEXT:
                DrawTextCmd(canvas, c);
                break;
            case UI_CMD_PUSH_CLIP:
                canvas->save();
                canvas->clipRect(
                    SkRect::MakeXYWH(c.bounds_x, c.bounds_y, c.bounds_w, c.bounds_h),
                    SkClipOp::kIntersect, /*doAntiAlias=*/true);
                break;
            case UI_CMD_POP_CLIP:
                canvas->restore();
                break;
            case UI_CMD_PUSH_OPACITY: {
                SkRect b = SkRect::MakeXYWH(c.bounds_x, c.bounds_y, c.bounds_w, c.bounds_h);
                canvas->saveLayerAlpha(&b, c.opacity);
                break;
            }
            case UI_CMD_POP_OPACITY:
                canvas->restore();
                break;
        }
    }
    canvas->restore();
}

// ---- frame -----------------------------------------------------------------

void RenderAndPresent(const UiDrawCmd* cmds, int32_t n_cmds,
                      const UiRect* damage, int32_t n_damage,
                      float content_scale) {
    App& app = g_app;

    // Use the configured swapchain size (tracked in surfaceConfig); the
    // window handle lives on the Odin side now.
    if (app.surfaceConfig.width == 0 || app.surfaceConfig.height == 0) return;

    // 1. Acquire the current swapchain texture.
    wgpu::SurfaceTexture surfaceTexture;
    app.surface.GetCurrentTexture(&surfaceTexture);
    if (surfaceTexture.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessOptimal &&
        surfaceTexture.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessSuboptimal) {
        return;
    }

    // 2. Wrap it for Skia Graphite.
    skgpu::graphite::BackendTexture backendTex =
        skgpu::graphite::BackendTextures::MakeDawn(surfaceTexture.texture.Get());
    sk_sp<SkSurface> skSurface = SkSurfaces::WrapBackendTexture(
        app.recorder.get(), backendTex, SkColorSpace::MakeSRGB(), nullptr);
    if (!skSurface) {
        printf("nui: could not wrap backend texture into SkSurface\n");
        return;
    }

    // 3. Replay the draw commands.
    SkCanvas* canvas = skSurface->getCanvas();
    canvas->clear(SkColors::kWhite);
    ReplayCommands(canvas, cmds, n_cmds, damage, n_damage, content_scale);

    // 4. Submit and present.
    std::unique_ptr<skgpu::graphite::Recording> recording = app.recorder->snap();
    if (recording) {
        skgpu::graphite::InsertRecordingInfo info;
        info.fRecording = recording.get();
        app.context->insertRecording(info);
        app.context->submit(skgpu::graphite::SyncToCpu::kNo);
    }
    app.surface.Present();
}

void ResizeSurface(wgpu::PresentMode mode, uint32_t width_px, uint32_t height_px,
                   bool immediate_render) {
    App& app = g_app;
    if (width_px == 0 || height_px == 0) return;
    if (app.presentMode == mode && app.surfaceConfig.width == width_px &&
        app.surfaceConfig.height == height_px) {
        return;
    }

    // Flush current GPU work before destroying/recreating swapchain textures.
    if (app.context) {
        app.context->submit(skgpu::graphite::SyncToCpu::kNo);
    }

    app.presentMode = mode;
    app.surfaceConfig.presentMode = mode;
    app.surfaceConfig.width = width_px;
    app.surfaceConfig.height = height_px;
    app.surface.Configure(&app.surfaceConfig);

    // Immediately render and commit a frame to satisfy Wayland's configure
    // cycle. Full repaint: any cached damage is stale after a resize.
    // (Kept from the testbed: needed for smooth window resizing.)
#if defined(__linux__)
    if (immediate_render && app.cachedCount > 0 && app.cachedCmds) {
        RenderAndPresent(app.cachedCmds, app.cachedCount, nullptr, 0, app.cachedScale);
    }
#else
    (void)immediate_render;
#endif
}

} // namespace

// ---- public C API ----------------------------------------------------------

int32_t nui_init(const UiNativeHandles* handles, uint32_t width_px, uint32_t height_px) {
    App& app = g_app;
    if (!handles || !handles->driver) {
        printf("nui_init: null handles\n");
        return -1;
    }

    // 1. Dawn backend context.
    app.backendContext = GetDawnContext();

    // 2. Graphite context + recorder.
    skgpu::graphite::ContextOptions options;
    app.context = skgpu::graphite::ContextFactory::MakeDawn(app.backendContext, options);
    if (!app.context) {
        printf("nui_init: could not make Graphite context\n");
        return -1;
    }
    app.recorder = app.context->makeRecorder();
    if (!app.recorder) {
        printf("nui_init: could not make recorder\n");
        return -1;
    }

    // 3. Dawn surface from the platform handles (no SDL on this side).
    app.surface = CreateDawnSurface(app.backendContext.fInstance, handles);
    if (!app.surface) {
        printf("nui_init: could not create Dawn surface\n");
        return -1;
    }

    wgpu::SurfaceCapabilities capabilities;
    app.surface.GetCapabilities(app.backendContext.fDevice.GetAdapter(), &capabilities);
    for (size_t i = 0; i < capabilities.presentModeCount; ++i) {
        if (capabilities.presentModes[i] == wgpu::PresentMode::Mailbox) {
            app.isMailboxModeAvailable = true;
            break;
        }
    }

    app.surfaceConfig.device = app.backendContext.fDevice;
    app.surfaceConfig.format = capabilities.formatCount > 0
        ? capabilities.formats[0]
        : wgpu::TextureFormat::BGRA8Unorm;
    app.surfaceConfig.usage = wgpu::TextureUsage::RenderAttachment;
    app.surfaceConfig.width = width_px;
    app.surfaceConfig.height = height_px;
    app.surfaceConfig.presentMode = app.presentMode;
    app.surface.Configure(&app.surfaceConfig);

    // Refresh rate defaults to 60 Hz; the Odin side overrides it via
    // nui_set_refresh_rate at startup and on display changes.
    app.nextFrameTimeNs = NowNs();
    return 0;
}

void nui_resize(uint32_t width_px, uint32_t height_px) {
    App& app = g_app;
    if (!app.context) return;
    app.lastResizeTime = std::chrono::steady_clock::now();
    if (app.isMailboxModeAvailable &&
        (!app.isUserResizing || app.presentMode == wgpu::PresentMode::Fifo)) {
        app.isUserResizing = true;
        app.nextFrameTimeNs = NowNs();
        ResizeSurface(wgpu::PresentMode::Mailbox, width_px, height_px, true);
    } else {
        ResizeSurface(app.presentMode, width_px, height_px, true);
    }
}

void nui_set_refresh_rate(float hz) {
    if (hz > 0) g_app.targetFrameTimeNs = (uint64_t)(1e9 / hz);
}

int32_t nui_is_resizing(void) {
    return g_app.isUserResizing ? 1 : 0;
}

void nui_render(const UiDrawCmd* cmds, int32_t n_cmds,
                const UiRect* damage, int32_t n_damage,
                float content_scale) {
    App& app = g_app;
    if (!app.context) return;

    // Frame pacing while the user is dragging a resize (was SDL_AppIterate).
    if (app.isUserResizing) {
        uint64_t now = NowNs();
        if (now < app.nextFrameTimeNs) {
            uint64_t waitNs = app.nextFrameTimeNs - now;
            if (waitNs > 1'000'000) {
                std::this_thread::sleep_for(
                    std::chrono::nanoseconds(waitNs - 500'000));
            }
            while (NowNs() < app.nextFrameTimeNs) { /* spin the last slice */ }
        }
        now = NowNs();
        if (app.nextFrameTimeNs == 0 || now > app.nextFrameTimeNs + app.targetFrameTimeNs) {
            app.nextFrameTimeNs = now + app.targetFrameTimeNs;
        } else {
            app.nextFrameTimeNs += app.targetFrameTimeNs;
        }

        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - app.lastResizeTime).count();
        if (elapsed > 150) {
            // Drag ended: back to power-efficient, tear-free Fifo.
            app.isUserResizing = false;
            ResizeSurface(wgpu::PresentMode::Fifo, app.surfaceConfig.width,
                          app.surfaceConfig.height, /*immediate_render=*/false);
        }
    }

    RenderAndPresent(cmds, n_cmds, damage, n_damage, content_scale);

    // Cache for the immediate resize render (see App).
    app.cachedCmds = cmds;
    app.cachedCount = n_cmds;
    app.cachedScale = content_scale;
}

void nui_register_font(uint32_t family, const char* path) {
    if (!path) return;
    sk_sp<SkData> data = SkData::MakeFromFileName(path);
    if (!data) {
        printf("nui_register_font: could not load '%s'\n", path);
        return;
    }
    App::FontFamily& fam = g_app.families[family];
    fam.is_name = false;
    fam.data = data;
    fam.name.clear();
    // Registration is cold; drop cached fonts so a re-registration can't go stale.
    g_app.font_cache.clear();
}

void nui_register_font_family(uint32_t family, const char* name) {
    if (!name) return;
    App::FontFamily& fam = g_app.families[family];
    fam.is_name = true;
    fam.name = name;
    fam.data.reset();
    g_app.font_cache.clear();
}

float nui_measure_word(uint32_t family, int32_t weight, int32_t slant, float size_px,
                       const uint8_t* text, int64_t len) {
    SkFont* f = ResolveFont(family, weight, slant, size_px);
    if (!f || !text || len <= 0) return 0.0f;
    return f->measureText(text, (size_t)len, SkTextEncoding::kUTF8);
}

float nui_line_height(uint32_t family, int32_t weight, int32_t slant, float size_px) {
    SkFont* f = ResolveFont(family, weight, slant, size_px);
    if (!f) return 0.0f;
    SkFontMetrics metrics;
    f->getMetrics(&metrics);
    return -metrics.fAscent + metrics.fDescent + metrics.fLeading;
}

void nui_destroy(void) {
    App& app = g_app;
    // Finish GPU work, then tear down. The SDL window is NOT destroyed here:
    // the Odin side owns it.
    if (app.context) {
        app.context->submit(skgpu::graphite::SyncToCpu::kYes);
    }
    app.families.clear();
    app.font_cache.clear();
    app.recorder.reset();
    app.context.reset();
    app.surface = nullptr;
    app.surfaceConfig.device = nullptr; // drop the device ref before shutdown
    app.surfaceConfig = {};
    app.backendContext = {};
    app.cachedCmds = nullptr;
    app.cachedCount = 0;
}
