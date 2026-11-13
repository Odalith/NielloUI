# Getting started

## What you need

- **Odin.** NielloUI tracks recent Odin releases. It is developed and tested
  with `dev-2026-08`.
- **The native backend** for your platform: a prebuilt static library with Skia
  and Dawn inside. From a clone of the repository, fetch it once:

  ```sh
  ./tools/fetch-native.sh        # Linux
  ./tools/fetch-native.ps1       # Windows (also drops SDL3.dll beside your .exe)
  ```

  Or build it from `native/` with CMake against a Skia checkout; see
  `tools/build-native.md`.
- **SDL3** installed on Linux (your distribution's package). On Windows it ships
  as `SDL3.dll` next to your program.

Headless use (tests, tools) needs neither the backend nor SDL: the core is pure
Odin.

## Using NielloUI from your project

Put the repository somewhere in your project (a git submodule works well) and
make its `niello` directory a collection when you build:

```sh
odin run myapp -collection:niello=path/to/NielloUI/niello
```

Then import the core, the SDL app glue, and the optional packages by that name:

```odin
import niello "niello:."           // the core
import niello_sdl "niello:sdl"     // windows and the event loop
import controls "niello:controls"  // the shipped controls
```

## A first window

```odin
{{#include ../snippets/apps/hello/main.odin:all}}
```

Two halves, and they are the whole model:

- **Units are minted once.** `niello.mint` creates a unit: an object that owns a
  style (layout, colors, text size…). You keep the handle and use it every
  frame.
- **The UI is declared every frame.** `declare` runs each frame. `begin` opens a
  container (its block holds its children; the matching end happens when the
  `if` closes) and `show` places a leaf. Every occurrence becomes an *instance*:
  the same unit can be shown many times, each instance with its own position,
  text and interaction state.

`niello_sdl.run` opens the window and runs the loop. It sleeps until something
happens: the loop uses no CPU while your UI is idle.

## Interaction and state

Real apps have state. Keep it in a struct and hand it to `run`; `declare` gets it
every frame:

```odin
{{#include ../snippets/counter/counter.odin:state}}
```

```odin
{{#include ../snippets/counter/counter.odin:mint}}
```

```odin
{{#include ../snippets/counter/counter.odin:declare}}
```

```odin
{{#include ../snippets/apps/counter/main.odin:main}}
```

`controls.button` returns the button's instance, and `niello.clicked` asks
whether it was clicked, right where it is declared. `controls.text_box` keeps its
text in the `Text_Box` you own; it handles typing, selection, the clipboard and
undo itself.

## Testing without a window

The core runs headless, so the same `declare` can be driven by a test: feed it
input frame by frame and check your state.

```odin
{{#include ../snippets/headless/counter_test.odin:test}}
```

Run it with `odin test`, as any Odin test (`-define:ODIN_TEST_THREADS=1`: the
engine keeps global state). Every example on this page is compiled, and this test
is run, when the documentation is built.

## Where next

- [The model](model/index.md): units, declaring, identity, groups, and what
  happens in a frame.
- [Controls](controls.md): the shipped controls and how to theme them.
- The examples in `niello/examples/`. `showcase` covers most of the framework
  in one app.
