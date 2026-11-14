package controls

import niello ".."

// ---- tooltip -----------------------------------------------------------------

// Tooltip_Parts: the popup box and its text.
Tooltip_Parts :: struct {
	box, text: niello.Unit,
}

// TOOLTIP_DELAY is how long, in seconds, the pointer rests on a control
// before its tooltip shows.
TOOLTIP_DELAY :: 0.5

// TOOLTIP_MAX_W is a tooltip's widest, in DIP: longer text wraps.
TOOLTIP_MAX_W :: 280

@(private)
mint_tooltip :: proc(t: Theme) {
	P := &parts.tooltip
	niello.mint(&P.box, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = niello.size(niello.fit(max = TOOLTIP_MAX_W), niello.fit()),
		padding = niello.pad_xy(10, 6), corner_radius = 6,
		color = t.raised, border_width = 1, border_color = t.dim,
		group_masks = joins(as(groups.raised, .Color), as(groups.outline, .Border_Color)),
	})
	niello.mint(&P.text, niello.NO_UNIT, {
		font_size = type_sizes.caption, font_color = t.ink, wrap = .Word,
		group_masks = joins(as(groups.ink, .Font_Color), as(groups.caption, .Font_Size)),
	})
}

// tooltip shows text in a small popup below anchor (or at placement)
// once the pointer has rested on anchor for delay seconds, and at once
// while anchor holds keyboard focus that shows (Tab onto it). Declare it
// after anchor, every frame; it shows itself only when due. While the
// pointer rests on anchor the engine keeps frames coming, so the delay
// runs out even when nothing else animates.
//
//	save_i := controls.button("Save")
//	controls.tooltip(save_i, "Save the document (Ctrl+S)")
//
// a11y: the popup is a ToolTip named by text. A screen reader reads
// it when it shows; to have the text read with the control itself, also
// give the control's With a description.
tooltip :: proc(
	anchor: niello.Instance,
	text: string,
	delay: f32 = TOOLTIP_DELAY,
	placement := niello.Placement.Below,
	loc := #caller_location,
) {
	if anchor == 0 || len(text) == 0 {
		return
	}
	if niello.hover_duration(anchor) < delay && !niello.focus_visible(anchor) {
		return
	}
	P := &parts.tooltip
	w := niello.With{role = .ToolTip, label = text}
	if niello.begin_popup(P.box, anchor, placement, w, key = niello.Key(u64(anchor)), opts = {gap = 6, stay = true}, loc = loc) {
		niello.show(P.text, {text = text})
	}
}
