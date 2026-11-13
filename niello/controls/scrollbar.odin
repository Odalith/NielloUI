package controls

import niello ".."

// ---- scrollbar ---------------------------------------------------------------
//
// Chrome for any scroller (a virtual list's section host included):
// declared inside it, after its content, as an anchored child — it takes no
// flow slot and does not scroll. The scroller's align places it (align
// [.End, .Start] puts a vertical bar at the right edge). Drag the thumb, or
// press the track to page.
//
//	if niello.begin(list_u, out = &app.list_i) {
//		… content …
//		controls.scrollbar(&app.list_bar, app.list_i)
//	}

Bar_Axis :: enum {
	Vertical,
	Horizontal,
}

// Scrollbar_Parts are shared by every bar: the thumb's length and its
// offset (the spacer) are per instance, carried by With.size.
Scrollbar_Parts :: struct {
	strip:              [Bar_Axis]niello.Unit,
	spacer, thumb, hot: niello.Unit,
}

// Scrollbar is one bar's state: its axis, and its drag. The zero value is
// a vertical bar.
Scrollbar :: struct {
	axis:             Bar_Axis,
	strip_i, thumb_i: niello.Instance,
	dragging:         bool,
	grab:             f32,
	track_down:       bool,
}

BAR_WIDTH     :: 10
BAR_MIN_THUMB :: f32(24)

@(private)
mint_scrollbar :: proc(t: Theme) {
	P := &parts.scrollbar
	for axis in Bar_Axis {
		vert := axis == .Vertical
		niello.mint(&P.strip[axis], niello.NO_UNIT, {
			layout = vert ? niello.Layout.Top_To_Bottom : niello.Layout.Left_To_Right,
			size = vert ? niello.size(niello.fixed(BAR_WIDTH), niello.grow()) : niello.size(niello.grow(), niello.fixed(BAR_WIDTH)),
			padding = niello.pad(2),
		})
	}
	niello.mint(&P.spacer, niello.NO_UNIT, {})
	niello.mint(&P.hot, niello.NO_UNIT, {color = t.dim, groups = roles(groups.dim)})
	thumb := t.dim
	thumb.a = 160
	niello.mint(&P.thumb, niello.NO_UNIT, {color = thumb, corner_radius = 3, hover = P.hot, press = P.hot})
}

// scrollbar declares sb's bar for scroller (see above). Nothing is
// declared while the scroller has nothing to scroll on sb's axis.
scrollbar :: proc(sb: ^Scrollbar, scroller: niello.Instance, loc := #caller_location) {
	vert := sb.axis == .Vertical
	ax := vert ? 1 : 0
	rng := niello.scroll_range(scroller)
	range_ := rng[ax]
	if range_ <= 0 {
		sb.strip_i, sb.thumb_i, sb.dragging = 0, 0, false
		return
	}
	off := niello.scroll_offset(scroller)
	cur := off[ax]

	track := f32(0)
	if r, ok := niello.rect(sb.strip_i); ok {
		track = r.size[ax]
	} else if r, ok := niello.rect(scroller); ok {
		track = r.size[ax]
	}
	track = max(track - 4, 0) // the strip's padding
	thumb := clamp(track * track / (track + range_), BAR_MIN_THUMB, max(track, BAR_MIN_THUMB))
	travel := max(track - thumb, 0)
	pos := clamp(travel * cur / range_, 0, travel)

	if mouse, ok := niello.mouse_position(); ok && sb.thumb_i != 0 {
		m := mouse[ax]
		if niello.pointer_pressed(sb.thumb_i) {
			thumb_r, _ := niello.rect(sb.thumb_i)
			if !sb.dragging {
				sb.dragging = true
				sb.grab = m - thumb_r.pos[ax]
			}
			if travel > 0 {
				strip_r, _ := niello.rect(sb.strip_i)
				start := strip_r.pos[ax] + 2
				frac := clamp((m - start - sb.grab) / travel, 0, 1)
				target := off
				target[ax] = frac * range_
				niello.scroll_to(scroller, target)
				pos = travel * frac
			}
		} else {
			sb.dragging = false
		}
		down := niello.pointer_pressed(sb.strip_i) && !niello.pointer_pressed(sb.thumb_i)
		if down && !sb.track_down {
			thumb_r, _ := niello.rect(sb.thumb_i)
			page := m < thumb_r.pos[ax] ? -track : track
			target := off
			target[ax] = clamp(off[ax] + page, 0, range_)
			niello.scroll_to(scroller, target)
		}
		sb.track_down = down
	}

	// The parts are shared; this bar's geometry rides on With.size.
	spacer_size := vert ? niello.size(niello.fixed(0), niello.fixed(pos)) : niello.size(niello.fixed(pos), niello.fixed(0))
	thumb_size := vert ? niello.size(niello.grow(), niello.fixed(thumb)) : niello.size(niello.fixed(thumb), niello.grow())
	P := &parts.scrollbar
	if niello.begin(P.strip[sb.axis], {anchored = true, role = .ScrollBar}, out = &sb.strip_i, loc = loc) {
		niello.show(P.spacer, {size = spacer_size})
		sb.thumb_i = niello.show(P.thumb, {size = thumb_size})
	} else {
		sb.strip_i, sb.thumb_i = 0, 0
	}
}
