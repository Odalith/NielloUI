#include <iostream>
#include <vulkan/vulkan.h>
#include <memory>
#include <expected>
#include <print>
#include <cassert>
#include <fstream>
#include <SDL3/SDL.h>

#include "util.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColor.h"
#include "include/core/SkPaint.h"
#include "include/core/SkSurface.h"
#include "include/core/SkRRect.h"
#include "include/core/SkData.h"
#include "include/core/SkColorSpace.h"
#include "include/gpu/graphite/BackendTexture.h"
#include "include/gpu/graphite/Context.h"
#include "include/gpu/graphite/ContextOptions.h"
#include "include/gpu/graphite/Recorder.h"
#include "include/gpu/graphite/Recording.h"
#include "include/gpu/graphite/Surface.h"
#include "include/encode/SkJpegEncoder.h"
#include "include/gpu/graphite/GraphiteTypes.h"
#include "include/gpu/graphite/dawn/DawnBackendContext.h"
#include "include/gpu/graphite/dawn/DawnUtils.h"
#include "webgpu/webgpu_cpp.h"
#include "dawn/native/DawnNative.h"
#include "dawn/dawn_proc.h"


wgpu::Surface CreateDawnSurface(wgpu::Instance instance, SDL_Window* window) {
    SDL_PropertiesID props = SDL_GetWindowProperties(window);

#if defined(__linux__)
    const char* driver = SDL_GetCurrentVideoDriver();
    if (driver && strcmp(driver, "wayland") == 0) {
        wgpu::SurfaceSourceWaylandSurface waylandDesc{};
        waylandDesc.display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER, nullptr);
        waylandDesc.surface = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER, nullptr);

        wgpu::SurfaceDescriptor surfaceDesc{};
        surfaceDesc.nextInChain = &waylandDesc;
        return instance.CreateSurface(&surfaceDesc);
    } else { // X11
        wgpu::SurfaceSourceXlibWindow x11Desc{};
        x11Desc.display = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_X11_DISPLAY_POINTER, nullptr);
        x11Desc.window = static_cast<uint64_t>(SDL_GetNumberProperty(props, SDL_PROP_WINDOW_X11_WINDOW_NUMBER, 0));

        wgpu::SurfaceDescriptor surfaceDesc{};
        surfaceDesc.nextInChain = &x11Desc;
        return instance.CreateSurface(&surfaceDesc);
    }
#elif defined(_WIN32)
    wgpu::SurfaceSourceWindowsHWND winDesc{};
    winDesc.hinstance = GetModuleHandle(nullptr);
    winDesc.hwnd = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_WIN32_HWND_POINTER, nullptr);

    wgpu::SurfaceDescriptor surfaceDesc{};
    surfaceDesc.nextInChain = &winDesc;
    return instance.CreateSurface(&surfaceDesc);
#elif defined(__APPLE__)
    wgpu::SurfaceSourceMetalLayer metalDesc{};
    metalDesc.layer = SDL_GetPointerProperty(props, SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, nullptr);

    wgpu::SurfaceDescriptor surfaceDesc{};
    surfaceDesc.nextInChain = &metalDesc;
    return instance.CreateSurface(&surfaceDesc);
#endif
}


static void adapter_request(wgpu::RequestAdapterStatus status,
                            wgpu::Adapter adapter,
                            wgpu::StringView message,
                            wgpu::Adapter* data) {

    if (status != wgpu::RequestAdapterStatus::Success) {
        std::cout << "Adapter request failed: " << std::string_view(message);
        exit(1);
    }
    *data = adapter;
}

static void device_lost([[maybe_unused]] const wgpu::Device& device,
                 wgpu::DeviceLostReason reason,
                 struct wgpu::StringView message) {
    if (message == std::string_view(
                       "A valid external Instance reference no longer exists.")) {
        return;
                       }

    std::cout << "device lost: " << static_cast<int>(reason) << std::endl;
    if (message.length > 0) {
        std::cout << std::string_view(message);
    }
    std::cout << std::endl;
}

static void uncaptured_error [[noreturn]] ([[maybe_unused]] const wgpu::Device& device,
                                    wgpu::ErrorType type,
                                    struct wgpu::StringView message) {
    std::cout << "uncaptured error: " << static_cast<int>(type) << std::endl;
    if (message.length > 0) {
        std::cout << std::string_view(message);
    }

    std::cout << std::endl;
    assert(false);
};


skgpu::graphite::DawnBackendContext GetDawnContext() {
    // Set Dawn's procedure table
    dawnProcSetProcs(&dawn::native::GetProcs());

    const wgpu::InstanceFeatureName requiredFeatures[] = {
        wgpu::InstanceFeatureName::TimedWaitAny,
    };

    wgpu::InstanceDescriptor instanceDescriptor{};
    instanceDescriptor.requiredFeatureCount = sizeof(requiredFeatures) / sizeof(requiredFeatures[0]);
    instanceDescriptor.requiredFeatures = requiredFeatures;

    auto instance = wgpu::CreateInstance(&instanceDescriptor);

    if (!instance) {
        std::cout << "Failed to create instance" << std::endl;
        exit(1);
    }

    // Get Adapter
    wgpu::RequestAdapterOptions adapter_opts{
        .powerPreference = wgpu::PowerPreference::HighPerformance,
    };
    wgpu::Adapter adapter{};
    instance.RequestAdapter(&adapter_opts, wgpu::CallbackMode::AllowSpontaneous,
                            adapter_request, &adapter);

    if (!adapter) {
        std::cout << "Failed to get adapter" << std::endl;
        exit(1);
    }

    // Get device
    wgpu::DeviceDescriptor device_desc{};
    device_desc.label = "default device";
    device_desc.SetDeviceLostCallback(wgpu::CallbackMode::AllowProcessEvents, device_lost);
    device_desc.SetUncapturedErrorCallback(uncaptured_error);

    wgpu::Device device = adapter.CreateDevice(&device_desc);

    if (!device) {
        std::cerr << "Failed to create wgpu device.\n";
        exit(1);
    }

    skgpu::graphite::DawnBackendContext backendContext;
    backendContext.fInstance = instance;
    backendContext.fDevice = device;
    backendContext.fQueue = device.GetQueue();

    return backendContext;
}

/*void SetWindowSurface(wgpu::Instance instance, wgpu::Device device, SDL_Window *window) {
    const auto surface = CreateDawnSurfaceFromSDL3(instance, window);

    wgpu::SurfaceCapabilities capabilities;
    surface.GetCapabilities(device.GetAdapter(), &capabilities);

    wgpu::SurfaceConfiguration config{};
    config.device = device;
    config.format = capabilities.formats[0]; // e.g., BGRA8Unorm or RGBA8Unorm
    config.usage = wgpu::TextureUsage::RenderAttachment;
    config.width = WIDTH;
    config.height = HEIGHT;
    config.presentMode = wgpu::PresentMode::Fifo; // V-Sync

    surface.Configure(&config);
}*/
