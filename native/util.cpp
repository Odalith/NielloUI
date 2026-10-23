#include "util.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string_view>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

#include "webgpu/webgpu_cpp.h"
#include "dawn/native/DawnNative.h"
#include "dawn/dawn_proc.h"

namespace {

struct DeviceState {
    std::atomic<bool> failed{false};
};

// Assigned/read only by the backend's serialized API thread.
// Dawn callbacks capture their own state, never this variable.
std::shared_ptr<DeviceState> g_deviceState;
std::atomic<bool> g_uncapturedError{false};

void LogMessage(const char* prefix, wgpu::StringView message) noexcept {
    std::fputs(prefix, stderr);
    const std::string_view view(message);
    if (!view.empty()) {
        std::fwrite(view.data(), 1, view.size(), stderr);
    }
    std::fputc('\n', stderr);
}

} // namespace

// Internal bridge used by nui.cpp; deliberately not part of the C ABI.
// Access must be serialized with GetDawnContext().
bool NuiDawnBackendFailed() noexcept {
    return g_uncapturedError.load(std::memory_order_acquire) ||
           !g_deviceState ||
           g_deviceState->failed.load(std::memory_order_acquire);
}

wgpu::Surface CreateDawnSurface(const wgpu::Instance& instance,
                                const UiNativeHandles* handles) {
    if (!instance || !handles || !handles->driver) return nullptr;

    wgpu::SurfaceDescriptor desc{};

#if defined(__linux__)
    if (std::strcmp(handles->driver, "wayland") == 0) {
        if (!handles->wl_display || !handles->wl_surface) return nullptr;

        wgpu::SurfaceSourceWaylandSurface source{};
        source.display = handles->wl_display;
        source.surface = handles->wl_surface;
        desc.nextInChain = &source;
        return instance.CreateSurface(&desc);
    }

    if (std::strcmp(handles->driver, "x11") == 0) {
        if (!handles->x11_display || handles->x11_window == 0) return nullptr;

        wgpu::SurfaceSourceXlibWindow source{};
        source.display = handles->x11_display;
        source.window = handles->x11_window;
        desc.nextInChain = &source;
        return instance.CreateSurface(&desc);
    }

#elif defined(_WIN32)
    if (std::strcmp(handles->driver, "windows") == 0) {
        if (!handles->win32_hwnd) return nullptr;

        wgpu::SurfaceSourceWindowsHWND source{};
        source.hinstance = handles->win32_hinstance
            ? handles->win32_hinstance
            : GetModuleHandleW(nullptr);
        source.hwnd = handles->win32_hwnd;
        desc.nextInChain = &source;
        return instance.CreateSurface(&desc);
    }

#elif defined(__APPLE__)
    if (std::strcmp(handles->driver, "cocoa") == 0) {
        if (!handles->cocoa_layer) return nullptr;

        wgpu::SurfaceSourceMetalLayer source{};
        source.layer = handles->cocoa_layer;
        desc.nextInChain = &source;
        return instance.CreateSurface(&desc);
    }
#endif

    std::fputs("nui: unsupported or invalid native window driver\n", stderr);
    return nullptr;
}

skgpu::graphite::DawnBackendContext GetDawnContext() {
    // This installs a process-global Dawn dispatch table. The host must not
    // concurrently replace it with a different Dawn implementation.
    static std::once_flag procsOnce;
    std::call_once(procsOnce, [] {
        dawnProcSetProcs(&dawn::native::GetProcs());
    });

    auto state = std::make_shared<DeviceState>();
    g_deviceState = state;
    g_uncapturedError.store(false, std::memory_order_release);

    const wgpu::InstanceFeatureName features[] = {
        wgpu::InstanceFeatureName::TimedWaitAny,
    };

    wgpu::InstanceDescriptor instanceDesc{};
    instanceDesc.requiredFeatureCount = 1;
    instanceDesc.requiredFeatures = features;

    auto instance = wgpu::CreateInstance(&instanceDesc);
    if (!instance) {
        state->failed.store(true, std::memory_order_release);
        std::fputs("nui: failed to create Dawn instance\n", stderr);
        return {};
    }

    struct AdapterResult {
        wgpu::Adapter adapter;
        bool success = false;
    };

    // Owned by the callback as well as this function: safe even if WaitAny
    // fails before the callback has been delivered.
    auto result = std::make_shared<AdapterResult>();

    wgpu::RequestAdapterOptions adapterOptions{};
    adapterOptions.powerPreference = wgpu::PowerPreference::HighPerformance;

    auto future = instance.RequestAdapter(
        &adapterOptions, wgpu::CallbackMode::WaitAnyOnly,
        [result](wgpu::RequestAdapterStatus status,
                 wgpu::Adapter adapter, wgpu::StringView message) {
            result->success = status == wgpu::RequestAdapterStatus::Success;
            if (result->success) {
                result->adapter = adapter;
            } else {
                LogMessage("nui: adapter request failed: ", message);
            }
        });

    if (instance.WaitAny(future, UINT64_MAX) != wgpu::WaitStatus::Success ||
        !result->success || !result->adapter) {
        state->failed.store(true, std::memory_order_release);
        std::fputs("nui: adapter acquisition failed\n", stderr);
        return {};
    }

    wgpu::DeviceDescriptor deviceDesc{};
    deviceDesc.label = "Niello shared device";

    deviceDesc.SetDeviceLostCallback(
        wgpu::CallbackMode::AllowSpontaneous,
        [state](const wgpu::Device&, wgpu::DeviceLostReason reason,
                wgpu::StringView message) {
            // Normal teardown is not an unexpected backend failure.
            if (reason == wgpu::DeviceLostReason::Destroyed) return;
            state->failed.store(true, std::memory_order_release);
            LogMessage("nui: device lost: ", message);
        });

    deviceDesc.SetUncapturedErrorCallback(
        [](const wgpu::Device&, wgpu::ErrorType,
           wgpu::StringView message) {
            g_uncapturedError.store(true, std::memory_order_release);
            LogMessage("nui: uncaptured Dawn error: ", message);
        });

    auto device = result->adapter.CreateDevice(&deviceDesc);
    if (!device || state->failed.load(std::memory_order_acquire)) {
        state->failed.store(true, std::memory_order_release);
        std::fputs("nui: failed to create Dawn device\n", stderr);
        return {};
    }

    skgpu::graphite::DawnBackendContext backend{};
    backend.fInstance = instance;
    backend.fDevice = device;
    backend.fQueue = device.GetQueue();

    if (!backend.fQueue) {
        state->failed.store(true, std::memory_order_release);
        return {};
    }
    return backend;
}