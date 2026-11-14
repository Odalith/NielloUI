package niello

import "core:os"

// ============ images (§3.25, TODO #13) ============

// An image is node content, like text: a Style carries an Image
// handle plus fit/interp modes, and a With can swap the handle per
// instance. Avalonia's shape (IImage / Bitmap / Image control),
// expressed with this engine's mechanisms — handles and a registry,
// the same pattern as font families.
//
// Where an image lives, frame to frame — nowhere in the frame:
//   - the handle (a u32) sits in Style/With as plain data;
//   - the global store holds a registry entry per image: DIP size,
//     crop, backend id (one load draws in any context);
//   - the backend holds the decoded image under that id (a
//     refcounted SkImage over the encoded bytes; GPU textures
//     upload lazily and are cache-managed by Graphite).
// Draw commands are rebuilt per frame and carry only the id.
//
// Ids are allocated monotonically and NEVER reused within a
// session, so a stale handle in a style can never silently alias
// a different image — it just draws nothing.

// Image is a loaded image: content an instance shows like text (Style.image,
// With.image). Load one with image_load or image_load_memory; free it with
// image_release. A released image's handle is never reused: it draws
// nothing.
Image :: distinct u32

// NO_IMAGE is the null image: no image.
NO_IMAGE :: Image(0)

// Image_Fit is how an image fills a box whose proportions differ from its
// own. It affects drawing only, not the box's size.
Image_Fit :: enum u8 {
	Uniform,      // fit inside, aspect preserved (letterbox)
	Fill,         // fill the box, aspect distorted
	Uniform_Fill, // fill the box, aspect preserved (crop)
	None,         // natural size, centered, clipped by the box
}

// Image_Interp is the sampling quality when an image is scaled. High, the
// default, also scales down well.
Image_Interp :: enum u8 {
	High,   // cubic resampling + mipmaps
	Medium, // linear + mipmaps
	Low,    // linear, no mipmaps
	None,   // nearest neighbour (pixel art, exact icons)
}

// decode_image_hook is how a host decodes images for the core (niello/sdl
// sets it when it is imported; tests install fakes). It decodes encoded
// bytes, optionally to a size (max_w or max_h may be 0: derive it from
// the aspect), and returns the host's id for the image and its size in
// DIP; ok is false for bytes it cannot decode.
decode_image_hook: proc(data: []byte, max_w, max_h: int) -> (backend: u32, w, h: f32, ok: bool)

// release_image_hook frees the host's image for an id decode_image_hook
// returned.
release_image_hook: proc(backend: u32)

// dim_ok is the boundary check for backend-reported dimensions:
// every comparison against NaN is false, so the
// naive w <= 0 guard waves a NaN hook result straight into the
// registry — and from there into layout, where it manufactures
// NaN src-rects that make native validation reject the whole
// frame. Finite, positive, and under a generous ceiling (the
// check exists to reject garbage, not to police real images).
@(private)
dim_ok :: proc(v: f32) -> bool {
	return v > 0 && v <= 65536
}

@(private)
Image_Rec :: struct {
	backend: u32,     // backend id; shared by a crop family
	size:    Vec2,    // DIP size of THIS entry (the crop size for crops)
	crop:    [4]f32,  // absolute source rect in the root image's space (x, y, w, h)
	alive:   bool,
}

// image_load reads a file and decodes it. decode_w/decode_h ask
// the decoder for a smaller decode (memory); one may be 0 to keep
// aspect. The returned size is the decoded size.
image_load :: proc(path: string, decode_w: int = 0, decode_h: int = 0) -> (Image, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return NO_IMAGE, false
	}
	defer delete(data)
	return image_load_memory(data, decode_w, decode_h)
}

// image_load_memory decodes encoded bytes (PNG/JPEG/WebP/... —
// whatever the backend's codec accepts). Embedded assets ride
// Odin's #load: image_load_memory(#load("hero.png")).
image_load_memory :: proc(data: []byte, decode_w: int = 0, decode_h: int = 0) -> (Image, bool) {
	if decode_image_hook == nil || len(data) == 0 {
		return NO_IMAGE, false
	}
	backend, w, h, ok := decode_image_hook(data, decode_w, decode_h)
	if !ok || backend == 0 || !dim_ok(w) || !dim_ok(h) {
		return NO_IMAGE, false
	}
	if len(store.images) == 0 {
		append(&store.images, Image_Rec{}) // slot 0: NO_IMAGE sentinel
	}
	img := Image(len(store.images))
	append(&store.images, Image_Rec{
		backend = backend,
		size = {w, h},
		crop = {0, 0, w, h},
		alive = true,
	})
	return img, true
}

// image_size is the entry's DIP size, captured at load/crop time;
// layout reads this, never the backend. Zero for unknown/released.
image_size :: proc(img: Image) -> Vec2 {
	rec, ok := image_rec(img)
	if !ok {
		return {}
	}
	return rec.size
}

// image_cropped derives a new Image showing a sub-rect of img
// (a separate image, not a style field).
// r is in img's own DIP space; it clamps to img's bounds. The
// derivative shares img's backend image and keeps it alive.
image_cropped :: proc(img: Image, r: Rect) -> (Image, bool) {
	rec, ok := image_rec(img)
	if !ok {
		return NO_IMAGE, false
	}
	// A NaN rect component would otherwise be silently discarded
	// by the min/max clamps below into a wrong-but-plausible crop:
	// reject non-finite input at the boundary.
	if !(r.pos.x == r.pos.x && r.pos.y == r.pos.y &&
	   r.size.x == r.size.x && r.size.y == r.size.y) {
		return NO_IMAGE, false
	}
	x0 := max(r.pos.x, 0)
	y0 := max(r.pos.y, 0)
	x1 := min(r.pos.x + r.size.x, rec.size.x)
	y1 := min(r.pos.y + r.size.y, rec.size.y)
	if x1 <= x0 || y1 <= y0 {
		return NO_IMAGE, false
	}
	out := Image(len(store.images))
	append(&store.images, Image_Rec{
		backend = rec.backend,
		size = {x1 - x0, y1 - y0},
		crop = {rec.crop[0] + x0, rec.crop[1] + y0, x1 - x0, y1 - y0},
		alive = true,
	})
	return out, true
}

// image_release frees the backend image once its last registry
// entry (the image or any crop of it) is released. Safe at any
// time: renders consume draw lists synchronously and retain
// nothing, and a handle no longer known draws nothing.
image_release :: proc(img: Image) {
	rec, ok := image_rec(img)
	if !ok {
		return
	}
	backend := rec.backend
	store.images[int(img)].alive = false
	for other in store.images {
		if other.alive && other.backend == backend {
			return // a crop (or the root) still holds it
		}
	}
	if release_image_hook != nil {
		release_image_hook(backend)
	}
}

@(private)
image_rec :: proc(img: Image) -> (^Image_Rec, bool) {
	if int(img) <= 0 || int(img) >= len(store.images) {
		return nil, false
	}
	rec := &store.images[int(img)]
	if !rec.alive {
		return nil, false
	}
	return rec, true
}

// Layout's read: a node's intrinsic image size.
@(private)
image_intrinsic :: proc(img: Image) -> (Vec2, bool) {
	rec, ok := image_rec(img)
	if !ok {
		return {}, false
	}
	return rec.size, true
}

// Render's read: backend id + absolute source rect for a handle.
@(private)
image_paint_info :: proc(img: Image) -> (backend: u32, crop: [4]f32, ok: bool) {
	rec, rok := image_rec(img)
	if !rok {
		return 0, {}, false
	}
	return rec.backend, rec.crop, true
}
