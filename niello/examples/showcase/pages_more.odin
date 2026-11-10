// pages_more.odin — Scrolling, Animation, Popups, Drag, Images, and
// Async & windows.
package main

import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"
import niello "../.."
import debugui "../../debugui"
import inbox "../../inbox"
import niello_sdl "../../sdl"

// =====================================================================
// Scrolling
// =====================================================================

Scrolling_State :: struct {
	list_i, inner_i, smooth_i, wide_i:     niello.Instance,
	list_bar, inner_bar, smooth_bar, wide_bar: Scrollbar,
}

scroll_units: struct {
	list, inner, smooth, wide, col, row, inner_row, wide_row, sticky: niello.Unit,
}

page_scrolling :: proc(app: ^App) {
	s := &app.scrolling
	niello.show(ui.title, niello.key("t"), {text = "Scrolling"})
	note("n", "The wheel scrolls the deepest scroller under the cursor; leftover delta chains outward to the next one (this page itself scrolls). Scrollbars are a component: an anchored child reading scroll_offset / scroll_range.")

	if _, ok := niello.begin(ui.card_row, niello.key("lists")); ok {
		if _, cok := niello.begin(ui.column, niello.key("c1")); cok {
			heading("List + nested scroller")
			scroll_list(s)
			if _, rok := niello.begin(ui.row, niello.key("jump")); rok {
				if niello.clicked(button(niello.key("top"), "Top")) {
					niello.scroll_to(s.list_i, {0, 0})
				}
				if niello.clicked(button(niello.key("bottom"), "Bottom")) {
					niello.scroll_to(s.list_i, {0, 1e9}) // clamped to the range
				}
			}
			off := niello.scroll_offset(s.list_i)
			rng := niello.scroll_range(s.list_i)
			note("off", fmt.tprintf("offset %.0f of %.0f", off.y, rng.y))
		}
		if _, cok := niello.begin(ui.column, niello.key("c2")); cok {
			heading("Smooth + overscroll")
			scroll_smooth(s)
			note("sm", "smooth_scroll glides each wheel tick; overscroll pulls past the ends with resistance and springs back.")
			heading("Horizontal")
			scroll_wide(s)
			note("h", "Horizontal wheel or trackpad, or drag the bar.")
		}
	}
}

// Each scroller is its own proc: a begin that is not an if-initializer
// ends when its enclosing scope does, and a proc is the natural scope.

scroll_list :: proc(s: ^Scrolling_State) {
	S := &scroll_units
	li, ok := niello.begin(S.list, niello.key("list"))
	s.list_i = li
	if !ok {
		return
	}
	if _, cok := niello.begin(S.col, niello.key("col")); cok {
		for k in 0 ..< 6 {
			niello.show(S.row, niello.key_int(k), {text = fmt.tprintf("Row %d", k + 1)})
		}
		scroll_inner(s)
		for k in 6 ..< 30 {
			niello.show(S.row, niello.key_int(k), {text = fmt.tprintf("Row %d", k + 1)})
		}
	}
	niello.show(S.sticky, niello.key("sticky"), {text = "anchored header — does not scroll", anchored = true})
	scrollbar(&s.list_bar, li)
}

scroll_inner :: proc(s: ^Scrolling_State) {
	S := &scroll_units
	ii, ok := niello.begin(S.inner, niello.key("inner"))
	s.inner_i = ii
	if !ok {
		return
	}
	if _, cok := niello.begin(S.col, niello.key("col")); cok {
		for k in 0 ..< 12 {
			niello.show(S.inner_row, niello.key_int(k), {text = fmt.tprintf("Nested row %d — wheel here first", k + 1)})
		}
	}
	scrollbar(&s.inner_bar, ii)
}

scroll_smooth :: proc(s: ^Scrolling_State) {
	S := &scroll_units
	si, ok := niello.begin(S.smooth, niello.key("smooth"))
	s.smooth_i = si
	if !ok {
		return
	}
	if _, cok := niello.begin(S.col, niello.key("col")); cok {
		for k in 0 ..< 30 {
			niello.show(S.row, niello.key_int(k), {text = fmt.tprintf("Glide row %d", k + 1)})
		}
	}
	scrollbar(&s.smooth_bar, si)
}

scroll_wide :: proc(s: ^Scrolling_State) {
	S := &scroll_units
	wi, ok := niello.begin(S.wide, niello.key("wide"))
	s.wide_i = wi
	if !ok {
		return
	}
	for k in 0 ..< 14 {
		niello.show(S.wide_row, niello.key_int(k), {text = fmt.tprintf("Tile %d", k + 1)})
	}
	scrollbar(&s.wide_bar, wi)
}

// =====================================================================
// Animation
// =====================================================================

Anim_State :: struct {
	box_at_b:   bool,
	accent_idx: int,
	card_i:     [3]niello.Instance,
	edit_step:  int,
}

anim_units: struct {
	box, pose_a, pose_b, card_proto, flash, edit_box, card_text: niello.Unit,
	cards: [3]niello.Unit,
	accent_group: niello.Group,
}

ACCENTS := [4]niello.Color{{92, 140, 230, 255}, {200, 110, 70, 255}, {80, 165, 110, 255}, {170, 100, 200, 255}}

page_animation :: proc(app: ^App) {
	s := &app.anim
	A := &anim_units
	niello.show(ui.title, niello.key("t"), {text = "Animation"})
	note("n", "Writes go through units: tween glides a unit toward another unit's style, group_set with a duration glides a whole group, propagate pushes a prototype's values to the units minted from it, and transient pulses one instance.")

	if _, ok := niello.begin(ui.card, niello.key("tween")); ok {
		heading("tween — glide toward a pose unit")
		if niello.clicked(button(niello.key("glide"), "Glide the box")) {
			s.box_at_b = !s.box_at_b
			niello.tween(A.box, s.box_at_b ? A.pose_b : A.pose_a, 400, niello.Fields{.Size, .Color, .Corner_Radius})
		}
		niello.show(A.box, niello.key("box"))
	}

	if _, ok := niello.begin(ui.card, niello.key("cards")); ok {
		heading("propagate, group_set with a duration, transient")
		if _, rok := niello.begin(ui.row, niello.key("btns")); rok {
			if niello.clicked(button(niello.key("prop"), "Next accent (propagate)")) {
				s.accent_idx = (s.accent_idx + 1) % len(ACCENTS)
				niello.set(A.card_proto, .Color, ACCENTS[s.accent_idx])
				niello.propagate(A.card_proto, niello.Fields{.Color})
				status_set(&app.status, "propagate: the prototype's color reached every card minted from it")
			}
			if niello.clicked(button(niello.key("gset"), "Fade accent (group_set 600 ms)")) {
				s.accent_idx = (s.accent_idx + 1) % len(ACCENTS)
				niello.group_set(A.accent_group, .Color, ACCENTS[s.accent_idx], 600)
			}
		}
		if _, rok := niello.begin(ui.row, niello.key("cards")); rok {
			for k in 0 ..< 3 {
				ci, cok := niello.begin(A.cards[k], niello.key_int(k), {role = .Button, label = fmt.tprintf("Card %d", k + 1)})
				s.card_i[k] = ci
				if cok {
					niello.show(A.card_text, 0, {text = fmt.tprintf("Card %d — click to flash", k + 1)})
				}
				if niello.clicked(ci) {
					niello.transient(ci, A.flash, 100, 350)
				}
			}
		}
	}

	if _, ok := niello.begin(ui.card, niello.key("edit")); ok {
		heading("edit — bulk changes, diffed at frame end")
		if niello.clicked(button(niello.key("ed"), "Restyle with edit()")) {
			s.edit_step += 1
			e := niello.edit(A.edit_box)
			e.corner_radius = u8((s.edit_step * 9) % 32)
			e.color = ACCENTS[s.edit_step % len(ACCENTS)]
			e.border_width = u16(s.edit_step % 4)
			e.size = sz(fixed(f32(160 + (s.edit_step % 3) * 60)), fixed(48))
		}
		niello.show(A.edit_box, niello.key("box"), {text = fmt.tprintf("edit step %d", s.edit_step)})
	}
}

// =====================================================================
// Popups
// =====================================================================

Popups_State :: struct {
	menu_btn_i, menu_i, canvas_i, ctx_menu_i, dlg_i: niello.Instance,
	menu_open, ctx_open, dlg_open:                   bool,
	ctx_at:                                          niello.Vec2,
	toast_until:                                     time.Tick,
	toast:                                           string,
}

popup_units: struct {
	canvas, toast: niello.Unit,
}

page_popups :: proc(app: ^App) {
	s := &app.popups
	niello.show(ui.title, niello.key("t"), {text = "Popups"})
	note("n", "Popups are overlay roots declared after the main tree. The engine owns no open state: it reports dismiss_requested (click outside, Esc) and the app stops declaring.")

	if _, ok := niello.begin(ui.card, niello.key("menus")); ok {
		heading("Menu, dialog, toast")
		if _, rok := niello.begin(ui.row, niello.key("r")); rok {
			s.menu_btn_i = button(niello.key("menu"), "Open menu ▾")
			if niello.clicked(s.menu_btn_i) {
				s.menu_open = !s.menu_open
			}
			if niello.clicked(button(niello.key("dlg"), "Modal dialog…")) {
				s.dlg_open = true
			}
			if niello.clicked(button(niello.key("toast"), "Show toast")) {
				s.toast = "Saved. This toast hides itself after 2.5 s (wake_in)."
				s.toast_until = time.tick_add(time.tick_now(), 2500 * time.Millisecond)
			}
		}
		note("d", "The dialog is modal: outside presses are absorbed, Tab stays inside it, and focus returns to the opener when it closes.")
	}

	if _, ok := niello.begin(ui.card, niello.key("canvas")); ok {
		heading("Context menu")
		s.canvas_i = niello.show(popup_units.canvas, niello.key("c"), {text = "Click anywhere in this area"})
		if niello.clicked(s.canvas_i) {
			if p, pok := niello.mouse_position(); pok {
				s.ctx_at = p
				s.ctx_open = true
			}
		}
	}
}

// popups_overlay declares the open popups. It runs after the main tree
// every frame, whichever page is showing, so a toast outlives a page
// switch.
popups_overlay :: proc(app: ^App) {
	s := &app.popups
	if s.menu_i != 0 && niello.dismiss_requested(s.menu_i) {
		s.menu_open = false
	}
	if s.ctx_menu_i != 0 && niello.dismiss_requested(s.ctx_menu_i) {
		s.ctx_open = false
	}
	if s.dlg_i != 0 && niello.dismiss_requested(s.dlg_i) {
		s.dlg_open = false
		status_set(&app.status, "Dialog dismissed (backdrop click or Esc)")
	}
	if app.page != .Popups {
		s.menu_open, s.ctx_open = false, false
	}

	if s.menu_open {
		pi, open := niello.begin_popup(ui.menu, s.menu_btn_i, .Below, {gap = 4}, key = niello.key("menu"))
		s.menu_i = pi
		if open {
			for text, k in ([]string{"New", "Open…", "Save", "Save as…"}) {
				if menu_item(niello.key_int(k), text) {
					status_set(&app.status, "Menu: %s", text)
					s.menu_open = false
				}
			}
		}
	}
	if s.ctx_open {
		pi, open := niello.begin_popup(ui.menu, 0, .At, {at = s.ctx_at}, key = niello.key("ctx"))
		s.ctx_menu_i = pi
		if open {
			for text, k in ([]string{"Cut", "Copy", "Paste"}) {
				if menu_item(niello.key_int(k), text) {
					status_set(&app.status, "Context menu: %s at (%.0f, %.0f)", text, s.ctx_at.x, s.ctx_at.y)
					s.ctx_open = false
				}
			}
		}
	}
	if s.dlg_open {
		if _, bok := niello.begin_popup(ui.backdrop, 0, .At, {stay = true}, key = niello.key("backdrop")); bok {}
		pi, open := niello.begin_popup(ui.dialog, 0, .Center, {modal = true}, key = niello.key("dialog"))
		s.dlg_i = pi
		if open {
			niello.show(ui.title, niello.key("t"), {text = "Discard changes?"})
			note("b", "Tab cycles between the buttons; Esc or a click on the backdrop cancels.")
			if _, rok := niello.begin(ui.row, niello.key("btns")); rok {
				if niello.clicked(button(niello.key("discard"), "Discard", .Danger)) {
					s.dlg_open = false
					status_set(&app.status, "Dialog: discarded")
				}
				if niello.clicked(button(niello.key("cancel"), "Cancel")) {
					s.dlg_open = false
					status_set(&app.status, "Dialog: cancelled")
				}
			}
		}
	}
	if s.toast != "" {
		left := time.tick_diff(time.tick_now(), s.toast_until)
		if left <= 0 {
			s.toast = ""
		} else {
			// The engine sleeps when nothing changes; ask for the frame
			// that hides the toast.
			niello.wake_in(u32(time.duration_milliseconds(left)) + 1)
			if _, open := niello.begin_popup(popup_units.toast, 0, .At, {stay = true, at = {24, 24}}, key = niello.key("toast")); open {
				niello.show(ui.btn_label_on, 0, {text = s.toast})
			}
		}
	}
}

menu_item :: proc(key: niello.Key, text: string) -> bool {
	i, open := niello.begin(ui.menu_item, key, {role = .MenuItem, label = text})
	if open {
		niello.show(ui.body, 0, {text = text})
	}
	return niello.clicked(i)
}

// =====================================================================
// Drag
// =====================================================================

Drag_State :: struct {
	volume:                        Slider,
	split_w, split_grab:           f32,
	divider_i:                     niello.Instance,
	chip_pos, chip_grab:           niello.Vec2,
	chip_i, area_i:                niello.Instance,
	dlg_open:                      bool,
	dlg_pos, dlg_grab:             niello.Vec2,
	dlg_i, header_i, close_i:      niello.Instance,
}

drag_units: struct {
	split_row, left, right, divider, divider_hot, area, chip_slot, chip, dlg, dlg_header: niello.Unit,
}

page_drag :: proc(app: ^App) {
	s := &app.drag
	D := &drag_units
	niello.show(ui.title, niello.key("t"), {text = "Drag"})
	note("n", "A drag is a phase of a press: past 4 DIP the press becomes a drag, reported by dragging / drag_started / drag_ended with drag_delta, drag_total and drag_pos.")

	if _, ok := niello.begin(ui.card, niello.key("slider")); ok {
		heading("Slider (press to seek, drag to scrub, arrows when focused)")
		slider(&s.volume, niello.key("vol"), "Volume")
		note("v", fmt.tprintf("value %.0f%%", s.volume.value * 100))
	}

	if _, ok := niello.begin(ui.card, niello.key("split")); ok {
		heading("Splitter")
		if niello.drag_started(s.divider_i) {
			s.split_grab = s.split_w
		}
		if niello.dragging(s.divider_i) {
			s.split_w = clamp(s.split_grab + niello.drag_total().x, 80, 600)
		}
		niello.set(D.left, .Size, sz(fixed(s.split_w), grow()))
		if _, rok := niello.begin(D.split_row, niello.key("row")); rok {
			if _, lok := niello.begin(D.left, niello.key("l")); lok {
				note("l", fmt.tprintf("left pane, %.0f DIP", s.split_w))
			}
			if di, dok := niello.begin(D.divider, niello.key("div")); dok {
				s.divider_i = di
			}
			if _, rok2 := niello.begin(D.right, niello.key("r")); rok2 {
				note("r", "right pane (grow)")
			}
		}
	}

	if _, ok := niello.begin(ui.card, niello.key("free")); ok {
		heading("Free drag")
		if niello.drag_started(s.chip_i) {
			s.chip_grab = s.chip_pos
		}
		if niello.dragging(s.chip_i) {
			if r, rok := niello.rect(s.area_i); rok {
				p := s.chip_grab + niello.drag_total()
				s.chip_pos = {clamp(p.x, 0, max(r.size.x - 120, 0)), clamp(p.y, 0, max(r.size.y - 40, 0))}
			}
		}
		// The slot's padding is the chip's position inside the area.
		niello.set(D.chip_slot, .Padding, [4]u16{u16(s.chip_pos.x), u16(s.chip_pos.y), 0, 0})
		drag_area(s)
		if niello.clicked(button(niello.key("dlg"), "Open a draggable dialog")) {
			s.dlg_open = true
		}
	}
}

drag_area :: proc(s: ^Drag_State) {
	D := &drag_units
	ai, ok := niello.begin(D.area, niello.key("area"))
	s.area_i = ai
	if ok {
		if _, sok := niello.begin(D.chip_slot, niello.key("slot")); sok {
			s.chip_i = niello.show(D.chip, niello.key("chip"), {text = "drag me", role = .Thumb, label = "Draggable chip"})
		}
	}
}

// drag_overlay declares the draggable dialog: an .At popup whose point
// is app state, moved by its header's drag. Dragging the close button
// does not move it — the subtraction rule.
drag_overlay :: proc(app: ^App) {
	s := &app.drag
	D := &drag_units
	if !s.dlg_open {
		return
	}
	if niello.drag_started(s.header_i) && !niello.dragging(s.close_i) {
		s.dlg_grab = s.dlg_pos
	}
	if niello.dragging(s.header_i) && !niello.dragging(s.close_i) {
		s.dlg_pos = s.dlg_grab + niello.drag_total()
	}
	pi, open := niello.begin_popup(D.dlg, 0, .At, {at = s.dlg_pos, stay = true}, key = niello.key("dragdlg"))
	s.dlg_i = pi
	if open {
		if hi, hok := niello.begin(D.dlg_header, niello.key("hdr")); hok {
			s.header_i = hi
			niello.show(ui.heading, 0, {text = "Drag me by the header"})
			niello.show(shell.spacer)
			s.close_i = button(niello.key("x"), "Close")
		}
		note("b", fmt.tprintf("position (%.0f, %.0f)", s.dlg_pos.x, s.dlg_pos.y))
	}
	if niello.clicked(s.close_i) {
		s.dlg_open = false
	}
}

// =====================================================================
// Images
// =====================================================================

TEST_PNG :: #load("../images/test.png")

Images_State :: struct {
	hero, crop, thumb: niello.Image,
	loaded:            bool,
}

image_units: struct {
	fits: [4]niello.Unit,
	strip, nearest, smooth, bg, caption: niello.Unit,
}

FIT_NAMES := [4]string{"Uniform", "Fill", "Uniform_Fill", "None"}

load_images :: proc(s: ^Images_State) {
	ok1, ok2, ok3: bool
	s.hero, ok1 = niello.image_load_memory(TEST_PNG)
	if ok1 {
		s.crop, ok2 = niello.image_cropped(s.hero, niello.Rect{{0, 0}, {120, 120}})
	}
	s.thumb, ok3 = niello.image_load_memory(TEST_PNG, decode_w = 120)
	s.loaded = ok1 && ok2 && ok3
}

page_images :: proc(app: ^App) {
	s := &app.images
	I := &image_units
	niello.show(ui.title, niello.key("t"), {text = "Images"})
	if !s.loaded {
		note("fail", "The test image did not decode (no backend?) — nothing to show.")
		return
	}
	if _, ok := niello.begin(ui.card, niello.key("fits")); ok {
		heading("Fit modes — a 480x320 image in 180x120 boxes")
		if _, rok := niello.begin(ui.row, niello.key("r")); rok {
			for k in 0 ..< 4 {
				if _, cok := niello.begin(ui.column, niello.key_int(k)); cok {
					niello.show(I.fits[k], 0, {image = s.hero})
					niello.show(I.caption, 0, {text = FIT_NAMES[k]})
				}
			}
		}
	}
	if _, ok := niello.begin(ui.card, niello.key("variants")); ok {
		heading("One unit, per-instance images: full, crop, decode-to-120")
		if _, rok := niello.begin(ui.row, niello.key("r")); rok {
			niello.show(I.strip, niello.key("a"), {image = s.hero})
			niello.show(I.strip, niello.key("b"), {image = s.crop})
			niello.show(I.strip, niello.key("c"), {image = s.thumb})
		}
		heading("Interpolation (crop upscaled): high vs none")
		if _, rok := niello.begin(ui.row, niello.key("interp")); rok {
			niello.show(I.smooth, niello.key("hi"), {image = s.crop})
			niello.show(I.nearest, niello.key("no"), {image = s.crop})
		}
		heading("Background image behind children")
		if _, bok := niello.begin(I.bg, niello.key("bg"), {image = s.hero}); bok {
			niello.show(ui.btn_label_on, 0, {text = "a container paints its image first"})
		}
	}
}

// =====================================================================
// Async & windows
// =====================================================================

Progress :: struct {
	pct: int,
}
Job_Done :: struct {
	cancelled: bool,
}
Msg :: union {
	Progress,
	Job_Done,
}

PROGRESS_TAG :: u64(1)

Async_State :: struct {
	box:          inbox.Inbox(Msg),
	scratch:      [dynamic]Msg,
	worker:       ^thread.Thread,
	job:          Job, // the worker's view of the state; lives as long as the app
	cancel:       bool, // atomic
	running:      bool,
	pct:          int,
	last:         string,
	progress:     Slider,
	clock_on:     bool,
	clock_start:  time.Tick,
	insp:         Inspector,
}

Inspector :: struct {
	open: bool,
	id:   niello_sdl.Window_Id,
	ctx:  ^niello.Context,
	main: ^App,
}

Job :: struct {
	box:    ^inbox.Inbox(Msg),
	cancel: ^bool,
}

job_worker :: proc(data: rawptr) {
	job := cast(^Job)data
	for pct := 0; pct <= 100; pct += 2 {
		if sync.atomic_load(job.cancel) {
			inbox.send(job.box, Msg(Job_Done{cancelled = true}))
			return
		}
		// send_latest coalesces: the UI sees the newest progress only.
		inbox.send_latest(job.box, PROGRESS_TAG, Msg(Progress{pct = pct}))
		time.sleep(60 * time.Millisecond)
	}
	inbox.send(job.box, Msg(Job_Done{}))
}

async_start :: proc(s: ^Async_State) {
	if s.running {
		return
	}
	async_join(s)
	sync.atomic_store(&s.cancel, false)
	s.running, s.pct, s.last = true, 0, "running…"
	s.job = Job{box = &s.box, cancel = &s.cancel}
	s.worker = thread.create_and_start_with_data(&s.job, job_worker)
}

async_join :: proc(s: ^Async_State) {
	if s.worker != nil {
		thread.join(s.worker)
		thread.destroy(s.worker)
		s.worker = nil
	}
}

// async_drain applies worker messages once per frame, before declare.
async_drain :: proc(app: ^App) {
	s := &app.async
	inbox.drain(&s.box, &s.scratch)
	for m in s.scratch {
		switch v in m {
		case Progress:
			s.pct = v.pct
		case Job_Done:
			s.running = false
			s.last = v.cancelled ? "cancelled" : "finished"
			status_set(&app.status, "Background job %s", s.last)
		}
	}
}

async_shutdown :: proc(app: ^App) {
	sync.atomic_store(&app.async.cancel, true)
	async_join(&app.async)
	delete(app.async.scratch)
}

page_async :: proc(app: ^App) {
	s := &app.async
	niello.show(ui.title, niello.key("t"), {text = "Async & windows"})

	if _, ok := niello.begin(ui.card, niello.key("job")); ok {
		heading("Background work through an inbox")
		note("n", "A worker thread sends progress into an inbox; send wakes the UI, and the app drains the inbox once per frame before declaring. Nothing touches app state between drains.")
		if _, rok := niello.begin(ui.row, niello.key("r")); rok {
			if niello.clicked(button(niello.key("start"), "Start job", .Primary, disabled = s.running)) {
				async_start(s)
			}
			if niello.clicked(button(niello.key("cancel"), "Cancel", .Normal, disabled = !s.running)) {
				sync.atomic_store(&s.cancel, true)
			}
			niello.show(ui.body, niello.key("st"), {text = fmt.tprintf("%d%% — %s", s.pct, s.last == "" ? "idle" : s.last)})
		}
		s.progress.value = f32(s.pct) / 100
		progress_bar(&s.progress, niello.key("bar"), "Job progress")
	}

	if _, ok := niello.begin(ui.card, niello.key("clock")); ok {
		heading("Timers: wake_in")
		note("n", "The loop sleeps at ~0% CPU when nothing changes. A ticking readout asks for its next frame with wake_in.")
		if toggle(niello.key("clk"), "Run the clock", &s.clock_on) && s.clock_on {
			s.clock_start = time.tick_now()
		}
		if s.clock_on {
			el := time.tick_since(s.clock_start)
			niello.wake_in(100)
			niello.show(ui.title, niello.key("time"), {text = fmt.tprintf("%.1f s", time.duration_seconds(el))})
		} else {
			niello.show(ui.title, niello.key("time"), {text = "stopped — the app is idle"})
		}
	}

	if _, ok := niello.begin(ui.card, niello.key("win")); ok {
		heading("Windows")
		note("n", "A second window has its own context; units and groups are global, so the theme switch reaches it too. It reads this window's committed tree with the cross-context API (rect_in, instance_count).")
		if niello.clicked(button(niello.key("insp"), s.insp.open ? "Inspector is open" : "Open inspector window", .Normal, disabled = s.insp.open)) {
			inspector_open(app)
		}
		when niello.NIELLO_DEBUG {
			if niello.clicked(button(niello.key("dbg"), "Open debugger (F12)")) {
				debugui.open(app.ctx)
			}
		}
	}
}

inspector_units: struct {
	root: niello.Unit,
}

inspector_open :: proc(app: ^App) {
	s := &app.async.insp
	if s.open {
		return
	}
	s.ctx = niello.context_create()
	s.main = app
	s.id = niello_sdl.open_window(s.ctx, {title = "Showcase inspector", width = 420, height = 300}, declare_inspector, s)
	s.open = true
}

declare_inspector :: proc(s: ^Inspector) {
	app := s.main
	if _, ok := niello.begin(inspector_units.root); ok {
		niello.show(ui.title, 0, {text = "Inspector"})
		niello.show(ui.body, niello.key("n"), {text = fmt.tprintf("main window: %d instances, page %s", niello.instance_count(app.ctx), PAGE_NAMES[app.page])})
		if r, rok := niello.rect_in(app.ctx, app.content_i); rok {
			niello.show(ui.body, niello.key("c"), {text = fmt.tprintf("content area: %.0f x %.0f at (%.0f, %.0f)", r.size.x, r.size.y, r.pos.x, r.pos.y)})
		}
		if r, rok := niello.rect_in(app.ctx, app.nav_i[app.page]); rok {
			niello.show(ui.body, niello.key("s"), {text = fmt.tprintf("selected nav item: y = %.0f", r.pos.y)})
		}
		note("w", "This window re-renders when the main window wakes it.")
		if niello.clicked(button(niello.key("close"), "Close")) {
			niello_sdl.close_window(s.id)
		}
	}
}

// inspector_reap notices the inspector's window has gone (Close, or
// the OS close button) and frees its context; the main window wakes
// it so its readout follows the main tree.
inspector_reap :: proc(app: ^App) {
	s := &app.async.insp
	if !s.open {
		return
	}
	alive := false
	for w in niello_sdl.window_list() {
		if w.ctx == s.ctx {
			alive = true
		}
	}
	// The window is created at the next loop pass; until then it is
	// not listed yet, so give it a frame before reaping.
	if !alive && niello.instance_count(s.ctx) > 0 {
		niello.context_destroy(s.ctx)
		s.ctx, s.open = nil, false
		return
	}
	niello.context_wake(s.ctx)
}

inspector_shutdown :: proc(app: ^App) {
	s := &app.async.insp
	if s.ctx != nil {
		niello.context_destroy(s.ctx)
		s.ctx = nil
	}
}

// =====================================================================
// Minting the remaining pages' units
// =====================================================================

mint_pages_more :: proc(app: ^App, t: Theme) {
	S := &scroll_units
	list := niello.Style_Decl{
		layout = .Left_To_Right, // a row reads align the same for flow and the anchored bar
		size = sz(grow(), fixed(260)), scroll = .Vertical,
		align = [2]niello.Align_Kind{.End, .Start},
		color = t.bg, corner_radius = 8, padding = [4]u16{6, 30, 16, 6},
		groups = []niello.Group{groups.bg},
	}
	niello.mint(&S.list, niello.NO_UNIT, list)
	list.size = sz(grow(), fixed(260))
	list.smooth_scroll = true
	list.overscroll = true
	list.padding = [4]u16{6, 6, 16, 6}
	niello.mint(&S.smooth, niello.NO_UNIT, list)
	list.smooth_scroll, list.overscroll = false, false
	list.size = sz(grow(), fixed(110))
	list.scroll = .Horizontal
	list.align = [2]niello.Align_Kind{.Start, .End}
	list.padding = [4]u16{6, 6, 6, 16}
	niello.mint(&S.wide, niello.NO_UNIT, list)
	niello.mint(&S.inner, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(grow(), fixed(120)), scroll = .Vertical,
		align = [2]niello.Align_Kind{.End, .Start},
		color = t.raised, corner_radius = 6, padding = [4]u16{6, 6, 16, 6},
		groups = []niello.Group{groups.raised},
	})
	niello.mint(&S.row, niello.NO_UNIT, {
		size = sz(grow(), fixed(30)), padding = pad_xy(10, 7),
		font_size = 13, font_color = t.ink, groups = []niello.Group{groups.ink},
	})
	niello.mint(&S.inner_row, niello.NO_UNIT, {
		size = sz(grow(), fixed(26)), padding = pad_xy(10, 5),
		font_size = 12, font_color = t.dim, groups = []niello.Group{groups.dim},
	})
	niello.mint(&S.wide_row, niello.NO_UNIT, {
		size = sz(fixed(110), fixed(70)), padding = pad(10), corner_radius = 6,
		color = t.raised, font_size = 13, font_color = t.ink,
		groups = []niello.Group{groups.raised, groups.ink},
	})
	niello.mint(&S.sticky, niello.NO_UNIT, {
		size = sz(grow(), fixed(24)), padding = pad_xy(10, 5),
		color = t.accent, font_size = 12, font_color = rgb(0xffffff),
	})
	// The vertical scrollers are rows (see shell.content) hosting one
	// column of content.
	niello.mint(&S.col, niello.NO_UNIT, {layout = .Top_To_Bottom, size = sz(grow(), fit()), gap = 2})

	A := &anim_units
	niello.mint(&A.pose_a, niello.NO_UNIT, {size = sz(fixed(120), fixed(56)), color = rgb(0x4082a0), corner_radius = 8})
	niello.mint(&A.pose_b, niello.NO_UNIT, {size = sz(fixed(360), fixed(56)), color = rgb(0xc87840), corner_radius = 28})
	niello.mint(&A.box, A.pose_a)
	A.accent_group = niello.group_new("accent")
	niello.mint(&A.card_proto, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(grow(), fixed(80)), padding = pad(14),
		color = ACCENTS[0], corner_radius = 10, cursor = .Pointer,
	})
	for k in 0 ..< 3 {
		niello.mint(&A.cards[k], A.card_proto)
		niello.group_add(A.accent_group, A.cards[k])
	}
	niello.mint(&A.card_text, niello.NO_UNIT, {font_size = 14, font_color = rgb(0xffffff)})
	niello.mint(&A.flash, niello.NO_UNIT, {color = rgb(0xffffff)})
	niello.mint(&A.edit_box, niello.NO_UNIT, {
		size = sz(fixed(160), fixed(48)), padding = pad_xy(12, 15),
		color = ACCENTS[0], border_color = rgb(0xffffff),
		font_size = 13, font_color = rgb(0xffffff),
	})

	niello.mint(&popup_units.canvas, niello.NO_UNIT, {
		size = sz(grow(), fixed(140)), padding = pad(14), corner_radius = 8,
		color = t.bg, font_size = 13, font_color = t.dim, cursor = .Crosshair,
		groups = []niello.Group{groups.bg, groups.dim},
	})
	niello.mint(&popup_units.toast, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(fit(), fit()), padding = pad_xy(16, 12),
		color = SUCCESS, corner_radius = 8,
	})

	D := &drag_units
	niello.mint(&D.split_row, niello.NO_UNIT, {layout = .Left_To_Right, size = sz(grow(), fixed(110))})
	pane := niello.Style_Decl{
		layout = .Top_To_Bottom, size = sz(grow(), grow()), padding = pad(10),
		color = t.raised, corner_radius = 6, groups = []niello.Group{groups.raised},
	}
	niello.mint(&D.right, niello.NO_UNIT, pane)
	pane.size = sz(fixed(240), grow())
	niello.mint(&D.left, niello.NO_UNIT, pane)
	niello.mint(&D.divider_hot, niello.NO_UNIT, {color = t.accent})
	niello.mint(&D.divider, niello.NO_UNIT, {
		size = sz(fixed(10), grow()), cursor = .Resize_EW,
		hover = D.divider_hot, press = D.divider_hot, corner_radius = 3,
	})
	niello.mint(&D.area, niello.NO_UNIT, {
		layout = .Stack, size = sz(grow(), fixed(180)),
		color = t.bg, corner_radius = 8, overflow = .Clip,
		groups = []niello.Group{groups.bg},
	})
	niello.mint(&D.chip_slot, niello.NO_UNIT, {layout = .Left_To_Right, size = sz(fit(), fit())})
	niello.mint(&D.chip, niello.NO_UNIT, {
		size = sz(fixed(120), fixed(40)), padding = pad_xy(14, 12), corner_radius = 20,
		color = t.accent, font_size = 13, font_color = rgb(0xffffff), cursor = .Move,
	})
	niello.mint(&D.dlg, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(fixed(340), fit()),
		color = t.panel, corner_radius = 10, border_width = 1, border_color = t.hover,
		padding = [4]u16{0, 0, 0, 14}, gap = 10,
		groups = []niello.Group{groups.panel},
	})
	niello.mint(&D.dlg_header, niello.NO_UNIT, {
		layout = .Left_To_Right, size = sz(grow(), fixed(48)),
		padding = pad_xy(14, 0), align = START_CENTER, gap = 8,
		color = t.raised, corner_radius = 10, cursor = .Move,
		groups = []niello.Group{groups.raised},
	})
	app.drag.split_w = 240
	app.drag.chip_pos = {20, 20}
	app.drag.dlg_pos = {420, 180}

	I := &image_units
	fits := [4]niello.Image_Fit{.Uniform, .Fill, .Uniform_Fill, .None}
	for k in 0 ..< 4 {
		niello.mint(&I.fits[k], niello.NO_UNIT, {
			size = sz(fixed(180), fixed(120)), color = t.bg, image_fit = fits[k],
			groups = []niello.Group{groups.bg},
		})
	}
	niello.mint(&I.caption, ui.small, {})
	niello.group_add(groups.dim, I.caption)
	niello.mint(&I.strip, niello.NO_UNIT, {size = sz(grow(), fixed(80)), color = t.bg, groups = []niello.Group{groups.bg}})
	niello.mint(&I.smooth, niello.NO_UNIT, {size = sz(fixed(160), fixed(160)), image_interp = .High})
	niello.mint(&I.nearest, niello.NO_UNIT, {size = sz(fixed(160), fixed(160)), image_interp = .None})
	niello.mint(&I.bg, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(grow(), fixed(140)), align = CENTER,
		image_fit = .Uniform_Fill, corner_radius = 8,
	})

	niello.mint(&inspector_units.root, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = sz(percent(1), percent(1)),
		padding = pad(18), gap = 10, color = t.bg,
		groups = []niello.Group{groups.bg},
	})

	scrollbar_init(&app.scrolling.list_bar, .Vertical)
	scrollbar_init(&app.scrolling.inner_bar, .Vertical)
	scrollbar_init(&app.scrolling.smooth_bar, .Vertical)
	scrollbar_init(&app.scrolling.wide_bar, .Horizontal)
	load_images(&app.images)
}

mint_pages :: proc(app: ^App) {
	mint_pages_basic(DARK_THEME)
	mint_pages_more(app, DARK_THEME)
}

destroy_pages :: proc(app: ^App) {
	destroy_pages_basic(app)
}
