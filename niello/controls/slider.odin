package controls

import niello ".."

// ---- slider and progress bar -----------------------------------------------

// Slider_Parts are shared by every slider and progress bar: the fill's
// length is per instance, carried by With.size.
Slider_Parts :: struct {
	track, fill, progress_fill: niello.Unit,
	track_disabled:             niello.Unit,
}

// Slider is one slider's state. The range is [min, max] (max <= min means
// 0..1); step is the keyboard step (0: a twentieth of the range).
Slider :: struct {
	value:          f32,
	min, max, step: f32,
	inst:           niello.Instance,
}

SLIDER_H :: 22

@(private)
mint_slider :: proc(t: Theme) {
	P := &parts.slider
	niello.mint(&P.track_disabled, niello.NO_UNIT, {cursor = .Not_Allowed, color = t.panel, groups = roles(groups.panel)})
	niello.mint(&P.track, niello.NO_UNIT, {
		layout = .Stack, size = niello.size(niello.grow(), niello.fixed(SLIDER_H)),
		color = t.raised, corner_radius = SLIDER_H / 2, cursor = .Pointer,
		focusable = true, disabled = P.track_disabled,
		groups = roles(groups.raised),
	})
	niello.mint(&P.fill, niello.NO_UNIT, {color = t.accent, corner_radius = SLIDER_H / 2, groups = roles(groups.accent)})
	niello.mint(&P.progress_fill, niello.NO_UNIT, {color = t.success, corner_radius = SLIDER_H / 2, groups = roles(groups.success)})
}

@(private)
slider_range :: proc(s: ^Slider) -> (lo, hi, step: f32) {
	lo, hi = s.min, s.max
	if hi <= lo {
		lo, hi = 0, 1
	}
	step = s.step > 0 ? s.step : (hi - lo) / 20
	return
}

// slider declares a horizontal slider for s, labelled label for
// accessibility. A pointer press seeks and a drag scrubs; while focused,
// Left/Down and Right/Up step, Page Up/Down move ten steps, Home/End go
// to the ends. Reports whether s.value changed. a11y: Slider with its value
// and range.
slider :: proc(s: ^Slider, label: string, disabled := false, key: niello.Key = 0, loc := #caller_location) -> (changed: bool) {
	lo, hi, step := slider_range(s)
	before := s.value
	// Seek on the pointer only: Space/Enter also press a focused slider.
	if niello.pointer_pressed(s.inst) || niello.dragging(s.inst) {
		if r, ok := niello.rect(s.inst); ok && r.size.x > 0 {
			s.value = lo + clamp(niello.drag_pos(s.inst).x / r.size.x, 0, 1) * (hi - lo)
		}
	}
	for ev in niello.input_keys(s.inst) {
		if !ev.down {
			continue
		}
		#partial switch ev.key {
		case .Left, .Down:  s.value -= step
		case .Right, .Up:   s.value += step
		case .Page_Down:    s.value -= 10 * step
		case .Page_Up:      s.value += 10 * step
		case .Home:         s.value = lo
		case .End:          s.value = hi
		}
	}
	s.value = clamp(s.value, lo, hi)
	changed = s.value != before

	P := &parts.slider
	w := with_a11y({}, .Slider, label, disabled)
	w.value = niello.A11y_Value{num = s.value, has_num = true, min = lo, max = hi}
	if niello.begin(P.track, w, key = key, out = &s.inst, loc = loc) {
		frac := (s.value - lo) / (hi - lo)
		niello.show(P.fill, {size = niello.size(niello.percent(frac), niello.percent(1))})
	}
	return
}

// progress_bar declares a bar filled to value (0..1), labelled label for
// accessibility. a11y: ProgressBar, valued 0..100.
progress_bar :: proc(value: f32, label: string, key: niello.Key = 0, loc := #caller_location) {
	P := &parts.slider
	v := clamp(value, 0, 1)
	w := with_a11y({}, .ProgressBar, label, false)
	w.value = niello.A11y_Value{num = v * 100, has_num = true, min = 0, max = 100}
	w.focusable = false
	if niello.begin(P.track, w, key = key, loc = loc) {
		niello.show(P.progress_fill, {size = niello.size(niello.percent(v), niello.percent(1))})
	}
}
