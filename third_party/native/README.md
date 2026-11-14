# Prebuilt native backends

The render backend (Skia Graphite + Dawn) ships as a **prebuilt static library
per platform**, so app authors never build Skia themselves. Binaries are
distributed through GitHub Releases, not committed here.

## Layout

```
third_party/native/
  linux-x64/
    lib/libniello_native.a   # fat archive: nui_native + Skia + Dawn
    include/nui.h            # the C API (mirrored by niello/sdl/ffi.odin)
  windows-x64/
    lib/niello_native.lib
    include/nui.h
  macos-arm64/
    lib/libniello_native.a
    include/nui.h
```

One Linux binary covers both X11 and Wayland — the backend reads the native
handle from the SDL window at runtime and picks the right surface path.

## Which version

The code needs a backend that defines every function `native/nui.h`
declares: **native-v0.3.0 or later** since niello/sdl renders headless
pictures through `nui_render_png` (an older archive fails to link with an
undefined `nui_render_png`). Re-fetch after updating NielloUI;
`tools/check-native-exports.sh <archive>` says whether an archive has
them all.

## Fetching

```sh
./tools/fetch-native.sh            # downloads for the current platform
```

## Cutting a release (maintainers)

1. Build Skia per platform with Graphite + Dawn (see `skiasdl/skia build.txt`
   for the gn args).
2. Build the `nui_native` static lib from `skiasdl/` (`nui.h`, `nui.cpp`,
   `util.cpp`).
3. Merge the archives into one fat static lib per platform
   (`ar -M` / `libtool -static`), so downstream links a single archive plus
   system libs (SDL3, Vulkan, Freetype, Fontconfig, Threads).
4. Zip `lib/` + `include/nui.h` as `niello-native-<platform>.zip` and attach
   to a GitHub Release.
