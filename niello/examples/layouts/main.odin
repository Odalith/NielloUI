// niello/examples/layouts — a gallery of the layout primitives.
//
// One window, six labeled sections: rows, columns, grow splits, percent,
// nesting, stack, and alignment. Every box carries a centered label saying
// what it is, and the sizing in its mint below is what produces it — resize
// the window and watch the Grow boxes absorb the change.
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md):
//
//	odin run niello/examples/layouts
package main

import niello "../.."
import niello_sdl "../../sdl"

// Shared text units: one unit, many instances (distinguished by key),
// each instance carrying its own text via With.
title_u: niello.Unit // window title
hdr_u:   niello.Unit // section headers
lbl_u:   niello.Unit // box labels

// Demo bands and boxes, minted once.
window_u:               niello.Unit
row1, row2, row3, row4: niello.Unit
col1, colA, colB:       niello.Unit
stack1:                 niello.Unit
b_fixed, b_fit, b_grow: niello.Unit
g1, g2, pc:             niello.Unit
c_fixed, c_fit, c_grow: niello.Unit
a1, a2:                 niello.Unit
bb1, bb2, bb3:          niello.Unit
back, front, mid:       niello.Unit

BAND  :: niello.Color{36, 40, 50, 255}
BLUE  :: niello.Color{72, 96, 148, 255}
TEAL  :: niello.Color{52, 124, 112, 255}
PLUM  :: niello.Color{128, 76, 118, 255}
RUST  :: niello.Color{156, 94, 60, 255}
OLIVE :: niello.Color{112, 124, 62, 255}
SLATE :: niello.Color{86, 104, 128, 255}
ROSE  :: niello.Color{148, 76, 84, 255}

// A box is a small container holding one centered label.
mint_box :: proc(out: ^niello.Unit, color: niello.Color, size: niello.Size) {
	niello.mint(out, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		align   = niello.CENTER,
		color   = color,
		size    = size,
		padding = niello.pad_xy(8, 4),
	})
}

mint_units :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		color   = niello.rgb(0x181a22),
		padding = niello.pad(18),
		gap     = 10,
	})
	niello.mint(&title_u, niello.NO_UNIT, {
		font_size  = 22,
		font_color = niello.rgb(0xf0f0f5),
	})
	niello.mint(&hdr_u, niello.NO_UNIT, {
		font_size  = 13,
		font_color = niello.rgb(0x969caa),
	})
	niello.mint(&lbl_u, niello.NO_UNIT, {
		font_size  = 13,
		font_color = niello.rgb(0xe8eaf0),
	})

	// Section 1: a row of Fixed / Fit / Grow.
	niello.mint(&row1, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.size(niello.grow(), niello.fixed(52)),
		gap    = 8,
	})
	mint_box(&b_fixed, BLUE, niello.size(niello.fixed(120), niello.grow()))
	mint_box(&b_fit, TEAL, niello.size(niello.fit(), niello.grow()))
	mint_box(&b_grow, PLUM, niello.size(niello.grow(), niello.grow()))

	// Section 2: a row split by Grow, plus a Percent box.
	niello.mint(&row2, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.size(niello.grow(), niello.fixed(52)),
		gap    = 8,
	})
	mint_box(&g1, OLIVE, niello.size(niello.grow(), niello.grow()))
	mint_box(&g2, SLATE, niello.size(niello.grow(), niello.grow()))
	mint_box(&pc, RUST, niello.size(niello.percent(0.25), niello.grow()))

	// Section 3: a column inside a fixed-height band.
	niello.mint(&col1, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		size    = niello.size(niello.grow(), niello.fixed(140)),
		color   = BAND,
		padding = niello.pad(10),
		gap     = 6,
	})
	mint_box(&c_fixed, BLUE, niello.size(niello.grow(), niello.fixed(30)))
	mint_box(&c_fit, TEAL, niello.size(niello.grow(), niello.fit()))
	mint_box(&c_grow, PLUM, niello.size(niello.grow(), niello.grow()))

	// Section 4: nesting — a row of two columns.
	niello.mint(&row3, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.size(niello.grow(), niello.fixed(116)),
		gap    = 8,
	})
	niello.mint(&colA, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		size    = niello.size(niello.grow(), niello.grow()),
		color   = BAND,
		padding = niello.pad(8),
		gap     = 6,
	})
	niello.mint(&colB, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		size    = niello.size(niello.grow(), niello.grow()),
		color   = BAND,
		padding = niello.pad(8),
		gap     = 6,
	})
	mint_box(&a1, BLUE, niello.size(niello.grow(), niello.grow()))
	mint_box(&a2, TEAL, niello.size(niello.grow(), niello.grow()))
	mint_box(&bb1, SLATE, niello.size(niello.grow(), niello.fixed(26)))
	mint_box(&bb2, OLIVE, niello.size(niello.grow(), niello.grow()))
	mint_box(&bb3, ROSE, niello.size(niello.grow(), niello.fixed(26)))

	// Section 5: a stack — children overlap, resolved against the full box.
	niello.mint(&stack1, niello.NO_UNIT, {
		layout  = .Stack,
		align   = niello.align(.End, .End),
		size    = niello.size(niello.grow(), niello.fixed(96)),
		color   = BAND,
		padding = niello.pad(10),
	})
	mint_box(&back, SLATE, niello.size(niello.grow(), niello.grow()))
	mint_box(&front, RUST, niello.size(niello.fixed(230), niello.fixed(44)))

	// Section 6: alignment — one small box centered in a wide row.
	niello.mint(&row4, niello.NO_UNIT, {
		layout  = .Left_To_Right,
		align   = niello.CENTER,
		size    = niello.size(niello.grow(), niello.fixed(64)),
		color   = BAND,
		padding = niello.pad(10),
	})
	mint_box(&mid, PLUM, niello.size(niello.fixed(190), niello.fixed(38)))
}

// A label centered in its box (the box's align does the centering).
box :: proc(u: niello.Unit, text: string, loc := #caller_location) {
	if niello.begin(u, loc = loc) {
		niello.show(lbl_u, {text = text})
	}
}

hdr :: proc(text: string, loc := #caller_location) {
	niello.show(hdr_u, {text = text}, loc = loc)
}

declare :: proc() {
	if niello.begin(window_u) {
		niello.show(title_u, {text = "Layout gallery — NielloUI"})

		hdr("1 · Row (Left_To_Right) — Fixed, Fit, Grow")
		if niello.begin(row1) {
			box(b_fixed, "Fixed 120")
			box(b_fit, "Fit")
			box(b_grow, "Grow — takes what's left")
		}

		hdr("2 · Row — Grow split and Percent")
		if niello.begin(row2) {
			box(g1, "Grow")
			box(g2, "Grow")
			box(pc, "Percent 25%")
		}

		hdr("3 · Column (Top_To_Bottom) in a fixed-height band")
		if niello.begin(col1) {
			box(c_fixed, "Fixed 30")
			box(c_fit, "Fit")
			box(c_grow, "Grow — fills the band")
		}

		hdr("4 · Nesting — a Row of two Columns")
		if niello.begin(row3) {
			if niello.begin(colA) {
				box(a1, "A1 (Grow)")
				box(a2, "A2 (Grow)")
			}
			if niello.begin(colB) {
				box(bb1, "B1 (Fixed)")
				box(bb2, "B2 (Grow)")
				box(bb3, "B3 (Fixed)")
			}
		}

		hdr("5 · Stack — children overlap, each resolved against the full box")
		if niello.begin(stack1) {
			box(back, "Back (Grow)")
			box(front, "Front (Fixed, End-aligned)")
		}

		hdr("6 · Alignment — Align Center / Center")
		if niello.begin(row4) {
			box(mid, "Centered")
		}
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "NielloUI — Layout gallery", width = 880, height = 820}, declare)
}
