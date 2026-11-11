// niello/examples/images — image support (TODO #13, §3.25).
//
// One test pattern (test.png, embedded with #load) shown every
// way the engine can show it: the four fit modes in fixed boxes,
// per-instance images via With.image in a list, a decode-to-size
// thumbnail, a cropped derivative, a container background image,
// and nearest-vs-cubic interpolation on the checkerboard crop.
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md):
//
//	odin run niello/examples/images
package main

import niello "../.."
import niello_sdl "../../sdl"

TEST_PNG :: #load("test.png")

window_u, row_u, col_u: niello.Unit
title_u, hdr_u, lbl_u:  niello.Unit
fit_uniform, fit_fill, fit_ufill, fit_none: niello.Unit
thumb_u:                niello.Unit // list rows sharing one unit
bg_u:                   niello.Unit // background-image container
interp_hi, interp_no:   niello.Unit

hero:      niello.Image // the full 480x320 decode
hero_crop: niello.Image // the checkerboard crop (120x120)
hero_tiny: niello.Image // a decode-to-width 120 thumbnail (120x80)

DARK :: niello.Color{24, 26, 34, 255}
BAND :: niello.Color{36, 40, 50, 255}

mint_units :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout  = niello.Layout.Top_To_Bottom,
		color   = DARK,
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
	niello.mint(&row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size   = niello.size(niello.grow(), niello.fit()),
		gap    = 10,
	})
	niello.mint(&col_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size   = niello.size(niello.fit(), niello.fit()),
		gap    = 6,
	})
	// The four fit-mode boxes: one shape, one fit each.
	fits := [4]niello.Image_Fit{.Uniform, .Fill, .Uniform_Fill, .None}
	for u, i in ([]^niello.Unit{&fit_uniform, &fit_fill, &fit_ufill, &fit_none}) {
		fit := fits[i]
		niello.mint(u, niello.NO_UNIT, {
			size      = niello.size(niello.fixed(196), niello.fixed(130)),
			color     = BAND,
			image_fit = fit,
			align     = niello.CENTER, // a leaf's align places its image
		})
	}
	niello.mint(&thumb_u, niello.NO_UNIT, {
		size  = niello.size(niello.grow(), niello.fixed(56)),
		color = BAND,
		align = niello.CENTER,
	})
	niello.mint(&bg_u, niello.NO_UNIT, {
		layout    = niello.Layout.Top_To_Bottom,
		align     = niello.CENTER,
		size      = niello.size(niello.grow(), niello.fixed(150)),
		image_fit = niello.Image_Fit.Uniform_Fill,
	})
	niello.mint(&interp_hi, niello.NO_UNIT, {
		size         = niello.size(niello.fixed(150), niello.fixed(150)),
		image_interp = niello.Image_Interp.High,
		align        = niello.CENTER,
	})
	niello.mint(&interp_no, niello.NO_UNIT, {
		size         = niello.size(niello.fixed(150), niello.fixed(150)),
		image_interp = niello.Image_Interp.None,
		align        = niello.CENTER,
	})
}

hdr :: proc(text: string, loc := #caller_location) {
	niello.show(hdr_u, {text = text}, loc = loc)
}

fit_cell :: proc(u: niello.Unit, caption: string, loc := #caller_location) {
	if niello.begin(col_u, loc = loc) {
		niello.show(u, {image = hero})
		niello.show(lbl_u, {text = caption})
	}
}

declare :: proc() {
	if niello.begin(window_u) {
		niello.show(title_u, {text = "Images — NielloUI"})

		hdr("Fit modes — the 480x320 pattern in 196x130 boxes")
		if niello.begin(row_u) {
			fit_cell(fit_uniform, "Uniform (letterbox)")
			fit_cell(fit_fill, "Fill (distort)")
			fit_cell(fit_ufill, "Uniform_Fill (crop)")
			fit_cell(fit_none, "None (natural, clipped)")
		}

		hdr("One unit, per-instance images (With.image) — full, crop, decode-to-120")
		if niello.begin(col_u) {
			niello.show(thumb_u, {image = hero})
			niello.show(thumb_u, {image = hero_crop})
			niello.show(thumb_u, {image = hero_tiny})
		}

		hdr("Interpolation — the 120x120 checkerboard crop, upscaled: cubic vs nearest")
		if niello.begin(row_u) {
			niello.show(interp_hi, {image = hero_crop})
			niello.show(interp_no, {image = hero_crop})
		}

		hdr("Background image — a container with text over it")
		if niello.begin(bg_u, {image = hero}) {
			niello.show(lbl_u, {text = "painted by the container, behind its children"})
		}
	}
}

main :: proc() {
	ok: bool
	hero, ok = niello.image_load_memory(TEST_PNG)
	assert(ok, "test.png failed to decode")
	hero_crop, ok = niello.image_cropped(hero, niello.Rect{{0, 0}, {120, 120}})
	assert(ok, "crop failed")
	hero_tiny, ok = niello.image_load_memory(TEST_PNG, decode_w = 120)
	assert(ok, "thumbnail decode failed")

	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "NielloUI — Images", width = 900, height = 760}, declare)
}
