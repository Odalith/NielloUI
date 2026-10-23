// Inbox demo: the one-inbox pattern (Async_Inbox_Design.md) with the
// niello/inbox package doing the plumbing.
//
//   - "Index library" starts a worker thread that scans a fake
//     library in batches. Progress arrives as send_latest state
//     updates (tag-coalesced: the frame only ever sees the newest),
//     completion as a send event. The worker touches nothing but the
//     inbox — no model access, no unit writes, no callbacks.
//   - "Cancel" sets an atomic flag the worker polls between batches;
//     its exit protocol is one final Done message marked cancelled.
//   - "Play" runs a ticker thread (the audio-engine stand-in): while
//     playing it send_latest's the position and sends Track_Ended at
//     the end of each fake track. Declare arms niello.wake_in(250)
//     only while playing, so a stopped, idle window still sleeps.
//   - Everything lands in ONE drain at the top of declare and is
//     applied to the model by one exhaustive switch. Declare itself
//     only projects the model and dispatches clicks.
package main

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"

import niello "../.."
import inbox "../../inbox"
import niello_sdl "../../sdl"

BG :: niello.Color{24, 25, 32, 255}
SURFACE :: niello.Color{43, 46, 56, 255}
TEXT :: niello.Color{232, 234, 240, 255}
DIM :: niello.Color{150, 154, 168, 255}
ACCENT :: niello.Color{84, 120, 200, 255}
BTN :: niello.Color{52, 56, 72, 255}
BTN_HOVER :: niello.Color{66, 71, 90, 255}
BTN_PRESS :: niello.Color{40, 43, 56, 255}

TOTAL_ITEMS :: 240
BATCH :: 20
TRACK_SECS :: 180

// ---- messages ---------------------------------------------------------------

Index_Progress :: struct {
	pct:   int,
	found: int,
}
Index_Done :: struct {
	items:     [dynamic]string, // ownership moves with the message
	cancelled: bool,
}
Position :: struct {
	secs: f32,
}
Track_Ended :: struct {}

Msg :: union {
	Index_Progress,
	Index_Done,
	Position,
	Track_Ended,
}

PROGRESS_TAG :: u64(1)
POSITION_TAG :: u64(2)

// ---- the model: plain data, mutated only at the drain and by clicks --------

model: struct {
	items:    [dynamic]string,
	indexing: bool,
	pct:      int,
	found:    int,
	indexed:  int, // items from the last completed index; 0 = never
	cancelled: bool, // the last index run was cancelled
	playing:  bool,
	track:    int,
	position: f32,
}

box: inbox.Inbox(Msg)
app_ctx: ^niello.Context
scratch: [dynamic]Msg

engine_playing: bool // accessed only via sync.atomic_* (the engine's wake_requested pattern)
index_cancel: bool
app_quit: bool

// ---- workers -----------------------------------------------------------------

Index_Job :: struct {
	box: ^inbox.Inbox(Msg),
}

index_worker :: proc(data: rawptr) {
	job := cast(^Index_Job)data
	defer free(job)
	found: [dynamic]string
	done_count := 0
	cancelled := false
	for done_count < TOTAL_ITEMS {
		if sync.atomic_load(&index_cancel) || sync.atomic_load(&app_quit) {
			cancelled = true
			break
		}
		for i in 0 ..< BATCH {
			append(&found, fmt.aprintf("Track %03d — Fake Artist %d", done_count + 1, (done_count % 9) + 1))
			done_count += 1
		}
		inbox.send_latest(job.box, PROGRESS_TAG, Msg(Index_Progress {
			pct = done_count * 100 / TOTAL_ITEMS, found = done_count,
		}))
		time.sleep(120 * time.Millisecond)
	}
	inbox.send(job.box, Msg(Index_Done{items = found, cancelled = cancelled}))
}

// The audio-engine stand-in: owns the position counter, reports it
// as latest-wins updates, and announces track ends as events.
ticker_worker :: proc(data: rawptr) {
	pos := f32(0)
	for !sync.atomic_load(&app_quit) {
		time.sleep(200 * time.Millisecond)
		if !sync.atomic_load(&engine_playing) {
			continue
		}
		pos += 0.2
		if pos >= TRACK_SECS {
			pos = 0
			inbox.send(&box, Msg(Track_Ended{}))
		} else {
			inbox.send_latest(&box, POSITION_TAG, Msg(Position{secs = pos}))
		}
	}
}

// ---- the drain: the only place results become state --------------------------

apply_msgs :: proc() {
	inbox.drain(&box, &scratch)
	for m in scratch {
		switch v in m {
		case Index_Progress:
			model.pct = v.pct
			model.found = v.found
		case Index_Done:
			model.indexing = false
			model.cancelled = v.cancelled
			if v.cancelled {
				delete(v.items)
			} else {
				for s in model.items {
					delete(s)
				}
				delete(model.items)
				model.items = v.items
				model.indexed = len(v.items)
			}
		case Position:
			model.position = v.secs
		case Track_Ended:
			model.track = (model.track + 1) % 3
			model.position = 0
		}
	}
	clear(&scratch)
}

start_index :: proc() {
	model.indexing = true
	model.pct = 0
	model.found = 0
	sync.atomic_store(&index_cancel, false)
	job := new(Index_Job)
	job.box = &box
	thread.create_and_start_with_data(job, index_worker)
}

// ---- units + declare ----------------------------------------------------------

window_u, title_u, hint_u, row_u, status_u, item_u, player_u: niello.Unit
btn_u, btn_hover_u, btn_press_u, btn_label_u: niello.Unit
index_i, cancel_i, play_i: niello.Instance

mint :: proc() {
	niello.mint(&window_u, niello.NO_UNIT, {
		layout = niello.Layout.Top_To_Bottom,
		color = BG, padding = [4]u16{22, 22, 22, 22}, gap = 10,
	})
	niello.mint(&title_u, niello.NO_UNIT, {font_size = 22, font_color = TEXT, text = "One inbox"})
	niello.mint(&hint_u, niello.NO_UNIT, {
		font_size = 13.5, font_color = DIM,
		text = "Worker threads only push messages. One drain per frame applies them; declare just projects.",
	})
	niello.mint(&row_u, niello.NO_UNIT, {
		layout = niello.Layout.Left_To_Right, gap = 10,
		size = niello.Size{niello.grow(), niello.fit()},
	})
	niello.mint(&btn_hover_u, niello.NO_UNIT, {color = BTN_HOVER})
	niello.mint(&btn_press_u, niello.NO_UNIT, {color = BTN_PRESS})
	niello.mint(&btn_u, niello.NO_UNIT, {
		layout = niello.Layout.Stack,
		align = [2]niello.Align_Kind{niello.Align_Kind.Center, niello.Align_Kind.Center},
		size = niello.Size{niello.fixed(150), niello.fixed(36)},
		color = BTN, corner_radius = 6,
		hover = btn_hover_u, press = btn_press_u, focusable = true,
	})
	niello.mint(&btn_label_u, niello.NO_UNIT, {font_size = 14, font_color = TEXT})
	niello.mint(&status_u, niello.NO_UNIT, {font_size = 14, font_color = TEXT})
	niello.mint(&item_u, niello.NO_UNIT, {font_size = 13.5, font_color = DIM})
	niello.mint(&player_u, niello.NO_UNIT, {font_size = 14, font_color = ACCENT})
}

button :: proc(key: string, label: string) -> niello.Instance {
	i, open := niello.begin(btn_u, niello.key(key))
	if open {
		niello.show(btn_label_u, 0, {text = label})
	}
	return i
}

declare :: proc() {
	apply_msgs()
	if model.playing {
		niello.wake_in(250) // the seek readout stays fresh only while playing
	}
	if _, ok := niello.begin(window_u); ok {
		niello.show(title_u)
		niello.show(hint_u)
		if _, ok2 := niello.begin(row_u, niello.key("buttons")); ok2 {
			index_i = button("index", model.indexing ? "Indexing…" : "Index library")
			cancel_i = button("cancel", "Cancel")
			play_i = button("play", model.playing ? "Pause" : "Play")
		}
		if niello.clicked(index_i) && !model.indexing {
			start_index()
		}
		if niello.clicked(cancel_i) && model.indexing {
			sync.atomic_store(&index_cancel, true)
		}
		if niello.clicked(play_i) {
			model.playing = !model.playing
			sync.atomic_store(&engine_playing, model.playing)
		}

		niello.show(status_u, niello.key("status"), {text = status_text()})
		niello.show(player_u, niello.key("player"), {
			text = fmt.tprintf("%s Track %d — %d:%02d / %d:%02d",
				model.playing ? "▶" : "⏸", model.track + 1,
				int(model.position) / 60, int(model.position) % 60,
				TRACK_SECS / 60, TRACK_SECS % 60),
		})

		shown := min(len(model.items), 12)
		for k in 0 ..< shown {
			niello.show(item_u, niello.key_int(k), {text = model.items[k]})
		}
		if len(model.items) > shown {
			niello.show(item_u, niello.key("more"), {
				text = fmt.tprintf("… and %d more", len(model.items) - shown),
			})
		}
	}
}

status_text :: proc() -> string {
	if model.indexing {
		return fmt.tprintf("Indexing… %d%% (%d of %d)", model.pct, model.found, TOTAL_ITEMS)
	}
	if model.cancelled {
		return "Indexing cancelled — library unchanged."
	}
	if model.indexed > 0 {
		return fmt.tprintf("Indexed %d tracks.", model.indexed)
	}
	return "Idle. The frame loop is asleep until a message or an event arrives."
}

main :: proc() {
	mint()
	app_ctx = niello.context_create()
	defer niello.context_destroy(app_ctx)
	box = inbox.create(Msg, app_ctx)
	defer inbox.destroy(&box)
	thread.create_and_start_with_data(nil, ticker_worker)
	niello_sdl.run(app_ctx, {title = "NielloUI — inbox", width = 720, height = 560}, declare)
	sync.atomic_store(&app_quit, true)
}
