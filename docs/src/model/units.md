# Units and mint

A **unit** is a retained object that owns a style. You create units once,
usually at startup, and declare them every frame. A
[`Unit`](../reference/niello.md#Unit) is a handle: copy it, store it in a
struct or a package variable, pass it around.

## Minting

[`mint`](../reference/niello.md#mint) creates a unit into a variable, from a
base and a declaration of the fields to set:

```odin
{{#include ../../snippets/model/units.odin:mint}}
```

The declaration is a [`Style_Decl`](../reference/niello.md#Style_Decl). Its
fields are all optional (`Maybe`): only the ones you write count, so a zero
(`padding = niello.pad(0)`, `opacity = 0`) is a value like any other, not
"unset". Fields you leave out come from the base.

With `niello.NO_UNIT` as the base, a unit starts from the default style: no
fill, black 16 DIP text in the platform's default font, sized to its content,
children laid out left to right from the top-left corner.

## Variants

With another unit as the base, the new unit is a **variant**: it starts as a
copy of the base's current style, its state overlays and its focus behavior,
and the declaration is applied on top. Above, `title` is `body` in a larger,
bold face.

A variant is a copy, not a link. Changing `body` later does not change
`title`. That is deliberate: what a unit looks like is decided by what was
written into it, not by a chain of parents you would have to trace. When you
do want a base's change to reach its variants, ask for it with
[`propagate`](../reference/niello.md#propagate):

```odin
{{#include ../../snippets/model/units.odin:propagate}}
```

`propagate` pushes the fields you name to every unit minted from the base,
and to theirs. A field a variant set itself (`title`'s `font_size`) is its
own, and keeps its value.

Group memberships are not copied to variants; see
[Groups and roles](groups.md).

## Changing a unit

A unit's style changes through a few calls, and only through them:

```odin
{{#include ../../snippets/model/units.odin:set}}
```

- [`set`](../reference/niello.md#set) writes one field, named by a
  [`Field`](../reference/niello.md#Field). The value must have the field's
  type (`f32(18)` for a font size).
- [`set_many`](../reference/niello.md#set_many) writes every field a
  `Style_Decl` sets.
- [`style_of`](../reference/niello.md#style_of) reads a copy of the current
  style.

Every instance of the unit changes from the next frame on. Setting a field to
the value it already has does nothing at all, not even a repaint. Broadcasts
to many units at once are [groups](groups.md); gliding from one style to
another (`tween`), editing a style in bulk (`edit`) and one-off pulses
(`transient`) are in [Animation](../animation.md).

## State overlays

A control looks different while it is hovered, pressed, focused or disabled.
Each of those looks is a unit too, an **overlay**, named on the base unit:

```odin
{{#include ../../snippets/model/units.odin:overlays}}
```

An overlay sets only the fields that change. While an instance is hovered,
the engine merges `button_hover`'s fields over `button`'s style; when the
pointer leaves, the merge stops. You never set "hovered" colors yourself, so
a control can never get stuck looking hovered.

Overlays combine in a fixed order, weakest first: the unit's own style, then
the instance's variant (see [With](with.md)), then focus, hover, press and
disabled. A disabled instance looks disabled whatever else is going on.

The keyboard focus ring is not an overlay: the engine draws it for whatever
holds keyboard focus, from one app-wide setting
([`set_focus_ring`](../reference/niello.md#set_focus_ring)).

## Freeing units

A unit lives until [`unmint`](../reference/niello.md#unmint) frees it.
`unmint` also removes every reference the engine holds to it: group
memberships, other units' overlays, animations in flight. Stop declaring a
unit before you free it. A freed handle is never reused, so
[`unit_live`](../reference/niello.md#unit_live) can tell a stale handle from a
live one.

Most apps never unmint: their units live as long as the app.
[`shutdown`](../reference/niello.md#shutdown), after the last frame, releases
everything at once.

## Names

`mint` records the expression you passed (`body`, `parts.button.root`) as the
unit's name, and where it was minted. The [debugger](../debugger.md) shows
both, so you never name units by hand.
