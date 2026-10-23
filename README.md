# NielloUI

A cross-platform desktop UI framework in Odin — retained styling, immediate-mode
declaration, and a Skia Graphite render backend behind SDL3.

**Status:** working in real windows on Linux (X11 and Wayland). Implemented:
the layout engine (row/column/stack, waterfill grow/shrink); rich text
(fragment-aware word cache, styled spans, wrap + paint-time ellipsis,
collapse/preserve whitespace); input (state overlays, press capture, click
and hover queries); focus traversal and text input; groups; the mutation
layer (`tween`, `edit`, `propagate`, `transient`); scrolling (wheel
chaining, smooth glides, overscroll with spring-back); a popup layer
(dropdowns, context menus, modal dialogs); and scrollbar chrome as a
component; and multi-window: one engine context per window, units and
groups global (mint once — a broadcast re-themes every window), windows
opened and closed from inside declare procs. A debug window
(Clay/Avalonia-style: live node tree, hover-to-highlight, the
overflow report) ships as a package in debug builds only
(-define:NIELLO_DEBUG=true, F12 in any window) at zero prod cost.
A headless suite (129 tests; 134 in debug builds) covers the core, and the SDL loop idles at ~0 CPU — it blocks on
OS events and wakes on the nearest engine deadline across windows.
Still ahead: prebuilt releases, a packaged component collection, and
the remaining parity work in `TODO.md`.

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
odin run niello/examples/buttons -extra-linker-flags:"-L$PWD/third_party/native/linux-x64 -Wl,--start-group -lnui_render -lskia -ldawn_combined -lskcms -lwuffs -Wl,--end-group -lstdc++ -lz -lpng -ljpeg -lwebp -lwebpdemux"
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
- `examples/scroll` — scrolling: wheel chaining between nested scrollers,
  scroll ranges, programmatic `scroll_to`.
- `examples/animate` — the mutation layer: tweens, edit handles, style
  propagation, and transient pulses.
- `examples/text` — rich text: styled spans (weight, slant, color) inside
  a single string, measured and drawn as one flow.
- `examples/form` — focus and text input: two editable fields with
  traversal, a layout-positioned caret, Clear/Submit.
- `examples/popups` — the popup layer: dropdown menus, a canvas context
  menu, and a modal dialog — dismiss is reported, never automatic.
- `examples/scrollbars` — scrollbar chrome as a component: drag the
  thumb, page from the track, plus a restyled bar with smooth scrolling
  and overscroll on the same scroller.
- `examples/multiwindow` — multi-window: a main window whose button
  opens inspector windows that render its committed tree live through
  the cross-context read API.
- `examples/debugger` — the debug window's host: a scene with
  deliberate layout defects; F12 opens the debugger on it.
- `examples/images` — image support (§3.25): the four fit modes,
  per-instance images, crops, decode-to-size, interpolation,
  background images.

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
    animate.odin        the mutation layer: tweens, edits, transients
    tests/              headless test suite (odin test)
    examples/           hello, layouts, buttons, groups, scroll, animate,
                        text, form, popups, scrollbars, multiwindow
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
