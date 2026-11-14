# Per-instance values: With

A unit's style is shared by every instance of it. What differs between
instances travels with the declaration, in a
[`With`](../reference/niello.md#With): the second argument of `show` and
`begin`.

```odin
{{#include ../../snippets/model/with.odin:tasks}}
```

Every row is `task_u`. Each has its own text, the selected one its own look,
and the finished ones are disabled. A value set in `With` wins over the
unit's; what `With` leaves unset comes from the unit.

## What a With carries

**Content.**
- `text`: the instance's text. It is copied, so a temporary string (a
  `fmt.tprintf` result) is fine. For large text your app keeps anyway,
  `text_no_copy` borrows it instead; the bytes must then stay unchanged until
  the frame is drawn.
- `text_spans`: rich text, spans of weight, slant or color over the text
  (see [Text](../text.md)).
- `image`: the instance's image (see the
  [reference](../reference/niello.md#Image)).

**Look and geometry.**
- `variant`: an overlay unit merged over the instance's style while it is
  set: a selected row, a toggle that is on. It is the per-instance
  counterpart of the state overlays (see [Units](units.md#state-overlays)).
- `size`: the instance's own size. It lets one unit serve parts whose
  geometry differs per instance, like a progress bar's fill:

```odin
{{#include ../../snippets/model/with.odin:progress}}
```

**Behavior.**
- `disabled`: no interaction and no focus, for the instance and its children;
  the unit's disabled overlay applies.
- `focusable`, `focus_ring`: per-instance versions of the unit's focus
  settings (see [Input and focus](../input.md)).
- `anchored`: the instance sits over its parent rather than in its flow, like
  a scrollbar or a badge (see [Layout](../layout.md)).
- `static_values`: a promise that the text, spans and image never change
  while the instance lives, so the engine stops comparing them.

**Accessibility.** `role`, `label`, `description`, `value` and `a11y_flags`
describe the instance to assistive technology. See
[Accessibility](../accessibility.md).

## Values, not units

Reach for `With` before minting another unit. A unit per row, or a unit per
"selected" state, would multiply styles that are really one style with a
different value. The rule of thumb: what every instance shares is the unit;
what one instance shows or is, is its `With`; what a family of units shares
and changes together is a [group](groups.md).
