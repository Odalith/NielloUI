cmake_minimum_required(VERSION 4.3)
project(nui_render CXX)

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

# The NielloUI native backend: a static library exposing the nui_* C API
# (see nui.h). SDL appears only as a borrowed window handle; the event loop
# and window lifecycle live on the Odin side.
add_library(nui_render STATIC
        nui.cpp
        nui.h
        util.cpp
        util.h)

find_package(Freetype REQUIRED)
find_package(Fontconfig REQUIRED)
find_package(Threads REQUIRED)
find_package(Vulkan REQUIRED)
# NOTE: no SDL3 here. The C++ backend takes platform window handles from the
# Odin side (UiNativeHandles); SDL lives entirely in Odin.

target_include_directories(nui_render PRIVATE
        ${SKIA_DIR}
        ${SKIA_DIR}/include
        ${SKIA_DIR}/out/Release/gen
        ${SKIA_DIR}/third_party/externals/dawn/include
        ${SKIA_DIR}/out/Release/gen/third_party/dawn/include
)

target_link_directories(nui_render PRIVATE
        ${SKIA_DIR}/out/Release
)

target_link_libraries(nui_render PRIVATE
        -Wl,--start-group
        skia
        dawn_combined
        -Wl,--end-group
        Vulkan::Vulkan
        Freetype::Freetype
        Fontconfig::Fontconfig
        Threads::Threads
        ${CMAKE_DL_LIBS}
)
