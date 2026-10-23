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
//	odin run niello/examples/images -extra-linker-flags:"-L..."
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
	niello.mint(&row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fit()},
		gap    = 10,
	})
	niello.mint(&col_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		size   = niello.Size{niello.fit(), niello.fit()},
		gap    = 6,
	})
	// The four fit-mode boxes: one shape, one fit each.
	fits := [4]niello.Image_Fit{.Uniform, .Fill, .Uniform_Fill, .None}
	for u, i in ([]^niello.Unit{&fit_uniform, &fit_fill, &fit_ufill, &fit_none}) {
		fit := fits[i]
		niello.mint(u, niello.NO_UNIT, {
			size      = niello.Size{niello.fixed(196), niello.fixed(130)},
			color     = BAND,
			image_fit = fit,
		})
	}
	niello.mint(&thumb_u, niello.NO_UNIT, {
		size  = niello.Size{niello.grow(), niello.fixed(56)},
		color = BAND,
	})
	niello.mint(&bg_u, niello.NO_UNIT, {
		layout    = niello.Layout.Top_To_Bottom,
		align     = [2]niello.Align_Kind{.Center, .Center},
		size      = niello.Size{niello.grow(), niello.fixed(150)},
		image_fit = niello.Image_Fit.Uniform_Fill,
	})
	niello.mint(&interp_hi, niello.NO_UNIT, {
		size         = niello.Size{niello.fixed(150), niello.fixed(150)},
		image_interp = niello.Image_Interp.High,
	})
	niello.mint(&interp_no, niello.NO_UNIT, {
		size         = niello.Size{niello.fixed(150), niello.fixed(150)},
		image_interp = niello.Image_Interp.None,
	})
}

hdr :: proc(key, text: string) {
	niello.show(hdr_u, niello.key(key), {text = text})
}

fit_cell :: proc(u: niello.Unit, key, caption: string) {
	if _, ok := niello.begin(col_u, niello.key(key)); ok {
		niello.show(u, niello.key(key), {image = hero})
		niello.show(lbl_u, niello.key(key), {text = caption})
	}
}

declare :: proc() {
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u, niello.key("title"), {text = "Images — NielloUI"})

		hdr("h1", "Fit modes — the 480x320 pattern in 196x130 boxes")
		if _, ok := niello.begin(row_u, niello.key("fits")); ok {
			fit_cell(fit_uniform, "c1", "Uniform (letterbox)")
			fit_cell(fit_fill, "c2", "Fill (distort)")
			fit_cell(fit_ufill, "c3", "Uniform_Fill (crop)")
			fit_cell(fit_none, "c4", "None (natural, clipped)")
		}

		hdr("h2", "One unit, per-instance images (With.image) — full, crop, decode-to-120")
		if _, ok := niello.begin(col_u, niello.key("rows")); ok {
			niello.show(thumb_u, niello.key("r1"), {image = hero})
			niello.show(thumb_u, niello.key("r2"), {image = hero_crop})
			niello.show(thumb_u, niello.key("r3"), {image = hero_tiny})
		}

		hdr("h3", "Interpolation — the 120x120 checkerboard crop, upscaled: cubic vs nearest")
		if _, ok := niello.begin(row_u, niello.key("interp")); ok {
			niello.show(interp_hi, niello.key("hi"), {image = hero_crop})
			niello.show(interp_no, niello.key("no"), {image = hero_crop})
		}

		hdr("h4", "Background image — a container with text over it")
		if _, ok := niello.begin(bg_u, niello.key("bg"), {image = hero}); ok {
			niello.show(lbl_u, niello.key("bgt"), {text = "painted by the container, behind its children"})
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
