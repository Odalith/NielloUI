// niello/examples/image_soak — memory-leak soak for image support.
//
// TODO #13 VERIFICATION OWED: "test images/media, to make sure that there
// are no memory leaks." This is the harness for that test.
//
// Each cycle: load a full decode, a decode-to-size thumbnail, and a crop
// family (two crops sharing one backend image); attempt two garbage
// decodes (must fail clean, no backend image); DRAW everything for
// DRAW_FRAMES frames — frames matter, the GPU texture uploads lazily on
// first draw; then release every handle. Release order alternates per
// cycle to hit both refcount paths (root-first vs crops-first). Cycle 0
// is warmup (Dawn/atlas one-time costs) and is discarded; cycles 1..N
// are measured. The verdict — max RSS drift vs the first measured
// cycle — prints to stdout per cycle and shows on screen at the end;
// close the window to quit.
//
// The per-frame status text changes every frame, which keeps the frame
// loop pumping (a fully static scene would idle at ~0% CPU and the soak
// would never advance).
//
// What it watches, per the TODO entry:
//   - process RSS per cycle (Linux /proc/self/status VmRSS) — the
//     headline number; must stay flat after warmup.
//   - the crop-family refcount: the backend drops its image only when
//     the last registry entry sharing the backend id releases — the
//     alternating release order catches an off-by-one either way
//     (leak or premature free).
//   - the Graphite cache: purged before each measurement; its
//     post-purge byte count is printed per cycle and at the verdict.
//   - registry liveness: every handle ever created must read back as
//     released at the end (image_size == zero); a stale alive entry
//     would be a real leak of the pinned raster below.
// Backend reality (from nui.cpp): natural-size decodes are NOT
// deferred — the codec's native format (e.g. RGB_888x) can't be
// texturized by Graphite/Dawn, so decode pins N32 raster pixels per
// backend image and the GPU texture uploads at first draw through
// TextureFromImage. So a leaked backend id pins a full raster, and a
// leaked Graphite texture is only *purgeable* until eviction — which
// is why RSS alone can cry wolf on cache residency (see below).
//
// Graphite's resource-cache bytes are watched too, through the
// backend's diagnostics (nui_gpu_cache_bytes / nui_purge_gpu_cache):
// each cycle purges every purgeable resource BEFORE measuring, so
// what remains in RSS and in the cache count is residency the cache
// chose to keep or a real leak — the cry-wolf gap is closed. Cache
// bytes are reported, not verdicted: the budget legitimately holds
// persistent resources (glyph atlas, the window's cache texture).
//
// Build: same link line as examples/images (needs the native backend).
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import niello "../.."
import niello_sdl "../../sdl"

TEST_PNG :: #load("../images/test.png") // the images demo's asset, shared
GARBAGE  :: "this is not image data, it is a trap"

CYCLES      :: 40
DRAW_FRAMES :: 30
// RSS drift that fails the soak. One 480x320 RGBA texture is ~600KB;
// Graphite may legitimately retain released textures until eviction,
// so this is generous — the printed drift is the number that matters.
DRIFT_LIMIT_KB :: 64 * 1024

window_u, row_u:                 niello.Unit
title_u, status_u, verdict_u:    niello.Unit
cell_u:                         niello.Unit // one unit, per-instance images

cycle:          int // 0 = warmup (discarded), 1..CYCLES measured
frame_in_cycle: int
live:           [dynamic]niello.Image // handles alive this cycle
all_handles:    [dynamic]niello.Image // every handle ever created (liveness audit)
rss_kb:         [dynamic]int          // measured RSS after each measured cycle
gpu_kb:         [dynamic]int          // Graphite cache bytes (kB) after purge, per measured cycle
failed_decodes: int
verdict_shown:  bool

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
		font_size  = 20,
		font_color = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&status_u, niello.NO_UNIT, {
		font_size  = 13,
		font_color = niello.Color{150, 156, 170, 255},
	})
	niello.mint(&verdict_u, niello.NO_UNIT, {
		font_size  = 15,
		font_color = niello.Color{232, 234, 240, 255},
	})
	niello.mint(&row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fit()},
		gap    = 10,
	})
	niello.mint(&cell_u, niello.NO_UNIT, {
		size      = niello.Size{niello.fixed(150), niello.fixed(100)},
		color     = BAND,
		image_fit = niello.Image_Fit.Uniform,
	})
}

// proc_rss_kb reads resident set size from /proc/self/status (Linux).
// -1 if unreadable — the soak reports, never guesses.
proc_rss_kb :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/status", context.temp_allocator)
	if err != nil {
		return -1
	}
	for line in strings.split_lines(string(data)) {
		if strings.has_prefix(line, "VmRSS:") {
			fields := strings.fields(line) // ["VmRSS:", "12345", "kB"]
			if len(fields) >= 2 {
				v, ok := strconv.parse_int(fields[1])
				if ok {
					return v
				}
			}
		}
	}
	return -1
}

load_cycle :: proc() {
	ok: bool
	full: niello.Image
	full, ok = niello.image_load_memory(TEST_PNG)
	assert(ok, "soak: full decode failed")
	append(&live, full)
	append(&all_handles, full)

	thumb: niello.Image
	thumb, ok = niello.image_load_memory(TEST_PNG, decode_w = 120)
	assert(ok, "soak: thumbnail decode failed")
	append(&live, thumb)
	append(&all_handles, thumb)

	// Crop family: two crops sharing full's backend image.
	c1: niello.Image
	c1, ok = niello.image_cropped(full, niello.Rect{{0, 0}, {120, 120}})
	assert(ok, "soak: crop 1 failed")
	append(&live, c1)
	append(&all_handles, c1)
	c2: niello.Image
	c2, ok = niello.image_cropped(full, niello.Rect{{120, 120}, {120, 120}})
	assert(ok, "soak: crop 2 failed")
	append(&live, c2)
	append(&all_handles, c2)

	// Deliberately failed decodes — must fail clean, no backend image.
	garbage: string = GARBAGE
	_, ok = niello.image_load_memory(transmute([]byte)garbage)
	assert(!ok, "soak: garbage decode unexpectedly succeeded")
	failed_decodes += 1
	_, ok = niello.image_load_memory([]byte{})
	assert(!ok, "soak: empty decode unexpectedly succeeded")
	failed_decodes += 1
}

release_cycle :: proc() {
	// Alternate release order to hit both refcount paths: even cycles
	// release the root first (backend must survive via the crops),
	// odd cycles release the crops first (backend must drop with it).
	if cycle % 2 == 0 {
		for img in live {
			niello.image_release(img)
		}
	} else {
		#reverse for img in live {
			niello.image_release(img)
		}
	}
	clear(&live)
}

declare :: proc() {
	if cycle > CYCLES {
		show_verdict()
		return
	}
	if frame_in_cycle == 0 {
		load_cycle()
	}
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u, niello.key("title"), niello.With{
			text = "Image soak — TODO #13 VERIFICATION OWED",
		})
		niello.show(status_u, niello.key("status"), niello.With{
			text = fmt.tprintf("cycle %d/%d · frame %d/%d · live handles %d · failed decodes (clean) %d · RSS %d kB · GPU cache %d kB",
				cycle, CYCLES, frame_in_cycle, DRAW_FRAMES, len(live), failed_decodes, proc_rss_kb(),
				int(niello_sdl.gpu_cache_bytes() / 1024)),
		})
		if _, ok := niello.begin(row_u, niello.key("row")); ok {
			for img, i in live {
				niello.show(cell_u, niello.key(fmt.tprintf("cell%d", i)), niello.With{image = img})
			}
		}
	}
	frame_in_cycle += 1
	if frame_in_cycle >= DRAW_FRAMES {
		release_cycle()
		if cycle >= 1 {
			// Purge BEFORE measuring: whatever the cache still holds
			// afterwards is kept residency or a leak, never just
			// evictable leftovers.
			niello_sdl.purge_gpu_cache()
			rss := proc_rss_kb()
			gpu := int(niello_sdl.gpu_cache_bytes() / 1024)
			append(&rss_kb, rss)
			append(&gpu_kb, gpu)
			fmt.printf("soak: cycle %d/%d released — RSS %d kB · GPU cache %d kB (post-purge)\n",
				cycle, CYCLES, rss, gpu)
		}
		cycle += 1
		frame_in_cycle = 0
	}
}

show_verdict :: proc() {
	base := rss_kb[0]
	worst := base
	for v in rss_kb {
		worst = max(worst, v)
	}
	drift := worst - base
	// Liveness audit: every handle ever created must read back as
	// released (image_size is zero for unknown/released). A stale
	// alive entry pins a full raster in the backend — a real leak.
	stale := 0
	for h in all_handles {
		if niello.image_size(h) != {0, 0} {
			stale += 1
		}
	}
	gpu_worst := gpu_kb[0]
	for v in gpu_kb {
		gpu_worst = max(gpu_worst, v)
	}
	pass := drift <= DRIFT_LIMIT_KB && stale == 0
	verdict := fmt.tprintf("SOAK %s — %d measured cycles, RSS drift %d kB (limit %d kB), stale handles %d, %d clean failed decodes · GPU cache post-purge: first %d kB, worst %d kB",
		"PASS" if pass else "FAIL", len(rss_kb), drift, DRIFT_LIMIT_KB, stale, failed_decodes,
		gpu_kb[0], gpu_worst)
	if !verdict_shown {
		fmt.printf("soak: %s\n", verdict)
		verdict_shown = true
	}
	if _, ok := niello.begin(window_u); ok {
		niello.show(verdict_u, niello.key("verdict"), niello.With{text = verdict})
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, niello_sdl.App_Config{
		title  = "NielloUI — Image soak",
		width  = 900,
		height = 420,
	}, declare)
}
