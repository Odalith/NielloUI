// multiwindow — TODO #20's demo: real multi-window on the shipped
// glue (M1 contexts, M2 backend handles, M3 window table).
//
// The main window is a small scene. Its "Open inspector" button —
// clicked inside a declare proc, the deferred queue's intended use —
// opens an inspector window on its OWN engine context. The
// inspector renders the MAIN window's committed state through the
// cross-context read API (rect_in / unit_in / instance_count),
// read fresh every inspector frame without ever binding the main
// context. Every inspector is independent: open several, close
// them in any order (its Close button exercises close_window from
// inside the window's own declare; the OS close button works too).
// run() returns when the last window closes.
//
// Two honest demo simplifications:
//   - The inspector re-reads on its own frame cadence. While the
//     main window changes (this demo's counter changes it every
//     frame), the readouts change with it, so the inspector stays
//     hot and every open inspector adds its own render load; a
//     static scene would let all of them idle at ~0 CPU. A
//     production inspector would throttle its read rate; apps have
//     no public periodic-wake API yet — context_wake from a timer
//     thread is the current escape hatch.
//   - A context whose window was OS-closed is reaped only if the
//     inspector used its own Close button (which marks it); an
//     OS-closed inspector's context lives until exit. Window
//     lifecycle notifications are TODO #26 territory.
package main

import "core:fmt"
import niello "../.."
import niello_sdl "../../sdl"

// ---- the scene (units are global, minted once — fork 5) ----
root_u, title_u, panel_u, chip_u, pulse_u, pulse_on_u: niello.Unit
open_btn_u, open_btn_hover_u, open_btn_label_u, counter_u: niello.Unit
insp_root_u, insp_title_u, line_u, close_btn_u, close_btn_hover_u, close_btn_label_u: niello.Unit

main_ctx: ^niello.Context
main_frames: int

// Instances the inspector tracks, captured during the main declare.
trk_panel, trk_chip, trk_counter: niello.Instance

// Inspectors this app has opened. reap is set by an inspector's own
// Close button; the main declare destroys the context (an inspector
// cannot destroy its own context mid-frame — it is inside that
// context's frame when it decides to close).
Inspector :: struct {
	id:   niello_sdl.Window_Id,
	ctx:  ^niello.Context,
	reap: bool,
}
inspectors: [dynamic]Inspector

spawn_inspector :: proc() {
	ictx := niello.context_create()
	id := niello_sdl.open_window(ictx, {title = "Inspector — NielloUI", width = 400, height = 320}, declare_inspector)
	append(&inspectors, Inspector{id = id, ctx = ictx})
}

reap_inspectors :: proc() {
	for i := len(inspectors) - 1; i >= 0; i -= 1 {
		if inspectors[i].reap {
			niello.context_destroy(inspectors[i].ctx)
			ordered_remove(&inspectors, i)
		}
	}
}

pulse_was_hovered: bool

declare_main :: proc() {
	reap_inspectors()
	main_frames += 1
	// Declare pattern: every container's begin goes in an if
	// initializer, so its deferred end() pops at that statement's
	// scope exit. A begin written as a plain statement inside a
	// parent's block keeps the container open — and the parent —
	// until the BLOCK ends, silently reparenting later siblings.
	if _, open := niello.begin(root_u); open {
		niello.show(title_u, 0, {text = "Main window"})
		if panel_inst, open2 := niello.begin(panel_u); open2 {
			trk_panel = panel_inst
			trk_chip = niello.show(chip_u)
			pulse := niello.show(pulse_u)
			hov := niello.hovered(pulse)
			if hov && !pulse_was_hovered {
				niello.transient(pulse, pulse_on_u, 120, 240)
			}
			pulse_was_hovered = hov
			niello.show(title_u, 0, {text = "hover the square"})
		}
		btn: niello.Instance
		if b, bopen := niello.begin(open_btn_u); bopen {
			btn = b
			niello.show(open_btn_label_u)
		}
		if niello.clicked(btn) {
			spawn_inspector()
		}
		buf: [48]u8
		trk_counter = niello.show(counter_u, 0, {text = fmt.bprintf(buf[:], "main frame %d", main_frames)})
	}
}

declare_inspector :: proc() {
	me := niello.current_context()
	if _, open := niello.begin(insp_root_u); open {
		niello.show(insp_title_u, 0, {text = "Inspector"})
		buf: [128]u8
		niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "main window: %d instances", niello.instance_count(main_ctx))})
		if r, ok := niello.rect_in(main_ctx, trk_chip); ok {
			u, _ := niello.unit_in(main_ctx, trk_chip)
			niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "chip: (%.0f, %.0f) %.0f x %.0f, unit %d", r.pos.x, r.pos.y, r.size.x, r.size.y, int(u))})
		}
		if r, ok := niello.rect_in(main_ctx, trk_counter); ok {
			u, _ := niello.unit_in(main_ctx, trk_counter)
			niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "counter: (%.0f, %.0f) %.0f x %.0f, unit %d", r.pos.x, r.pos.y, r.size.x, r.size.y, int(u))})
		}
		if r, ok := niello.rect_in(main_ctx, trk_panel); ok {
			u, _ := niello.unit_in(main_ctx, trk_panel)
			niello.show(line_u, 0, {text = fmt.bprintf(buf[:], "panel: (%.0f, %.0f) %.0f x %.0f, unit %d", r.pos.x, r.pos.y, r.size.x, r.size.y, int(u))})
		}
		niello.show(line_u, 0, {text = "watch the counter's width grow as it counts"})
		btn: niello.Instance
		if b, copen := niello.begin(close_btn_u); copen {
			btn = b
			niello.show(close_btn_label_u)
		}
		if niello.clicked(btn) {
			for &rec in inspectors {
				if rec.ctx == me {
					rec.reap = true
					niello_sdl.close_window(rec.id)
				}
			}
		}
	}
}

mint_units :: proc() {
	niello.mint(&root_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.percent(1), niello.percent(1)},
		color = niello.Color{22, 22, 30, 255},
		padding = [4]u16{16, 16, 16, 16}, gap = 12,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 15, font_color = niello.Color{225, 225, 235, 255}})
	niello.mint(&panel_u, niello.NO_UNIT, {
		layout = .Left_To_Right,
		size = niello.Size{niello.percent(1), niello.fixed(72)},
		color = niello.Color{36, 36, 50, 255},
		padding = [4]u16{12, 12, 12, 12}, gap = 12, corner_radius = 8,
	})
	niello.mint(&chip_u, niello.NO_UNIT, {size = niello.Size{niello.fixed(48), niello.fixed(48)}, color = niello.Color{70, 170, 120, 255}, corner_radius = 8})
	niello.mint(&pulse_u, niello.NO_UNIT, {size = niello.Size{niello.fixed(48), niello.fixed(48)}, color = niello.Color{60, 60, 78, 255}, corner_radius = 8})
	niello.mint(&pulse_on_u, niello.NO_UNIT, {color = niello.Color{250, 190, 60, 255}})
	niello.mint(&open_btn_hover_u, niello.NO_UNIT, {color = niello.Color{64, 84, 130, 255}})
	niello.mint(&open_btn_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(150), niello.fixed(36)},
		color = niello.Color{48, 62, 100, 255}, corner_radius = 6,
		align = [2]niello.Align_Kind{.Center, .Center},
		hover = open_btn_hover_u,
	})
	niello.mint(&open_btn_label_u, niello.NO_UNIT, {text = "Open inspector", font_size = 14, font_color = niello.Color{235, 238, 245, 255}})
	niello.mint(&counter_u, niello.NO_UNIT, {font_size = 14, font_color = niello.Color{170, 175, 190, 255}})

	niello.mint(&insp_root_u, niello.NO_UNIT, {
		layout = .Top_To_Bottom,
		size = niello.Size{niello.percent(1), niello.percent(1)},
		color = niello.Color{26, 24, 20, 255},
		padding = [4]u16{14, 14, 14, 14}, gap = 8,
	})
	niello.mint(&insp_title_u, niello.NO_UNIT, {font_size = 15, font_color = niello.Color{240, 226, 200, 255}})
	niello.mint(&line_u, niello.NO_UNIT, {font_size = 13, font_color = niello.Color{205, 200, 190, 255}})
	niello.mint(&close_btn_hover_u, niello.NO_UNIT, {color = niello.Color{120, 70, 55, 255}})
	niello.mint(&close_btn_u, niello.NO_UNIT, {
		size = niello.Size{niello.fixed(110), niello.fixed(32)},
		color = niello.Color{96, 56, 44, 255}, corner_radius = 6,
		align = [2]niello.Align_Kind{.Center, .Center},
		hover = close_btn_hover_u,
	})
	niello.mint(&close_btn_label_u, niello.NO_UNIT, {text = "Close", font_size = 14, font_color = niello.Color{245, 238, 230, 255}})
}

main :: proc() {
	mint_units()
	main_ctx = niello.context_create()
	defer niello.context_destroy(main_ctx)
	defer delete(inspectors)
	niello_sdl.run(main_ctx, {title = "Multi-window — NielloUI", width = 520, height = 360}, declare_main)
}
