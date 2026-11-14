#+private
package debugui

// debugui_impl.odin — the debugger itself. Every declaration is
// inside `when niello.NIELLO_DEBUG`: in a prod build this file
// contributes nothing (its imports included — Odin only errors
// on unused imports when the declarations using them survive).
// debugui.odin holds the always-compiled entry points.
//
// Targeting is by WINDOW (the glue's window_list), never by
// context and never itself: a closed window's context can
// outlive it in the engine registry, and a debugger aimed at
// its own half-built frame is a freeze. When no other window
// remains, the debugger closes itself — otherwise it would
// keep the app alive after the user killed the main window.
//
// Every change the debugger makes to a target (highlight,
// overflow tint) is followed by context_wake(target): change
// detection is per-context, so an idle target would otherwise
// never repaint the update — the same lesson the multi-window
// inspector demo taught.

import "core:fmt"
import niello ".."
import niello_sdl "../sdl"

when niello.NIELLO_DEBUG {

	// ---- state --------------------------------------------------

	own_ctx: ^niello.Context
	win_id: niello_sdl.Window_Id
	is_open: bool
	installed: bool
	target: ^niello.Context
	selected: niello.Instance
	hl_inst: niello.Instance // what we currently highlight, if any
	show_ovf: bool

	depths: [dynamic]int

	// ---- units (fixed neutral look) -----------------------------

	root_u, bar_u, mid_u, title_u, section_u, chip_u, chip_on_u, chip_label_u, chip_label_on_u: niello.Unit
	panel_u, tree_scroll_u, tree_col_u: niello.Unit
	row_u, row_hover_u, row_sel_u, row_sel_hover_u: niello.Unit
	label_u, alert_u, info_u, krow_u, key_u, val_u, ovf_u, ovf_head_u: niello.Unit

	mint_units :: proc() {
		niello.mint(&root_u, niello.NO_UNIT, {
			layout = .Top_To_Bottom,
			size = niello.size(niello.percent(1), niello.percent(1)),
			color = niello.rgb(0x17171b),
			padding = niello.pad(10), gap = 6,
		})
		niello.mint(&section_u, niello.NO_UNIT, {
			font_size = 11, font_weight = .Bold,
			font_color = niello.rgb(0x9498a8),
		})
		niello.mint(&bar_u, niello.NO_UNIT, {
			layout = .Left_To_Right,
			size = niello.size(niello.percent(1), niello.fixed(28)),
			gap = 6,
		})
		niello.mint(&mid_u, niello.NO_UNIT, {
			layout = .Left_To_Right,
			size = niello.size(niello.percent(1), niello.grow()),
			gap = 8,
		})
		niello.mint(&title_u, niello.NO_UNIT, {font_size = 14, font_color = niello.rgb(0xe8e6e0)})
		// Chips are containers with a centered label child:
		// leaf text has no vertical centering, so a text-leaf
		// chip can never center its caption. Padding is
		// {left, top, right, bottom}.
		niello.mint(&chip_u, niello.NO_UNIT, {
			size = niello.size(niello.fit(), niello.fixed(26)),
			color = niello.rgb(0x2c2c36), corner_radius = 5,
			padding = niello.pad_xy(8, 3),
			align = niello.CENTER,
		})
		niello.mint(&chip_on_u, niello.NO_UNIT, {
			size = niello.size(niello.fit(), niello.fixed(26)),
			color = niello.rgb(0x465c8c), corner_radius = 5,
			padding = niello.pad_xy(8, 3),
			align = niello.CENTER,
		})
		niello.mint(&chip_label_u, niello.NO_UNIT, {font_size = 12, font_color = niello.rgb(0xc8c8d0)})
		niello.mint(&chip_label_on_u, niello.NO_UNIT, {font_size = 12, font_color = niello.rgb(0xeef0f6)})
		niello.mint(&panel_u, niello.NO_UNIT, {
			layout = .Top_To_Bottom,
			size = niello.size(niello.percent(0.52), niello.grow()),
			color = niello.rgb(0x1d1d22), corner_radius = 6,
			padding = niello.pad_xy(8, 7), gap = 4,
		})
		niello.mint(&tree_scroll_u, niello.NO_UNIT, {
			size = niello.size(niello.percent(1), niello.grow()),
			scroll = niello.Scroll.Vertical,
		})
		niello.mint(&tree_col_u, niello.NO_UNIT, {
			layout = .Top_To_Bottom,
			size = niello.size(niello.percent(1), niello.fit()),
			gap = 1,
		})
		niello.mint(&row_hover_u, niello.NO_UNIT, {color = niello.rgb(0x343440)})
		niello.mint(&row_u, niello.NO_UNIT, {
			layout = .Left_To_Right,
			size = niello.size(niello.percent(1), niello.fixed(20)),
			gap = 8, corner_radius = 3,
			hover = row_hover_u,
		})
		niello.mint(&row_sel_hover_u, niello.NO_UNIT, {color = niello.rgb(0x546a96)})
		niello.mint(&row_sel_u, niello.NO_UNIT, {
			layout = .Left_To_Right,
			size = niello.size(niello.percent(1), niello.fixed(20)),
			gap = 8, corner_radius = 3,
			color = niello.rgb(0x3e507a),
			hover = row_sel_hover_u,
		})
		niello.mint(&label_u, niello.NO_UNIT, {font_size = 13, font_color = niello.rgb(0xceccc6)})
		niello.mint(&alert_u, niello.NO_UNIT, {font_size = 12, font_color = niello.rgb(0xff6e64)})
		niello.mint(&info_u, niello.NO_UNIT, {
			layout = .Top_To_Bottom,
			size = niello.size(niello.grow(), niello.grow()),
			color = niello.rgb(0x1d1d22), corner_radius = 6,
			padding = niello.pad(8), gap = 3,
		})
		niello.mint(&krow_u, niello.NO_UNIT, {
			layout = .Left_To_Right,
			size = niello.size(niello.percent(1), niello.fixed(18)),
			gap = 8,
		})
		niello.mint(&key_u, niello.NO_UNIT, {
			size = niello.size(niello.fixed(78), niello.fixed(18)),
			font_size = 12, font_color = niello.rgb(0x8a8c98),
		})
		niello.mint(&val_u, niello.NO_UNIT, {font_size = 12, font_color = niello.rgb(0xd0cec8)})
		niello.mint(&ovf_u, niello.NO_UNIT, {
			layout = .Top_To_Bottom,
			size = niello.size(niello.percent(1), niello.fixed(132)),
			color = niello.rgb(0x1d1d22), corner_radius = 6,
			padding = niello.pad_xy(8, 7), gap = 2,
		})
		niello.mint(&ovf_head_u, niello.NO_UNIT, {
			layout = .Left_To_Right,
			size = niello.size(niello.percent(1), niello.fixed(28)),
			gap = 8,
		})
	}

	// ---- entry points -------------------------------------------

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
			return // never target ourselves
		}
		if is_open && !own_window_alive() {
			is_open = false // our window was closed under us
		}
		target = ctx
		if show_ovf {
			niello.debug_show_overflows(ctx, true)
		}
		poke()
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

	// ---- helpers --------------------------------------------------

	own_window_alive :: proc() -> bool {
		for w in niello_sdl.window_list() {
			if w.ctx == own_ctx {
				return true
			}
		}
		return false
	}

	// poke makes the target repaint once: debugger-driven
	// changes (highlight, tint) are invisible to an idle
	// target's per-context change detection until it frames.
	poke :: proc() {
		if target != nil {
			niello.context_wake(target)
		}
	}

	set_hl :: proc(inst: niello.Instance) {
		if hl_inst == inst {
			return
		}
		hl_inst = inst
		niello.debug_highlight(target, inst)
		poke()
	}

	clear_hl :: proc() {
		if hl_inst != 0 {
			hl_inst = 0
			niello.debug_highlight(nil, 0)
			poke()
		}
	}

	find_node :: proc(tree: []niello.Debug_Node, inst: niello.Instance) -> (niello.Debug_Node, bool) {
		for dn in tree {
			if dn.instance == inst {
				return dn, true
			}
		}
		return {}, false
	}

	basename :: proc(path: string) -> string {
		for i := len(path) - 1; i >= 0; i -= 1 {
			if path[i] == '/' || path[i] == '\\' {
				return path[i + 1:]
			}
		}
		return path
	}

	fmt_sizing :: proc(b: []u8, s: niello.Sizing) -> string {
		switch s.kind {
		case .Fixed:
			return fmt.bprintf(b, "fixed %.0f", s.value)
		case .Percent:
			return fmt.bprintf(b, "%.0f%%", s.value * 100)
		case .Fit:
			return fmt.bprintf(b, "fit")
		case .Grow:
			return fmt.bprintf(b, "grow %.0f", s.value)
		}
		return ""
	}

	// ---- the window -----------------------------------------------

	declare :: proc() {
		// Sustain our own cadence while open: a debug window that
		// only refreshes when poked is useless, and the cost is
		// dev-only by definition.
		niello.context_wake(own_ctx)

		wins := niello_sdl.window_list()
		others := 0
		target_found := false
		for w in wins {
			if w.ctx != own_ctx {
				others += 1
				if w.ctx == target {
					target_found = true
				}
			}
		}

		if others == 0 {
			// Every app window is gone: close ourselves, or this
			// window would keep the app alive on its own.
			if is_open {
				niello_sdl.close_window(win_id)
				is_open = false
			}
			target = nil
			selected = 0
			hl_inst = 0
			niello.debug_highlight(nil, 0)
			niello.debug_show_overflows(nil, false)
			if niello.begin(root_u) {
			}
			return
		}
		if target != nil && !target_found {
			// The target window closed: drop it, and anything
			// aimed at it.
			target = nil
			selected = 0
			hl_inst = 0
			niello.debug_highlight(nil, 0)
			niello.debug_show_overflows(nil, false)
		}

		hovered_any := false

		if niello.begin(root_u) {
			// Windows section: targets only. Toggles live with
			// the panels they affect (the tint is in Overflows).
			niello.show(section_u, {text = "WINDOWS"})
			if niello.begin(bar_u) {
				for w, wi in wins {
					if w.ctx == own_ctx {
						continue // the debugger never targets itself
					}
					buf: [128]u8
					name := w.title if w.title != "" else "window"
					txt := fmt.bprintf(buf[:], "%s · %d nodes", name, len(niello.debug_tree(w.ctx)))
					on := w.ctx == target
					chip: niello.Instance
					if niello.begin(chip_on_u if on else chip_u, out = &chip) {
						niello.show(chip_label_on_u if on else chip_label_u, {text = txt})
					}
					if niello.clicked(chip) && w.ctx != target {
						clear_hl()
						target = w.ctx
						selected = 0
						if show_ovf {
							niello.debug_show_overflows(target, true)
						}
						poke()
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

			if niello.begin(mid_u) {
				// Units panel.
				if niello.begin(panel_u) {
					niello.show(section_u, {text = "UNITS"})
					if niello.begin(tree_scroll_u) {
						if niello.begin(tree_col_u) {
							if len(tree) == 0 {
								niello.show(val_u, {text = "no target — F12 in any window"})
							}
							for dn, i in tree {
								row: niello.Instance
								row_style := row_sel_u if dn.instance == selected else row_u
								if niello.begin(row_style, out = &row) {
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
									niello.show(label_u, {text = string(buf[:off])})
									// A node can overflow on both
									// axes; badge each.
									boff := 0
									bb: [64]u8
									for rec in recs {
										if rec.instance == dn.instance {
											boff += len(fmt.bprintf(bb[boff:], "%v %.0fpx ", rec.axis, rec.px))
										}
									}
									if boff > 0 {
										niello.show(alert_u, {text = string(bb[:boff])})
									} else if .Culled in dn.flags {
										niello.show(val_u, {text = "culled"})
									}
								}
								if niello.hovered(row) {
									hovered_any = true
									set_hl(dn.instance)
								}
								if niello.clicked(row) {
									selected = dn.instance
								}
							}
						}
					}
				}

				// Details panel.
				if niello.begin(info_u) {
					niello.show(section_u, {text = "DETAILS"})
					declare_info(tree)
				}
			}

			// Overflows panel: the §3.13 report, presented. The
			// tint toggle lives here — it is this panel's switch.
			if niello.begin(ovf_u) {
				if niello.begin(ovf_head_u) {
					niello.show(section_u, {text = "OVERFLOWS"})
					tog: niello.Instance
					if niello.begin(chip_on_u if show_ovf else chip_u, out = &tog) {
						niello.show(chip_label_on_u if show_ovf else chip_label_u, {text = "tint: on" if show_ovf else "tint"})
					}
					if niello.clicked(tog) {
						show_ovf = !show_ovf
						if target != nil {
							niello.debug_show_overflows(target, show_ovf)
							poke()
						}
					}
				}
				if target == nil || len(recs) == 0 {
					niello.show(val_u, {text = "none"})
				}
				shown := 0
				for rec in recs {
					if shown >= 4 {
						buf: [48]u8
						niello.show(val_u, {text = fmt.bprintf(buf[:], "+ %d more", len(recs) - shown)})
						break
					}
					shown += 1
					row: niello.Instance
					if niello.begin(row_u, out = &row) {
						buf: [96]u8
						niello.show(alert_u, {text = fmt.bprintf(buf[:], "%s · %v · %.0f px", rec.name, rec.axis, rec.px)})
					}
					if niello.hovered(row) {
						hovered_any = true
						set_hl(rec.instance)
					}
					if niello.clicked(row) {
						selected = rec.instance
					}
				}
			}
		}

		// Nothing hovered this frame: drop the highlight we own.
		if !hovered_any {
			clear_hl()
		}
	}

	// kv declares one label/value row in the Details panel.
	kv :: proc(key: string, val: string) {
		if niello.begin(krow_u) {
			niello.show(key_u, {text = key})
			niello.show(val_u, {text = val})
		}
	}

	declare_info :: proc(tree: []niello.Debug_Node) {
		dn, ok := find_node(tree, selected)
		if !ok {
			niello.show(val_u, {text = "click a unit row to inspect"})
			return
		}
		buf: [192]u8
		name := niello.debug_unit_name(dn.unit)
		if name == "" {
			name = "unit"
		}
		niello.show(title_u, {text = fmt.bprintf(buf[:], "%s #%d", name, int(dn.unit))})

		niello.show(section_u, {text = "NODE"})
		kv("instance", fmt.bprintf(buf[:], "%d", int(dn.instance)))
		if file, line, lok := niello.debug_unit_loc(dn.unit); lok {
			kv("minted", fmt.bprintf(buf[:], "%s:%d", basename(file), line))
		}
		kv("rect", fmt.bprintf(buf[:], "(%.0f, %.0f)  %.0f x %.0f", dn.rect.pos.x, dn.rect.pos.y, dn.rect.size.x, dn.rect.size.y))
		kv("overfl", fmt.bprintf(buf[:], "(%.0f, %.0f)", dn.overfl.x, dn.overfl.y))
		kv("spill", fmt.bprintf(buf[:], "(%.0f, %.0f)", dn.spill.x, dn.spill.y))
		{
			off := 0
			b: [128]u8
			if .Popup in dn.flags { off += len(fmt.bprintf(b[off:], "popup ")) }
			if .Culled in dn.flags { off += len(fmt.bprintf(b[off:], "culled ")) }
			if .Scroll_X in dn.flags { off += len(fmt.bprintf(b[off:], "scroll-x ")) }
			if .Scroll_Y in dn.flags { off += len(fmt.bprintf(b[off:], "scroll-y ")) }
			if .Clip in dn.flags { off += len(fmt.bprintf(b[off:], "clip ")) }
			if .Focused in dn.flags { off += len(fmt.bprintf(b[off:], "focused ")) }
			if .Hovered in dn.flags { off += len(fmt.bprintf(b[off:], "hovered ")) }
			kv("flags", string(b[:off]) if off > 0 else "—")
		}

		if s, sok := niello.debug_style_in(target, dn.instance); sok {
			niello.show(section_u, {text = "STYLE (UNIT)"})
			kv("layout", fmt.bprintf(buf[:], "%v", s.layout))
			{
				bx: [64]u8
				xs := fmt_sizing(bx[:], s.size.x)
				by: [64]u8
				ys := fmt_sizing(by[:], s.size.y)
				kv("size", fmt.bprintf(buf[:], "%s x %s", xs, ys))
			}
			kv("color", fmt.bprintf(buf[:], "rgba(%d, %d, %d, %d)", s.color.r, s.color.g, s.color.b, s.color.a))
			kv("radius", fmt.bprintf(buf[:], "%v", s.corner_radius))
			if s.border_width > 0 {
				kv("border", fmt.bprintf(buf[:], "%v · rgba(%d, %d, %d, %d)", s.border_width, s.border_color.r, s.border_color.g, s.border_color.b, s.border_color.a))
			}
			kv("font", fmt.bprintf(buf[:], "%.0f · %v · %v", s.font_size, s.font_weight, s.font_slant))
			kv("font color", fmt.bprintf(buf[:], "rgba(%d, %d, %d, %d)", s.font_color.r, s.font_color.g, s.font_color.b, s.font_color.a))
			if s.text != "" {
				t := s.text
				if len(t) > 36 {
					t = t[:36]
				}
				kv("text", fmt.bprintf(buf[:], "\"%s\"", t))
			}
			kv("scroll", fmt.bprintf(buf[:], "%v", s.scroll))
			kv("overflow", fmt.bprintf(buf[:], "%v", s.overflow))
			kv("opacity", fmt.bprintf(buf[:], "%d", s.opacity))
			kv("gap", fmt.bprintf(buf[:], "%v", s.gap))
			kv("padding", fmt.bprintf(buf[:], "%v", s.padding))
		}

		niello.show(section_u, {text = "WITH (INSTANCE)"})
		w := dn.with
		if w.present == {} {
			kv("—", "(none)")
		}
		if .Text in w.present {
			t := w.text
			if len(t) > 36 {
				t = t[:36]
			}
			kv("text", fmt.bprintf(buf[:], "\"%s\"", t))
		}
		if .Text_Borrowed in w.present {
			kv("text", "(borrowed, no copy)")
		}
		if .Spans in w.present {
			kv("spans", fmt.bprintf(buf[:], "%d", w.spans))
		}
		if .Disabled in w.present {
			kv("disabled", "true")
		}
		if .Anchored in w.present {
			kv("anchored", "true")
		}
		if .Focusable in w.present {
			kv("focusable", fmt.bprintf(buf[:], "%v", w.focusable))
		}
		if .Variant in w.present {
			vn := niello.debug_unit_name(w.variant)
			if vn == "" {
				vn = "unit"
			}
			kv("variant", fmt.bprintf(buf[:], "%s #%d", vn, int(w.variant)))
		}
		if .Label in w.present {
			kv("label", fmt.bprintf(buf[:], "\"%s\"", w.label))
		}
	}
}
