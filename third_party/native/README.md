# Prebuilt native backends

The render backend (Skia Graphite + Dawn) ships as a **prebuilt static library
per platform**, so app authors never build Skia themselves. Binaries are
distributed through GitHub Releases, not committed here.

## Layout

```
third_party/native/
  linux-x64/
    lib/libniello_render.a   # fat archive: nui_render + Skia + Dawn
    include/nui.h            # the C API (mirrored by niello/sdl/ffi.odin)
  windows-x64/
    lib/niello_render.lib
    include/nui.h
  macos-arm64/
    lib/libniello_render.a
    include/nui.h
```

One Linux binary covers both X11 and Wayland — the backend reads the native
handle from the SDL window at runtime and picks the right surface path.

## Fetching

```sh
./tools/fetch-native.sh            # downloads for the current platform
```

## Cutting a release (maintainers)

1. Build Skia per platform with Graphite + Dawn (see `skiasdl/skia build.txt`
   for the gn args).
2. Build the `nui_render` static lib from `skiasdl/` (`nui.h`, `nui.cpp`,
   `util.cpp`).
3. Merge the archives into one fat static lib per platform
   (`ar -M` / `libtool -static`), so downstream links a single archive plus
   system libs (SDL3, Vulkan, Freetype, Fontconfig, Threads).
4. Zip `lib/` + `include/nui.h` as `niello-native-<platform>.zip` and attach
   to a GitHub Release.
