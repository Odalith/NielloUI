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
//	odin run niello/examples/layouts -extra-linker-flags:"-L..."
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
		align   = [2]niello.Align_Kind{.Center, .Center},
		color   = color,
		size    = size,
		padding = [4]u16{8, 4, 8, 4},
	})
}

mint_units :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		color   = niello.Color{24, 26, 34, 255},
		padding = [4]u16{18, 18, 18, 18},
		gap     = 10,
	})
	niello.mint(&title_u, niello.NO_UNIT, {
		font_size  = 22,
		font_color = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&hdr_u, niello.NO_UNIT, {
		font_size  = 13,
		font_color = niello.Color{150, 156, 170, 255},
	})
	niello.mint(&lbl_u, niello.NO_UNIT, {
		font_size  = 13,
		font_color = niello.Color{232, 234, 240, 255},
	})

	// Section 1: a row of Fixed / Fit / Grow.
	niello.mint(&row1, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(52)},
		gap    = 8,
	})
	mint_box(&b_fixed, BLUE, niello.Size{niello.fixed(120), niello.grow()})
	mint_box(&b_fit, TEAL, niello.Size{niello.fit(), niello.grow()})
	mint_box(&b_grow, PLUM, niello.Size{niello.grow(), niello.grow()})

	// Section 2: a row split by Grow, plus a Percent box.
	niello.mint(&row2, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(52)},
		gap    = 8,
	})
	mint_box(&g1, OLIVE, niello.Size{niello.grow(), niello.grow()})
	mint_box(&g2, SLATE, niello.Size{niello.grow(), niello.grow()})
	mint_box(&pc, RUST, niello.Size{niello.percent(0.25), niello.grow()})

	// Section 3: a column inside a fixed-height band.
	niello.mint(&col1, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		size    = niello.Size{niello.grow(), niello.fixed(140)},
		color   = BAND,
		padding = [4]u16{10, 10, 10, 10},
		gap     = 6,
	})
	mint_box(&c_fixed, BLUE, niello.Size{niello.grow(), niello.fixed(30)})
	mint_box(&c_fit, TEAL, niello.Size{niello.grow(), niello.fit()})
	mint_box(&c_grow, PLUM, niello.Size{niello.grow(), niello.grow()})

	// Section 4: nesting — a row of two columns.
	niello.mint(&row3, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(116)},
		gap    = 8,
	})
	niello.mint(&colA, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		size    = niello.Size{niello.grow(), niello.grow()},
		color   = BAND,
		padding = [4]u16{8, 8, 8, 8},
		gap     = 6,
	})
	niello.mint(&colB, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		size    = niello.Size{niello.grow(), niello.grow()},
		color   = BAND,
		padding = [4]u16{8, 8, 8, 8},
		gap     = 6,
	})
	mint_box(&a1, BLUE, niello.Size{niello.grow(), niello.grow()})
	mint_box(&a2, TEAL, niello.Size{niello.grow(), niello.grow()})
	mint_box(&bb1, SLATE, niello.Size{niello.grow(), niello.fixed(26)})
	mint_box(&bb2, OLIVE, niello.Size{niello.grow(), niello.grow()})
	mint_box(&bb3, ROSE, niello.Size{niello.grow(), niello.fixed(26)})

	// Section 5: a stack — children overlap, resolved against the full box.
	niello.mint(&stack1, niello.NO_UNIT, {
		layout  = .Stack,
		align   = [2]niello.Align_Kind{.End, .End},
		size    = niello.Size{niello.grow(), niello.fixed(96)},
		color   = BAND,
		padding = [4]u16{10, 10, 10, 10},
	})
	mint_box(&back, SLATE, niello.Size{niello.grow(), niello.grow()})
	mint_box(&front, RUST, niello.Size{niello.fixed(230), niello.fixed(44)})

	// Section 6: alignment — one small box centered in a wide row.
	niello.mint(&row4, niello.NO_UNIT, {
		layout  = .Left_To_Right,
		align   = [2]niello.Align_Kind{.Center, .Center},
		size    = niello.Size{niello.grow(), niello.fixed(64)},
		color   = BAND,
		padding = [4]u16{10, 10, 10, 10},
	})
	mint_box(&mid, PLUM, niello.Size{niello.fixed(190), niello.fixed(38)})
}

// A label centered in its box (the box's align does the centering).
box :: proc(u: niello.Unit, key: string, text: string) {
	if _, ok := niello.begin(u, niello.key(key)); ok {
		niello.show(lbl_u, niello.key(key), {text = text})
	}
}

hdr :: proc(key, text: string) {
	niello.show(hdr_u, niello.key(key), {text = text})
}

declare :: proc() {
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u, niello.key("title"), {text = "Layout gallery — NielloUI"})

		hdr("h1", "1 · Row (Left_To_Right) — Fixed, Fit, Grow")
		if _, ok := niello.begin(row1); ok {
			box(b_fixed, "b1", "Fixed 120")
			box(b_fit, "b2", "Fit")
			box(b_grow, "b3", "Grow — takes what's left")
		}

		hdr("h2", "2 · Row — Grow split and Percent")
		if _, ok := niello.begin(row2); ok {
			box(g1, "g1", "Grow")
			box(g2, "g2", "Grow")
			box(pc, "pc", "Percent 25%")
		}

		hdr("h3", "3 · Column (Top_To_Bottom) in a fixed-height band")
		if _, ok := niello.begin(col1); ok {
			box(c_fixed, "c1", "Fixed 30")
			box(c_fit, "c2", "Fit")
			box(c_grow, "c3", "Grow — fills the band")
		}

		hdr("h4", "4 · Nesting — a Row of two Columns")
		if _, ok := niello.begin(row3); ok {
			if _, ok := niello.begin(colA); ok {
				box(a1, "a1", "A1 (Grow)")
				box(a2, "a2", "A2 (Grow)")
			}
			if _, ok := niello.begin(colB); ok {
				box(bb1, "bb1", "B1 (Fixed)")
				box(bb2, "bb2", "B2 (Grow)")
				box(bb3, "bb3", "B3 (Fixed)")
			}
		}

		hdr("h5", "5 · Stack — children overlap, each resolved against the full box")
		if _, ok := niello.begin(stack1); ok {
			box(back, "back", "Back (Grow)")
			box(front, "front", "Front (Fixed, End-aligned)")
		}

		hdr("h6", "6 · Alignment — Align Center / Center")
		if _, ok := niello.begin(row4); ok {
			box(mid, "mid", "Centered")
		}
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "NielloUI — Layout gallery", width = 880, height = 820}, declare)
}
