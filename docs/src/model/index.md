# The model

NielloUI has a small number of ideas, and the rest of the framework is built
from them. This chapter covers each in turn; this page is the map.

**Units own styles.** A [unit](units.md) is a retained object you create once
with `mint`: a panel, a label, a button's box. It holds a complete style
(layout, sizing, colors, text). Changing a unit's style changes everything
declared from it.

**The UI is declared every frame.** Your `declare` procedure
[describes the whole UI](declaring.md) each frame with `show` (a leaf) and
`begin` (a container), straight from your app's state. There is no tree to
build, update or keep in sync. Each occurrence of a unit becomes an
*instance*, and an instance keeps its identity from frame to frame, so its
position, hover state and scroll offset follow it.

**Instances carry their own values.** What differs between instances of one
unit (their text, an image, a size, a selected look, accessibility
semantics) is passed [with the declaration](with.md), in a `With`. Everything
else comes from the unit.

**Interaction is asked for, where it is declared.**
[`clicked`, `hovered`, `pressed`](interaction.md) and the drag and focus
queries are ordinary calls in `declare`, next to the code that shows the
control. No callbacks, no event handlers, no state copied out of a closure.

**Groups broadcast to roles.** A [group](groups.md) is a list of units that
play a role (surface, ink, accent…). One call writes a value into every
member, so a theme switch, a text-size change or a density change is a
handful of calls, however many units the app has.

**The engine works out what changed.** You never notify it.
[Each frame](frame.md) it compares the declaration and the units with the
last frame, lays out and repaints only what changed, and sleeps when nothing
did.

## Compared with other approaches

If you know immediate-mode UI (Dear ImGui, Clay), declaring will feel
familiar: the UI is code that runs every frame, and an `if` decides whether
something exists. The difference is where style lives. Here it is retained,
in units, not repeated in every call, and the engine diffs and repaints
instead of redrawing everything.

If you know retained frameworks (Qt, WPF, Avalonia), units will feel
familiar, and groups play the part of styles and resources. The difference is
that there is no widget tree to mutate and no binding: your state is plain
data, and the UI is a function of it.

## Reading on

The pages build on each other:

1. [Units and mint](units.md)
2. [Declaring: show, begin, identity](declaring.md)
3. [Per-instance values: With](with.md)
4. [Interaction: polling](interaction.md)
5. [Groups and roles](groups.md)
6. [The frame pipeline](frame.md)

Every example in this chapter is compiled, and the behavior each page
describes is checked by a test, when the documentation is built.
