// Text demo: the rich-text span system (Text_Span) in one window.
// Text itself is per-instance content (With.text); spans are
// byte-range style overrides that ride along with it.
//
//   - Style spans: a unit carries a static []Text_Span (bold, color,
//     italic, size runs inside one string).
//   - span_bytes: spans are BYTE ranges, but nobody counts bytes by
//     hand — span_bytes converts rune indices, which is what you
//     actually have when authoring ("café ☕" below has multibyte
//     characters before the styled word).
//   - With.text_spans: a per-instance span list REPLACES the unit's
//     list wholesale (same string, different styling per instance).
//   - Wrapping: spans are measurement/shaping boundaries; a wrapped
//     paragraph keeps its per-run styling line by line.
//   - Truncation: a no-wrap line in a narrow box ellipsizes at paint
//     time, cutting cleanly through styled runs.
//   - Overlap: where spans overlap, the later span wins.
package main

import niello "../.."
import niello_sdl "../../sdl"

BG :: niello.Color{24, 25, 32, 255}
CARD :: niello.Color{38, 41, 54, 255}
INK :: niello.Color{232, 234, 240, 255}
DIM :: niello.Color{150, 154, 168, 255}
ACCENT :: niello.Color{120, 170, 255, 255}
WARM :: niello.Color{240, 170, 90, 255}
COOL :: niello.Color{120, 220, 170, 255}

// The demo strings live at package level: mint() needs them for
// span_bytes math, declare() needs them for With.text.
LINE1 :: "Spans style a run inside one string"
LINE2 :: "Le café ☕ serves bold ideas daily"
LINE3 :: "Wrapped text keeps every run's style as lines break: a bold claim, a warm aside, one LARGE word, and an italic tail that carries the sentence home."
LINE4 :: "A long styled sentence that cannot fit the box it was given"
LINE5 :: "Overlap: later wins here"

window_u, title_u, head_u, card_u, body_u: niello.Unit
spanned_u, cafe_u, wrap_u, clip_u, overlap_u, narrow_u, clipbox_u: niello.Unit

// Built once in mint(): a slice literal returned from a proc would
// allocate on every declare.
override_spans: []niello.Text_Span

mint :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = BG, padding = [4]u16{24, 24, 24, 24}, gap = 16,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 22, font_color = INK})
	niello.mint(&head_u, niello.NO_UNIT, {font_size = 13, font_color = DIM})
	niello.mint(&card_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = CARD, corner_radius = 8, padding = [4]u16{14, 12, 14, 12}, gap = 8,
	})
	niello.mint(&body_u, niello.NO_UNIT, {font_size = 15, font_color = INK})
	niello.mint(&narrow_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(440), niello.fit()},
	})
	niello.mint(&clipbox_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size = niello.Size{niello.fixed(300), niello.fit()},
	})

	// The per-instance override for the WITH.TEXT_SPANS section:
	// same runs as spanned_u, different choices (built once, here).
	{
		a1, b1 := niello.span_bytes(LINE1, 0, 5)
		a2, b2 := niello.span_bytes(LINE1, 12, 17)
		a3, b3 := niello.span_bytes(LINE1, 29, 35)
		override_spans = []niello.Text_Span{
			{start = a1, end = b1, font_weight = .Bold},
			{start = a2, end = b2, font_color = COOL},
			{start = a3, end = b3, font_weight = .Bold},
		}
	}

	// LINE1: "Spans" bold, "a run" accent color, "string" italic.
	s1, e1 := niello.span_bytes(LINE1, 0, 5)
	s2, e2 := niello.span_bytes(LINE1, 12, 17)
	s3, e3 := niello.span_bytes(LINE1, 29, 35)
	niello.mint(&spanned_u, niello.NO_UNIT, {
		font_size = 15, font_color = INK,
		text_spans = []niello.Text_Span{
			{start = s1, end = e1, font_weight = .Bold},
			{start = s2, end = e2, font_color = ACCENT},
			{start = s3, end = e3, font_slant = .Italic},
		},
	})

	// LINE2: "bold" sits after two multibyte characters (é, ☕).
	// Rune indices 18..22; the byte range is different — span_bytes
	// is the only sane way to get it.
	s4, e4 := niello.span_bytes(LINE2, 17, 21)
	niello.mint(&cafe_u, niello.NO_UNIT, {
		font_size = 15, font_color = INK,
		text_spans = []niello.Text_Span{
			{start = s4, end = e4, font_weight = .Bold, font_color = WARM},
		},
	})

	// LINE3: runs of weight, color, size, and slant in one wrapped
	// paragraph.
	w1s, w1e := niello.span_bytes(LINE3, 53, 65) // "a bold claim"
	w2s, w2e := niello.span_bytes(LINE3, 67, 79) // "a warm aside"
	w3s, w3e := niello.span_bytes(LINE3, 81, 95) // "one LARGE word"
	w4s, w4e := niello.span_bytes(LINE3, 101, 115) // "an italic tail"
	niello.mint(&wrap_u, niello.NO_UNIT, {
		font_size = 15, font_color = INK, wrap = .Word,
		text_spans = []niello.Text_Span{
			{start = w1s, end = w1e, font_weight = .Bold},
			{start = w2s, end = w2e, font_color = WARM},
			{start = w3s, end = w3e, font_size = 22, font_weight = .Bold, font_color = ACCENT},
			{start = w4s, end = w4e, font_slant = .Italic, font_color = COOL},
		},
	})

	// LINE4: spans up front, then a long plain tail the box cuts off.
	c1s, c1e := niello.span_bytes(LINE4, 2, 6) // "long"
	c2s, c2e := niello.span_bytes(LINE4, 7, 13) // "styled"
	niello.mint(&clip_u, niello.NO_UNIT, {
		font_size = 15, font_color = INK,
		text_spans = []niello.Text_Span{
			{start = c1s, end = c1e, font_weight = .Bold, font_color = WARM},
			{start = c2s, end = c2e, font_color = ACCENT},
		},
	})

	// LINE5: "later wins here" — the second span overlaps the first;
	// in the overlap (and beyond) its color governs.
	o1s, o1e := niello.span_bytes(LINE5, 9, 19)
	o2s, o2e := niello.span_bytes(LINE5, 15, 23)
	niello.mint(&overlap_u, niello.NO_UNIT, {
		font_size = 15, font_color = INK,
		text_spans = []niello.Text_Span{
			{start = o1s, end = o1e, font_color = WARM},
			{start = o2s, end = o2e, font_color = COOL, font_weight = .Bold},
		},
	})
}

section :: proc(heading: string, body: proc()) {
	niello.show(head_u, 0, {text = heading})
	if _, open := niello.begin(card_u); open {
		body()
	}
}

declare :: proc() {
	if _, open := niello.begin(window_u); open {
		niello.show(title_u, 0, {text = "Text spans"})
		section("STYLE SPANS — baked into the unit", proc() {
			niello.show(body_u, 0, {text = LINE1})
			niello.show(spanned_u, 0, {text = LINE1})
		})
		section("SPAN_BYTES — rune indices in, byte ranges out", proc() {
			niello.show(cafe_u, 0, {text = LINE2})
		})
		section("WITH.TEXT_SPANS — per-instance override (replaces the list)", proc() {
			niello.show(spanned_u, 0, {text = LINE1, text_spans = override_spans})
		})
		section("WRAPPED — runs survive line breaking", proc() {
			if _, open2 := niello.begin(narrow_u); open2 {
				niello.show(wrap_u, 0, {text = LINE3})
			}
		})
		section("TRUNCATION — the ellipsis cuts through runs", proc() {
			if _, open2 := niello.begin(clipbox_u); open2 {
				niello.show(clip_u, 0, {text = LINE4})
			}
		})
		section("OVERLAP — later span wins", proc() {
			niello.show(overlap_u, 0, {text = LINE5})
		})
	}
}

main :: proc() {
	mint()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "NielloUI — text spans", width = 760, height = 700}, declare)
}
