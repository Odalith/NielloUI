// NielloUI Graphite/Dawn backend.
//
// All public calls belong to one UI thread. API calls are serialized, but
// serialization does not permit transferring a Graphite recorder between
// threads. OS/native window objects remain owned by the host.
//
// Errors never intentionally terminate the host. After a GPU/recording failure,
// destroy all windows, shut down, and initialize again.

#include "nui.h"
#include "util.h"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "include/codec/SkCodec.h"
#include "include/core/SkBitmap.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkData.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontMetrics.h"
#include "include/core/SkFontMgr.h"
#include "include/core/SkImage.h"
#include "include/core/SkPaint.h"
#include "include/core/SkRRect.h"
#include "include/core/SkSamplingOptions.h"
#include "include/core/SkSurface.h"
#include "include/core/SkTextBlob.h"

#include "modules/skshaper/include/SkShaper.h"
#include "include/core/SkTypeface.h"

#include "gpu/graphite/BackendTexture.h"
#include "gpu/graphite/dawn/DawnGraphiteTypes.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/Image.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Surface.h"

#if defined(__linux__)
#include "include/ports/SkFontMgr_fontconfig.h"
#include "include/ports/SkFontScanner_FreeType.h"
#elif defined(__APPLE__)
#include "include/ports/SkFontMgr_mac_ct.h"
#elif defined(_WIN32)
#include "include/ports/SkTypeface_win.h"
#endif

// Defined in util.cpp; not exported through the public C header.
bool NuiDawnBackendFailed() noexcept;

static_assert(offsetof(UiDrawCmd, text_ptr) == 32);
static_assert(offsetof(UiDrawCmd, src_x) == 68);
static_assert(offsetof(UiDrawCmd, image) == 84);
static_assert(offsetof(UiDrawCmd, interp) == 88);

struct nui_window {
    // driver owns the string referenced by handles.driver.
    std::string driver;
    UiNativeHandles handles{};

    wgpu::Surface surface;
    wgpu::SurfaceConfiguration config{};

    // Declaration order ensures the Skia wrapper dies before the texture.
    wgpu::Texture cacheTexture;
    sk_sp<SkSurface> cacheSurface;

    uint32_t width = 0;
    uint32_t height = 0;
    bool configured = false;
    bool recreateSurface = false;
    bool cacheValid = false;

    uint64_t targetFrameTimeNs = 1'000'000'000 / 60;
    uint64_t nextFrameTimeNs = 0;

    uint64_t replays = 0;
    uint64_t copies = 0;
    uint64_t configurations = 0;
    uint64_t acquireFailures = 0;
};

namespace {

constexpr size_t kMaxFontCacheEntries = 2048;
constexpr size_t kMaxFamilies = 1024;
constexpr size_t kMaxImages = 4096;
constexpr uint64_t kMaxImagePixels = 32ull * 1024 * 1024;
constexpr uint64_t kMaxRasterBytes = 256ull * 1024 * 1024;
constexpr int32_t kMaxEncodedBytes = 64 * 1024 * 1024;
constexpr int64_t kMaxTextBytes = 4 * 1024 * 1024;
constexpr int32_t kMaxCommands = 1'000'000;
constexpr size_t kMaxScopeDepth = 4096;
constexpr unsigned kPresentationBatchSize = 2;

std::mutex g_apiMutex;
std::thread::id g_ownerThread;
bool g_haveOwnerThread = false;

// Process-lifetime sequence. Zero is never allocated; exhaustion never wraps.
// Kept outside Shared so shutdown cannot recycle IDs.
uint64_t g_nextImageId = 1;

struct FontFamily {
    sk_sp<SkData> data;
    std::string name;
    bool isName = false;
};

struct FontKey {
    uint32_t family;
    int32_t weight;
    int32_t slant;
    float size;

    bool operator==(const FontKey& other) const {
        return family == other.family && weight == other.weight &&
               slant == other.slant && size == other.size;
    }
};

struct FontKeyHash {
    size_t operator()(const FontKey& key) const noexcept {
        size_t hash = std::hash<uint32_t>{}(key.family);
        const auto mix = [&hash](size_t value) {
            hash ^= value + size_t{0x9e3779b9} + (hash << 6) + (hash >> 2);
        };
        mix(std::hash<int32_t>{}(key.weight));
        mix(std::hash<int32_t>{}(key.slant));
        mix(std::hash<float>{}(key.size));
        return hash;
    }
};

struct ImageEntry {
    sk_sp<SkImage> raster;
    sk_sp<SkImage> texture;
    bool mipmapped = false;
    uint64_t rasterBytes = 0;
};

struct Shared {
    skgpu::graphite::DawnBackendContext backend{};
    std::unique_ptr<skgpu::graphite::Context> context;
    std::unique_ptr<skgpu::graphite::Recorder> recorder;

    sk_sp<SkFontMgr> fontMgr;
    std::unique_ptr<SkShaper> shaper;
    std::unordered_map<uint32_t, FontFamily> families;
    std::unordered_map<FontKey, SkFont, FontKeyHash> fonts;
    std::unordered_map<uint32_t, ImageEntry> images;
    // Images released by nui_image_release, awaiting the sweep
    // (audit nat-13): out of the live map, refs not yet dropped.
    std::vector<ImageEntry> retiredImages;
    std::unordered_set<nui_window*> windows;

    uint64_t rasterBytes = 0;
    uint32_t maxTextureDimension = 0;
    unsigned pendingPresentations = 0;
    // Failure tiers (audit BL-4; the latch used to be one bool, so
    // any local failure bricked the process):
    //  - Device (failed): Dawn backend / device / queue is gone.
    //    Nothing renders; recovery is destroy windows, then
    //    nui_shutdown or nui_init (see nui_init's contract).
    //  - Recording (recorderPoisoned): an exception or a failed
    //    Graphite submit left the recorder's pending state
    //    suspect. Calls fail until the recorder is recreated,
    //    which nui_resize and nui_init attempt.
    //  - Surface failures are NOT latched here at all: they live
    //    on the window (configured / recreateSurface) and recover
    //    by reconfiguration, without touching other windows.
    bool failed = false;
    bool recorderPoisoned = false;
    bool trace = std::getenv("NUI_TRACE") != nullptr;
};

Shared g;

void Log(const char* message) noexcept {
    std::fprintf(stderr, "nui: %s\n", message);
}

bool CheckThread() noexcept {
    const auto current = std::this_thread::get_id();
    if (!g_haveOwnerThread) {
        g_ownerThread = current;
        g_haveOwnerThread = true;
    }
    if (g_ownerThread == current) return true;
    Log("API called from a non-owner thread");
    return false;
}

// Exceptions in rendering can leave pending recorder work. Fail closed rather
// than attempting to continue recording into partially modified state.
template <typename R, typename F>
R Api(const char* name, R failure, F&& function) noexcept {
    try {
        std::lock_guard lock(g_apiMutex);
        if (!CheckThread()) return failure;
        try {
            return function();
        } catch (const std::exception& error) {
            g.recorderPoisoned = true;
            std::fprintf(stderr, "nui: %s: %s\n", name, error.what());
        } catch (...) {
            g.recorderPoisoned = true;
            std::fprintf(stderr, "nui: %s: unknown C++ exception\n", name);
        }
    } catch (...) {
        std::fprintf(stderr, "nui: %s: API synchronization failed\n", name);
    }
    return failure;
}

template <typename F>
void ApiVoid(const char* name, F&& function) noexcept {
    (void)Api<int>(name, 0, [&] {
        function();
        return 1;
    });
}

bool Ready() {
    if (!g.context || !g.recorder || g.failed || g.recorderPoisoned) return false;
    if (NuiDawnBackendFailed()) {
        g.failed = true;
        return false;
    }
    return true;
}

bool Live(const nui_window* window) {
    return window && g.windows.contains(const_cast<nui_window*>(window));
}

bool DimensionsValid(uint32_t width, uint32_t height) {
    return width <= g.maxTextureDimension &&
           height <= g.maxTextureDimension;
}

uint64_t NowNs() {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count());
}

// Pace sleeps until the window's next frame slot. The anchor is a
// fixed grid (audit nat-6): the next slot steps by whole periods
// from the previous one instead of re-anchoring to completion
// time, so the effective rate is the requested Hz, not Hz minus
// frame work. A grid that has fallen a full period behind (long
// frame, suspend) re-anchors to now rather than bursting catch-up
// presents. Only nui_present_cached calls this — see there.
void Pace(nui_window& window) {
    const uint64_t now = NowNs();
    if (now < window.nextFrameTimeNs) {
        std::this_thread::sleep_for(
            std::chrono::nanoseconds(window.nextFrameTimeNs - now));
    }
    const uint64_t next = window.nextFrameTimeNs + window.targetFrameTimeNs;
    const uint64_t after = NowNs();
    window.nextFrameTimeNs = next > after ? next : after + window.targetFrameTimeNs;
}

void Trace(const nui_window& window) noexcept {
    if (!g.trace) return;
    std::fprintf(
        stderr,
        "nui: replays=%llu copies=%llu configurations=%llu "
        "acquire_failures=%llu size=%ux%u valid=%d\n",
        static_cast<unsigned long long>(window.replays),
        static_cast<unsigned long long>(window.copies),
        static_cast<unsigned long long>(window.configurations),
        static_cast<unsigned long long>(window.acquireFailures),
        window.width, window.height, static_cast<int>(window.cacheValid));
}

bool DrainQueue() {
    if (!g.backend.fQueue || !g.backend.fInstance) return true;

    auto success = std::make_shared<bool>(false);
    const auto future = g.backend.fQueue.OnSubmittedWorkDone(
        wgpu::CallbackMode::WaitAnyOnly,
        [success](wgpu::QueueWorkDoneStatus status,
                  wgpu::StringView) {
            *success = status == wgpu::QueueWorkDoneStatus::Success;
        });

    const auto status = g.backend.fInstance.WaitAny(future, UINT64_MAX);
    g.pendingPresentations = 0;

    if (status != wgpu::WaitStatus::Success || !*success ||
        NuiDawnBackendFailed()) {
        g.failed = true;
        Log("GPU queue synchronization failed");
        return false;
    }
    return true;
}

bool Synchronize() {
    if (g.context &&
        !g.context->submit(skgpu::graphite::SyncToCpu::kYes)) {
        g.recorderPoisoned = true;
        Log("Graphite submit failed during synchronization");
    }
    const bool drained = DrainQueue();
    if (drained) {
        // The sweep point for retired images (audit nat-13): with
        // the queue empty, nothing in flight can still reference
        // them, so their refs may drop here — once per drain, not
        // once per release.
        g.retiredImages.clear();
    }
    return drained && !g.failed && !g.recorderPoisoned;
}

void DropCache(nui_window& window) {
    window.cacheValid = false;
    window.cacheSurface.reset();
    window.cacheTexture = nullptr;
}

SkFontMgr* GetFontMgr() {
    if (!g.fontMgr) {
#if defined(__linux__)
        g.fontMgr =
            SkFontMgr_New_FontConfig(nullptr, SkFontScanner_Make_FreeType());
#elif defined(__APPLE__)
        g.fontMgr = SkFontMgr_New_CoreText(nullptr);
#elif defined(_WIN32)
        g.fontMgr = SkFontMgr_New_DirectWrite();
#endif
        if (!g.fontMgr) Log("could not create platform font manager");
    }
    return g.fontMgr.get();
}

// GetShaper lazily builds the process-wide text shaper
// (SkShaper::Make over the platform font manager: the
// HarfBuzz-backed shaper in this build configuration — see
// tools/build-native.md §3). The manager is the fallback for
// runs the resolved font cannot cover.
SkShaper* GetShaper() {
    if (!g.shaper) {
        auto* manager = GetFontMgr();
        if (!manager) return nullptr;
        g.shaper = SkShaper::Make(sk_ref_sp(manager));
        if (!g.shaper) Log("could not create text shaper");
    }
    return g.shaper.get();
}

// AdvanceHandler sums the shaped advance of a fragment without
// building a blob: RunInfo.fAdvance is the only trustworthy
// width a RunHandler ever sees. (SkTextBlobBuilderRunHandler's
// endPoint() is NOT one: its fOffset advances only vertically,
// line to line — endPoint().x() is the caller's own offset back.)
class AdvanceHandler final : public SkShaper::RunHandler {
public:
    float advance = 0;

    void beginLine() override {}
    void runInfo(const RunInfo& info) override { advance += info.fAdvance.x(); }
    void commitRunInfo() override {}
    Buffer runBuffer(const RunInfo& info) override {
        glyphs.assign(info.glyphCount, 0);
        positions.assign(info.glyphCount, SkPoint::Make(0, 0));
        clusters.assign(info.glyphCount, 0);
        return {glyphs.data(), positions.data(), nullptr, clusters.data(),
                SkPoint::Make(0, 0)};
    }
    void commitRunBuffer(const RunInfo&) override {}
    void commitLine() override {}

private:
    std::vector<SkGlyphID> glyphs;
    std::vector<SkPoint> positions;
    std::vector<uint32_t> clusters;
};

// Fragments are the engine's shaping boundary: the Odin word
// cache measures fragments and the draw stream emits them, so
// measured == drawn holds per fragment, kerning and ligatures
// included (audit X-3). The shaper sees the fragment as one
// LTR paragraph; embedded bidirectional runs are reordered by
// the shaper's bidi pass.
bool MeasureAdvance(const SkFont& font, const char* text, size_t length,
                    float* out) {
    auto* shaper = GetShaper();
    if (!shaper || length == 0) return false;
    AdvanceHandler handler;
    shaper->shape(text, length, font, true, SK_ScalarInfinity, &handler);
    *out = handler.advance;
    return std::isfinite(*out);
}

// ShapeText shapes one fragment into a blob. The blob's glyph
// positions are relative to the LINE TOP (the blob handler
// bakes the line's ascent into its run positions), so callers
// draw it at the text rect's top, not at a baseline.
bool ShapeText(const SkFont& font, const char* text, size_t length,
               sk_sp<SkTextBlob>* out) {
    auto* shaper = GetShaper();
    if (!shaper || length == 0) return false;
    SkTextBlobBuilderRunHandler handler(text, SkPoint::Make(0, 0));
    shaper->shape(text, length, font, true, SK_ScalarInfinity, &handler);
    *out = handler.makeBlob();
    return *out != nullptr;
}

bool FontSizeValid(float size) {
    return std::isfinite(size) && size > 0 && size <= 4096;
}

SkFont* ResolveFont(uint32_t family, int32_t weight,
                    int32_t slant, float size) {
    if (!FontSizeValid(size)) return nullptr;
    weight = std::clamp(weight, 100, 900);
    slant = std::clamp(slant, 0, 2);

    const FontKey key{family, weight, slant, size};
    if (auto it = g.fonts.find(key); it != g.fonts.end()) {
        return &it->second;
    }

    auto* manager = GetFontMgr();
    if (!manager) return nullptr;

    const SkFontStyle requested(
        weight, SkFontStyle::kNormal_Width,
        static_cast<SkFontStyle::Slant>(slant));

    sk_sp<SkTypeface> typeface;
    if (auto it = g.families.find(family); it != g.families.end()) {
        const auto& registered = it->second;
        if (registered.isName) {
            typeface =
                manager->matchFamilyStyle(registered.name.c_str(), requested);
        } else if (registered.data) {
            int bestScore = INT_MAX;
            for (int index = 0; index < 64; ++index) {
                auto candidate =
                    manager->makeFromData(registered.data, index);
                if (!candidate) break;
                const auto style = candidate->fontStyle();
                const int score =
                    std::abs(style.weight() - weight) * 4 +
                    std::abs(static_cast<int>(style.slant()) - slant);
                if (score < bestScore) {
                    bestScore = score;
                    typeface = std::move(candidate);
                }
            }
        }
    }

    if (!typeface) {
        // The default font must come from legacyMakeTypeface(nullptr):
        // matchFamilyStyle(nullptr, ...) is not a portable way to ask
        // for it — the DirectWrite manager's onMatchFamily
        // null-guards to an empty style set, so on Windows it silently
        // yields no typeface at all (zero measurements, no text), where
        // FontConfig happens to tolerate the null family name.
        typeface = manager->legacyMakeTypeface(nullptr, requested);
    }
    if (!typeface) return nullptr;

    // Bounded exact-size cache: measurements and drawing use identical sizes.
    // No caller retains a pointer across another ResolveFont call.
    if (g.fonts.size() >= kMaxFontCacheEntries) g.fonts.clear();
    return &g.fonts.emplace(key, SkFont(typeface, size)).first->second;
}

SkColor Color(const uint8_t rgba[4]) {
    return SkColorSetARGB(rgba[3], rgba[0], rgba[1], rgba[2]);
}

SkRect Bounds(const UiDrawCmd& command) {
    return SkRect::MakeXYWH(command.bounds_x, command.bounds_y,
                            command.bounds_w, command.bounds_h);
}

bool RectValid(float x, float y, float width, float height) {
    return std::isfinite(x) && std::isfinite(y) &&
           std::isfinite(width) && std::isfinite(height) &&
           width >= 0 && height >= 0 &&
           std::isfinite(x + width) && std::isfinite(y + height);
}

// Strict UTF-8 validation; never reads beyond [bytes, bytes + length).
// When requested, boundaries contains 0 and every complete code-point end.
bool Utf8(const uint8_t* bytes, int64_t length,
          std::vector<size_t>* boundaries = nullptr) {
    if (length < 0 || length > kMaxTextBytes ||
        (length > 0 && !bytes)) return false;

    if (boundaries) {
        boundaries->clear();
        boundaries->push_back(0);
    }

    const size_t size = static_cast<size_t>(length);
    size_t offset = 0;
    while (offset < size) {
        const uint8_t lead = bytes[offset];
        size_t count = 0;
        uint32_t value = 0;
        uint32_t minimum = 0;

        if (lead < 0x80) {
            count = 1;
            value = lead;
        } else if (lead >= 0xC2 && lead <= 0xDF) {
            count = 2;
            value = lead & 0x1F;
            minimum = 0x80;
        } else if (lead >= 0xE0 && lead <= 0xEF) {
            count = 3;
            value = lead & 0x0F;
            minimum = 0x800;
        } else if (lead >= 0xF0 && lead <= 0xF4) {
            count = 4;
            value = lead & 0x07;
            minimum = 0x10000;
        } else {
            return false;
        }

        if (count > size - offset) return false;
        for (size_t index = 1; index < count; ++index) {
            const uint8_t next = bytes[offset + index];
            if ((next & 0xC0) != 0x80) return false;
            value = (value << 6) | (next & 0x3F);
        }
        if (value < minimum || value > 0x10FFFF ||
            (value >= 0xD800 && value <= 0xDFFF)) return false;

        offset += count;
        if (boundaries) boundaries->push_back(offset);
    }
    return true;
}

// Validate before touching the persistent canvas or shared recorder.
bool ValidateCommands(const UiDrawCmd* commands, int32_t count) {
    if (count < 0 || count > kMaxCommands ||
        (count > 0 && !commands)) return false;

    std::vector<uint8_t> scopes;
    for (int32_t index = 0; index < count; ++index) {
        const auto& command = commands[index];
        if (command.tag > UI_CMD_IMAGE) return false;

        if (command.tag == UI_CMD_POP_CLIP ||
            command.tag == UI_CMD_POP_OPACITY) {
            const uint8_t expected =
                command.tag == UI_CMD_POP_CLIP
                    ? UI_CMD_PUSH_CLIP : UI_CMD_PUSH_OPACITY;
            if (scopes.empty() || scopes.back() != expected) return false;
            scopes.pop_back();
            continue;
        }

        if (!RectValid(command.bounds_x, command.bounds_y,
                       command.bounds_w, command.bounds_h)) return false;

        if (command.tag == UI_CMD_PUSH_CLIP ||
            command.tag == UI_CMD_PUSH_OPACITY) {
            if (scopes.size() >= kMaxScopeDepth) return false;
            scopes.push_back(command.tag);
        }

        if (command.tag == UI_CMD_TEXT) {
            if (!FontSizeValid(command.font_size) ||
                !Utf8(command.text_ptr, command.text_len) ||
                (command.truncated &&
                 !std::isfinite(command.max_width))) return false;
        }

        if (command.tag == UI_CMD_IMAGE &&
            !RectValid(command.src_x, command.src_y,
                       command.src_w, command.src_h)) return false;
    }
    return scopes.empty();
}

// Corner radius clamped to half the smaller side, matching the engine's
// hit test (point_in_node). Commands carry the raw style radius; every
// consumer clamps with this one formula so fill, clip, and pick agree.
float ClampedRadius(const UiDrawCmd& command) {
    return std::min(static_cast<float>(command.radius),
                    std::min(command.bounds_w, command.bounds_h) * 0.5f);
}

void DrawRect(SkCanvas* canvas, const UiDrawCmd& command) {
    const SkRect rect = Bounds(command);
    if (rect.isEmpty()) return;

    const float radius = ClampedRadius(command);
    const SkRRect outer = SkRRect::MakeRectXY(rect, radius, radius);

    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor(Color(command.color));
    canvas->drawRRect(outer, paint);

    if (!command.border_width) return;

    paint.setColor(Color(command.border_color));
    const float width = static_cast<float>(command.border_width);

    // A border consuming either dimension fills the entire outer shape.
    if (2 * width >= std::min(rect.width(), rect.height())) {
        canvas->drawRRect(outer, paint);
        return;
    }

    SkRect innerRect = rect;
    innerRect.inset(width, width);
    const float innerRadius = std::max(0.0f, radius - width);
    const SkRRect inner =
        SkRRect::MakeRectXY(innerRect, innerRadius, innerRadius);
    canvas->drawDRRect(outer, inner, paint);
}

void DrawImage(SkCanvas* canvas, const UiDrawCmd& command) {
    auto it = g.images.find(command.image);
    if (it == g.images.end() ||
        command.bounds_w <= 0 || command.bounds_h <= 0 ||
        command.src_w <= 0 || command.src_h <= 0) return;

    auto& entry = it->second;
    // Interp 0 (High: cubic) and 1 (linear) both minify with
    // mipmaps — the Odin enum's contract (audit nat-4: High
    // silently lost its mips to an enum mismatch here).
    const bool needMips = command.interp == 0 || command.interp == 1;

    if (!entry.texture || (needMips && !entry.mipmapped)) {
        SkImage::RequiredProperties properties{};
        properties.fMipmapped = needMips;
        auto texture = SkImages::TextureFromImage(
            g.recorder.get(), entry.raster.get(), properties);
        if (!texture) return;
        entry.texture = std::move(texture);
        entry.mipmapped = needMips;
    }

    SkSamplingOptions sampling;
    switch (command.interp) {
        case 1:
            sampling = SkSamplingOptions(
                SkFilterMode::kLinear, SkMipmapMode::kLinear);
            break;
        case 2:
            sampling = SkSamplingOptions(
                SkFilterMode::kLinear, SkMipmapMode::kNone);
            break;
        case 3:
            sampling = SkSamplingOptions(
                SkFilterMode::kNearest, SkMipmapMode::kNone);
            break;
        default:
            sampling = SkSamplingOptions(SkCubicResampler::Mitchell());
            break;
    }

    const SkRect source = SkRect::MakeXYWH(
        command.src_x, command.src_y, command.src_w, command.src_h);
    // A rounded node rounds its own image, like its fill: clip the
    // draw to the drawn rect's rounded shape (the dest rect, which
    // is the node rect for filling fits). Radius zero keeps the
    // plain draw; the clamp is the shared ClampedRadius formula.
    const float radius = ClampedRadius(command);
    SkAutoCanvasRestore rounded_clip(canvas, radius > 0);
    if (radius > 0) {
        canvas->clipRRect(SkRRect::MakeRectXY(Bounds(command), radius, radius),
                          SkClipOp::kIntersect, true);
    }
    canvas->drawImageRect(
        entry.texture.get(), source, Bounds(command), sampling, nullptr,
        SkCanvas::kStrict_SrcRectConstraint);
}

void DrawText(SkCanvas* canvas, const UiDrawCmd& command) {
    if (command.text_len == 0) return;
    if (command.truncated && command.max_width <= 0) return;

    auto* font = ResolveFont(
        command.font, command.font_weight, command.font_slant,
        command.font_size);
    if (!font) return;

    const auto* text = reinterpret_cast<const char*>(command.text_ptr);
    size_t length = static_cast<size_t>(command.text_len);
    std::string owned;

    if (command.truncated) {
        float fullAdvance = 0;
        if (!MeasureAdvance(*font, text, length, &fullAdvance)) return;

        if (fullAdvance > command.max_width) {
            // Cut at a UTF-8 boundary: binary search for the widest
            // prefix whose SHAPED form (prefix + ellipsis, shaped as
            // one run, so the cut point takes its final forms) fits.
            constexpr char ellipsis[] = "\xE2\x80\xA6";

            std::vector<size_t> boundaries;
            if (!Utf8(command.text_ptr, command.text_len, &boundaries)) return;

            auto fits = [&](size_t boundary) {
                std::string candidate(text, boundary);
                candidate.append(ellipsis, 3);
                float advance = 0;
                return MeasureAdvance(*font, candidate.data(), candidate.size(),
                                      &advance) &&
                       advance <= command.max_width;
            };

            if (!fits(0)) return; // the ellipsis alone is too wide

            size_t low = 0;
            size_t high = boundaries.size() - 1;
            while (low < high) {
                const size_t middle = low + (high - low + 1) / 2;
                if (fits(boundaries[middle])) {
                    low = middle;
                } else {
                    high = middle - 1;
                }
            }

            owned.assign(text, boundaries[low]);
            owned.append(ellipsis, 3);
            text = owned.data();
            length = owned.size();
        }
    }

    sk_sp<SkTextBlob> blob;
    if (!ShapeText(*font, text, length, &blob)) return;

    SkPaint paint;
    paint.setAntiAlias(true);
    paint.setColor(Color(command.color));

    // The shaped blob's positions are line-top relative (see
    // ShapeText): bounds_y is the text rect's top.
    canvas->drawTextBlob(blob.get(), command.bounds_x, command.bounds_y, paint);
}

void Replay(SkCanvas* canvas, const UiDrawCmd* commands,
            int32_t count, float scale) {
    // Restores the original save count even if a C++ allocation throws.
    SkAutoCanvasRestore restore(canvas, true);
    canvas->scale(scale, scale);

    for (int32_t index = 0; index < count; ++index) {
        const auto& command = commands[index];
        switch (command.tag) {
            case UI_CMD_RECT:
            case UI_CMD_OVERLAY:
                DrawRect(canvas, command);
                break;
            case UI_CMD_TEXT:
                DrawText(canvas, command);
                break;
            case UI_CMD_IMAGE:
                DrawImage(canvas, command);
                break;
            case UI_CMD_PUSH_CLIP: {
                canvas->save();
                const float radius = ClampedRadius(command);
                if (radius > 0) {
                    canvas->clipRRect(
                        SkRRect::MakeRectXY(Bounds(command), radius, radius),
                        SkClipOp::kIntersect, true);
                } else {
                    canvas->clipRect(
                        Bounds(command), SkClipOp::kIntersect, true);
                }
                break;
            }
            case UI_CMD_PUSH_OPACITY: {
                const SkRect bounds = Bounds(command);
                canvas->saveLayerAlpha(&bounds, command.opacity);
                break;
            }
            case UI_CMD_POP_CLIP:
            case UI_CMD_POP_OPACITY:
                canvas->restore();
                break;
        }
    }
}

wgpu::TextureFormat PickFormat(const wgpu::SurfaceCapabilities& capabilities) {
    for (size_t index = 0; index < capabilities.formatCount; ++index) {
        if (capabilities.formats[index] == wgpu::TextureFormat::BGRA8Unorm) {
            return wgpu::TextureFormat::BGRA8Unorm;
        }
    }
    for (size_t index = 0; index < capabilities.formatCount; ++index) {
        if (capabilities.formats[index] == wgpu::TextureFormat::RGBA8Unorm) {
            return wgpu::TextureFormat::RGBA8Unorm;
        }
    }
    return wgpu::TextureFormat::Undefined;
}

bool Configure(nui_window& window) {
    if (!Ready() || !window.width || !window.height ||
        !DimensionsValid(window.width, window.height)) {
        Log("configure skipped: backend not ready or bad size");
        return false;
    }

    if (window.configured && !window.recreateSurface &&
        window.config.width == window.width &&
        window.config.height == window.height) return true;

    // Cache retirement and native swapchain changes are cold paths.
    if (!Synchronize()) return false;

    if (window.recreateSurface || !window.surface) {
        if (window.surface) {
            // Replacing a live surface object: logged because a
            // second CreateSurface for the same OS surface while
            // the first is still compositor-registered is fatal
            // on Wayland (linux-drm-syncobj "surface already
            // exists") — this line is the witness for that path.
            Log("replacing an existing surface");
        }
        window.configured = false;
        window.surface = nullptr;
        window.surface =
            CreateDawnSurface(g.backend.fInstance, &window.handles);
        if (!window.surface) {
            Log("surface creation failed");
            return false;
        }
        window.recreateSurface = false;
    }

    wgpu::SurfaceCapabilities capabilities{};
    if (!window.surface.GetCapabilities(
            g.backend.fDevice.GetAdapter(), &capabilities) ||
        !(capabilities.usages & wgpu::TextureUsage::CopyDst)) {
        Log("surface does not support the required CopyDst path");
        return false;
    }

    const auto format = PickFormat(capabilities);
    if (format == wgpu::TextureFormat::Undefined ||
        capabilities.alphaModeCount == 0) {
        Log("surface has no supported format/alpha mode");
        return false;
    }

    bool fifo = false;
    for (size_t index = 0; index < capabilities.presentModeCount; ++index) {
        fifo |= capabilities.presentModes[index] == wgpu::PresentMode::Fifo;
    }
    if (!fifo) {
        Log("surface does not support FIFO presentation");
        return false;
    }

    if (window.config.width != window.width ||
        window.config.height != window.height ||
        window.config.format != format) {
        DropCache(window);
    }

    window.config = {};
    window.config.device = g.backend.fDevice;
    window.config.format = format;
    window.config.usage = wgpu::TextureUsage::CopyDst;
    window.config.width = window.width;
    window.config.height = window.height;
    window.config.presentMode = wgpu::PresentMode::Fifo;
    window.config.alphaMode = capabilities.alphaModes[0];

    // Prefer opaque composition for this opaque-black-backed renderer.
    for (size_t index = 0; index < capabilities.alphaModeCount; ++index) {
        if (capabilities.alphaModes[index] ==
            wgpu::CompositeAlphaMode::Opaque) {
            window.config.alphaMode = wgpu::CompositeAlphaMode::Opaque;
            break;
        }
    }

    window.surface.Configure(&window.config);
    if (!Ready()) return false;

    window.configured = true;
    ++window.configurations;
    Trace(window);
    return true;
}

bool EnsureCache(nui_window& window) {
    if (window.cacheSurface) return true;

    wgpu::TextureDescriptor desc{};
    desc.label = "Niello owned frame cache";
    desc.size = {window.width, window.height, 1};
    desc.format = window.config.format;
    desc.usage = wgpu::TextureUsage::RenderAttachment |
                 wgpu::TextureUsage::CopySrc |
                 wgpu::TextureUsage::TextureBinding;

    auto texture = g.backend.fDevice.CreateTexture(&desc);
    if (!texture || !Ready()) {
        Log("cache texture creation failed");
        return false;
    }

    const auto backend =
        skgpu::graphite::BackendTextures::MakeDawn(texture.Get());
    auto surface = SkSurfaces::WrapBackendTexture(
        g.recorder.get(), backend, SkColorSpace::MakeSRGB(), nullptr);
    if (!surface) {
        Log("cache surface wrap failed");
        return false;
    }

    window.cacheTexture = std::move(texture);
    window.cacheSurface = std::move(surface);
    return true;
}

bool Present(nui_window& window) {
    if (!Configure(window) || !window.cacheValid ||
        !window.cacheSurface || !window.cacheTexture) return false;

    // Bounds shared-queue work without waiting after every present.
    if (g.pendingPresentations >= kPresentationBatchSize &&
        !DrainQueue()) return false;

    wgpu::SurfaceTexture acquired{};
    window.surface.GetCurrentTexture(&acquired);

    switch (acquired.status) {
        case wgpu::SurfaceGetCurrentTextureStatus::SuccessOptimal:
        case wgpu::SurfaceGetCurrentTextureStatus::SuccessSuboptimal:
            break;

        case wgpu::SurfaceGetCurrentTextureStatus::Timeout:
            ++window.acquireFailures;
            Log("surface acquisition timed out");
            return false;

        case wgpu::SurfaceGetCurrentTextureStatus::Outdated:
            ++window.acquireFailures;
            Log("surface acquisition outdated; reconfiguring");
            window.configured = false;
            return false;

        case wgpu::SurfaceGetCurrentTextureStatus::Lost:
            ++window.acquireFailures;
            Log("surface lost; recreating the surface");
            window.configured = false;
            window.recreateSurface = true;
            return false;

        default:
            // Surface tier (audit BL-4): an acquisition failure is
            // this window's problem, not the process's. Recreate
            // the surface on the next Configure; other windows
            // keep rendering.
            ++window.acquireFailures;
            window.configured = false;
            window.recreateSurface = true;
            Log("surface acquisition failed; recreating the surface");
            return false;
    }

    if (!acquired.texture || !Ready()) return false;

    if (acquired.texture.GetWidth() != window.width ||
        acquired.texture.GetHeight() != window.height ||
        acquired.texture.GetFormat() != window.config.format) {
        // Release the acquisition before a future reconfiguration.
        acquired.texture = nullptr;
        window.configured = false;
        return false;
    }

    auto encoder = g.backend.fDevice.CreateCommandEncoder();
    if (!encoder) {
        g.failed = true;
        return false;
    }

    wgpu::TexelCopyTextureInfo source{}, destination{};
    source.texture = window.cacheTexture;
    destination.texture = acquired.texture;
    const wgpu::Extent3D size{window.width, window.height, 1};
    encoder.CopyTextureToTexture(&source, &destination, &size);

    auto commands = encoder.Finish();
    if (!commands || !Ready()) {
        g.failed = true;
        return false;
    }

    // Graphite and this copy use the same queue. Submission order establishes
    // the dependency; no per-frame CPU wait is required.
    g.backend.fQueue.Submit(1, &commands);
    ++g.pendingPresentations;

    const auto status = window.surface.Present();
    if (status != wgpu::Status::Success || !Ready()) {
        Log("surface present failed");
        window.configured = false;
        return false;
    }

    if (acquired.status ==
        wgpu::SurfaceGetCurrentTextureStatus::SuccessSuboptimal) {
        window.configured = false;
    }

    ++window.copies;
    if (window.copies % 60 == 0) Trace(window);
    return true;
}

void ResetShared() {
    // Caller has already destroyed windows and synchronized where possible.
    g.images.clear();
    g.retiredImages.clear();
    g.rasterBytes = 0;
    g.fonts.clear();
    g.families.clear();
    g.shaper.reset();
    g.fontMgr.reset();
    g.recorder.reset();
    g.context.reset();
    g.backend = {};
    g.maxTextureDimension = 0;
    g.pendingPresentations = 0;
    g.failed = false;
    g.recorderPoisoned = false;
}

uint32_t DecodeImage(const uint8_t* bytes, int32_t length,
                     int32_t maxWidth, int32_t maxHeight,
                     float* outWidth, float* outHeight) {
    if (!bytes || length <= 0 || length > kMaxEncodedBytes ||
        maxWidth < 0 || maxHeight < 0 ||
        g.images.size() >= kMaxImages ||
        g_nextImageId > std::numeric_limits<uint32_t>::max()) return 0;

    auto data = SkData::MakeWithCopy(bytes, static_cast<size_t>(length));
    if (!data) return 0;
    auto codec = SkCodec::MakeFromData(data);
    if (!codec) return 0;

    const auto info = codec->getInfo();
    const int nativeWidth = info.width();
    const int nativeHeight = info.height();
    if (nativeWidth <= 0 || nativeHeight <= 0) return 0;

    const uint64_t pixels =
        static_cast<uint64_t>(nativeWidth) * nativeHeight;
    if (pixels > kMaxImagePixels) {
        Log("image exceeds native decode pixel limit");
        return 0;
    }

    double scale = 1;
    if (maxWidth > 0) {
        scale = std::min(scale, static_cast<double>(maxWidth) / nativeWidth);
    }
    if (maxHeight > 0) {
        scale = std::min(scale, static_cast<double>(maxHeight) / nativeHeight);
    }

    const int width = std::max(
        1, static_cast<int>(std::lround(nativeWidth * scale)));
    const int height = std::max(
        1, static_cast<int>(std::lround(nativeHeight * scale)));

    // Decoded images must eventually fit a single device texture.
    if (g.maxTextureDimension &&
        (static_cast<uint32_t>(width) > g.maxTextureDimension ||
         static_cast<uint32_t>(height) > g.maxTextureDimension)) return 0;

    const uint64_t finalBytes =
        static_cast<uint64_t>(width) * height * 4;
    const bool resize = width != nativeWidth || height != nativeHeight;
    const uint64_t temporaryBytes = pixels * 4 +
        (resize ? finalBytes : 0);

    if (temporaryBytes > kMaxRasterBytes ||
        g.rasterBytes > kMaxRasterBytes - temporaryBytes) {
        Log("image decode exceeds raster memory budget");
        return 0;
    }

    // Use premultiplied pixels for nonopaque content.
    const auto alphaType = info.alphaType() == kOpaque_SkAlphaType
        ? kOpaque_SkAlphaType : kPremul_SkAlphaType;
    const auto destinationInfo =
        info.makeColorType(kN32_SkColorType).makeAlphaType(alphaType);

    SkBitmap full;
    if (!full.tryAllocPixels(destinationInfo) ||
        codec->getPixels(full.pixmap()) != SkCodec::kSuccess) return 0;
    full.setImmutable();

    auto image = SkImages::RasterFromBitmap(full);
    if (!image) return 0;

    if (resize) {
        SkBitmap small;
        if (!small.tryAllocPixels(destinationInfo.makeWH(width, height)) ||
            !image->scalePixels(
                small.pixmap(),
                SkSamplingOptions(SkCubicResampler::Mitchell()))) return 0;

        small.setImmutable();
        auto resized = SkImages::RasterFromBitmap(small);
        if (!resized) return 0;
        image = std::move(resized);
    }

    // Reserve permanently before insertion: allocation failure may skip an ID,
    // but can never cause a stale ID to alias a later image.
    const uint32_t id = static_cast<uint32_t>(g_nextImageId++);
    ImageEntry entry;
    entry.raster = std::move(image);
    entry.rasterBytes = finalBytes;
    g.images.emplace(id, std::move(entry));
    g.rasterBytes += finalBytes;

    if (outWidth) *outWidth = static_cast<float>(width);
    if (outHeight) *outHeight = static_cast<float>(height);
    return id;
}

} // namespace

int32_t nui_init(void) {
    return Api<int32_t>("nui_init", -1, [] {
        if (g.context && Ready()) return 0;

        // Recovery contract (audit BL-4): with a failed backend the
        // documented path is destroy every window, then call
        // nui_init again (or nui_shutdown first). The old early-out
        // returned -1 whenever a context existed, so the clear
        // below could never run for the exact partial/failed states
        // it was written for, and re-init was unreachable.
        if (!g.windows.empty()) {
            Log("re-init refused: destroy every window first");
            return -1;
        }

        // Clear partial GPU initialization, but preserve pre-init font/image
        // registrations. Their CPU-side data does not depend on a device.
        g.recorder.reset();
        g.context.reset();
        g.backend = {};
        g.failed = false;
        g.recorderPoisoned = false;

        g.backend = GetDawnContext();
        if (!g.backend.fInstance || !g.backend.fDevice ||
            !g.backend.fQueue || NuiDawnBackendFailed()) return -1;

        wgpu::Limits limits{};
        if (!g.backend.fDevice.GetLimits(&limits)) {
            g.failed = true;
            Log("could not query device limits");
            return -1;
        }
        g.maxTextureDimension = limits.maxTextureDimension2D;

        skgpu::graphite::ContextOptions options{};
        g.context =
            skgpu::graphite::ContextFactory::MakeDawn(g.backend, options);
        if (!g.context) {
            g.failed = true;
            Log("could not create Graphite context");
            return -1;
        }

        g.recorder = g.context->makeRecorder();
        if (!g.recorder) {
            g.failed = true;
            Log("could not create Graphite recorder");
            return -1;
        }
        return Ready() ? 0 : -1;
    });
}

nui_window* nui_create_window(const UiNativeHandles* handles,
                              uint32_t width, uint32_t height) {
    return Api<nui_window*>("nui_create_window", nullptr, [&] {
        if (!Ready() || !handles || !handles->driver ||
            !DimensionsValid(width, height)) return static_cast<nui_window*>(nullptr);

        auto window = std::make_unique<nui_window>();
        window->driver = handles->driver;
        window->handles = *handles;
        window->handles.driver = window->driver.c_str();
        window->width = width;
        window->height = height;
        window->surface =
            CreateDawnSurface(g.backend.fInstance, &window->handles);

        if (!window->surface) return static_cast<nui_window*>(nullptr);
        if (width && height && !Configure(*window)) {
            return static_cast<nui_window*>(nullptr);
        }

        window->nextFrameTimeNs = NowNs();
        g.windows.insert(window.get());
        return window.release();
    });
}

void nui_destroy_window(nui_window* window) {
    ApiVoid("nui_destroy_window", [&] {
        if (!Live(window)) return;

        // Device-loss cleanup must remain possible even after Ready() fails.
        // On failure, handles are still released; no further rendering occurs.
        if (!Synchronize()) {
            Log("destroying a window after a failed synchronization; its GPU work may not have drained");
        }

        Trace(*window);
        DropCache(*window);
        window->surface = nullptr;
        window->config = {};
        g.windows.erase(window);
        delete window;
    });
}

void nui_resize(nui_window* window, uint32_t width, uint32_t height) {
    ApiVoid("nui_resize", [&] {
        if (!Live(window)) return;

        if (!DimensionsValid(width, height)) {
            Log("resize exceeds device texture limits");
            return;
        }

        // Geometry bookkeeping is CPU-side and always applies,
        // even while a failure tier blocks rendering (audit BL-4:
        // resize used to refuse outright when !Ready(), which
        // blocked the teardown/recovery ordering and left the
        // window's size stale for the eventual reconfigure).
        if (window->width != width || window->height != height) {
            window->width = width;
            window->height = height;
            window->configured = false;
            window->cacheValid = false;
            window->nextFrameTimeNs = NowNs();
        }

        // Zero size suspends without configuring a zero-sized surface.
        if (!width || !height) {
            window->cacheValid = false;
            return;
        }

        // Device tier: geometry is current; rendering waits for
        // the destroy + re-init recovery path.
        if (g.failed) return;

        // Recording tier recovery: a fresh recorder drops whatever
        // the poisoned one was holding.
        if (g.recorderPoisoned) {
            g.recorder = g.context ? g.context->makeRecorder() : nullptr;
            if (!g.recorder) {
                Log("could not recreate the Graphite recorder");
                return;
            }
            g.recorderPoisoned = false;
        }

        // Record-only (audit nat-11): no eager Configure here.
        // nui_render configures first thing and reports failure;
        // an eager call drained the queue on every resize event
        // and swallowed its result in a (void) cast. (Recovery
        // above is not skipped merely because dimensions are
        // unchanged — a resize is the runtime recorder-recreate
        // trigger, per BL-4.)
    });
}

void nui_set_refresh_rate(nui_window* window, float hz) {
    ApiVoid("nui_set_refresh_rate", [&] {
        if (!Live(window) || !std::isfinite(hz) || hz < 1 || hz > 1000) return;
        window->targetFrameTimeNs = static_cast<uint64_t>(1e9 / hz);
        window->nextFrameTimeNs = NowNs();
    });
}

int32_t nui_is_resizing(nui_window* window) {
    (void)window;
    return 0;
}

int32_t nui_present_cached(nui_window* window) {
    return Api<int32_t>("nui_present_cached", 0, [&] {
        if (!Live(window) || !Ready() ||
            !window->width || !window->height) return 0;

        // Pacing lives here and only here (audit nat-6, ruling
        // F5): this is the present/idle path; nui_render never
        // sleeps. And only on the success path — a failed present
        // must not burn a vsync interval before its retry.
        if (!Present(*window)) return 0;
        Pace(*window);
        return 1;
    });
}

int32_t nui_render(nui_window* window,
                   const UiDrawCmd* commands, int32_t count,
                   const UiRect* damage, int32_t damageCount,
                   float scale) {
    return Api<int32_t>("nui_render", 0, [&] {
        if (!Live(window) || !Ready()) {
            Log("render skipped: window not live or backend not ready");
            return 0;
        }
        if (!window->width || !window->height ||
            !std::isfinite(scale) || scale <= 0 ||
            damageCount < 0 || (damageCount > 0 && !damage)) {
            std::fprintf(stderr,
                "nui: render skipped: bad geometry/scale "
                "(w=%u h=%u scale=%f damage_count=%d)\n",
                window->width, window->height,
                static_cast<double>(scale), damageCount);
            return 0;
        }

        // Damage is intentionally ignored: the entire cache is cleared.
        if (!ValidateCommands(commands, count)) {
            Log("invalid render command stream");
            return 0;
        }

        if (!Configure(*window)) return 0;

        // Bound work before recording another frame, not only before copying.
        if (g.pendingPresentations >= kPresentationBatchSize &&
            !DrainQueue()) return 0;

        window->cacheValid = false;
        if (!EnsureCache(*window)) return 0;

        auto* canvas = window->cacheSurface->getCanvas();
        canvas->clear(SkColors::kBlack);
        Replay(canvas, commands, count, scale);
        ++window->replays;

        auto recording = g.recorder->snap();
        if (!recording) {
            g.recorderPoisoned = true;
            Log("Graphite snap failed");
            return 0;
        }

        skgpu::graphite::InsertRecordingInfo info{};
        info.fRecording = recording.get();
        if (!g.context->insertRecording(info) || !g.context->submit() ||
            !Ready()) {
            g.recorderPoisoned = true;
            Log("Graphite recording submission failed");
            return 0;
        }

        window->cacheValid = true;
        const bool presented = Present(*window);

        // Failed acquisition must not let repeated repaints accumulate
        // unbounded GPU work without reaching the presentation batch limit.
        if (!presented && !g.failed) {
            if (!DrainQueue()) return 0;
        }
        return presented ? 1 : 0;
    });
}

void nui_register_font(uint32_t family, const char* path) {
    ApiVoid("nui_register_font", [&] {
        if (!path || !*path) return;
        if (!g.families.contains(family) &&
            g.families.size() >= kMaxFamilies) {
            Log("font family limit reached");
            return;
        }

        auto data = SkData::MakeFromFileName(path);
        if (!data) {
            Log("could not load font file");
            return;
        }

        FontFamily entry;
        entry.data = std::move(data);
        g.families.insert_or_assign(family, std::move(entry));
        g.fonts.clear();
    });
}

void nui_register_font_family(uint32_t family, const char* name) {
    ApiVoid("nui_register_font_family", [&] {
        if (!name || !*name) return;
        if (!g.families.contains(family) &&
            g.families.size() >= kMaxFamilies) {
            Log("font family limit reached");
            return;
        }

        FontFamily entry;
        entry.name = name;
        entry.isName = true;
        g.families.insert_or_assign(family, std::move(entry));
        g.fonts.clear();
    });
}

float nui_measure_word(uint32_t family, int32_t weight, int32_t slant,
                        float size, const uint8_t* text, int64_t length) {
    return Api<float>("nui_measure_word", 0.0f, [&] {
        if (length <= 0 || !Utf8(text, length)) return 0.0f;
        auto* font = ResolveFont(family, weight, slant, size);
        if (!font) return 0.0f;

        // Measured through the shaper, exactly as DrawText draws:
        // the Odin word cache's fragment width is the drawn width.
        float advance = 0;
        if (!MeasureAdvance(*font, reinterpret_cast<const char*>(text),
                            static_cast<size_t>(length), &advance)) {
            return 0.0f;
        }
        return advance;
    });
}

float nui_line_height(uint32_t family, int32_t weight, int32_t slant,
                      float size) {
    return Api<float>("nui_line_height", 0.0f, [&] {
        auto* font = ResolveFont(family, weight, slant, size);
        if (!font) return 0.0f;

        SkFontMetrics metrics;
        font->getMetrics(&metrics);
        const float height =
            -metrics.fAscent + metrics.fDescent + metrics.fLeading;
        return std::isfinite(height) && height > 0 ? height : 0.0f;
    });
}

uint32_t nui_image_decode(const uint8_t* bytes, int32_t length,
                          int32_t maxWidth, int32_t maxHeight,
                          float* outWidth, float* outHeight) {
    return Api<uint32_t>("nui_image_decode", 0, [&] {
        if (outWidth) *outWidth = 0;
        if (outHeight) *outHeight = 0;
        return DecodeImage(
            bytes, length, maxWidth, maxHeight, outWidth, outHeight);
    });
}

void nui_image_release(uint32_t id) {
    ApiVoid("nui_image_release", [&] {
        auto it = g.images.find(id);
        if (it == g.images.end()) return;

        // Mark-and-sweep (audit nat-13): the entry leaves the
        // live map now — draws miss it and the raster budget is
        // credited — but its GPU refs drop only at the next
        // Synchronize(), where the queue is known empty. This
        // used to Synchronize() PER RELEASE: releasing a page of
        // 200 thumbnails meant 200 full queue drains on the UI
        // thread. (nui_purge_gpu_cache keeps its immediate drain:
        // it is the explicit purge-now verb, and its Synchronize
        // is a sweep point too.)
        g.rasterBytes -= it->second.rasterBytes;
        g.retiredImages.push_back(std::move(it->second));
        g.images.erase(it);
    });
}

uint64_t nui_gpu_cache_bytes(void) {
    return Api<uint64_t>("nui_gpu_cache_bytes", 0, [&] {
        if (!Ready()) return uint64_t{0};
        return static_cast<uint64_t>(g.context->currentBudgetedBytes());
    });
}

void nui_purge_gpu_cache(void) {
    ApiVoid("nui_purge_gpu_cache", [&] {
        if (!Ready()) return;

        // Same cold-path discipline as nui_image_release: drain submitted
        // work first (the Context header's own condition for a complete
        // purge), then drop everything purgeable — 0 ms unused means
        // age is no excuse. In-use resources are never deleted by this.
        if (!Synchronize()) {
            Log("purging the GPU cache after a failed synchronization");
        }
        g.context->performDeferredCleanup(std::chrono::milliseconds(0));
    });
}

void nui_shutdown(void) {
    ApiVoid("nui_shutdown", [] {
        if (!g.windows.empty()) {
            Log("shutdown refused: destroy every window first");
            return;
        }

        if (!Synchronize()) {
            Log("shutting down after a failed synchronization; GPU work may not have drained");
        }
        ResetShared();

        // The API thread remains fixed for this process lifetime. Image IDs
        // likewise remain monotonic across shutdown/reinitialization.
    });
}