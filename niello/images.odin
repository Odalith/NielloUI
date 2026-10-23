package niello

import "core:os"

// ============ images (§3.25, TODO #13) ============
//
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

Image :: distinct u32
NO_IMAGE :: Image(0)

// How an image paints inside a box whose aspect differs from its
// own (Avalonia's Stretch). The box itself stays axis-independent;
// this is paint-time math only (aspect-coupled sizing is TODO #40).
Image_Fit :: enum u8 {
	Uniform,      // fit inside, aspect preserved (letterbox)
	Fill,         // fill the box, aspect distorted
	Uniform_Fill, // fill the box, aspect preserved (crop)
	None,         // natural size, centered, clipped by the box
}

// Sampling quality at draw (Avalonia's BitmapInterpolationMode).
// High is the zero value on purpose: bare linear sampling
// downscales poorly, so the default is the good one.
Image_Interp :: enum u8 {
	High,   // cubic resampling + mipmaps
	Medium, // linear + mipmaps
	Low,    // linear, no mipmaps
	None,   // nearest neighbour (pixel art, exact icons)
}

// The backend seam, set by the glue at startup (the
// measure_word_hook pattern — the core never links the backend,
// and tests install fakes):
//
//   decode: encoded bytes (+ optional decode-to size; one of
//     max_w/max_h may be 0 = derive from aspect) -> backend id and
//     the decoded DIP size; ok=false for undecodable bytes.
//   release: drop the backend image for an id.
decode_image_hook: proc(data: []byte, max_w, max_h: int) -> (backend: u32, w, h: f32, ok: bool)
release_image_hook: proc(backend: u32)

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
	if !ok || backend == 0 || w <= 0 || h <= 0 {
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
// (Avalonia's CroppedBitmap — composition, not a style field).
// r is in img's own DIP space; it clamps to img's bounds. The
// derivative shares img's backend image and keeps it alive.
image_cropped :: proc(img: Image, r: Rect) -> (Image, bool) {
	rec, ok := image_rec(img)
	if !ok {
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
