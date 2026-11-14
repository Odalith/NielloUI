# NielloUI

A cross-platform desktop UI framework in Odin — retained styling, immediate-mode
declaration, and a Skia Graphite render backend behind SDL3.

**Status:** working in real windows on Linux (X11 and Wayland) and Windows;
macOS has release builds of the backend but is untested. Implemented:

- the layout engine: rows, columns and stacks, fit / grow / fixed / percent
  sizing with waterfill distribution, padding, gap, alignment, overflow;
- rich text: a fragment-aware word cache, styled spans, wrapping, paint-time
  ellipsis, whitespace modes, platform and bundled fonts;
- input polled during declare (`clicked`, `hovered`, `pressed`, drag queries)
  with press capture and state overlays; keyboard focus, traversal and an
  engine-drawn focus ring; text input and the clipboard;
- groups for theming by role; the mutation layer (`tween`, `edit`,
  `propagate`, `transient`);
- scrolling with wheel chaining, smooth glides and overscroll; deferred
  sections and virtual lists (`niello/virtual`);
- a popup layer (dropdowns, context menus, modal dialogs); images;
- accessibility: a mirror tree exported over AT-SPI on Linux;
- multi-window (a context per window, units and groups shared), timers, and
  a one-queue inbox for results from worker threads (`niello/inbox`);
- shipped controls (`niello/controls`): buttons, toggle button, switch,
  text box, slider, progress bar and scrollbar, with theme, type and spacing
  roles;
- a debugger window in debug builds only (`-define:NIELLO_DEBUG=true`, F12
  in any window) at zero cost otherwise.

A headless suite (270+ tests) covers the core, and the SDL loop idles at
~0 CPU: it blocks on OS events and wakes on the nearest engine deadline
across windows. Next: more controls (check box, radio group, combo box,
tabs, tooltip, list box, multi-line text) and a fuller default theme.

## Documentation

The user guide lives in `docs/` (an [mdBook](https://rust-lang.github.io/mdBook/)) and is
published at <https://odalith.github.io/NielloUI/>. Its code examples are compiled, and the
headless ones run as tests, every time it is built. Preview it locally with live reload:

```sh
tools/docs.sh            # needs odin and mdbook on PATH
```

## The model in one paragraph

(The guide's [model chapter](https://odalith.github.io/NielloUI/model/index.html)
has the full story.)

You `mint` Units — retained objects that own their style values — then declare
the tree every frame with `show`/`begin`. The engine diffs each declaration
against the retained store and discovers changes itself; there are no change
notifications to wire up. Interaction is polled during declare (`clicked`,
`hovered`, `pressed`, `hover_duration`) against last frame's hit test, and
state styles (hover/press/focus/disabled) are overlay Units. Groups are
address books of Units so a caller higher up can change components everywhere
with one `group_set` — joining a group applies nothing; a Unit's birth values
come from its base at mint. A Unit lives until `unmint(u)`, which frees it and every
reference the engine holds to it; `shutdown()` releases the whole engine
(contexts, units, groups, caches) after the last frame.

## Building

The framework core is pure Odin and tests headless (mock text metrics):

```sh
odin test niello/tests -define:ODIN_TEST_THREADS=1 -o:speed
```

Windowed examples need the native backend for your platform under
`third_party/native/<platform>/`. Fetch the prebuilt release once (or build
`native/` yourself, below), then run any example from the repo root:

```sh
tools/fetch-native.sh          # Linux; Windows: tools/fetch-native.ps1
odin run niello/examples/showcase
```

On Linux the examples link the system SDL3 (your distribution's package);
`fetch-native.sh` also fetches a bundled SDL3 for apps that ship their own.

On Windows, run `tools/fetch-native.ps1` instead — and note the one
dynamic piece: everything links statically into your `.exe` except
SDL3. `fetch-native.ps1` drops a copy of `SDL3.dll` at the repo root
(where example `.exe`s land), and a shipped app is just the two files
together: `yourapp.exe` + `SDL3.dll` in one folder.

## Examples

Run any of them with `odin run niello/examples/<name>` from the repo root.

- `showcase`: the whole framework in one app. A sidebar of pages (controls,
  layout, text, keyboard and focus, scrolling, virtual lists, animation,
  popups, drag, images, async and windows) with a live theme switch and
  text-size and spacing sliders. `showcase_test.odin` drives the same app
  headlessly through every page:
  `odin test niello/examples/showcase -define:ODIN_TEST_THREADS=1`.
- `hello`: the first window, a colored rect and a line of text.
- `buttons`: input with no callbacks: hover and press overlays, press
  capture, hover duration, a disabled button that absorbs clicks, cursors.
- `form`: keyboard focus and text input on the shipped controls: two text
  boxes and two buttons in one tab order.
- `layouts`: a layout gallery: fixed, fit, grow, percent splits, nested rows
  and columns, stack alignment.
- `groups`: theming with groups: one broadcast recolors the app, a pinned
  button keeps its color, and cards minted later are born in the base
  palette.
- `text`: rich text: styled spans (weight, slant, color) in one string.
- `scroll`: wheel chaining between nested scrollers, scroll ranges,
  `scroll_to`.
- `scrollbars`: scrollbar chrome: drag the thumb, page from the track, a
  restyled bar with smooth scrolling and overscroll.
- `animate`: the mutation layer: tweens, edit handles, propagation,
  transient pulses.
- `popups`: dropdown menus, a context menu and a modal dialog; dismissal is
  reported, never automatic.
- `drag`: the drag query's three uses: a slider, a splitter, and a dialog
  dragged by its header.
- `images`: the four fit modes, per-instance images, crops, decode-to-size,
  interpolation, background images.
- `inbox`: work on other threads (a library scan, a playback ticker)
  reporting back through `niello/inbox`.
- `multiwindow`: a main window whose button opens inspector windows that
  show its tree live.
- `a11y`: accessibility semantics exported over AT-SPI; run it under Orca or
  Accerciser.
- `debugger`: a scene with deliberate layout defects; build with
  `-define:NIELLO_DEBUG=true` and press F12.
- `image_soak`: a memory soak for image loading and release.

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

## Repository layout

```
NielloUI/
  niello/               package niello: the framework core (pure Odin, no OS code)
    public.odin         the API: units, declaring, With, styles, input
                        queries, groups, the mutation layer, frames
    images.odin         images (load, crop, release)
    a11y.odin           accessibility types and the mirror tree
    render.odin         Draw_Cmd and the draw list a host renders
    debug.odin          the debug snapshot and overflow report (debug builds)
    state.odin, declare.odin, layout.odin, input.odin, text.odin,
    animate.odin        internals: the store, declaration, layout passes,
                        hit testing, text measurement, animation
    tests/              the headless test suite (odin test)
    examples/           the examples above
    sdl/                package sdl: SDL3 windows and event loop, FFI to the backend
    controls/           package controls: the shipped controls
    virtual/            package virtual: virtual lists
    inbox/              package inbox: results from worker threads
    debugui/            package debugui: the debugger window
  native/               the backend source (nui.h, nui.cpp): Skia Graphite
                        + Dawn behind a small C ABI, built as a static lib
  third_party/native/   prebuilt backends, one directory per platform
                        (downloaded, not committed; see its README)
  docs/                 the user guide (mdBook) and its compiled snippets
  tools/
    fetch-native.sh     downloads the prebuilt backend (fetch-native.ps1 on Windows)
    build-native.sh     builds the backend (maintainers; see build-native.md)
    docgen/             generates the API reference from the doc comments
    docs.sh             builds or serves the user guide
```

## The native backend

Rendering goes through Skia Graphite (Dawn/WebGPU). Building Skia takes the
better part of an afternoon and a correct toolchain per OS, so the backend is
distributed **prebuilt, one static library per platform**:

- `linux-x64` (one binary covers X11 and Wayland; SDL picks at runtime)
- `windows-x64`
- `macos-arm64` (built by CI, not yet tested)

Each release artifact (`niello-native-<platform>.zip`) holds a single fat
static archive (the backend with Skia + Dawn merged in) plus `nui.h`; see
`third_party/native/README.md` for the layout. Fetch a release with
`tools/fetch-native.sh` (`tools/fetch-native.ps1` on Windows), or build it
from `native/` with CMake against an out-of-tree Skia checkout:

```sh
cmake -B build -DSKIA_DIR=/path/to/skia native/
```

The Odin side owns the window, the event loop, and all input; the C++ side
is a rendering slave behind the C ABI and never touches SDL.
