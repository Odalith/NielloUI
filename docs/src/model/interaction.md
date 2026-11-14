# Interaction: polling

NielloUI has no callbacks. You ask about interaction where you declare the
control, with the instance `show` or `begin` gave you, and act on the answer
right there:

```odin
{{#include ../../snippets/model/interaction.odin:toolbar}}
```

The handler is the `if` block. It runs in `declare`, with your state and
every local variable in reach. Nothing is registered or unregistered, and
nothing outlives the frame.

## The queries

**Pointer and activation.**
- [`clicked`](../reference/niello.md#clicked): pressed and released over the
  instance (or one of its children) with the left button, or activated with
  Space or Enter while it has focus. True for one frame.
- [`hovered`](../reference/niello.md#hovered): the pointer is over the
  instance or one of its children.
- [`pressed`](../reference/niello.md#pressed): a press that began on the
  instance is still held. The press captures the instance: `pressed` stays
  true wherever the pointer goes, until the button is released.
- [`hover_duration`](../reference/niello.md#hover_duration): how long the
  pointer has been over it, for tooltips.

**Dragging.** A press that moves more than a few DIP becomes a drag:
[`drag_started`](../reference/niello.md#drag_started),
[`dragging`](../reference/niello.md#dragging),
[`drag_ended`](../reference/niello.md#drag_ended), with the movement in
[`drag_delta`](../reference/niello.md#drag_delta) (since the last frame) and
[`drag_total`](../reference/niello.md#drag_total) (since the press).

```odin
{{#include ../../snippets/model/interaction.odin:splitter}}
```

**Focus and keys.** [`focused`](../reference/niello.md#focused),
[`input_keys`](../reference/niello.md#input_keys) and
[`input_text`](../reference/niello.md#input_text) answer for the instance that
holds keyboard focus. [Input and focus](../input.md) covers them, with
traversal and text input.

## One frame behind

Queries made while declaring see the **previous** frame. The pointer is
tested against where things were last drawn, which is where the user saw them
and clicked. A click therefore reaches your code one frame after it happened,
about 16 ms at 60 frames a second, which nobody can see.

Two consequences are worth knowing:

- On the very first frame nothing has been laid out yet, so nothing is
  hovered or clicked and `rect` reports no rect.
- After [`frame_end`](../reference/niello.md#frame_end), the same queries see
  the frame that just ended. A host or a test reading results between frames
  gets the new layout.

## Rules the engine keeps

- **Hover follows the pointer; a press follows its instance.** A button
  pressed and dragged off is no longer hovered but still pressed, and
  releasing away from it is not a click.
- **Disabled absorbs.** A disabled instance reports `hovered`, so it can look
  disabled under the pointer, but is never pressed or clicked, and a press on
  it does not reach the containers around it either.
- **Children count as their parent.** Clicking a button's label clicks the
  button. Ask about the instance that means something to you.
- **What you see is what you hit.** The pointer is tested against each
  instance's painted shape, rounded corners included, and against the clips
  of its ancestors: what a scroller or a clipping container hides cannot be
  hit.

## Keeping instance handles

An `Instance` is only a name, so it is safe to keep across frames. The
examples keep handles in the app's state (`app.save_i`) so code elsewhere,
or a test, can ask about them. A handle for an instance that is no longer
declared answers false to every query.
