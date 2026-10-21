# NielloUI

A cross-platform desktop UI framework in Odin — retained styling, immediate-mode
declaration, and a Skia Graphite render backend behind SDL3.

**Status:** working in real windows on Linux (X11 and Wayland). Layout, text,
input, scheduling, and groups are implemented and covered by a headless suite
(62 tests). Still ahead for v1: scrolling, focus traversal + text input, the
tween/transient layer, more examples, prebuilt releases, and a component
collection.

## The model in one paragraph

You `mint` Units — retained objects that own their style values — then declare
the tree every frame with `show`/`begin`. The engine diffs each declaration
against the retained store and discovers changes itself; there are no change
notifications to wire up. Interaction is polled during declare (`clicked`,
`hovered`, `pressed`, `hover_duration`) against last frame's hit test, and
state styles (hover/press/focus/disabled) are overlay Units. Groups are
address books of Units so a caller higher up can change components everywhere
with one `group_set` — joining a group applies nothing; a Unit's birth values
come from its base at mint.

## Building

The framework core is pure Odin and tests headless (mock text metrics):

```sh
odin test niello/tests -define:ODIN_TEST_THREADS=1 -o:speed
```

Windowed examples need the native backend for your platform under
`third_party/native/<platform>/` — see that directory's README
(`tools/fetch-native.sh` fetches it once a release exists; until then, build
`native/` yourself, below). Then, from the repo root on Linux:

```sh
odin run niello/examples/buttons -extra-linker-flags:"-L$PWD/third_party/native/linux-x64 -Wl,--start-group -lnui_render -lskia -ldawn_combined -lskcms -lwuffs -Wl,--end-group -lstdc++"
```

## Examples

- `examples/hello` — the first window: a colored rect and a line of text,
  the full declare → draw → Skia path.
- `examples/buttons` — input: clickable buttons with hover/press overlays,
  press capture, a sound toggle, and a disabled button that absorbs clicks.
- `examples/layouts` — a layout gallery: fixed/fit/grow, percent splits,
  nested rows and columns, stack alignment.
- `examples/groups` — theming with groups: one broadcast recolors the app,
  a pinned button keeps its color, and cards minted at runtime are born in
  the base palette — locating is not applying.

## Fonts

Family 0 is the platform default. Register your own before `run()` and use
the id as `Style.font` — from a bundled file, or by system family name:

```odin
Inter: niello.Font_Handle = 1
niello_sdl.register_font(Inter, "assets/Inter.ttf")
niello_sdl.register_font_family(Other, "Segoe UI")
niello.mint(&u, niello.NO_UNIT, {font = Inter})
```

Unregistered families, and files that fail to load, fall back to the default
face. The backend caches (family, weight, slant, size) faces internally;
measurement goes through Skia only on a word-cache miss.

## Layout

```
NielloUI/
  niello/               package niello — the framework core (pure Odin)
    public.odin         the entire public API: Unit/Instance/Group,
                        mint/show/begin, set, input queries, wake, groups
    state.odin          cold store: units, groups, generations, damage
    declare.odin        declaration machinery, identity, text resolution
    text.odin           measurement + word cache (backend hooks on miss)
    layout.odin         the layout passes + waterfill distribution
    render.odin         Draw_Cmd command buffer + emitter
    input.odin          hit-testing + dispatch, overlay resolution
    tests/              headless test suite (odin test)
    examples/           hello, buttons, layouts, groups
    sdl/                package sdl — SDL3 app glue + FFI to the backend
      app.odin          run(): the hand-driven loop — blocks on OS events
                        when idle, wakes on the engine's next deadline
      ffi.odin          nui_* bindings, font registration, ABI asserts
  native/               the backend source (nui.h, nui.cpp): Skia Graphite
                        + Dawn behind a small C ABI, built as a static lib
  third_party/native/   prebuilt native backends, one dir per platform
                        (downloaded, not committed — see its README)
  tools/
    fetch-native.sh     downloads the prebuilt backend for this platform
```

## The native backend

Rendering goes through Skia Graphite (Dawn/WebGPU). Building Skia takes the
better part of an afternoon and a correct toolchain per OS, so the backend is
distributed **prebuilt, one static library per platform**:

- `windows-x64`
- `macos-arm64`
- `linux-x64` (one binary covers X11 and Wayland — SDL picks at runtime)

Each release artifact (`niello-native-<platform>.zip`) holds a single fat
static archive (the backend with Skia + Dawn merged in) plus `nui.h`; see
`third_party/native/README.md` for the layout. The first release is still to
be cut — until then, build it from `native/` with CMake against an
out-of-tree Skia checkout:

```sh
cmake -B build -DSKIA_DIR=/path/to/skia native/
```

The Odin side owns the window, the event loop, and all input; the C++ side
is a rendering slave behind the C ABI and never touches SDL.
