// niello/examples/a11y — the accessibility export demo (TODO #23 M2).
//
// Declares a small window with semantics in With (roles, labels,
// descriptions, values, flags) and publishes the mirror to the
// AT-SPI exporter on Linux. Run it under a screen reader (Orca) or
// an inspector (Accerciser) to verify the exported tree: the app
// object, the window, the button/slider/list rows, their states,
// and the change signals when the toggle flips, the volume moves,
// or the selection changes.
//
// The exporter is inert when no accessibility bus answers, so the
// window runs identically without AT-SPI. Only the public API is
// used; the export itself is glue-level (niello/sdl/app).
//
// Build (needs the native backend for your platform — see
// third_party/native/README.md, and rebuild it after pulling M2):
//
//	odin run niello/examples/a11y -extra-linker-flags:"-L..."
package main

import "core:fmt"

import niello "../.."
import niello_sdl "../../sdl"

// Cold units, minted once.
window:     niello.Unit
heading:    niello.Unit
row:        niello.Unit
play_btn:   niello.Unit
vol_down:   niello.Unit
vol_up:     niello.Unit
vol_track:  niello.Unit
list_box:   niello.Unit
song_row:   niello.Unit
song_label: niello.Unit
status:     niello.Unit

// App state, mutated by clicks; the declares read it.
playing:  bool
volume:   f32 = 75
selected: int = 1 // index into the song rows, -1 = none

songs := [3]string{"Night Drive", "Static Bloom", "Low Orbit"}

mint_units :: proc() {
	niello.mint(&window, niello.NO_UNIT, {
		layout  = .Top_To_Bottom,
		color   = niello.Color{30, 32, 40, 255},
		padding = [4]u16{24, 24, 24, 24},
		gap     = 16,
	})
	niello.mint(&heading, niello.NO_UNIT, {
		font_size  = 28,
		font_color = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&row, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size   = niello.Size{niello.grow(), niello.fixed(48)},
		gap    = 12,
	})
	niello.mint(&play_btn, niello.NO_UNIT, {
		layout        = .Left_To_Right,
		size          = niello.Size{niello.fixed(140), niello.fixed(48)},
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 8,
		font_size     = 16,
		font_color    = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&vol_down, niello.NO_UNIT, {
		size          = niello.Size{niello.fixed(48), niello.fixed(48)},
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 8,
		font_size     = 20,
		font_color    = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&vol_up, niello.NO_UNIT, {
		size          = niello.Size{niello.fixed(48), niello.fixed(48)},
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 8,
		font_size     = 20,
		font_color    = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&vol_track, niello.NO_UNIT, {
		layout        = .Left_To_Right,
		size          = niello.Size{niello.grow(), niello.fixed(48)},
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 8,
		font_size     = 16,
		font_color    = niello.Color{200, 200, 212, 255},
	})
	niello.mint(&list_box, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size   = niello.Size{niello.grow(), niello.fixed(168)},
		gap    = 8,
	})
	niello.mint(&song_row, niello.NO_UNIT, {
		layout        = .Left_To_Right,
		size          = niello.Size{niello.grow(), niello.fixed(48)},
		color         = niello.Color{46, 50, 62, 255},
		corner_radius = 8,
		padding       = [4]u16{16, 16, 16, 16},
	})
	niello.mint(&song_label, niello.NO_UNIT, {
		font_size  = 16,
		font_color = niello.Color{240, 240, 245, 255},
	})
	niello.mint(&status, niello.NO_UNIT, {
		font_size  = 14,
		font_color = niello.Color{160, 160, 175, 255},
	})
}

// Hot: declare the UI every frame. Semantics ride in With: role,
// label, description, value, flags. Nodes without semantics never
// enter the mirror.
declare :: proc() {
	if _, ok := niello.begin(window); ok {
		niello.show(heading, niello.key("heading"), {
			text = "Accessibility Demo",
			role = .Text,
			label = "Accessibility Demo",
		})
		if _, ok := niello.begin(row); ok {
			play_i := niello.show(play_btn, niello.key("play"), {
				text = "Pause" if playing else "Play",
				role = .Button,
				label = "Play or pause",
				description = "Toggles playback",
				a11y_flags = {.Checked} if playing else {},
				focusable = true,
			})
			if niello.clicked(play_i) {
				playing = !playing
			}
			down_i := niello.show(vol_down, niello.key("voldn"), {
				text = "−",
				role = .Button,
				label = "Volume down",
				focusable = true,
			})
			if niello.clicked(down_i) {
				volume = max(0, volume - 5)
			}
			niello.show(vol_track, niello.key("vol"), {
				text = fmt.tprintf("%d%%", int(volume)),
				role = .Slider,
				label = "Volume",
				description = "Playback volume, 0 to 130 percent",
				value = niello.A11y_Value{num = volume, has_num = true, min = 0, max = 130},
				focusable = true,
			})
			up_i := niello.show(vol_up, niello.key("volup"), {
				text = "+",
				role = .Button,
				label = "Volume up",
				focusable = true,
			})
			if niello.clicked(up_i) {
				volume = min(130, volume + 5)
			}
		}
		if _, ok := niello.begin(list_box, niello.key("songs")); ok {
			for song, i in songs {
				// One declare per row: begin carries the ListItem
				// semantics, the text child names it for the
				// mirror's fallback (the label wins when set).
				// begin goes in the if initializer: its deferred
				// end pops at the if's scope exit.
				if row_i, row_open := niello.begin(song_row, niello.key(i), {
					role = .ListItem,
					label = song,
					a11y_flags = {.Selected} if i == selected else {},
					focusable = true,
				}); row_open {
					niello.show(song_label, niello.key("name"), {text = song})
					if niello.clicked(row_i) {
						selected = i
					}
				}
			}
		}
		niello.show(status, niello.key("status"), {
			text = "Verify with Orca or Accerciser: the tree, the states, and the change signals.",
			role = .Text,
		})
	}
}

main :: proc() {
	mint_units()
	ctx := niello.context_create()
	defer niello.context_destroy(ctx)
	niello_sdl.run(ctx, {title = "Accessibility Demo", width = 800, height = 600}, declare)
}
