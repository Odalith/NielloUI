# NielloUI

NielloUI is a cross-platform desktop UI framework in [Odin](https://odin-lang.org).
You describe your UI every frame, immediate-mode style, while the styles live in
retained objects you create once. Rendering goes through Skia Graphite (on Dawn) behind
SDL3.

```odin
{{#include ../snippets/counter/counter.odin:declare}}
```

What that buys you:

- **No callbacks, no change notifications.** The UI is a function of your state,
  declared each frame. Interaction (`clicked`, `hovered`, `pressed`…) is asked
  where the control is declared. The engine finds what changed and repaints only
  that.
- **Styles you restyle in one place.** Styles live in *units* you `mint` once.
  Groups broadcast a value to every unit playing a role, so re-theming, resizing
  text or changing density is a single call, and it can glide.
- **A real layout engine.** Rows, columns and stacks with fixed / fit / grow /
  percent sizing, a fair waterfill for growing and shrinking, wrapping rich text,
  scrolling with smooth glides and overscroll, popups and dialogs.
- **Batteries included.** `niello/controls` ships buttons, switches, a text box
  with selection, clipboard and undo, sliders, progress bars and scrollbars.
  `niello/virtual` adds virtual lists for data too long to declare in full.
- **Accessible and debuggable.** An accessibility tree is maintained every frame
  (AT-SPI on Linux), and a debug window (F12, debug builds only) shows the live
  node tree and layout problems.

**Status:** NielloUI works on Linux (X11 and Wayland). Windows builds are
supported; macOS is planned. The API is still settling.

Start with [Getting started](getting-started.md).
