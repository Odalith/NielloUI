# Building the NielloUI native backend (maintainers)

Goal: produce `niello-native-<platform>.zip` — one fat static archive
(`nui_render` + Skia + Dawn merged) plus `include/nui.h` — for
`linux-x64`, `macos-arm64`, and `windows-x64`, then attach the three zips to
a GitHub Release. App authors then just run `tools/fetch-native.sh`
(`fetch-native.ps1` on Windows). Binaries are never committed (enforced by
`.gitignore`).

## Ruled build options (2026-11-01, F1–F9)

The Skia build options are ruled (brief `Skia_Build_Options_Plan.md`):
F1(b) bundled third-party deps everywhere ("just work"); F2(a)
clang-cl from depot_tools' bundled LLVM; F3(a) pin the tested Skia
vintage in `tools/skia-rev.txt`; F4(a) defaults on plus the
DNG/PIEX trim; F5(a) exactly one Dawn backend per platform;
F6 macOS deployment target 13 (Dawn's minimum), drop the `cc`/`cxx`
overrides on macOS; F7(a) gate the CMake `find_package` calls by
platform; F8 `macos-15` runner; F9 the full 21-function native
surface (below). §2 and §8 below carry the ruled flags.

Precondition: this branch still carries the pre-#23 `nui.h`
(13 functions), the pre-rename `nui_render` naming, and the
ungated `find_package` calls. Do not cut a release from this
branch before main is merged in — the merge brings the
21-function `nui.h`, the `ffi.odin` mirrors, the `nui_native`
rename, the AT-SPI objects, and the F7 gating.

**Frozen native surface — ruled target** (F9, 2026-11-01): a release
pins exactly the ABI in `native/nui.h` — 21 functions: `nui_init`,
`nui_create_window`, `nui_destroy_window`, `nui_resize`,
`nui_set_refresh_rate`, `nui_is_resizing`, `nui_render`,
`nui_present_cached`, `nui_register_font`, `nui_register_font_family`,
`nui_measure_word`, `nui_line_height`, `nui_image_decode`,
`nui_image_release`, `nui_gpu_cache_bytes`, `nui_purge_gpu_cache`,
`nui_atspi_start`, `nui_atspi_stop`, `nui_atspi_sync`,
`nui_atspi_remove_window`, `nui_shutdown` — mirrored by
`niello/sdl/ffi.odin`. Changing any signature means a new native
release train, not a patch. Count note: the freeze fork said "20",
but 13 + 2 + 2 + 4 = 21 and `nui.h` declares 21;
`nui_atspi_sync` carries the trailing `win_focused` parameter.
This branch's `nui.h` still names the 13-function surface — the
21-function freeze takes effect when main is merged in (see the
precondition above); the 2026-10-22 thirteen-function freeze is
superseded.

`tools/build-native.sh` scripts the linux-x64 path below end to end;
the Windows and macOS paths are proven by hand once, then automated
(§8).

## 0. Ground truth: the tested linux-x64 args

Verbatim from `Odalith/skiasdl`, file `skia build.txt` — the config that
builds the working testbed today:

```
bin/gn gen out/Release --args="
  is_official_build=true
  is_debug=false
  skia_enable_graphite=true
  skia_enable_ganesh=false
  skia_use_vulkan=true
  skia_use_dawn=true
  dawn_enable_vulkan=true
  skia_use_webgpu=true
  skia_use_vma=true
  skia_use_partition_alloc=false
  cc=\"clang\"
  cxx=\"clang++\"
"

  dawn_enable_metal=true
  dawn_enable_d3d12=true
```

## 1. Fix first: the args-quoting bug

`dawn_enable_metal=true` and `dawn_enable_d3d12=true` sit **outside** the
`--args="..."` quotes, so they never reached GN — on the shell command line
they are stray positional arguments to `gn gen`, not build args. Harmless on
linux-x64 (the testbed only needs Dawn's Vulkan backend), but the platform
matrix below needs them **inside** the quotes:

- macOS needs `dawn_enable_metal=true` in args (Dawn-on-macOS is Metal;
  `util.cpp` builds the surface from the NSWindow's `CAMetalLayer`).
- Windows needs `dawn_enable_d3d12=true` in args (Dawn-on-Windows is D3D12).

When cutting the platform builds, fold the needed flags into each
platform's args block instead of leaving them dangling after the quote.

## 2. Per-platform gn args

Common base (all three platforms):

```
is_official_build=true
is_debug=false
skia_enable_graphite=true
skia_enable_ganesh=false
skia_use_dawn=true
skia_use_webgpu=true
skia_use_vma=true
skia_use_partition_alloc=false
skia_use_dng_sdk=false
skia_use_piex=false
skia_use_system_expat=false
skia_use_system_libjpeg_turbo=false
skia_use_system_libpng=false
skia_use_system_libwebp=false
skia_use_system_zlib=false
skia_use_system_harfbuzz=false
```

Bundled-flag spellings were SkiaSharp's at m156; the 2026-11-01
linux-x64 build (rev f3bd16e6) proves them, with one correction from
the consume test: HarfBuzz needs `skia_use_system_harfbuzz=false`
explicitly, or the fat archive carries 54 undefined `hb_*` references
and no HarfBuzz objects (SkShaper's harfbuzz backend does not link).
ICU needs no flag: the same consume test shows every `u_*` reference
resolves inside the archive at the current defaults.

**linux-x64** — deliberately diverges from the §0 tested config
(F1b ruling):

```
skia_use_vulkan=true
dawn_enable_vulkan=true
skia_use_system_freetype2=false
cc="clang"
cxx="clang++"
```

(`target_cpu` defaults to `x64` on an x64 host.)

**macos-arm64**:

```
target_cpu="arm64"
dawn_enable_metal=true
```

Notes: Dawn-on-macOS is Metal — the SDL window's native handle resolves to
an `NSWindow` and the surface path is `CAMetalLayer`, so there is no reason
to also build Dawn's Vulkan backend into this archive; leaving
`dawn_enable_vulkan` out keeps the static lib lean. `cc`/`cxx` overrides are
harmless here (Xcode CLT `clang` is on `PATH`) — drop the
overrides (F6 ruling). Deployment target 13 (F6, Dawn's minimum;
GN spelling verified against the pinned checkout at CI-write
time). Build on arm64 hardware or a `macos-15`+ CI runner
(Apple Silicon).

**windows-x64**:

```
target_os="win"
target_cpu="x64"
dawn_enable_d3d12=true
skia_use_system_freetype2=false
```

Notes: **drop the `cc="clang"` / `cxx="clang++"` overrides** on Windows.
Skia's Windows build expects clang-cl from depot_tools' bundled LLVM with
the MSVC-ABI setup; a bare `clang` override breaks that. After `gn gen`,
confirm the toolchain resolves to clang-cl before the long build starts.

## 3. SkShaper check (required for `nui_measure_word` / `nui_line_height`)

The text-measuring callbacks shape with SkShaper. `ninja skia` never
builds it: SkShaper lives under the `modules` aggregate as its own
archive, so every platform build runs `ninja skia modules/skshaper`
(§4) and the check is the built archive, not graph presence:

```
ls out/niello-<platform>/libskshaper.a
```

If the `modules/skshaper` target is unknown to ninja, a GN condition
excluded it — check the effective `skia_use_harfbuzz` /
`skia_use_system_harfbuzz` values (`bin/gn args out/niello-<platform> --list`) and the module's
`BUILD.gn` / `skia_enable_skshaper` rather than guessing at flags. Do
not ship a release whose `nui_measure_word` would link-fail.

## 4. Build commands

From the Skia checkout (or `$SKIA_DIR`):

```sh
bin/gn gen out/niello-<platform> --args="<platform args from §2>"
ninja -C out/niello-<platform> skia modules/skshaper
```

With `skia_use_dawn=true`, the Dawn targets build in the same graph. The
testbed links `dawn_combined`, so after ninja finishes, enumerate the
archives to merge:

```sh
ls out/niello-<platform>/*.a   # expect libskia.a, libdawn_combined.a, libskshaper.a, libskcms.a, libwuffs.a
```

Record the Skia revision next to each release for reproducibility:

```sh
git -C "$SKIA_DIR" rev-parse HEAD
```

The scripted Linux path is `tools/build-native.sh`, invoked as
`bash tools/build-native.sh` (with `SKIA_DIR` set). Invoke it via
`bash`: the file may land in the tree without the executable bit,
and the push path does not guarantee the mode — do not rely on
`./tools/build-native.sh`.

## 5. Build `nui_render`

From `NielloUI/native/` (`nui.h`, `nui.cpp`, `util.cpp`):

```cmake
add_library(nui_render STATIC nui.cpp util.cpp)
```

Point it at the Skia checkout's `include/`, the `out/niello-<platform>/gen`
dir, and link the archives from §4. `native/CMakeLists.txt` already does
this shape; the release variant passes `-DNIELLO_SKIA_OUT=niello-<platform>`
(and keeps honoring `SKIA_DIR`).

## 6. Merge into one fat archive

Merge `libskia.a` + `libdawn_combined.a` + `libskshaper.a` + `libharfbuzz.a` (+ any sibling Dawn archives from
§4) + `libnui_render.a` into a single archive so downstream links exactly
one native lib plus system libs (SDL3, Vulkan, Freetype, Fontconfig,
Threads).

- **Linux** — `ar -M` with an MRI script (avoids `.o` basename collisions
  that extract-and-re-add would cause):

  ```
  CREATE libniello_render.a
  ADDLIB out/niello-linux-x64/libskia.a
  ADDLIB out/niello-linux-x64/libdawn_combined.a
  ADDLIB out/niello-linux-x64/libskshaper.a
  ADDLIB out/niello-linux-x64/libharfbuzz.a
  ADDLIB <nui_render build dir>/libnui_render.a
  SAVE
  END
  ```
  ```
  ar -M < merge.mri
  ```

- **macOS** — `libtool`:
  ```
  libtool -static -o libniello_render.a \
    out/niello-macos-arm64/libskia.a \
    out/niello-macos-arm64/libdawn_combined.a \
    out/niello-macos-arm64/libskshaper.a \
    out/niello-macos-arm64/libharfbuzz.a \
    <nui_render build dir>/libnui_render.a
  ```

- **Windows** — `lib.exe`:
  ```
  lib.exe /OUT:niello_render.lib ^
    out\niello-windows-x64\skia.lib ^
    out\niello-windows-x64\dawn_combined.lib ^
    out\niello-windows-x64\skshaper.lib ^
    out\niello-windows-x64\harfbuzz.lib ^
    <nui_render build dir>\nui_render.lib
  ```

Windows CRT caveat: if the Odin app's link fails with `LNK2038`
(CRT mismatch), the Skia build's runtime-library flag disagrees with the
Odin toolchain's — align them in the GN args rather than working around it
downstream. Verify with a real Odin link before publishing the Windows zip.

## 7. Zip and release

```
niello-native-<platform>.zip
├── lib/libniello_render.a   # niello_render.lib on Windows
└── include/nui.h
```

matching the `third_party/native/<platform>/` layout. Attach the three zips
to a GitHub Release (tag like `native-v0.1.0`); `tools/fetch-native.sh` /
`fetch-native.ps1` download from the release by tag or `latest`.

## 8. CI (later, once the matrix is proven by hand)

`.github/workflows/native.yml`: matrix over `ubuntu-24.04`,
`windows-2022`, `macos-15` (F8 ruling; the `macos-14` image retired
2026-11-02); per job: install depot_tools, sync the Skia
checkout at the pinned revision, `gn gen` with the §2 args, `ninja skia`,
build `nui_render`, merge per §6, zip, `upload-artifact`. Dawn needs
CMake 3.30+; `ubuntu-24.04` ships 3.28, so the Linux job provisions
a newer CMake (pip/Kitware) — verify at the first CI run. A release job on
tag `native-v*` downloads the three artifacts and creates the GitHub
Release with them.

Honest caveats: a full Skia+Dawn release build is 30–90 minutes per
platform and the checkout with externals is several GB — cache the Skia
checkout and the `out/niello-<platform>` dirs keyed on the Skia revision.
Prove the matrix with manual builds first; automate once it is green.
