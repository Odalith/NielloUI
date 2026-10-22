// scrollbars — the default scrollbar component (TODO #16) and its
// customization story.
//
// The engine's part is deliberately tiny (§3.20): a scroll_range
// query next to scroll_offset, and With.anchored — a child of a
// scroller that neither scrolls nor counts as content. Everything
// else is this component's own programming: thumb geometry from
// the offset/range pair, drag by absolute pointer mapping under
// press capture, page-step on track presses, brightening via
// overlay units. A fade is the same kind of programming (drive
// opacity from your own state, e.g. with transient on activity);
// it is left out here so the default has no hidden timers.
//
// The component (below, up to the demo marker) is written to be
// copied: scrollbar_init mints a bar's units with the colors and
// width you pass — restyling is choosing different mint arguments,
// never fighting a theme system. Each bar owns its units, so two
// bars never share style state (the spacer and thumb sizes are set
// per frame from the live geometry).
//
// Host contract: the bar is declared inside its scroller, after
// the content, anchored. The scroller's own align places it
// (cross End = right edge, main End = bottom edge); anchored
// children take no flow slot, so a plain Column scroller hosts its
// bar directly — no wrapper containers.
package main

import "core:fmt"
import niello "../.."
import sdl "../../sdl"

// =====================================================================
// The default scrollbar component.
// =====================================================================

Bar_Axis :: enum {
	Vertical,
	Horizontal,
}

Scrollbar :: struct {
	axis:       Bar_Axis,
	strip_u:    niello.Unit, // the rail: fixed width, full length
	spacer_u:   niello.Unit, // invisible; its size is the thumb offset
	thumb_u:    niello.Unit,
	thumb_hot_u: niello.Unit, // hover/press overlay for the thumb
	strip_i:    niello.Instance,
	thumb_i:    niello.Instance,
	dragging:   bool,
	grab:       f32, // pointer distance into the thumb at grab time
	track_down: bool, // last frame's track-press state (page on edge)
}

scrollbar_init :: proc(
	sb: ^Scrollbar,
	axis: Bar_Axis,
	width: f32,
	strip_color, thumb_color, hot_color: niello.Color,
	thumb_radius: u8 = 0,
) {
	sb.axis = axis
	strip_size := axis == .Vertical \
		? niello.Size{niello.fixed(width), niello.grow(1)} \
		: niello.Size{niello.grow(1), niello.fixed(width)}
	niello.mint(&sb.strip_u, niello.NO_UNIT, {
		layout = axis == .Vertical ? niello.Layout.Top_To_Bottom : niello.Layout.Left_To_Right,
		size = strip_size,
		color = strip_color,
	})
	niello.mint(&sb.spacer_u, niello.NO_UNIT, {})
	niello.mint(&sb.thumb_hot_u, niello.NO_UNIT, {color = hot_color})
	niello.mint(&sb.thumb_u, niello.NO_UNIT, {
		color = thumb_color,
		corner_radius = thumb_radius,
		hover = sb.thumb_hot_u, press = sb.thumb_hot_u,
	})
}

BAR_MIN_THUMB :: f32(24)

// scrollbar_declare paints one bar inside its scroller and runs its
// interactions. Call it inside the scroller's begin, after the
// content, every frame the scroller is declared.
scrollbar_declare :: proc(sb: ^Scrollbar, scroller: niello.Instance) {
	vert := sb.axis == .Vertical
	ax := vert ? 1 : 0
	rng := niello.scroll_range(scroller)
	range_ := vert ? rng.y : rng.x
	if range_ <= 0 {
		sb.strip_i = 0
		sb.thumb_i = 0
		sb.dragging = false
		return // nothing to scroll: no bar (the component's one
		// built-in nicety that needs no timer)
	}
	off := niello.scroll_offset(scroller)
	cur := vert ? off.y : off.x

	// Geometry from last frame's committed rects (the engine's
	// one-frame rule). The strip spans the scroller's extent on the
	// axis, so the viewport extent is the strip's length.
	track_len := cur // (placeholder until the strip has a rect)
	if r, ok := niello.rect(sb.strip_i); ok {
		track_len = vert ? r.size.y : r.size.x
	} else if r, ok := niello.rect(scroller); ok {
		track_len = vert ? r.size.y : r.size.x
	}
	view := track_len
	thumb_len := track_len
	if view + range_ > 0 {
		thumb_len = track_len * view / (view + range_)
	}
	thumb_len = clamp(thumb_len, BAR_MIN_THUMB, track_len)
	travel := track_len - thumb_len
	thumb_pos := clamp(travel * (cur / range_), 0, travel) // cur
	// may overscroll past the range (§3.22); the thumb rides the
	// clamped position, not the band

	// Interactions (last frame's instances, this frame's pointer).
	if mouse, ok := niello.mouse_position(); ok && sb.thumb_i != 0 {
		m := vert ? mouse.y : mouse.x
		if niello.pressed(sb.thumb_i) {
			thumb_r, _ := niello.rect(sb.thumb_i)
			if !sb.dragging {
				sb.dragging = true
				sb.grab = m - (vert ? thumb_r.pos.y : thumb_r.pos.x)
			}
			if travel > 0 {
				strip_r, _ := niello.rect(sb.strip_i)
				start := vert ? strip_r.pos.y : strip_r.pos.x
				frac := clamp((m - start - sb.grab) / travel, 0, 1)
				target := off
				if vert {
					target.y = frac * range_
				} else {
					target.x = frac * range_
				}
				niello.scroll_to(scroller, target)
				cur = frac * range_
				thumb_pos = travel * frac
			}
		} else {
			sb.dragging = false
		}
		// Track press: page toward the press, once per press.
		down := niello.pressed(sb.strip_i) && !niello.pressed(sb.thumb_i)
		if down && !sb.track_down {
			thumb_r, _ := niello.rect(sb.thumb_i)
			tpos := vert ? thumb_r.pos.y : thumb_r.pos.x
			target := off
			page := view
			if m < tpos {
				page = -page
			}
			if vert {
				target.y = clamp(off.y + page, 0, range_)
			} else {
				target.x = clamp(off.x + page, 0, range_)
			}
			niello.scroll_to(scroller, target)
		}
		sb.track_down = down
	}

	// Paint: spacer carries the thumb position, the thumb unit
	// carries its length. Both sizes are this bar's own units, set
	// fresh each frame; layout reads them at frame_end.
	if vert {
		niello.set_many(sb.spacer_u, {size = niello.Size{niello.fixed(0), niello.fixed(thumb_pos)}})
		niello.set_many(sb.thumb_u, {size = niello.Size{niello.grow(1), niello.fixed(thumb_len)}})
	} else {
		niello.set_many(sb.spacer_u, {size = niello.Size{niello.fixed(thumb_pos), niello.fixed(0)}})
		niello.set_many(sb.thumb_u, {size = niello.Size{niello.fixed(thumb_len), niello.grow(1)}})
	}
	if si, ok := niello.begin(sb.strip_u, 0, {anchored = true}); ok {
		sb.strip_i = si
		niello.show(sb.spacer_u)
		sb.thumb_i = niello.show(sb.thumb_u)
	} else {
		sb.strip_i = 0
		sb.thumb_i = 0
	}
	_ = ax
}

// =====================================================================
// Demo.
// =====================================================================

BG     :: niello.Color{32, 36, 44, 255}
PANEL  :: niello.Color{43, 49, 61, 255}
ROW    :: niello.Color{52, 59, 74, 255}
INK    :: niello.Color{232, 236, 242, 255}
DIM    :: niello.Color{150, 158, 172, 255}
STRIP  :: niello.Color{24, 27, 34, 255}
THUMB  :: niello.Color{110, 120, 140, 255}
HOT    :: niello.Color{150, 162, 184, 255}
ACCENT :: niello.Color{96, 165, 250, 255}
ACCENT_HOT :: niello.Color{147, 197, 253, 255}

root_u, col_u, label_u, status_u: niello.Unit
list_scroll_u, row_u: niello.Unit
both_scroll_u, wide_row_u: niello.Unit
cust_scroll_u: niello.Unit

list_bar, both_vbar, both_hbar, cust_bar: Scrollbar
list_i, both_i, cust_i: niello.Instance

status_buf: [128]u8
status_len: int

mint :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size = niello.Size{niello.grow(1), niello.grow(1)},
		color = BG, padding = [4]u16{16, 16, 16, 16}, gap = 16,
	})
	niello.mint(&col_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(320), niello.grow(1)},
		gap = 8,
	})
	niello.mint(&label_u, niello.NO_UNIT, {font_size = 15, font_color = INK})
	niello.mint(&status_u, niello.NO_UNIT, {font_size = 13, font_color = DIM})
	// One unit is the whole scroller: the rows flow in it and the
	// bar is an anchored child of it.
	niello.mint(&list_scroll_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(1), niello.grow(1)},
		scroll = niello.Scroll.Vertical,
		align = [2]niello.Align_Kind{.Start, .End},
		color = PANEL, corner_radius = 8,
		gap = 4, padding = [4]u16{6, 6, 6, 6},
	})
	niello.mint(&row_u, niello.NO_UNIT, {
		size = niello.Size{niello.grow(1), niello.fixed(32)},
		color = ROW, corner_radius = 4,
		font_size = 14, font_color = INK,
	})
	niello.mint(&both_scroll_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(1), niello.fixed(216)},
		scroll = niello.Scroll.Both,
		align = [2]niello.Align_Kind{.End, .End},
		color = PANEL, corner_radius = 8,
		gap = 4, padding = [4]u16{6, 6, 6, 6},
	})
	niello.mint(&wide_row_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(620), niello.fixed(32)},
		color = ROW, corner_radius = 4,
	})
	niello.mint(&cust_scroll_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.grow(1), niello.grow(1)},
		scroll = niello.Scroll.Vertical,
		smooth_scroll = true, smooth_ms = 150, // wheel glides (§3.21);
		overscroll = true, overscroll_px = 80, // band + spring (§3.22)
		// thumb drags stay instant (they go through scroll_to)
		align = [2]niello.Align_Kind{.Start, .End},
		color = PANEL, corner_radius = 8,
		gap = 4, padding = [4]u16{6, 6, 6, 6},
	})
	scrollbar_init(&list_bar, .Vertical, 12, STRIP, THUMB, HOT, 6)
	scrollbar_init(&both_vbar, .Vertical, 12, STRIP, THUMB, HOT, 6)
	scrollbar_init(&both_hbar, .Horizontal, 12, STRIP, THUMB, HOT, 6)
	scrollbar_init(&cust_bar, .Vertical, 18, STRIP, ACCENT, ACCENT_HOT, 9)
}

row_text_buf: [32]u8

declare :: proc() {
	if _, ok := niello.begin(root_u); ok {
		// Left: the reading list with the default bar.
		if _, ok2 := niello.begin(col_u, niello.key_int(1)); ok2 {
			niello.show(label_u, niello.key_int(1), {text = "Reading list"})
			if si, ok3 := niello.begin(list_scroll_u, niello.key_int(2)); ok3 {
				list_i = si
				for k in 0 ..< 30 {
					n := len(fmt.bprintf(row_text_buf[:], "Chapter %d", k + 1))
					niello.show(row_u, niello.key_int(k + 1), {
						text = string(row_text_buf[:n]),
					})
				}
				scrollbar_declare(&list_bar, si)
			}
		}
		// Right: a both-axes pane and a restyled bar.
		if _, ok2 := niello.begin(col_u, niello.key_int(2)); ok2 {
			niello.show(label_u, niello.key_int(1), {text = "Both axes (wide rows)"})
			if si, ok3 := niello.begin(both_scroll_u, niello.key_int(2)); ok3 {
				both_i = si
				for k in 0 ..< 8 {
					n := len(fmt.bprintf(row_text_buf[:], "Wide row %d — lorem ipsum dolor sit amet", k + 1))
					niello.show(wide_row_u, niello.key_int(k + 1), {
						text = string(row_text_buf[:n]),
					})
				}
				scrollbar_declare(&both_vbar, si)
				scrollbar_declare(&both_hbar, si)
			}
			niello.show(label_u, niello.key_int(3), {text = "Same component, custom mint (18px, accent, smooth + overscroll)"})
			if si, ok3 := niello.begin(cust_scroll_u, niello.key_int(4)); ok3 {
				cust_i = si
				for k in 0 ..< 30 {
					n := len(fmt.bprintf(row_text_buf[:], "Entry %d", k + 1))
					niello.show(row_u, niello.key_int(k + 1), {
						text = string(row_text_buf[:n]),
					})
				}
				scrollbar_declare(&cust_bar, si)
			}
			off := niello.scroll_offset(list_i)
			rng := niello.scroll_range(list_i)
			status_len = len(fmt.bprintf(status_buf[:],
				"list: offset %.0f / range %.0f — wheel, drag the thumb, or click the track",
				off.y, rng.y))
			niello.show(status_u, niello.key_int(9), {
				text = string(status_buf[:status_len]),
			})
		}
	}
}

main :: proc() {
	mint()
	sdl.run({title = "NielloUI — scrollbars", width = 720, height = 520}, declare)
}
