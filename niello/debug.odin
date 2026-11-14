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
// copy per frame per context — accepted on purpose (useful
// tooling beats perf in development; prod pays zero).
//
// The snapshot is a context's last completed frame, in
// declaration order (parents before children; Debug_Node.parent
// is an index into the same array). Reads are cross-context like
// the M4 read API: a peer's snapshot may be read while another
// context is bound, because on the one UI thread a peer sits at
// a frame boundary.

// DEBUG_OVERFLOW_COLOR tints instances in the overflow report (debug builds):
// a translucent red fill with a solid red border.
DEBUG_OVERFLOW_COLOR :: Color{255, 60, 60, 56}

// DEBUG_HIGHLIGHT_COLOR is debug_highlight's default fill, a translucent
// amber; the border drawn with it is the same hue at full alpha.
DEBUG_HIGHLIGHT_COLOR :: Color{255, 170, 40, 64}

// Debug_Flag is a fact about a node in the debug snapshot.
Debug_Flag :: enum {
	Popup,   // a popup root (begin_popup)
	Culled,  // declared but not presented (a popup not shown): no instance, zero rect
	Scroll_X, // scrollable on X: overfl.x is a range, not a defect
	Scroll_Y,
	Clip,    // Overflow.Clip: the excess is cut by design
	Focused, // holds keyboard focus
	Hovered, // in the current hover chain
}
// Debug_Flags is a set of Debug_Flag.
Debug_Flags :: bit_set[Debug_Flag]

// Debug_Node is one node of a context's debug snapshot (debug_tree, debug
// builds): what the debugger window shows.
Debug_Node :: struct {
	instance: Instance,
	parent:   int, // index into the same snapshot; -1 for roots
	unit:     Unit,
	rect:     Rect, // committed rect; zero when culled
	overfl:   Vec2, // how far children extend past its bounds, per axis
	spill:    Vec2, // how far its own content exceeds its box, per axis
	                // (truncated text, a container squeezed below its
	                // content)
	flags:    Debug_Flags,
	with:     Debug_With, // the With overrides this instance was
	                      // declared with
}

// Overflow_Axis is the axis of an overflow report entry.
Overflow_Axis :: enum u8 {
	X,
	Y,
}

// Overflow_Rec is one entry of the overflow report (debug_overflows, debug
// builds): an instance whose content does not fit it, by px DIP on axis.
// A scrolling axis never appears: there the excess is the scroll range.
Overflow_Rec :: struct {
	instance: Instance,
	name:     string, // the unit's mint debug name
	axis:     Overflow_Axis,
	px:       f32,
}

// Debug_With_Flag is one With value an instance was declared with, as the
// debug snapshot records it (the debugger's WITH section).
Debug_With_Flag :: enum {
	Text,          // With.text (its value is recorded)
	Text_Borrowed, // With.text_no_copy (recorded as set; its bytes are
	               // the app's, so no value)
	Spans,
	Disabled,
	Anchored,
	Focusable,
	Variant,
	Label,
}
// Debug_With_Flags is a set of Debug_With_Flag.
Debug_With_Flags :: bit_set[Debug_With_Flag]

// Debug_With is the With values an instance was declared with, as the
// debug snapshot records them (present says which were set).
Debug_With :: struct {
	present:   Debug_With_Flags,
	text:      string, // when .Text
	spans:     int, // span count when .Spans
	focusable: bool, // value when .Focusable
	variant:   Unit, // value when .Variant
	label:     string, // value when .Label
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
			dw: Debug_With
			{
				w := node_with(nd) // every node keeps its With in debug builds
				if w.text != nil {
					dw.present += {.Text}
					dw.text = nd.text // declare's arena copy
				} else if w.text_no_copy != nil {
					dw.present += {.Text_Borrowed}
				}
				if w.text_spans != nil {
					dw.present += {.Spans}
					dw.spans = len(nd.spans)
				}
				if w.disabled {
					dw.present += {.Disabled}
				}
				if w.anchored {
					dw.present += {.Anchored}
				}
				if fv, ok := w.focusable.?; ok {
					dw.present += {.Focusable}
					dw.focusable = fv
				}
				if w.variant != 0 {
					dw.present += {.Variant}
					dw.variant = w.variant
				}
				if lb, ok := w.label.?; ok {
					dw.present += {.Label}
					dw.label = lb
				}
			}
			spill: Vec2
			if !nd.culled {
				spill = Vec2{
					max(0, g.lay[i].content.x - g.lay[i].size.x),
					max(0, g.lay[i].content.y - g.lay[i].size.y),
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
					with = dw,
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
				spill := max(0, g.lay[i].content[axis] - g.lay[i].size[axis])
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

	// debug_contexts lists the live contexts in creation order (the
	// debugger's window switcher reads it). The slice is borrowed: valid
	// until a context is created or destroyed.
	debug_contexts :: proc() -> []^Context {
		return store.contexts[:]
	}

	// debug_unit_name returns the name a unit was minted with (mint's name
	// parameter; "" for an unknown unit). The debugger labels tree rows
	// with it.
	debug_unit_name :: proc(u: Unit) -> string {
		if !unit_live(u) {
			return ""
		}
		return store.units[unit_index(u)].name
	}

	// debug_unit_loc returns where a unit was minted: the file and line of
	// the mint call. The debugger shows it for the selected node's unit.
	debug_unit_loc :: proc(u: Unit) -> (file: string, line: i32, ok: bool) {
		if !unit_live(u) {
			return "", 0, false
		}
		loc := store.units[unit_index(u)].loc
		return loc.file_path, loc.line, true
	}

	// debug_tree returns ctx's node tree as of its last frame. The slice is
	// borrowed: valid until ctx's next frame_end. A nil context, or one
	// that has not run a frame, gives an empty slice.
	debug_tree :: proc(ctx: ^Context) -> []Debug_Node {
		if ctx == nil {
			return nil
		}
		return ctx.debug_nodes[:]
	}

	// debug_style_in returns the effective style instance i had in ctx's
	// last frame: its unit's style with its variant, the active state
	// overlays, a running transient and With.size applied. Like rect_in,
	// it reads any context.
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
				return store.units[unit_index(nd.unit)].style, true
			}
		}
		return {}, false
	}

	// debug_overflows returns ctx's overflow report as of its last frame:
	// every instance whose content does not fit it (Overflow_Rec). The
	// slice is valid until the next debug_overflows call.
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
					Overflow_Rec{instance = dn.instance, name = store.units[unit_index(dn.unit)].name, axis = .X, px = px},
				)
			}
			px = max(dn.overfl.y, dn.spill.y)
			if px > 0 && .Scroll_Y not_in dn.flags {
				append(
					&store.debug_ovf_scratch,
					Overflow_Rec{instance = dn.instance, name = store.units[unit_index(dn.unit)].name, axis = .Y, px = px},
				)
			}
		}
		return store.debug_ovf_scratch[:]
	}

	// debug_highlight highlights one instance in one context (the debugger
	// does it as tree rows are hovered); one highlight exists at a time.
	// color is the fill; the border is the same hue at full alpha.
	// debug_highlight(nil, 0) clears it.
	debug_highlight :: proc(ctx: ^Context, i: Instance, color: Color = DEBUG_HIGHLIGHT_COLOR) {
		store.debug_hl_ctx = ctx
		store.debug_hl_inst = i
		store.debug_hl_color = color
	}

	// debug_show_overflows turns the overflow tint on or off in ctx: every
	// instance in its overflow report is painted with
	// DEBUG_OVERFLOW_COLOR.
	debug_show_overflows :: proc(ctx: ^Context, on: bool) {
		store.debug_ovf_ctx = ctx
		store.debug_ovf_on = on
	}

	// debug_summon_hook is how a host opens the debugger: niello/debugui's
	// install sets it, and niello/sdl calls it with the context of the
	// window that received F12. Nil, no debugger is installed and F12
	// does nothing.
	debug_summon_hook: proc(ctx: ^Context)
}
