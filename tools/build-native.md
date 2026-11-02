# Building the NielloUI native backend (maintainers)

Goal: produce `niello-native-<platform>.zip` — one fat static archive
(`nui_native` + Skia + Dawn merged) plus `include/nui.h` — for
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

Post-merge state (2026-11-01, PR #24 + F7): main is merged in — `nui.h`
names the 21-function surface, `ffi.odin` mirrors it, the target is
`nui_native`, and the AT-SPI objects build on Linux. F7(a) is
implemented in `native/CMakeLists.txt`: the `find_package` calls are
gated to Linux, and macOS/Windows link their platform system libs.

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
The 2026-10-22 thirteen-function freeze is superseded; the
21-function surface is in `native/nui.h` on main now.

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
skia_use_system_icu=false
```

Bundled-flag spellings were SkiaSharp's at m156; the 2026-11-01
linux-x64 build (rev f3bd16e6) proves them, with two corrections from
the consume tests: HarfBuzz needs `skia_use_system_harfbuzz=false`
explicitly, or the fat archive carries 54 undefined `hb_*` references
and no HarfBuzz objects (SkShaper's harfbuzz backend does not link).
ICU needs `skia_use_system_icu=false` explicitly too:
`is_official_build` defaults the system-ICU branch on (Skia's
`third_party/icu/icu.gni`), which expects system ICU headers —
present on the Manjaro build box, absent on bare CI runners, where
the build died on `unicode/ubidi.h`. The run-3 consume test's clean
`u_*` result was the build box's system ICU masking the gap; the
archive never contained ICU. Bundled ICU objects land in `libskia.a`
via the existing merge, no merge-list change needed.

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

Linux build prerequisites: the base build needs X11 and FontConfig
headers — `libx11-dev`, `libx11-xcb-dev`, `libfontconfig1-dev`
(Debian/Ubuntu; the CI installs the same set). On Arch the same
headers ship with `libx11`, `libxcb`, `fontconfig` — no `-dev`
split. Without them, Dawn's CMake `find_package(X11 REQUIRED)` fails
and the Skia FontConfig / Dawn X11-xcb compiles die on missing
headers, not on NielloUI code.

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

### Synced checkout

`gn gen` needs a depot_tools-synced checkout at the pinned revision
(`tools/skia-rev.txt`) — `bin/gn` is downloaded by the sync, never
checked in, and the externals (Dawn, HarfBuzz, ICU) land only via
`git-sync-deps`. Check out the pinned revision first, so DEPS at
that revision determines which externals sync:

```sh
git clone 'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
export PATH="${PWD}/depot_tools:${PATH}"
git clone 'https://skia.googlesource.com/skia.git'
cd skia
git checkout <rev from tools/skia-rev.txt>
GIT_SYNC_DEPS_SKIP_EMSDK=1 python3 tools/git-sync-deps
```

`GIT_SYNC_DEPS_SKIP_EMSDK=1` skips the Emscripten activation step;
desktop builds never use it. `git-sync-deps` also runs `bin/fetch-gn`,
so `bin/gn` exists afterwards. The CI workflow
(`.github/workflows/native.yml`) runs this same flow. Do not
substitute `gclient sync`: the checkout has no `.gclient`, the sync
no-ops silently, and the build then dies on the missing `bin/gn`.

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

## 5. Build `nui_native`

From `NielloUI/native/` (`nui.h`, `nui.cpp`, `util.cpp`):

```cmake
add_library(nui_native STATIC nui.cpp util.cpp)
```

Point it at the Skia checkout's `include/`, the `out/niello-<platform>/gen`
dir, and link the archives from §4. `native/CMakeLists.txt` already does
this shape; the release variant passes `-DNIELLO_SKIA_OUT=niello-<platform>`
(and keeps honoring `SKIA_DIR`).

## 6. Merge into one fat archive

Merge `libskia.a` + `libdawn_combined.a` + `libskshaper.a` + `libharfbuzz.a` (+ any sibling Dawn archives from
§4) + `libnui_native.a` into a single archive so downstream links exactly
one native lib plus system libs (SDL3, Vulkan, Freetype, Fontconfig,
Threads).

- **Linux** — `ar -M` with an MRI script (avoids `.o` basename collisions
  that extract-and-re-add would cause):

  ```
  CREATE libniello_native.a
  ADDLIB out/niello-linux-x64/libskia.a
  ADDLIB out/niello-linux-x64/libdawn_combined.a
  ADDLIB out/niello-linux-x64/libskshaper.a
  ADDLIB out/niello-linux-x64/libharfbuzz.a
  ADDLIB <nui_native build dir>/libnui_native.a
  SAVE
  END
  ```
  ```
  ar -M < merge.mri
  ```

- **macOS** — `libtool`:
  ```
  libtool -static -o libniello_native.a \
    out/niello-macos-arm64/libskia.a \
    out/niello-macos-arm64/libdawn_combined.a \
    out/niello-macos-arm64/libskshaper.a \
    out/niello-macos-arm64/libharfbuzz.a \
    <nui_native build dir>/libnui_native.a
  ```

- **Windows** — `lib.exe`:
  ```
  lib.exe /OUT:niello_native.lib ^
    out\niello-windows-x64\skia.lib ^
    out\niello-windows-x64\dawn_combined.lib ^
    out\niello-windows-x64\skshaper.lib ^
    out\niello-windows-x64\harfbuzz.lib ^
    <nui_native build dir>\nui_native.lib
  ```

Windows CRT caveat: if the Odin app's link fails with `LNK2038`
(CRT mismatch), the Skia build's runtime-library flag disagrees with the
Odin toolchain's — align them in the GN args rather than working around it
downstream. Verify with a real Odin link before publishing the Windows zip.

## 7. Zip and release

```
niello-native-<platform>.zip
├── lib/libniello_native.a   # niello_native.lib on Windows
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
build `nui_native`, merge per §6, zip, `upload-artifact`. Dawn needs
CMake 3.30+; `ubuntu-24.04` ships 3.28, so the Linux job provisions
a newer CMake (pip/Kitware) — verify at the first CI run. A release job on
tag `native-v*` downloads the three artifacts and creates the GitHub
Release with them.

Honest caveats: a full Skia+Dawn release build is 30–90 minutes per
platform and the checkout with externals is several GB — cache the Skia
checkout and the `out/niello-<platform>` dirs keyed on the Skia revision.
Prove the matrix with manual builds first; automate once it is green.
