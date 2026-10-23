// nui.cpp — NielloUI native render backend (static lib).
//
// Owns: the Dawn instance/device, the Skia Graphite context, and Draw_Cmd
// replay. Multi-window (M2): the device, the Graphite context, the ONE
// recorder, and the font registry are shared process-wide; each window's
// surface + owned pixel cache lives in its own nui_window. No SDL on this
// side: the Odin side passes platform window handles (UiNativeHandles) at
// window creation. The event loop, window lifecycle, input, and frame
// pacing policy all live in Odin.

#include "nui.h"
#include "util.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <cassert>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "include/codec/SkCodec.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkImage.h"
#include "include/core/SkSamplingOptions.h"
#include "include/gpu/graphite/Image.h"
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

// Shared: one per process, behind nui_init/nui_shutdown.
struct Shared {
    skgpu::graphite::DawnBackendContext backendContext;
    std::unique_ptr<skgpu::graphite::Context> context;
    // ONE recorder for all windows, used SEQUENTIALLY from the host's
    // one UI thread: record window A, snap, submit; record window B,
    // snap, submit. A Recorder is single-owner (not concurrent), which
    // sequential use satisfies — and sharing keeps ONE glyph atlas /
    // strike cache for text every window shows, instead of duplicating
    // them per window.
    std::unique_ptr<skgpu::graphite::Recorder> recorder;
    int window_count = 0;
    bool trace = std::getenv("NUI_TRACE") != nullptr;

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

    // Image registry (TODO #13): backend ids are allocated here,
    // monotonically, never reused — a stale id in a draw command
    // misses the map and draws nothing rather than aliasing a
    // different image. Decode keeps the pixels; the Graphite
    // texture image is created lazily at first draw through the
    // drawing surface's own recorder (see DrawImageCmd — the
    // implicit raster->texture conversion at draw time failed
    // on this build for every image, format notwithstanding).
    struct ImageEntry {
        SkBitmap pixels;
        sk_sp<SkImage> texture;
    };
    std::unordered_map<uint32_t, ImageEntry> images;
    uint32_t next_image_id = 1;
};

Shared g_shared;

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

    Shared::FontKey key{family, weight, slant, size};
    auto it = g_shared.font_cache.find(key);
    if (it != g_shared.font_cache.end()) return &it->second;

    SkFontMgr* mgr = GetFontMgr();
    sk_sp<SkTypeface> tf;
    if (mgr) {
        auto fit = g_shared.families.find(family);
        if (fit != g_shared.families.end()) {
            const Shared::FontFamily& fam = fit->second;
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
            // Default family, but at the REQUESTED style — the
            // no-style fallback (SkFontStyle()) silently flattened
            // every bold/italic request on family 0 to the regular
            // face, even when the family has the faces.
            SkFontStyle style(weight, SkFontStyle::kNormal_Width,
                              static_cast<SkFontStyle::Slant>(slant));
            tf = mgr->matchFamilyStyle(nullptr, style);
        }
    }
    if (!tf) return nullptr;
    SkFont font(tf, size);
    auto ins = g_shared.font_cache.emplace(key, font);
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

void DrawImageCmd(SkCanvas* canvas, skgpu::graphite::Recorder* recorder, const UiDrawCmd& c) {
    auto it = g_shared.images.find(c.image);
    if (it == g_shared.images.end()) return;
    Shared::ImageEntry& entry = it->second;
    if (!entry.texture && recorder) {
        entry.texture = SkImages::TextureFromBitmap(recorder, entry.pixels);
    }
    if (!entry.texture) return;
    // DIAGNOSTIC: once per id, what reaches the draw.
    static std::unordered_set<uint32_t> traced;
    if (traced.insert(c.image).second) {
        const SkImage* im = entry.texture.get();
        fprintf(stderr, "nui: image_draw id=%u %dx%d ct=%d at=%d cs=%s tex=%d\n",
                c.image, im->width(), im->height(), (int)im->colorType(),
                (int)im->alphaType(), im->colorSpace() ? "set" : "null",
                (int)im->isTextureBacked());
    }
    SkSamplingOptions sampling;
    switch (c.interp) {
        case 1:  sampling = SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kLinear); break;
        case 2:  sampling = SkSamplingOptions(SkFilterMode::kLinear, SkMipmapMode::kNone); break;
        case 3:  sampling = SkSamplingOptions(SkFilterMode::kNearest, SkMipmapMode::kNone); break;
        case 0:
        default: sampling = SkSamplingOptions(SkCubicResampler::Mitchell()); break;
    }
    SkRect src = SkRect::MakeXYWH(c.src_x, c.src_y, c.src_w, c.src_h);
    SkRect dst = SkRect::MakeXYWH(c.bounds_x, c.bounds_y, c.bounds_w, c.bounds_h);
    canvas->drawImageRect(entry.texture.get(), src, dst, sampling, nullptr,
                          SkCanvas::kStrict_SrcRectConstraint);
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
                // Probe only on a UTF-8 character boundary. A byte prefix
                // that splits a multi-byte sequence is not a valid string,
                // and measureText is not required to survive one — a
                // truncated label containing an em dash crashed here when
                // the descending search probed inside the sequence. The
                // search itself still runs in byte space; the final
                // walk-back below lands exactly on the probed boundary.
                size_t probe = mid;
                while (probe > 0 && (text[probe] & 0xC0) == 0x80) probe--;
                if (font->measureText(text, probe, SkTextEncoding::kUTF8) <= avail) lo = mid;
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

void ReplayCommands(SkCanvas* canvas, skgpu::graphite::Recorder* recorder,
                    const UiDrawCmd* cmds, int32_t n,
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
            case UI_CMD_IMAGE:
                DrawImageCmd(canvas, recorder, c);
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

} // namespace

// Per-window state: this struct IS the opaque nui_window. Everything
// surface-shaped lives here; the shared device/context/recorder/fonts
// are in g_shared above.
struct nui_window {
    wgpu::Surface surface;
    wgpu::SurfaceConfiguration surfaceConfig{};

    // All GPU work is completed before cache retirement or surface reconfiguration.
    wgpu::Texture cacheTexture;
    sk_sp<SkSurface> cacheSurface;
    bool cacheValid = false;
    bool suspended = false;
    uint64_t targetFrameTimeNs = 1'000'000'000 / 60;
    uint64_t nextFrameTimeNs = 0;
    uint64_t replays = 0, copies = 0, configurations = 0, acquireFailures = 0;
};

namespace {

// ---- frame -----------------------------------------------------------------

// Wait for direct Dawn copies too: Graphite's CPU synchronization alone does
// not cover work submitted after its last submission. The callback owns its
// result storage even if WaitAny fails before invoking it.
bool DrainQueue() {
    Shared& sh = g_shared;
    auto success = std::make_shared<bool>(false);
    auto future = sh.backendContext.fQueue.OnSubmittedWorkDone(
        wgpu::CallbackMode::WaitAnyOnly,
        [success](wgpu::QueueWorkDoneStatus status, wgpu::StringView) {
            *success = status == wgpu::QueueWorkDoneStatus::Success;
        });
    auto status = sh.backendContext.fInstance.WaitAny(future, UINT64_MAX);
    return status == wgpu::WaitStatus::Success && *success;
}

void Trace(const nui_window& w) {
    if (g_shared.trace) fprintf(stderr,
        "nui: replays=%llu copies=%llu configurations=%llu acquire_failures=%llu size=%ux%u valid=%d\n",
        (unsigned long long)w.replays, (unsigned long long)w.copies,
        (unsigned long long)w.configurations, (unsigned long long)w.acquireFailures,
        w.surfaceConfig.width, w.surfaceConfig.height, w.cacheValid);
}

void Pace(nui_window& w) {
    auto now = NowNs();
    if (now < w.nextFrameTimeNs)
        std::this_thread::sleep_for(std::chrono::nanoseconds(w.nextFrameTimeNs - now));
    w.nextFrameTimeNs = NowNs() + w.targetFrameTimeNs;
}

bool EnsureCache(nui_window& w) {
    Shared& sh = g_shared;
    if (w.cacheSurface) return true;
    wgpu::TextureDescriptor desc{};
    desc.label = "Niello owned frame cache";
    desc.size = {w.surfaceConfig.width, w.surfaceConfig.height, 1};
    desc.format = w.surfaceConfig.format;
    desc.usage = wgpu::TextureUsage::RenderAttachment | wgpu::TextureUsage::CopySrc |
                 wgpu::TextureUsage::TextureBinding;
    w.cacheTexture = sh.backendContext.fDevice.CreateTexture(&desc);
    if (!w.cacheTexture) return false;
    auto backend = skgpu::graphite::BackendTextures::MakeDawn(w.cacheTexture.Get());
    // The shared recorder records into this window's cache surface; the
    // recording is snapped + submitted before another window records.
    w.cacheSurface = SkSurfaces::WrapBackendTexture(
        sh.recorder.get(), backend, SkColorSpace::MakeSRGB(), nullptr);
    return bool(w.cacheSurface);
}

bool PresentCache(nui_window& w) {
    Shared& sh = g_shared;
    if (w.suspended || !w.cacheValid || !w.cacheSurface ||
        w.cacheTexture.GetWidth() != w.surfaceConfig.width ||
        w.cacheTexture.GetHeight() != w.surfaceConfig.height ||
        w.cacheTexture.GetFormat() != w.surfaceConfig.format) return false;
    wgpu::SurfaceTexture acquired;
    w.surface.GetCurrentTexture(&acquired);
    if ((acquired.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessOptimal &&
         acquired.status != wgpu::SurfaceGetCurrentTextureStatus::SuccessSuboptimal) ||
        !acquired.texture) {
        ++w.acquireFailures;
        Trace(w);
        return false;
    }
    if (acquired.texture.GetWidth() != w.surfaceConfig.width ||
        acquired.texture.GetHeight() != w.surfaceConfig.height ||
        acquired.texture.GetFormat() != w.surfaceConfig.format) return false;
    auto encoder = sh.backendContext.fDevice.CreateCommandEncoder();
    if (!encoder) return false;
    wgpu::TexelCopyTextureInfo src{}, dst{};
    src.texture = w.cacheTexture;
    dst.texture = acquired.texture;
    wgpu::Extent3D size{w.surfaceConfig.width, w.surfaceConfig.height, 1};
    encoder.CopyTextureToTexture(&src, &dst, &size);
    auto commands = encoder.Finish();
    if (!commands) return false;
    // Graphite submits on this very queue before this copy; queue order makes
    // the complete repaint visible. Bound outstanding work before returning.
    sh.backendContext.fQueue.Submit(1, &commands);
    if (!DrainQueue()) { w.cacheValid = false; return false; }
    if (w.surface.Present() != wgpu::Status::Success) return false;
    ++w.copies;
    if (w.copies % 60 == 0) Trace(w);
    return true;
}

void ResizeSurface(nui_window& w, uint32_t width, uint32_t height) {
    w.suspended = width == 0 || height == 0;
    if (w.suspended) { w.cacheValid = false; return; }
    if (w.surfaceConfig.width == width && w.surfaceConfig.height == height) return;
    w.cacheValid = false;
    // The queue is SHARED: this sync drains every window's outstanding
    // work, so reconfiguring one window briefly stalls the others'
    // submissions. Rare and short; accepted for v1 (the marker-scoped
    // wait in DrainQueue's helper is the known refinement).
    if (!g_shared.context->submit(skgpu::graphite::SyncToCpu::kYes) || !DrainQueue()) {
        w.suspended = true;
        fprintf(stderr, "nui: GPU synchronization failed during resize; presentation suspended\n");
        return;
    }
    // Release Graphite's wrapper before its externally owned Dawn texture.
    w.cacheSurface.reset();
    w.cacheTexture = nullptr;
    w.surfaceConfig.width = width;
    w.surfaceConfig.height = height;
    w.surface.Configure(&w.surfaceConfig);
    ++w.configurations;
    Trace(w);
}

} // namespace

// ---- public C API ----------------------------------------------------------


// Surface format pick: deterministic, never capabilities order (that order
// is driver/compositor enumeration accident and carries no contract).
//
// The cache SkSurface declares an sRGB colorspace, so Skia performs the
// gamma encode itself and the texture must store the encoded bytes raw. An
// -Srgb texture format makes the hardware encode a second time on write,
// which washes the image out (seen on X11, whose Dawn offers
// BGRA8UnormSrgb first; Wayland happened to offer a working format first).
// Following WebGPU's canvas model, the surface format is therefore always
// the plain Unorm variant: BGRA8Unorm where offered, RGBA8Unorm otherwise.
// If neither is offered the backend cannot guarantee correct color, so init
// fails loudly instead of silently degrading.
wgpu::TextureFormat PickSurfaceFormat(const wgpu::SurfaceCapabilities& caps) {
    bool have_bgra = false, have_rgba = false;
    for (size_t i = 0; i < caps.formatCount; i++) {
        have_bgra |= caps.formats[i] == wgpu::TextureFormat::BGRA8Unorm;
        have_rgba |= caps.formats[i] == wgpu::TextureFormat::RGBA8Unorm;
    }
    if (have_bgra) return wgpu::TextureFormat::BGRA8Unorm;
    if (have_rgba) return wgpu::TextureFormat::RGBA8Unorm;
    return wgpu::TextureFormat::Undefined;
}

const char* FormatName(wgpu::TextureFormat f) {
    switch (f) {
        case wgpu::TextureFormat::BGRA8Unorm: return "BGRA8Unorm";
        case wgpu::TextureFormat::RGBA8Unorm: return "RGBA8Unorm";
        default:                              return "other";
    }
}

int32_t nui_init(void) {
    Shared& sh = g_shared;
    if (sh.context) return 0; // already up

    // 1. Dawn backend context.
    sh.backendContext = GetDawnContext();

    // 2. Graphite context + the one shared recorder.
    skgpu::graphite::ContextOptions options;
    sh.context = skgpu::graphite::ContextFactory::MakeDawn(sh.backendContext, options);
    if (!sh.context) {
        printf("nui_init: could not make Graphite context\n");
        nui_shutdown();
        return -1;
    }
    sh.recorder = sh.context->makeRecorder();
    if (!sh.recorder) {
        printf("nui_init: could not make recorder\n");
        nui_shutdown();
        return -1;
    }
    return 0;
}

nui_window* nui_create_window(const UiNativeHandles* handles, uint32_t width_px, uint32_t height_px) {
    Shared& sh = g_shared;
    if (!sh.context) {
        printf("nui_create_window: nui_init has not run\n");
        return nullptr;
    }
    if (!handles || !handles->driver) {
        printf("nui_create_window: null handles\n");
        return nullptr;
    }
    auto win = std::make_unique<nui_window>();

    // Dawn surface from the platform handles (no SDL on this side).
    win->surface = CreateDawnSurface(sh.backendContext.fInstance, handles);
    if (!win->surface) {
        printf("nui_create_window: could not create Dawn surface\n");
        return nullptr;
    }

    wgpu::SurfaceCapabilities capabilities;
    if (!win->surface.GetCapabilities(sh.backendContext.fDevice.GetAdapter(), &capabilities)) {
        fprintf(stderr, "nui_create_window: surface capability query failed\n");
        return nullptr;
    }
    if (!(capabilities.usages & wgpu::TextureUsage::CopyDst) || capabilities.formatCount == 0) {
        fprintf(stderr, "nui_create_window: B1 requires a surface supporting CopyDst and a texture format\n");
        return nullptr;
    }

    win->surfaceConfig.device = sh.backendContext.fDevice;
    win->surfaceConfig.format = PickSurfaceFormat(capabilities);
    if (win->surfaceConfig.format == wgpu::TextureFormat::Undefined) {
        fprintf(stderr, "nui_create_window: surface offers no BGRA8Unorm/RGBA8Unorm format (required for correct color)\n");
        return nullptr;
    }
    printf("nui: surface format %s\n", FormatName(win->surfaceConfig.format));
    win->surfaceConfig.usage = wgpu::TextureUsage::CopyDst;
    win->surfaceConfig.width = width_px;
    win->surfaceConfig.height = height_px;
    win->surfaceConfig.presentMode = wgpu::PresentMode::Fifo;
    win->suspended = width_px == 0 || height_px == 0;
    if (!win->suspended) {
        win->surface.Configure(&win->surfaceConfig);
        ++win->configurations;
    }

    // Refresh rate defaults to 60 Hz; the Odin side overrides it via
    // nui_set_refresh_rate at startup and on display changes.
    win->nextFrameTimeNs = NowNs();
    ++sh.window_count;
    return win.release();
}

void nui_destroy_window(nui_window* win) {
    if (!win) return;
    Shared& sh = g_shared;
    // Finish GPU work, then tear down. The queue is shared, so this
    // drains every window's outstanding submissions (same discipline
    // as resize). The SDL window is NOT destroyed here: Odin owns it.
    if (sh.context) {
        sh.context->submit(skgpu::graphite::SyncToCpu::kYes);
    }
    if (sh.backendContext.fQueue) DrainQueue();
    Trace(*win);
    win->cacheValid = false;
    win->cacheSurface.reset(); // Graphite's wrapper before its Dawn texture
    win->cacheTexture = nullptr;
    win->surface = nullptr;
    win->surfaceConfig.device = nullptr; // drop the device ref
    win->surfaceConfig = {};
    --sh.window_count;
    delete win;
}

void nui_resize(nui_window* win, uint32_t width_px, uint32_t height_px) {
    if (!win || !g_shared.context) return;
    ResizeSurface(*win, width_px, height_px);
}

void nui_set_refresh_rate(nui_window* win, float hz) {
    if (win && hz > 0 && hz < 300) win->targetFrameTimeNs = (uint64_t)(1e9 / hz);
}

int32_t nui_is_resizing(nui_window* win) { (void)win; return 0; } // Fifo throughout; no debounce.

int32_t nui_present_cached(nui_window* win) {
    if (!win || !g_shared.context) return 0;
    Pace(*win);
    if (win->suspended) return 0;
    return PresentCache(*win) ? 1 : 0;
}

int32_t nui_render(nui_window* win, const UiDrawCmd* cmds, int32_t n_cmds,
                const UiRect* damage, int32_t n_damage, float content_scale) {
    Shared& sh = g_shared;
    (void)damage; (void)n_damage; // Full clear requires full replay.
    if (!win || !sh.context) return 0;
    Pace(*win);
    if (win->suspended) return 0;
    win->cacheValid = false;
    if (!EnsureCache(*win)) return 0;
    auto canvas = win->cacheSurface->getCanvas();
    canvas->clear(SkColors::kBlack);
    ReplayCommands(canvas, sh.recorder.get(), cmds, n_cmds, nullptr, 0, content_scale);
    ++win->replays;
    auto recording = sh.recorder->snap();
    if (!recording) return 0;
    skgpu::graphite::InsertRecordingInfo info;
    info.fRecording = recording.get();
    if (!sh.context->insertRecording(info) || !sh.context->submit()) return 0;
    win->cacheValid = true;
    return PresentCache(*win) ? 1 : 0;
}

void nui_register_font(uint32_t family, const char* path) {
    if (!path) return;
    sk_sp<SkData> data = SkData::MakeFromFileName(path);
    if (!data) {
        printf("nui_register_font: could not load '%s'\n", path);
        return;
    }
    Shared::FontFamily& fam = g_shared.families[family];
    fam.is_name = false;
    fam.data = data;
    fam.name.clear();
    // Registration is cold; drop cached fonts so a re-registration can't go stale.
    g_shared.font_cache.clear();
}

void nui_register_font_family(uint32_t family, const char* name) {
    if (!name) return;
    Shared::FontFamily& fam = g_shared.families[family];
    fam.is_name = true;
    fam.name = name;
    fam.data.reset();
    g_shared.font_cache.clear();
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

uint32_t nui_image_decode(const uint8_t* bytes, int32_t len, int32_t max_w, int32_t max_h,
                          float* out_w, float* out_h) {
    if (!bytes || len <= 0) return 0;
    sk_sp<SkData> data = SkData::MakeWithCopy(bytes, (size_t)len);
    std::unique_ptr<SkCodec> codec = SkCodec::MakeFromData(data);
    if (!codec) return 0;
    const SkImageInfo info = codec->getInfo();
    const int nat_w = info.width(), nat_h = info.height();
    if (nat_w <= 0 || nat_h <= 0) return 0;

    // Shrink-only, aspect-preserving (one axis may be 0 =
    // unconstrained): Avalonia's DecodeToWidth/Height semantics.
    double scale = 1.0;
    if (max_w > 0) scale = std::min(scale, (double)max_w / nat_w);
    if (max_h > 0) scale = std::min(scale, (double)max_h / nat_h);
    const int tw = std::max(1, (int)std::lround(nat_w * scale));
    const int th = std::max(1, (int)std::lround(nat_h * scale));

    // Decode to pixels here, converted to N32: the codec's
    // native format for e.g. an opaque PNG is RGB_888x, which
    // Graphite/Dawn cannot texturize — a deferred
    // (generator-backed) image in that format failed key
    // creation at draw time on the first field build and every
    // draw was dropped. Raster + N32 is the shape that draws;
    // the cost is decoded pixels pinned instead of encoded
    // bytes retained.
    const SkImageInfo dst_info = info.makeColorType(kN32_SkColorType);
    SkBitmap full;
    if (!full.tryAllocPixels(dst_info)) return 0;
    if (codec->getPixels(full.pixmap()) != SkCodec::kSuccess) return 0;
    SkBitmap pixels = full;
    if (tw != nat_w || th != nat_h) {
        // Resample into the target bitmap with a temp raster
        // image (CPU-side; no Graphite involvement).
        sk_sp<SkImage> full_img = SkImages::RasterFromBitmap(full);
        SkBitmap small;
        if (full_img && small.tryAllocPixels(dst_info.makeWH(tw, th)) &&
            full_img->scalePixels(small.pixmap(),
                                  SkSamplingOptions(SkCubicResampler::Mitchell()))) {
            pixels = small;
        }
    }

    const uint32_t id = g_shared.next_image_id++;
    g_shared.images[id].pixels = pixels;
    // DIAGNOSTIC (image-draw investigation, temporary).
    fprintf(stderr, "nui: image_decode v3-pixels id=%u %dx%d ct=%d at=%d cs=%s\n",
            id, pixels.width(), pixels.height(), (int)pixels.colorType(),
            (int)pixels.alphaType(), pixels.colorSpace() ? "set" : "null");
    if (out_w) *out_w = (float)tw;
    if (out_h) *out_h = (float)th;
    return id;
}

void nui_image_release(uint32_t id) {
    g_shared.images.erase(id);
}

void nui_shutdown(void) {
    Shared& sh = g_shared;
    // Finish GPU work, then tear down the shared device side. Windows
    // must already be destroyed (a live window's surface holds device
    // refs; wgpu handles are refcounted, so a straggler degrades to a
    // leak, not a crash — but it IS a caller bug, so say so).
    if (sh.window_count > 0) {
        fprintf(stderr, "nui_shutdown: %d window(s) still live (caller bug)\n", sh.window_count);
    }
    if (sh.context) {
        sh.context->submit(skgpu::graphite::SyncToCpu::kYes);
    }
    if (sh.backendContext.fQueue) DrainQueue();
    sh.families.clear();
    sh.font_cache.clear();
    sh.images.clear();
    sh.recorder.reset();
    sh.context.reset();
    sh.backendContext = {};
    sh = Shared{};
}
