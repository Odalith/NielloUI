package niello

// debug.odin — debug tooling (TODO #18): the per-context frame
// snapshot, the §3.13 overflow report, and the highlight channel
// the debugger window (niello/debugui) is built on.
//
// The gate is the NIELLO_DEBUG build define
// (-define:NIELLO_DEBUG=true; see public.odin). In a build
// without it, the snapshot is never built, the emit hook is a
// no-op, and the entire public API below is absent — zero
// per-frame work, zero behavior change. The data types and the
// state fields are plain inert declarations in every build (a
// dynamic-array header per context); work and API are what the
// gate removes. In a debug build the snapshot costs one flat
// copy per frame per context — accepted on purpose (Malkj's
// rule: useful tooling beats perf in development; prod pays
// zero).
//
// The snapshot is a context's last completed frame, in
// declaration order (parents before children; Debug_Node.parent
// is an index into the same array). Reads are cross-context like
// the M4 read API: a peer's snapshot may be read while another
// context is bound, because on the one UI thread a peer sits at
// a frame boundary.

// The tint for the overflow overlay: translucent red fill, solid
// red border. Its job is to tell the dev what is overflowing
// (§3.13) — not to mimic any other toolkit's rendering of it.
DEBUG_OVERFLOW_COLOR :: Color{255, 60, 60, 56}

// Default highlight fill (translucent amber); the border drawn
// with it is the same hue at full alpha. debug_highlight takes
// a color for callers that want their own.
DEBUG_HIGHLIGHT_COLOR :: Color{255, 170, 40, 64}

Debug_Flag :: enum {
	Popup,   // an overlay root (§3.19)
	Culled,  // declared but culled: no instance, zero rect
	Scroll_X, // scrollable on X: overfl.x is a range, not a defect
	Scroll_Y,
	Clip,    // Overflow.Clip: the excess is cut by design
	Focused, // holds keyboard focus
	Hovered, // in the current hover chain
}
Debug_Flags :: bit_set[Debug_Flag]

Debug_Node :: struct {
	instance: Instance,
	parent:   int, // index into the same snapshot; -1 for roots
	unit:     Unit,
	rect:     Rect, // committed rect; zero when culled
	overfl:   Vec2, // pass-F overflow: children extend past bounds, px per axis
	spill:    Vec2, // intrinsic content exceeds the box, px per axis
	                 // (text truncation, crushed containers — cases
	                 // child-extent overflow cannot see)
	flags:    Debug_Flags,
}

Overflow_Axis :: enum u8 {
	X,
	Y,
}

// One §3.13 report entry: this instance's content does not fit
// it, by px on axis — the larger of child-extent overflow
// (pass F) and intrinsic spill (content vs box). Scrollable
// axes never appear (there, overfl is the scroll range, not a
// defect).
Overflow_Rec :: struct {
	instance: Instance,
	name:     string, // the unit's mint debug name
	axis:     Overflow_Axis,
	px:       f32,
}

// debug_snapshot_build refreshes the bound context's snapshot.
// Called from frame_end after the commit; a no-op in prod.
@(private)
debug_snapshot_build :: proc() {
	when NIELLO_DEBUG {
		clear(&g.debug_nodes)
		for i in 0 ..< len(g.nodes) {
			nd := &g.nodes[i]
			s := node_style(i)
			flags: Debug_Flags
			if nd.is_popup {
				flags += {.Popup}
			}
			if nd.culled {
				flags += {.Culled}
			}
			if scrollable_axis(s, X_AXIS) {
				flags += {.Scroll_X}
			}
			if scrollable_axis(s, Y_AXIS) {
				flags += {.Scroll_Y}
			}
			if s.overflow == .Clip {
				flags += {.Clip}
			}
			if g.focus_id == nd.identity && nd.identity != 0 {
				flags += {.Focused}
			}
			for id in g.hover_chain {
				if id == nd.identity {
					flags += {.Hovered}
					break
				}
			}
			r: Rect
			if rec, ok := g.instances[nd.identity]; ok {
				r = rec.rect
			}
			spill: Vec2
			if !nd.culled {
				spill = Vec2{
					max(0, g.lay[i].content.x - (g.lay[i].size.x - padding_sum(s, X_AXIS))),
					max(0, g.lay[i].content.y - (g.lay[i].size.y - padding_sum(s, Y_AXIS))),
				}
			}
			append(
				&g.debug_nodes,
				Debug_Node{
					instance = nd.identity,
					parent = nd.parent,
					unit = nd.unit,
					rect = r,
					overfl = g.lay[i].overfl,
					spill = spill,
					flags = flags,
				},
			)
		}
	}
}

// emit_debug_overlay appends the debug highlight / overflow tint
// for one node at emit time, right after the node's own style
// overlay — the same paint position a focus ring uses. Called
// from render.odin's emit_node; a no-op in prod.
@(private)
emit_debug_overlay :: proc(i: int, nd: ^Frame_Node, s: ^Style, r: Rect) {
	when NIELLO_DEBUG {
		if store.debug_hl_ctx == g && store.debug_hl_inst != 0 && store.debug_hl_inst == nd.identity {
			c := store.debug_hl_color
			append(
				&g.draw_cmds,
				Draw_Cmd{
					tag = .Overlay,
					bounds = r,
					color = c,
					border_width = 2,
					border_color = Color{c.r, c.g, c.b, 255},
				},
			)
		}
		if store.debug_ovf_on && store.debug_ovf_ctx == g {
			over := false
			for axis in 0 ..< 2 {
				spill := max(0, g.lay[i].content[axis] - (g.lay[i].size[axis] - padding_sum(s, axis)))
				if max(g.lay[i].overfl[axis], spill) > 0 && !scrollable_axis(s, axis) {
					over = true
					break
				}
			}
			if over {
				append(
					&g.draw_cmds,
					Draw_Cmd{
						tag = .Overlay,
						bounds = r,
						color = DEBUG_OVERFLOW_COLOR,
						border_width = 2,
						border_color = Color{255, 60, 60, 255},
					},
				)
			}
		}
	}
}

when NIELLO_DEBUG {

	// debug_contexts lists the live contexts in creation order —
	// the debugger's target switcher reads it. Borrowed; valid
	// until a context is created or destroyed.
	debug_contexts :: proc() -> []^Context {
		return store.contexts[:]
	}

	// debug_unit_name returns a unit's mint debug name ("" for an
	// unknown unit) — tree labels for the debugger window.
	debug_unit_name :: proc(u: Unit) -> string {
		if int(u) < 0 || int(u) >= len(store.units) {
			return ""
		}
		return store.units[u].name
	}

	// debug_tree returns ctx's last-frame snapshot. Borrowed;
	// valid until ctx's next frame_end. Nil-safe: a nil context
	// or a context that never framed yields an empty slice.
	debug_tree :: proc(ctx: ^Context) -> []Debug_Node {
		if ctx == nil {
			return nil
		}
		return ctx.debug_nodes[:]
	}

	// debug_style_in reads the effective style instance i had in
	// ctx's last frame (the node_style resolution: the resolved
	// eff style when one was computed, the unit's base style
	// otherwise). Cross-context like rect_in.
	debug_style_in :: proc(ctx: ^Context, i: Instance) -> (Style, bool) {
		if ctx == nil || i == 0 {
			return {}, false
		}
		for idx in 0 ..< len(ctx.nodes) {
			nd := &ctx.nodes[idx]
			if nd.identity == i {
				if nd.has_eff {
					return ctx.eff[idx], true
				}
				return store.units[nd.unit].style, true
			}
		}
		return {}, false
	}

	// debug_overflows derives the §3.13 report from ctx's
	// snapshot. The result lives in a store scratch buffer —
	// valid until the next debug_overflows call.
	debug_overflows :: proc(ctx: ^Context) -> []Overflow_Rec {
		clear(&store.debug_ovf_scratch)
		if ctx == nil {
			return nil
		}
		for dn in ctx.debug_nodes {
			if .Culled in dn.flags {
				continue
			}
			// One entry per (node, axis): how much content does
			// not fit, from whichever measure sees more of it —
			// child-extent overflow or intrinsic spill.
			px := max(dn.overfl.x, dn.spill.x)
			if px > 0 && .Scroll_X not_in dn.flags {
				append(
					&store.debug_ovf_scratch,
					Overflow_Rec{instance = dn.instance, name = store.units[dn.unit].name, axis = .X, px = px},
				)
			}
			px = max(dn.overfl.y, dn.spill.y)
			if px > 0 && .Scroll_Y not_in dn.flags {
				append(
					&store.debug_ovf_scratch,
					Overflow_Rec{instance = dn.instance, name = store.units[dn.unit].name, axis = .Y, px = px},
				)
			}
		}
		return store.debug_ovf_scratch[:]
	}

	// debug_highlight aims the highlight channel at one instance
	// in one context (Clay-style: the debugger sets it as tree
	// rows are hovered). color is the fill; the border is the
	// same hue at full alpha. debug_highlight(nil, 0) clears.
	debug_highlight :: proc(ctx: ^Context, i: Instance, color: Color = DEBUG_HIGHLIGHT_COLOR) {
		store.debug_hl_ctx = ctx
		store.debug_hl_inst = i
		store.debug_hl_color = color
	}

	// debug_show_overflows toggles the overflow tint overlay in
	// ctx: every node in its report set paints the tint at emit.
	debug_show_overflows :: proc(ctx: ^Context, on: bool) {
		store.debug_ovf_ctx = ctx
		store.debug_ovf_on = on
	}

	// debug_summon_hook is set by the debugger package
	// (niello/debugui's install): the SDL glue, in debug builds,
	// calls it with the context of the window that received the
	// summon key combo (F12). Nil = no debugger installed; the
	// combo then does nothing.
	debug_summon_hook: proc(ctx: ^Context)
}
