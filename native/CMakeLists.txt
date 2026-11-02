cmake_minimum_required(VERSION 4.3)
project(nui_native CXX)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Location of your Skia checkout (source + GN-built out/Release).
# Configure with:  cmake -B build -DSKIA_DIR=$HOME/third_party/skia
# or export SKIA_DIR in your shell.
if(NOT SKIA_DIR)
    set(SKIA_DIR "$ENV{SKIA_DIR}")
endif()
if(NOT SKIA_DIR AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/skia/include/core/SkCanvas.h")
    set(SKIA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/skia")  # legacy in-tree fallback
endif()
if(NOT SKIA_DIR)
    message(FATAL_ERROR "SKIA_DIR is not set. Configure with -DSKIA_DIR=/path/to/skia")
endif()

# Which GN out dir under SKIA_DIR to build against: "Release" for
# the everyday dev build, "niello-<platform>" for release builds
# (tools/build-native.sh passes it).
set(NIELLO_SKIA_OUT "Release" CACHE STRING "Skia GN out dir name")

# The NielloUI native backend: a static library exposing the nui_* C API
# (see nui.h). SDL appears only as a borrowed window handle; the event loop
# and window lifecycle live on the Odin side.
add_library(nui_native STATIC
        nui.cpp
        nui.h
        util.cpp
        util.h)

# AT-SPI accessibility export (TODO #23 M2): the hand-rolled D-Bus
# wire client + exporter. Linux only — the D-Bus transport is a Unix
# socket and the bus protocols are Linux-desktop concepts. The Odin
# side guards its calls with `when ODIN_OS == .Linux`, so other
# platforms link clean without these objects.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_sources(nui_native PRIVATE
        dbus.cpp
        dbus.h
        atspi.cpp)
endif()

# F7(a) (TODO #11): the system-package lookups are gated by platform.
# Only the Linux backend needs the system font stack (Freetype +
# Fontconfig) and the Vulkan loader: Skia resolves those symbols from
# the merged archives, and the other platforms have no system
# Fontconfig or Vulkan loader to find — macOS uses CoreText + Metal,
# Windows uses DirectWrite + D3D12. Threads is needed everywhere
# (std::thread in the backend).
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    find_package(Freetype REQUIRED)
    find_package(Fontconfig REQUIRED)
    find_package(Vulkan REQUIRED)
endif()
find_package(Threads REQUIRED)
# NOTE: no SDL3 here. The C++ backend takes platform window handles from the
# Odin side (UiNativeHandles); SDL lives entirely in Odin.

target_include_directories(nui_native PRIVATE
        ${SKIA_DIR}
        ${SKIA_DIR}/include
        ${SKIA_DIR}/out/${NIELLO_SKIA_OUT}/gen
        ${SKIA_DIR}/third_party/externals/dawn/include
        ${SKIA_DIR}/out/${NIELLO_SKIA_OUT}/gen/third_party/dawn/include
)

target_link_directories(nui_native PRIVATE
        ${SKIA_DIR}/out/${NIELLO_SKIA_OUT}
)

# The Skia and Dawn archives reference each other; GNU ld needs them in
# a --start-group/--end-group pair, while ld64 and link.exe re-search
# archives on their own (and reject the GNU flags).
set(NUI_GROUP_START "")
set(NUI_GROUP_END "")
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(NUI_GROUP_START "-Wl,--start-group")
    set(NUI_GROUP_END "-Wl,--end-group")
endif()

target_link_libraries(nui_native PRIVATE
        ${NUI_GROUP_START}
        skia
        dawn_combined
        ${NUI_GROUP_END}
        Threads::Threads
        ${CMAKE_DL_LIBS}
)
# Linux-only system libs (F7(a) gating above): Skia's Linux font stack
# and Dawn's Vulkan backend. They come after the archives so the
# static link resolves Skia's references into them.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_libraries(nui_native PRIVATE
            Vulkan::Vulkan
            Freetype::Freetype
            Fontconfig::Fontconfig
    )
endif()
# macOS: Dawn's Metal backend + Skia's macOS surface. The documented
# set; the first CI link names anything this vintage still wants.
if(APPLE)
    target_link_libraries(nui_native PRIVATE
            "-framework Metal"
            "-framework Foundation"
            "-framework QuartzCore"
            "-framework CoreGraphics"
            "-framework IOKit"
    )
endif()
# Windows: Dawn's D3D12 backend (d3d12/dxgi/dxguid) + Skia's
# DirectWrite font manager (dwrite). Same caveat as macOS.
if(WIN32)
    target_link_libraries(nui_native PRIVATE
            d3d12
            dxgi
            dxguid
            dwrite
    )
endif()
