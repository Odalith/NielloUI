# Declaring: show, begin, identity

Every frame, your `declare` procedure describes the UI from scratch. Two calls
do it:

- [`show`](../reference/niello.md#show) places a **leaf**: a unit with no
  children (a label, an image, a box).
- [`begin`](../reference/niello.md#begin) opens a **container**. Everything
  declared until its block closes is its child.

```odin
{{#include ../../snippets/model/declaring.odin:declare}}
```

Write `begin` as the condition of an `if`. The container is closed for you
when the `if` statement's scope ends, so containers can never be left open by
an early `return` or a forgotten `end`. The result is almost always true; it
is false only inside a popup that is not shown (see
[Popups and dialogs](../popups.md)).

Declaring is just code: an `if` decides whether something exists, a `for`
repeats it, and a procedure is a reusable piece of UI. There is no tree to
update. What you declared last frame and do not declare this frame is gone.

## Instances

Each `show` and `begin` creates an **instance**: one occurrence of a unit,
with its own position, text and interaction state. Above, `row_u` is
declared twice, so there are two rows. Both share `row_u`'s style.

`show` returns the instance as an [`Instance`](../reference/niello.md#Instance)
handle, and `begin` hands it out through `out` (or
[`current`](../reference/niello.md#current), inside its block). You use it to
ask about the instance: was it [clicked](interaction.md), where is it
([`rect`](../reference/niello.md#rect)), does it hold focus.

```odin
{{#include ../../snippets/model/declaring.odin:out}}
```

## Identity

An instance keeps its identity from frame to frame, and everything the engine
remembers about it follows that identity: whether it is hovered or pressed,
its scroll offset, keyboard focus, an animation in flight. Usually you never
think about it, because the default does the right thing.

**By default, an instance is named by where it is declared:** the line of
code that calls `show` or `begin`, inside its parent. Code that runs several
times in one parent (a loop) is told apart by count: the first row, the
second, and so on.

Because the name comes from the call site, a conditional instance does not
disturb its neighbours:

```odin
{{#include ../../snippets/model/declaring.odin:settings}}
```

The Save row is the same instance whether "Advanced options" is shown or
not. If Save was pressed or focused, it still is.

**For lists whose order can change, pass a key.** In a loop, the default
names rows by position: if the list is sorted differently, the second row is
still "the second row", now showing a different item, and the hover, focus
or animation of the old second row stays with it. Keyed by the item, an
instance follows its item instead:

```odin
{{#include ../../snippets/model/declaring.odin:keys}}
```

With a key, the key alone names the instance under its parent.
[`key_int`](../reference/niello.md#key_int) takes a number (an id, never a
loop index), [`key_str`](../reference/niello.md#key_str) a string and
[`key_ptr`](../reference/niello.md#key_ptr) an address. Keys are only needed
where order changes or items come and go in the middle; static UI needs none.

An instance declared under a different parent is a different instance:
moving a subtree to another container gives it fresh state.

## Components

A component is a procedure that declares UI. To keep each use of it a call
site of its own, it takes the caller's location and passes it on:

```odin
{{#include ../../snippets/model/declaring.odin:component}}
```

Without `loc`, every `tag` would be declared from the same line inside `tag`,
and the uses would be told apart only by count. That works until one use is
conditional. With `loc`, each `tag(...)` in your code is named by its own
line. The shipped [controls](../controls.md) all do this.

## Children and layout

A container arranges its children by its unit's `layout` (left to right, top
to bottom, or stacked), with its `padding` and `gap`, and each child sizes by
its own `size`. Instances declared outside any container are roots: each one
fills the window. [Layout](../layout.md) covers sizing, alignment, scrolling
and overflow.
