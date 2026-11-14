package controls

import niello ".."

// ---- field ---------------------------------------------------------------

// Field_Parts: a field's box (a column: its caption above its control) and
// the caption.
Field_Parts :: struct {
	box, caption: niello.Unit,
}

@(private)
mint_field :: proc(t: Theme) {
	P := &parts.field
	// It takes the width it is given, so a control that grows (a slider,
	// a text box) has room to; one with a width of its own keeps it.
	niello.mint(&P.box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.grow(), niello.fit()), gap = 4,
	})
	niello.mint(&P.caption, niello.NO_UNIT, {
		font_size = type_sizes.caption, font_color = t.dim, wrap = .Word,
		group_masks = joins(as(groups.dim, .Font_Color), as(groups.caption, .Font_Size)),
	})
}

// field is a captioned control: caption above whatever its block declares
// (a combo box, a slider, a text box), close beneath it. Write it as an
// if-initializer, like niello.begin:
//
//	if controls.field("Language") {
//		controls.combo_box(&app.lang, LANGS, label = "Language")
//	}
//
// The caption is only drawn. Name the control as well (its label): a
// screen reader announces the control, not the text above it. with carries
// per-instance values for the field's box (a size, to line fields up).
@(deferred_out = field_end)
field :: proc(caption: string, with: niello.With = {}, key: niello.Key = 0, loc := #caller_location) -> (open: bool) {
	P := &parts.field
	open = niello.open_container(P.box, with, key = key, loc = loc)
	if open && len(caption) > 0 {
		// The caller's loc: a report on the caption points at the
		// field's line. (Its site is distinct within the field's box:
		// the block's own calls sit at other columns or lines.)
		niello.show(P.caption, {text = caption}, loc = loc)
	}
	return
}

@(private)
field_end :: proc(open: bool) {
	niello.end(open)
}
