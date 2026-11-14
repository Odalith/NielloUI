# Groups and roles

A **group** is an address book of units: a list of units, and for each the
fields it is listed for. Writing a value to a group writes it into every
member. That is how one call re-themes an app, resizes its text or tightens
its spacing, however many units it has.

Groups carry no styles of their own and cascade nothing. They only find units
for a broadcast.

## Roles

Organise groups by **role**: what a value means in the design, not which
control uses it. "Surface", "ink" and "action" are roles; "button
background" is not. A theme is then a value per role:

```odin
{{#include ../../snippets/model/groups.odin:theme}}
```

## Joining

A unit joins the roles it plays when it is minted, for the field it plays
each one with (`group_masks`), or for every field (`groups`):

```odin
{{#include ../../snippets/model/groups.odin:join}}
```

The action button joins two roles: `action` for its fill and `surface` for
its text, which is drawn in the surface color. The page joins `surface` for
its fill only, so a broadcast of a surface *text* color passes it by.

[`group_add`](../reference/niello.md#group_add) adds units to a group later,
for every field or for some.
[`group_new`](../reference/niello.md#group_new) takes a name, for
debugging.

## Broadcasting

[`group_set`](../reference/niello.md#group_set) writes one field into every
member that joined for it:

```odin
{{#include ../../snippets/model/groups.odin:apply}}
```

With `ms` above zero each member glides from its current value to the new
one; frames keep coming until every glide lands.
[`group_apply`](../reference/niello.md#group_apply) broadcasts every field of
a `Style_Decl` at once, and
[`group_tween`](../reference/niello.md#group_tween) glides each member toward
another unit's style.

A broadcast writes into each unit's own style, exactly as `set` would. There
is no layer of theme values kept on the side: after the broadcast, the value
is simply the unit's.

## Pinning

Delete, above, is an action, but always red. It joins `action` like every
other action, and [`pin`](../reference/niello.md#pin) keeps broadcasts from
writing its color. Its text color still follows the theme.

Pin rarely, and only where the reason is obvious from the unit itself. If you
find yourself pinning often, the group is drawn wrong: split it into two
roles instead.

## Joining applies nothing

Joining a group only lists a unit for later broadcasts. It does not give the
unit the group's current value, because a group has none. A unit gets its
values from its base and its declaration at mint, and from writes after that:

```odin
{{#include ../../snippets/model/groups.odin:later}}
```

After a switch to the dark theme, `dialog_u` is dark: it was minted from
`page_u`, which the broadcast reached. `note_u` keeps the light ink its
declaration gave it until the next broadcast to `ink`. So mint units that
appear later from bases that are already themed, and they match without
waiting for a broadcast.

Variants do not inherit memberships either. A variant joins the groups its
own declaration names, as `delete_u` does above.

## The shipped roles

[`niello/controls`](../reference/controls.md) is built this way: its parts
join the roles in [`controls.groups`](../reference/controls.md#groups), and
[`apply_theme`](../reference/controls.md#apply_theme),
[`apply_type`](../reference/controls.md#apply_type) and
[`apply_spacing`](../reference/controls.md#apply_spacing) broadcast through
them. Your own units can join the same roles, and then one call re-themes the
controls and your app together. See [Controls](../controls.md).
