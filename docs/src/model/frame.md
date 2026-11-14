# The frame pipeline

A frame is three calls, made by the host for each window: `frame_begin`, your
`declare`, `frame_end`. [`niello_sdl.run`](../reference/sdl.md#run) makes them
for you; a test, or a host of your own, makes them directly:

```odin
{{#include ../../snippets/model/frame.odin:host}}
```

## frame_begin: input

[`frame_begin`](../reference/niello.md#frame_begin) makes the context current
and applies the frame's [`Input`](../reference/niello.md#Input): the window
size, the pointer and buttons, the wheel, keys and typed text since the last
frame. Input is dispatched against the **last** frame's layout, which is what
the user saw: the pointer picks an instance, presses and clicks are worked
out, the wheel scrolls, Tab moves focus. This is why queries during declaring
see the previous frame (see [Interaction](interaction.md#one-frame-behind)).

`dt` is the time since the last frame, in seconds; animations advance by it.

## declare: your UI

Your code runs `show` and `begin`, asks its interaction queries and updates
its state. Nothing is laid out or drawn yet: declaring only records what the
UI is this frame.

## frame_end: everything else

[`frame_end`](../reference/niello.md#frame_end) does the work, in order:

1. **State.** Each instance's effective style is resolved: its unit's style
   with its variant, the state overlays that apply (hover, press, focus,
   disabled) and its `With` size.
2. **Layout.** Text is measured, sizes are worked out bottom-up from the
   content and distributed top-down from the window, text wraps, and every
   instance gets its rect. [Deferred sections](../scrolling.md), such as
   virtual lists, build and lay out here, once their size is known.
3. **Animation.** Glides and pulses advance.
4. **Change.** The new frame is compared with the last: which instances
   appeared, went, moved, or now look different. The result is the
   **damage**, the regions that need repainting.
5. **Accessibility.** The accessibility tree is brought up to date (see
   [Accessibility](../accessibility.md)).

It returns a [`Frame_Result`](../reference/niello.md#Frame_Result):

- `changed`: whether anything needs drawing. If not, the host draws nothing.
- `damage`: the regions that changed, exactly.
- `repaint`: the same regions as a few merged rects, for repainting.
- `next_wake_ms`: when the engine next needs a frame by itself, for an
  animation or a timer; the maximum `u32` when it needs none.
- `cursor`: the pointer cursor to show.

The host then draws [`draw_list`](../reference/niello.md#draw_list), the
frame's drawing commands in paint order, and sleeps until input arrives or
`next_wake_ms` passes. A host that keeps the previous frame's pixels, as
`niello/sdl` does, repaints only what changed: `draw_list(res.repaint)` holds
just the commands touching those rects, and the backend clears each rect and
replays them clipped to it. Everything that touches a repainted rect is drawn
again, bottom to top, so translucent content composites correctly. The first
frame, and any frame after a resize, is drawn in full.

## When nothing changes

A frame in which nothing changed (same declaration, same unit styles, no
input that matters, no animation) is cheap: the engine finds that out
without laying out again, and reports `changed = false`. The host draws
nothing and goes back to sleep, so an idle app uses no CPU.

You never tell the engine that something changed; it finds out. Writing a
unit (`set`, a broadcast) or declaring different text is noticed on the next
frame. What it cannot notice is time: a clock or a progress readout that
should move with nothing else happening asks for frames with
[`wake_in`](../reference/niello.md#wake_in), and a worker thread with results
wakes the window with [`context_wake`](../reference/niello.md#context_wake)
(see [Windows and async work](../windows.md)).

## Contexts

A [`Context`](../reference/niello.md#Context) is one window's UI: its
instances, layout and interaction. Units and groups are not part of a
context. They are global, so one unit can be declared in every window, and
one broadcast re-themes all of them. `niello_sdl.run` creates a context per
window; a headless test creates one with
[`context_create`](../reference/niello.md#context_create).
