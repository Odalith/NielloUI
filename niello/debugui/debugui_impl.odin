package debugui

// debugui_impl.odin — the debugger itself. Every declaration is
// inside `when niello.NIELLO_DEBUG`: in a prod build this file
// contributes nothing (its imports included — Odin only errors
// on unused imports when the declarations using them survive).
// debugui.odin holds the always-compiled entry points.

import "core:fmt"
import niello ".."
import niello_sdl "../sdl"

when niello.NIELLO_DEBUG {

// ---- state ------------------------------------------------------

own_ctx: ^niello.Context
win_id: niello_sdl.Window_Id
is_open: bool
installed: bool
target: ^niello.Context
selected: niello.Instance
hl_inst: niello.Instance // what we currently highlight, if any
show_ovf: bool

depths: [dynamic]int

// ---- units (fixed neutral look) ---------------------------------

root_u, bar_u, mid_u, title_u, chip_u, chip_on_u: niello.Unit
tree_scroll_u, tree_col_u, row_u, row_hover_u: niello.Unit
label_u, alert_u, info_u, line_u, ovf_u: niello.Unit

mint_units :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.percent(1), niello.percent(1)},
		color = niello.Color{23, 23, 27, 255},
		padding = [4]u16{10, 10, 10, 10}, gap = 8,
	})
	niello.mint(&bar_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size = niello.Size{niello.percent(1), niello.fixed(30)},
		gap = 6,
	})
	niello.mint(&mid_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size = niello.Size{niello.percent(1), niello.grow(1)},
		gap = 8,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 14, font_color = niello.Color{232, 230, 224, 255}})
	niello.mint(&chip_u, niello.NO_UNIT, {
		size = niello.Size{niello.fit(), niello.fixed(26)},
		color = niello.Color{44, 44, 54, 255}, corner_radius = 5,
		padding = [4]u16{3, 8, 3, 8},
		font_size = 12, font_color = niello.Color{200, 200, 208, 255},
	})
	niello.mint(&chip_on_u, niello.NO_UNIT, {
		size = niello.Size{niello.fit(), niello.fixed(26)},
		color = niello.Color{70, 92, 140, 255}, corner_radius = 5,
		padding = [4]u16{3, 8, 3, 8},
		font_size = 12, font_color = niello.Color{238, 240, 246, 255},
	})
	niello.mint(&tree_scroll_u, niello.NO_UNIT, {
		size = niello.Size{niello.percent(0.52), niello.grow(1)},
		scroll = niello.Scroll.Vertical,
		color = niello.Color{29, 29, 34, 255}, corner_radius = 6,
	})
	niello.mint(&tree_col_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.percent(1), niello.fit()},
		padding = [4]u16{5, 5, 5, 5}, gap = 1,
	})
	niello.mint(&row_hover_u, niello.NO_UNIT, {color = niello.Color{52, 52, 64, 255}})
	niello.mint(&row_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size = niello.Size{niello.percent(1), niello.fixed(20)},
		gap = 8, corner_radius = 3,
		hover = row_hover_u,
	})
	niello.mint(&label_u, niello.NO_UNIT, {font_size = 13, font_color = niello.Color{206, 204, 198, 255}})
	niello.mint(&alert_u, niello.NO_UNIT, {font_size = 12, font_color = niello.Color{255, 110, 100, 255}})
	niello.mint(&info_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.grow(1), niello.grow(1)},
		color = niello.Color{29, 29, 34, 255}, corner_radius = 6,
		padding = [4]u16{8, 8, 8, 8}, gap = 3,
	})
	niello.mint(&line_u, niello.NO_UNIT, {font_size = 12, font_color = niello.Color{196, 194, 190, 255}})
	niello.mint(&ovf_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.percent(1), niello.fixed(124)},
		color = niello.Color{29, 29, 34, 255}, corner_radius = 6,
		padding = [4]u16{7, 8, 7, 8}, gap = 2,
	})
}

// ---- entry points -----------------------------------------------

// install_impl is install()'s debug-build body.
install_impl :: proc() {
	if installed {
		return
	}
	installed = true
	mint_units()
	niello.debug_summon_hook = summon
}

summon :: proc(ctx: ^niello.Context) {
	if ctx == nil || ctx == own_ctx {
		return // F12 inside the debugger itself does nothing
	}
	target = ctx
	if show_ovf {
		niello.debug_show_overflows(ctx, true)
	}
	if !is_open {
		if own_ctx == nil {
			own_ctx = niello.context_create()
		}
		win_id = niello_sdl.open_window(own_ctx, {title = "Niello Debugger", width = 860, height = 620}, declare)
		is_open = true
	} else {
		niello.context_wake(own_ctx)
	}
}

// ---- helpers ------------------------------------------------------

target_alive :: proc() -> bool {
	if target == nil {
		return false
	}
	for c in niello.debug_contexts() {
		if c == target {
			return true
		}
	}
	return false
}

find_node :: proc(tree: []niello.Debug_Node, inst: niello.Instance) -> (niello.Debug_Node, bool) {
	for dn in tree {
		if dn.instance == inst {
			return dn, true
		}
	}
	return {}, false
}

overflow_of :: proc(recs: []niello.Overflow_Rec, inst: niello.Instance) -> (niello.Overflow_Rec, bool) {
	for r in recs {
		if r.instance == inst {
			return r, true
		}
	}
	return {}, false
}

// ---- the window ---------------------------------------------------

declare :: proc() {
	// Sustain our own cadence while open: a debug window that
	// only refreshes when poked is useless, and the cost is
	// dev-only by definition.
	niello.context_wake(own_ctx)

	if !target_alive() {
		target = nil
		selected = 0
	}

	hovered_any := false

	if _, open0 := niello.begin(root_u); open0 {
		// Target bar.
		if _, open1 := niello.begin(bar_u); open1 {
			niello.show(title_u, 0, {text = "Target:"})
			for c, ci in niello.debug_contexts() {
				buf: [64]u8
				txt: string
				if c == own_ctx {
					txt = "debugger"
				} else {
					txt = fmt.bprintf(buf[:], "window %d · %d nodes", ci, len(niello.debug_tree(c)))
				}
				chip := niello.show(chip_on_u if c == target else chip_u, niello.key_int(ci + 1), {text = txt})
				if niello.clicked(chip) {
					target = c
					selected = 0
					if show_ovf {
						niello.debug_show_overflows(c, true)
					}
				}
			}
			tog := niello.show(chip_on_u if show_ovf else chip_u, niello.key_int(900), {text = "overflow tint"})
			if niello.clicked(tog) {
				show_ovf = !show_ovf
				if target != nil {
					niello.debug_show_overflows(target, show_ovf)
				}
			}
		}

		tree := niello.debug_tree(target)
		recs := niello.debug_overflows(target)

		// Depths: parents precede children, one pass.
		resize(&depths, len(tree))
		for dn, i in tree {
			depths[i] = 0 if dn.parent < 0 else depths[dn.parent] + 1
		}

		if _, open2 := niello.begin(mid_u); open2 {
			// Tree.
			if _, open3 := niello.begin(tree_scroll_u); open3 {
				if _, open4 := niello.begin(tree_col_u); open4 {
					if len(tree) == 0 {
						niello.show(line_u, 0, {text = "no target — F12 in any window"})
					}
					for dn, i in tree {
						row: niello.Instance
						if r, open5 := niello.begin(row_u, niello.key_int(i + 1)); open5 {
							row = r
							buf: [128]u8
							off := 0
							for _ in 0 ..< depths[i] * 2 {
								off += len(fmt.bprintf(buf[off:], "  "))
							}
							name := niello.debug_unit_name(dn.unit)
							if name == "" {
								name = "unit"
							}
							off += len(fmt.bprintf(buf[off:], "%s #%d", name, int(dn.unit)))
							niello.show(label_u, 0, {text = string(buf[:off])})
							if rec, bad := overflow_of(recs, dn.instance); bad {
								niello.show(alert_u, 0, {text = fmt.bprintf(buf[:], "%v %.0fpx", rec.axis, rec.px)})
							} else if .Culled in dn.flags {
								niello.show(line_u, 0, {text = "culled"})
							}
						}
						if niello.hovered(row) {
							hovered_any = true
							if hl_inst != dn.instance {
								hl_inst = dn.instance
								niello.debug_highlight(target, dn.instance)
							}
						}
						if niello.clicked(row) {
							selected = dn.instance
						}
					}
				}
			}

			// Selection info.
			if _, open6 := niello.begin(info_u); open6 {
				declare_info(tree)
			}
		}

		// Overflow list (the §3.13 report, presented).
		if _, open7 := niello.begin(ovf_u); open7 {
			niello.show(title_u, 0, {text = "Overflows"})
			if target == nil || len(recs) == 0 {
				niello.show(line_u, 0, {text = "none"})
			}
			shown := 0
			for rec in recs {
				if shown >= 4 {
					buf: [48]u8
					niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "+ %d more", len(recs) - shown)})
					break
				}
				shown += 1
				row: niello.Instance
				if r, open8 := niello.begin(row_u, niello.key_int(10000 + shown)); open8 {
					row = r
					buf: [96]u8
					niello.show(alert_u, 0, {text = fmt.bprintf(buf[:], "%s · %v · %.0f px", rec.name, rec.axis, rec.px)})
				}
				if niello.hovered(row) {
					hovered_any = true
					if hl_inst != rec.instance {
						hl_inst = rec.instance
						niello.debug_highlight(target, rec.instance)
					}
				}
				if niello.clicked(row) {
					selected = rec.instance
				}
			}
		}
	}

	// Nothing hovered this frame: drop the highlight we own.
	if !hovered_any && hl_inst != 0 {
		hl_inst = 0
		niello.debug_highlight(nil, 0)
	}
}

declare_info :: proc(tree: []niello.Debug_Node) {
	dn, ok := find_node(tree, selected)
	if !ok {
		niello.show(line_u, 0, {text = "click a tree row to inspect"})
		return
	}
	buf: [160]u8
	name := niello.debug_unit_name(dn.unit)
	if name == "" {
		name = "unit"
	}
	niello.show(title_u, 0, {text = fmt.bprintf(buf[:], "%s #%d", name, int(dn.unit))})
	niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "instance %d", int(dn.instance))})
	niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "rect (%.0f, %.0f)  %.0f x %.0f", dn.rect.pos.x, dn.rect.pos.y, dn.rect.size.x, dn.rect.size.y)})
	niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "overfl (%.0f, %.0f)   spill (%.0f, %.0f)", dn.overfl.x, dn.overfl.y, dn.spill.x, dn.spill.y)})
	{
		off := 0
		b: [128]u8
		off += len(fmt.bprintf(b[off:], "flags:"))
		if .Popup in dn.flags { off += len(fmt.bprintf(b[off:], " popup")) }
		if .Culled in dn.flags { off += len(fmt.bprintf(b[off:], " culled")) }
		if .Scroll_X in dn.flags { off += len(fmt.bprintf(b[off:], " scroll-x")) }
		if .Scroll_Y in dn.flags { off += len(fmt.bprintf(b[off:], " scroll-y")) }
		if .Clip in dn.flags { off += len(fmt.bprintf(b[off:], " clip")) }
		if .Focused in dn.flags { off += len(fmt.bprintf(b[off:], " focused")) }
		if .Hovered in dn.flags { off += len(fmt.bprintf(b[off:], " hovered")) }
		if off == 6 { off += len(fmt.bprintf(b[off:], " —")) }
		niello.show(line_u, 0, {text = string(b[:off])})
	}
	if s, sok := niello.debug_style_in(target, dn.instance); sok {
		niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "layout %v · scroll %v · overflow %v", s.layout, s.scroll, s.overflow)})
		niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "color %v · radius %v · border %v", s.color, s.corner_radius, s.border_width)})
		niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "font %.0f · weight %v · slant %v · color %v", s.font_size, s.font_weight, s.font_slant, s.font_color)})
		if s.text != "" {
			t := s.text
			if len(t) > 40 {
				t = t[:40]
			}
			niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "text \"%s\"", t)})
		}
		niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "opacity %v · gap %v · padding %v", s.opacity, s.gap, s.padding)})
	}
}

}
