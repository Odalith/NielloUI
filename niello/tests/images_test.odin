package tests

// Image support (§3.25): registry + crop/release semantics, FIT
// intrinsic sizing, per-instance With.image, and the emit fit
// math — all against a fake decoder hook, no backend involved.

import "core:testing"
import niello ".."

// The fake decoder hands out incrementing backend ids and sizes
// from a queue the test stages; release calls are counted.
@(private)
fake_sizes: [][2]f32
@(private)
fake_idx: int
@(private)
fake_next_backend: u32
@(private)
fake_releases: int
@(private)
fake_last_release: u32
@(private)
fake_fail: bool

@(private)
fake_decode :: proc(data: []byte, max_w, max_h: int) -> (backend: u32, w, h: f32, ok: bool) {
	if fake_fail || len(data) == 0 {
		return 0, 0, 0, false
	}
	fake_next_backend += 1
	s := fake_sizes[min(fake_idx, len(fake_sizes) - 1)]
	fake_idx += 1
	return fake_next_backend, s[0], s[1], true
}

@(private)
fake_release :: proc(backend: u32) {
	fake_releases += 1
	fake_last_release = backend
}

@(private)
fake_install :: proc(sizes: [][2]f32) {
	fake_sizes = sizes
	fake_idx = 0
	fake_next_backend = 100
	fake_releases = 0
	fake_last_release = 0
	fake_fail = false
	niello.decode_image_hook = fake_decode
	niello.release_image_hook = fake_release
}

@(test)
test_image_registry :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()

	// No hook installed: load fails cleanly.
	niello.decode_image_hook = nil
	_, ok0 := niello.image_load_memory([]byte{1, 2, 3})
	testing.expect(t, !ok0, "no decoder -> no image")

	fake_install([][2]f32{{400, 200}})
	img, ok := niello.image_load_memory([]byte{9, 9})
	testing.expect(t, ok && img != niello.NO_IMAGE)
	testing.expect_value(t, niello.image_size(img), niello.Vec2{400, 200})

	// Undecodable bytes fail.
	fake_fail = true
	_, okf := niello.image_load_memory([]byte{1})
	testing.expect(t, !okf, "decoder failure propagates")
	fake_fail = false

	// Unknown handles read as zero and release as no-ops.
	testing.expect_value(t, niello.image_size(niello.Image(999)), niello.Vec2{})
	niello.image_release(niello.Image(999))
	testing.expect_value(t, fake_releases, 0)

	// Release frees the backend exactly once.
	niello.image_release(img)
	testing.expect_value(t, fake_releases, 1)
	testing.expect_value(t, niello.image_size(img), niello.Vec2{})
	niello.image_release(img)
	testing.expect_value(t, fake_releases, 1)
}

@(test)
test_image_crop_and_shared_release :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fake_install([][2]f32{{400, 200}})

	img, _ := niello.image_load_memory([]byte{1})
	crop, ok := niello.image_cropped(img, niello.Rect{{50, 25}, {100, 50}})
	testing.expect(t, ok)
	testing.expect_value(t, niello.image_size(crop), niello.Vec2{100, 50})

	// A crop of a crop composes in the root's space — verified
	// through the emitted command's source rect.
	sub, ok2 := niello.image_cropped(crop, niello.Rect{{10, 5}, {40, 20}})
	testing.expect(t, ok2)
	{
		ctx := niello.test_context()
		niello.mint(&img_box, niello.NO_UNIT, {
			size = niello.Size{niello.fixed(40), niello.fixed(20)},
			image = sub,
		})
		niello.frame_begin(ctx, niello.Input{viewport = {800, 600}}, 0.016)
		niello.show(img_box)
		niello.frame_end()
		cmd, found := find_image_cmd()
		testing.expect(t, found)
		if found {
			testing.expect_value(t, cmd.image, u32(101))
			testing.expect_value(t, cmd.src_rect, [4]f32{60, 30, 40, 20})
		}
	}

	// Clamping: a rect hanging off the edge shrinks; an empty
	// intersection fails.
	edge, ok3 := niello.image_cropped(img, niello.Rect{{390, 190}, {50, 50}})
	testing.expect(t, ok3)
	testing.expect_value(t, niello.image_size(edge), niello.Vec2{10, 10})
	_, ok4 := niello.image_cropped(img, niello.Rect{{500, 0}, {10, 10}})
	testing.expect(t, !ok4, "fully outside -> no image")

	// The backend image survives until the LAST entry releases.
	niello.image_release(img)
	testing.expect_value(t, fake_releases, 0)
	niello.image_release(crop)
	niello.image_release(sub)
	testing.expect_value(t, fake_releases, 0)
	niello.image_release(edge)
	testing.expect_value(t, fake_releases, 1)
	testing.expect_value(t, fake_last_release, u32(101))
}

@(private)
img_leaf, img_row: niello.Unit

@(test)
test_image_intrinsic_and_with :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fake_install([][2]f32{{400, 200}, {100, 50}})
	ctx := niello.test_context()

	big, _ := niello.image_load_memory([]byte{1})
	small, _ := niello.image_load_memory([]byte{2})

	// A FIT leaf takes the image's size exactly. (Padding does
	// not inflate a leaf's fit — the text-leaf rule; padding is
	// a container concept here.) Shown inside a root row: a FIT
	// root would fill the viewport instead (the Fit-root rule).
	niello.mint(&img_leaf, niello.NO_UNIT, {
		size = niello.Size{niello.fit(), niello.fit()},
		padding = [4]u16{10, 10, 10, 10},
		image = big,
	})
	niello.mint(&img_row, niello.NO_UNIT, {layout = niello.Layout.Left_To_Right})
	niello.frame_begin(ctx, niello.Input{viewport = {800, 600}}, 0.016)
	inst: niello.Instance
	if _, open := niello.begin(img_row); open {
		inst = niello.show(img_leaf)
	}
	niello.frame_end()
	r, rok := niello.rect(inst)
	testing.expect(t, rok)
	testing.expect_value(t, r.size, niello.Vec2{400, 200})

	// Per-instance swap: two instances of one unit, different
	// images via With — each FITs its own image.
	niello.frame_begin(ctx, niello.Input{viewport = {800, 600}}, 0.016)
	ia, ib: niello.Instance
	if _, open := niello.begin(img_row); open {
		ia = niello.show(img_leaf, niello.key("a"))
		ib = niello.show(img_leaf, niello.key("b"), {image = small})
	}
	niello.frame_end()
	ra, _ := niello.rect(ia)
	rb, _ := niello.rect(ib)
	testing.expect_value(t, ra.size, niello.Vec2{400, 200})
	testing.expect_value(t, rb.size, niello.Vec2{100, 50})
}

@(private)
find_image_cmd :: proc() -> (niello.Draw_Cmd, bool) {
	for cmd in niello.draw_list() {
		if cmd.tag == .Image {
			return cmd, true
		}
	}
	return {}, false
}

@(private)
img_box: niello.Unit

// Stage one fixed 100x100 box carrying img with the given fit.
@(test)
test_image_emit_fit_math :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fake_install([][2]f32{{400, 200}})
	ctx := niello.test_context()
	img, _ := niello.image_load_memory([]byte{1})

	cases := []struct {
		fit:        niello.Image_Fit,
		dest, src:  niello.Rect,
	}{
		// 400x200 into a 100x100 box.
		{.Uniform, {{0, 25}, {100, 50}}, {{0, 0}, {400, 200}}},
		{.Uniform_Fill, {{0, 0}, {100, 100}}, {{100, 0}, {200, 200}}},
		{.Fill, {{0, 0}, {100, 100}}, {{0, 0}, {400, 200}}},
		{.None, {{0, 0}, {100, 100}}, {{150, 50}, {100, 100}}},
	}
	for c in cases {
		niello.mint(&img_box, niello.NO_UNIT, {
			size = niello.Size{niello.fixed(100), niello.fixed(100)},
			image_fit = c.fit,
		})
		niello.frame_begin(ctx, niello.Input{viewport = {800, 600}}, 0.016)
		niello.show(img_box, niello.key("only"), {image = img})
		niello.frame_end()
		cmd, found := find_image_cmd()
		testing.expect(t, found, "image command emitted")
		if found {
			testing.expect_value(t, cmd.bounds, c.dest)
			testing.expect_value(t, niello.Rect{{cmd.src_rect[0], cmd.src_rect[1]}, {cmd.src_rect[2], cmd.src_rect[3]}}, c.src)
			testing.expect_value(t, cmd.image, u32(101))
			testing.expect_value(t, cmd.interp, u8(0)) // .High
		}
		niello.test_reset()
		ctx = niello.test_context()
		fake_install([][2]f32{{400, 200}})
		img, _ = niello.image_load_memory([]byte{1})
	}

	// A released image emits nothing.
	niello.mint(&img_box, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(100), niello.fixed(100)},
	})
	niello.frame_begin(ctx, niello.Input{viewport = {800, 600}}, 0.016)
	niello.show(img_box, niello.key("only"), {image = img})
	niello.frame_end()
	_, found := find_image_cmd()
	testing.expect(t, found)
	niello.image_release(img)
	niello.frame_begin(ctx, niello.Input{viewport = {800, 600}}, 0.016)
	niello.show(img_box, niello.key("only"), {image = img})
	niello.frame_end()
	_, found = find_image_cmd()
	testing.expect(t, !found, "released image draws nothing")
}

@(test)
test_image_swap_damages :: proc(t: ^testing.T) {
	niello.test_reset()
	defer niello.test_teardown()
	fake_install([][2]f32{{400, 200}, {100, 50}})
	ctx := niello.test_context()
	a, _ := niello.image_load_memory([]byte{1})
	b, _ := niello.image_load_memory([]byte{2})

	niello.mint(&img_box, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(100), niello.fixed(100)},
	})
	frame :: proc(ctx: ^niello.Context, img: niello.Image) -> bool {
		niello.frame_begin(ctx, niello.Input{viewport = {800, 600}}, 0.016)
		niello.show(img_box, niello.key("only"), {image = img})
		return niello.frame_end().changed
	}
	_ = frame(ctx, a) // settle
	testing.expect(t, !frame(ctx, a), "same image: no damage")
	testing.expect(t, frame(ctx, b), "swapped image: damage")
	testing.expect(t, !frame(ctx, b), "settled again")
}
