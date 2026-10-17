# NielloUI

A cross-platform desktop UI framework in Odin — retained styling, immediate-mode
declaration, and a Skia Graphite render backend behind SDL3.

**Status:** the framework core (`niello/`) is implemented and tested headless.
The native render backend is being extracted from the `skiasdl` testbed into a
static library; the SDL app glue (`niello/sdl/`) is stubbed against its ABI.

## Layout

```
NielloUI/
  niello/               package niello — the framework core (pure Odin)
    public.odin         the entire public API: Unit/Instance/mint/show/begin…
    state.odin          cold store, generations, dirty tracking
    declare.odin        declaration machinery, identity, text resolution
    text.odin           measurement + word cache (mock metrics until backend)
    layout.odin         the layout passes + waterfill
    render.odin         Draw_Cmd command buffer + emitter + damage predicate
    test_hooks.odin     test-only introspection (NOT public API)
    tests/              headless test suite (odin test)
    examples/hello/     runnable demo on the public API only (odin run)
    sdl/                package sdl — SDL3 app glue + FFI to the native backend
      ffi.odin          nui_* bindings; Draw_Cmd ABI asserts
  third_party/native/   prebuilt native backends, one dir per platform
                        (downloaded, not committed — see its README)
  tools/
    fetch-native.sh     downloads the prebuilt backend for this platform
```

## The native backend

Rendering goes through Skia Graphite (Dawn/WebGPU). Because building Skia takes
the better part of an afternoon and a correct toolchain per OS, the backend
ships **prebuilt, one static library per platform**:

- `windows-x64`
- `macos-arm64`
- `linux-x64` (one binary covers X11 and Wayland — SDL picks at runtime)

Each release artifact (`niello-native-<platform>.zip`) holds a single fat static
archive (`libniello_render.a` / `niello_render.lib`, with Skia + Dawn merged in)
plus `nui.h`. Drop it under `third_party/native/<platform>/` — or run
`tools/fetch-native.sh` — and the `niello/sdl` package links against it.

Until the first release is cut, `niello/` builds and tests headless with mock
text metrics; `niello/sdl` type-checks but does not link.

## Building

```sh
odin test niello/tests -define:ODIN_TEST_THREADS=1 -o:speed   # core suite
odin run niello/examples/hello                                # headless demo
```

## Repos

- `NielloUI` (this) — the public framework.
- `odin_ui` — original framework testbed.
- `skiasdl` — native backend (Skia Graphite + SDL3) testbed; source of `nui.h`.
