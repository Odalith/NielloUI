# Building the NielloUI native backend (maintainers)

Goal: produce `niello-native-<platform>.zip` — one fat static archive
(`nui_render` + Skia + Dawn merged) plus `include/nui.h` — for
`linux-x64`, `macos-arm64`, and `windows-x64`, then attach the three zips to
a GitHub Release. App authors then just run `tools/fetch-native.sh`
(`fetch-native.ps1` on Windows). Binaries are never committed (enforced by
`.gitignore`).

**Frozen native surface** (re-frozen 2026-10-22, after the multi-window
merge replaced the old five-function surface): a release pins exactly the
per-window ABI in `native/nui.h` — `nui_init`, `nui_create_window`,
`nui_destroy_window`, `nui_resize`, `nui_set_refresh_rate`,
`nui_is_resizing`, `nui_render`, `nui_present_cached`,
`nui_register_font`, `nui_register_font_family`, `nui_measure_word`,
`nui_line_height`, `nui_shutdown` — mirrored by `niello/sdl/ffi.odin`.
Changing any signature means a new native release train, not a patch.

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
```

**linux-x64** — the tested config, unchanged:

```
skia_use_vulkan=true
dawn_enable_vulkan=true
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
harmless here (Xcode CLT `clang` is on `PATH`) — keep or drop. Build on
arm64 hardware or a `macos-14`+ CI runner (Apple Silicon).

**windows-x64**:

```
target_os="win"
target_cpu="x64"
dawn_enable_d3d12=true
```

Notes: **drop the `cc="clang"` / `cxx="clang++"` overrides** on Windows.
Skia's Windows build expects clang-cl from depot_tools' bundled LLVM with
the MSVC-ABI setup; a bare `clang` override breaks that. After `gn gen`,
confirm the toolchain resolves to clang-cl before the long build starts.

## 3. SkShaper check (required for `nui_measure_word` / `nui_line_height`)

The text-measuring callbacks shape with SkShaper. Before cutting release
builds, verify SkShaper actually made it into each platform's build:

```
ninja -C out/niello-<platform> -t targets all | grep -i skshaper
# or: ls out/niello-<platform>/obj/modules/skshaper/
```

If it is absent, the `skia` target needs the skshaper module wired in —
check the module's `BUILD.gn` against what the `skia` target pulls in
rather than guessing at flags. Do not ship a release whose
`nui_measure_word` would link-fail.

## 4. Build commands

From the Skia checkout (or `$SKIA_DIR`):

```sh
bin/gn gen out/niello-<platform> --args="<platform args from §2>"
ninja -C out/niello-<platform> skia
```

With `skia_use_dawn=true`, the Dawn targets build in the same graph. The
testbed links `dawn_combined`, so after ninja finishes, enumerate the
archives to merge:

```sh
ls out/niello-<platform>/*.a   # expect libskia.a, libdawn_combined.a, ...
```

Record the Skia revision next to each release for reproducibility:

```sh
git -C "$SKIA_DIR" rev-parse HEAD
```

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

Merge `libskia.a` + `libdawn_combined.a` (+ any sibling Dawn archives from
§4) + `libnui_render.a` into a single archive so downstream links exactly
one native lib plus system libs (SDL3, Vulkan, Freetype, Fontconfig,
Threads, zlib — the codec's DNG module references zlib's
`compress2`; latent until #13 first pulled Skia's codec objects
into a link).

- **Linux** — `ar -M` with an MRI script (avoids `.o` basename collisions
  that extract-and-re-add would cause):

  ```
  CREATE libniello_render.a
  ADDLIB out/niello-linux-x64/libskia.a
  ADDLIB out/niello-linux-x64/libdawn_combined.a
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
    <nui_render build dir>/libnui_render.a
  ```

- **Windows** — `lib.exe`:
  ```
  lib.exe /OUT:niello_render.lib ^
    out\niello-windows-x64\skia.lib ^
    out\niello-windows-x64\dawn_combined.lib ^
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
`windows-2022`, `macos-14`; per job: install depot_tools, sync the Skia
checkout at the pinned revision, `gn gen` with the §2 args, `ninja skia`,
build `nui_render`, merge per §6, zip, `upload-artifact`. A release job on
tag `native-v*` downloads the three artifacts and creates the GitHub
Release with them.

Honest caveats: a full Skia+Dawn release build is 30–90 minutes per
platform and the checkout with externals is several GB — cache the Skia
checkout and the `out/niello-<platform>` dirs keyed on the Skia revision.
Prove the matrix with manual builds first; automate once it is green.
