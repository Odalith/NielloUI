package niello

// ===========================================================================
// The mutation layer (§3.16): tweens, group_tween, edit, propagate,
// transient — the animated and bulk writes. The public verbs live in
// public.odin; this file is the engine: the tween registry, per-field
// interpolation, the edit diff, and the transient envelope.
//
// frame_end order (public.odin): step_tweens, then apply_edits (an edit
// is an explicit write and wins over a glide on the same field), then
// sweep_transients — all before resolve_styles, so animation values
// flow through the ordinary style/layout/damage path and there is no
// animation-specific damage anywhere. While anything animates,
// frame_end keeps a short wake registered (~60fps steps); when the
// last tween/transient ends, next_wake_ms returns to infinity and a
// static UI blocks on OS events again (§3.3's idle-CPU clause).
// ===========================================================================

// How often the host is woken to step active animations.
ANIM_WAKE_MS :: 16

// The fields a transient may blend: paint-only, so a per-instance pulse
// never relayouts the tree (borders draw inset; radius/opacity/colors
// are pure paint). Layout-affecting fields in a transient unit are
// ignored by construction — they never enter the record's mask.
TRANSIENT_FIELDS :: Fields{
	.Color, .Font_Color, .Border_Color, .Border_Width, .Corner_Radius,
	.Opacity, .Overlay_Color, .Overlay_Border_Color, .Overlay_Border_Width,
}

// Tween is one in-flight glide: full from/to style snapshots (only the
// masked fields are meaningful), stepped at frame_end. Interrupting a
// tween re-snapshots `from` from the unit's live style, which the
// stepper has been mutating in place — retargeting is continuous by
// construction (§8).
Tween :: struct {
	unit:     Unit,
	fields:   Fields, // animatable fields only; the rest snapped at t=0
	from, to: Style,
	start_ms: u64, // engine time at the tween() call
	dur_ms:   u32,
}

// Transient_Rec is one fired pulse on one instance: a snapshot of the
// source unit's explicit fields (filtered to TRANSIENT_FIELDS),
// blended over the instance's resolved style by an in/out envelope.
// src/in/out are the pulse's identity: re-firing the identical pulse
// while it is in flight is a no-op (see transient in public.odin).
Transient_Rec :: struct {
	fields:   Fields,
	style:    Style,
	src:      Unit,
	start_ms: u64,
	in_ms:    u16,
	out_ms:   u16,
}

// Edit_State is one unit's pending edit: the style as it was when
// edit() was first called this frame (base) and the copy the caller is
// mutating (shadow). frame_end applies shadow-minus-base field by
// field, so an edit only ever writes what the caller actually changed.
Edit_State :: struct {
	base, shadow: Style,
}

// ---------------------------------------------------------------------------
// Field classification and interpolation

// field_animatable reports whether a field's values interpolate.
// Everything else (text, enums, bools, handles) snaps at t=0 per §8's
// field metadata rule. Size is conditionally animatable — see
// start_glide, which demotes it to a snap when the kinds differ.
@(private)
field_animatable :: proc(f: Field) -> bool {
	#partial switch f {
	case .Color, .Font_Color, .Border_Color, .Overlay_Color,
	     .Overlay_Border_Color,
	     .Font_Size,
	     .Padding, .Gap, .Border_Width, .Overlay_Border_Width,
	     .Corner_Radius, .Opacity,
	     .Size:
		return true
	}
	return false
}

@(private)
ease_out_cubic :: proc(t: f32) -> f32 {
	u := 1 - t
	return 1 - u * u * u
}

@(private)
lerp_f32 :: proc(a, b, t: f32) -> f32 {
	return a + (b - a) * t
}

@(private)
lerp_u8 :: proc(a, b: u8, t: f32) -> u8 {
	return u8(lerp_f32(f32(a), f32(b), t) + 0.5)
}

@(private)
lerp_u16 :: proc(a, b: u16, t: f32) -> u16 {
	return u16(lerp_f32(f32(a), f32(b), t) + 0.5)
}

@(private)
lerp_color :: proc(a, b: Color, t: f32) -> Color {
	return Color{
		lerp_u8(a[0], b[0], t),
		lerp_u8(a[1], b[1], t),
		lerp_u8(a[2], b[2], t),
		lerp_u8(a[3], b[3], t),
	}
}

// lerp_field writes the interpolation of a's and b's f into dst at t.
// Only called for animatable fields (and, via transients, the paint
// subset of them); anything else copies b defensively.
@(private)
lerp_field :: proc(dst, a, b: ^Style, f: Field, t: f32) {
	switch f {
	case .Color:         dst.color         = lerp_color(a.color, b.color, t)
	case .Font_Color:    dst.font_color    = lerp_color(a.font_color, b.font_color, t)
	case .Border_Color:  dst.border_color  = lerp_color(a.border_color, b.border_color, t)
	case .Overlay_Color:        dst.overlay_color        = lerp_color(a.overlay_color, b.overlay_color, t)
	case .Overlay_Border_Color: dst.overlay_border_color = lerp_color(a.overlay_border_color, b.overlay_border_color, t)
	case .Font_Size:     dst.font_size     = lerp_f32(a.font_size, b.font_size, t)
	case .Padding:
		for i in 0 ..< 4 {
			dst.padding[i] = lerp_u16(a.padding[i], b.padding[i], t)
		}
	case .Gap:           dst.gap           = lerp_u16(a.gap, b.gap, t)
	case .Border_Width:  dst.border_width  = lerp_u16(a.border_width, b.border_width, t)
	case .Overlay_Border_Width: dst.overlay_border_width = lerp_u16(a.overlay_border_width, b.overlay_border_width, t)
	case .Corner_Radius: dst.corner_radius = lerp_u8(a.corner_radius, b.corner_radius, t)
	case .Opacity:       dst.opacity       = lerp_u8(a.opacity, b.opacity, t)
	case .Size:
		for ax in 0 ..< 2 {
			sa, sb := a.size[ax], b.size[ax]
			dst.size[ax] = Sizing{
				kind  = sa.kind,
				value = lerp_f32(sa.value, sb.value, t),
				min   = lerp_f32(sa.min, sb.min, t),
				// max is INF in most styles; only lerp two finite,
				// differing ceilings, never arithmetic on INF.
				max   = sa.max if sa.max == sb.max else sb.max,
			}
		}
	case .Text, .Font, .Font_Weight, .Font_Slant, .Text_Spans,
	     .Text_Wrap, .Whitespace, .Ellipsis, .Layout, .Align, .Scroll, .Overflow,
	     .Cursor, .Scroll_Chain:
		copy_field(dst, b, f)
	}
}

// field_equal compares one field across two styles (edit diffs,
// propagate's change check). Text_Spans compares elementwise.
@(private)
field_equal :: proc(a, b: ^Style, f: Field) -> bool {
	switch f {
	case .Color:         return a.color == b.color
	case .Font_Color:    return a.font_color == b.font_color
	case .Border_Color:  return a.border_color == b.border_color
	case .Text:          return a.text == b.text
	case .Font:          return a.font == b.font
	case .Font_Size:     return a.font_size == b.font_size
	case .Font_Weight:   return a.font_weight == b.font_weight
	case .Font_Slant:    return a.font_slant == b.font_slant
	case .Text_Spans:
		if len(a.text_spans) != len(b.text_spans) {
			return false
		}
		for i in 0 ..< len(a.text_spans) {
			if a.text_spans[i] != b.text_spans[i] {
				return false
			}
		}
		return true
	case .Text_Wrap:     return a.wrap == b.wrap
	case .Whitespace:    return a.whitespace == b.whitespace
	case .Ellipsis:      return a.ellipsis == b.ellipsis
	case .Padding:       return a.padding == b.padding
	case .Gap:           return a.gap == b.gap
	case .Corner_Radius: return a.corner_radius == b.corner_radius
	case .Opacity:       return a.opacity == b.opacity
	case .Layout:        return a.layout == b.layout
	case .Align:         return a.align == b.align
	case .Size:          return a.size == b.size
	case .Scroll:        return a.scroll == b.scroll
	case .Overflow:      return a.overflow == b.overflow
	case .Border_Width:  return a.border_width == b.border_width
	case .Overlay_Color:        return a.overlay_color == b.overlay_color
	case .Overlay_Border_Color: return a.overlay_border_color == b.overlay_border_color
	case .Overlay_Border_Width: return a.overlay_border_width == b.overlay_border_width
	case .Cursor:       return a.cursor == b.cursor
	case .Scroll_Chain: return a.scroll_chain == b.scroll_chain
	}
	return true
}

// ---------------------------------------------------------------------------
// The tween registry

// write_field copies one field from src into u's style through the
// ordinary write tail (dirty + explicit + generation).
@(private)
write_field :: proc(u: Unit, f: Field, src: ^Style) {
	rec := &g.units[int(u)]
	copy_field_owned(&rec.style, src, f)
	touch(u, Fields{f})
}

// start_glide begins (or replaces) u's glide toward the `to` style over
// ms. Non-animatable fields — and Size when its kinds differ — snap
// immediately; ms == 0 snaps everything. Fields already gliding on u
// are stolen from their tween: the new glide snapshots `from` from the
// live style, so the handover is continuous.
@(private)
start_glide :: proc(u: Unit, fields: Fields, to: ^Style, ms: u32) {
	if fields == {} {
		return
	}
	rec := &g.units[int(u)]
	if ms == 0 {
		for f in fields {
			write_field(u, f, to)
		}
		return
	}
	glide := Fields{}
	for f in fields {
		if !field_animatable(f) ||
		   (f == .Size && (rec.style.size[0].kind != to.size[0].kind ||
		                   rec.style.size[1].kind != to.size[1].kind)) {
			write_field(u, f, to)
		} else {
			glide += Fields{f}
		}
	}
	if glide == {} {
		return
	}
	cancel_glide_fields(u, glide)
	append(&g.tweens, Tween{
		unit     = u,
		fields   = glide,
		from     = rec.style,
		to       = to^,
		start_ms = g.time_ms,
		dur_ms   = ms,
	})
}

// cancel_glide_fields removes the given fields from any tween running
// on u (an explicit write supersedes the glide on those fields).
@(private)
cancel_glide_fields :: proc(u: Unit, fields: Fields) {
	for i := len(g.tweens) - 1; i >= 0; i -= 1 {
		if g.tweens[i].unit == u {
			g.tweens[i].fields -= fields
			if g.tweens[i].fields == {} {
				unordered_remove(&g.tweens, i)
			}
		}
	}
}

@(private)
field_gliding :: proc(u: Unit, f: Field) -> bool {
	for &tw in g.tweens {
		if tw.unit == u && f in tw.fields {
			return true
		}
	}
	return false
}

// step_tweens advances every glide to the current engine time, writing
// interpolated values into the units' live styles. A finished glide
// lands on its exact target values and leaves the registry.
@(private)
step_tweens :: proc() {
	now := g.time_ms
	for i := len(g.tweens) - 1; i >= 0; i -= 1 {
		tw := &g.tweens[i]
		t := f32(1)
		if tw.dur_ms > 0 {
			t = clamp(f32(now - tw.start_ms) / f32(tw.dur_ms), 0, 1)
		}
		rec := &g.units[int(tw.unit)]
		if t >= 1 {
			for f in tw.fields {
				copy_field(&rec.style, &tw.to, f)
			}
			touch(tw.unit, tw.fields)
			unordered_remove(&g.tweens, i)
		} else {
			e := ease_out_cubic(t)
			for f in tw.fields {
				lerp_field(&rec.style, &tw.from, &tw.to, f, e)
			}
			touch(tw.unit, tw.fields)
		}
	}
}

// ---------------------------------------------------------------------------
// Edits

// apply_edits lands every pending edit shadow: fields the caller
// changed relative to the baseline are written (cancelling any glide
// on them — an explicit write wins), untouched fields are left alone,
// so an edit never clobbers an intervening set. States are freed and
// the map cleared: shadow pointers die at frame_end, per contract.
@(private)
apply_edits :: proc() {
	for u, es in g.edits {
		rec := &g.units[int(u)]
		for f in Field {
			if field_equal(&es.base, &es.shadow, f) {
				continue
			}
			cancel_glide_fields(u, Fields{f})
			copy_field_owned(&rec.style, &es.shadow, f)
			touch(u, Fields{f})
		}
		free(es)
	}
	clear(&g.edits)
}

// ---------------------------------------------------------------------------
// Transients

// transient_k is the envelope: the blend factor at the current engine
// time, and whether the pulse is still alive. In over in_ms, out over
// out_ms, then gone — a triangle peaking at the in/out seam.
@(private)
transient_k :: proc(tr: ^Transient_Rec) -> (k: f32, active: bool) {
	elapsed := g.time_ms - tr.start_ms
	total := u64(tr.in_ms) + u64(tr.out_ms)
	if elapsed >= total {
		return 0, false
	}
	if elapsed < u64(tr.in_ms) {
		return f32(elapsed) / f32(tr.in_ms), true
	}
	return 1 - f32(elapsed - u64(tr.in_ms)) / f32(tr.out_ms), true
}

// apply_transient blends a live transient over dst (the node's resolved
// style), after all overlays — the highest-precedence layer. Called by
// resolve_styles only for nodes whose identity has a record.
@(private)
apply_transient :: proc(dst: ^Style, id: Instance) {
	tr := g.transients[id]
	k, active := transient_k(&tr)
	if !active {
		return
	}
	for f in tr.fields {
		lerp_field(dst, dst, &tr.style, f, k)
	}
}

// sweep_transients drops expired records (frame_end prologue; the
// blend itself reads records during resolve_styles).
@(private)
sweep_transients :: proc() {
	if len(g.transients) == 0 {
		return
	}
	dead: [dynamic]Instance
	defer delete(dead)
	for id, &tr in g.transients {
		if _, active := transient_k(&tr); !active {
			append(&dead, id)
		}
	}
	for id in dead {
		delete_key(&g.transients, id)
	}
}

// update_animation_wake keeps frame steps coming while anything
// animates: a short rolling deadline (~60fps). Called just before
// frame_end computes next_wake_ms; when nothing animates it registers
// nothing and the deadline falls back to whatever else is pending —
// infinity for a static UI.
@(private)
update_animation_wake :: proc() {
	if len(g.tweens) > 0 || len(g.transients) > 0 {
		schedule_wake_in(ANIM_WAKE_MS)
	}
}
