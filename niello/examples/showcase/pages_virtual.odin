// pages_virtual.odin — Virtual lists: deferred sections and niello/virtual.
package main

import "core:fmt"
import niello "../.."
import virtual "../../virtual"

// =====================================================================
// Virtual lists
// =====================================================================

FIXED_ROWS     :: 100_000
ESTIMATED_ROWS :: 10_000
ROW_H          :: f32(30)

Virtual_State :: struct {
	fixed_list, est_list:   virtual.List,
	fixed_i, est_i:         niello.Instance,
	fixed_bar, est_bar:     Scrollbar,
	fixed_declared:         int,
	est_declared:           int,
}

virtual_units: struct {
	list, row, para, hover: niello.Unit,
}

PARAGRAPHS := [?]string{
	"A short note.",
	"Items in an estimated list differ in size: this one wraps over a couple of lines at the column's width.",
	"Unmeasured items count at an estimate; every item the build declares is measured on the spot, so the window fills the viewport exactly.",
	"Scrolling up into items never measured before does not make what is on screen jump: the size the list learns is cancelled with scroll_shift.",
	"One line.",
	"The scrollbar's length follows the best estimate of the whole list, so it settles as more items get measured, but the content never moves under it.",
}

page_virtual :: proc(app: ^App) {
	s := &app.virt
	V := &virtual_units
	niello.show(ui.title, {text = "Virtual lists"})
	note("A deferred section (begin_section) declares its children after the main layout, with its exact bounds and scroll offset. niello/virtual builds lists on it that declare only the visible window plus overscan: the rest of the list is held by spacers, so the scroll range and the scrollbar cover the whole list. Rows are focusable: Tab walks them past the window's edge, and the focused row stays declared when scrolled away.")

	if niello.begin(ui.card_row) {
		if niello.begin(ui.column) {
			heading(fmt.tprintf("Fixed: %d rows of %.0f DIP", FIXED_ROWS, ROW_H))
			if niello.begin_section(V.list, niello.builder(build_fixed_rows, app), out = &s.fixed_i) {
				scrollbar(&s.fixed_bar, s.fixed_i)
			}
			if niello.begin(ui.row) {
				if niello.clicked(button("Top")) {
					virtual.scroll_to_index(&s.fixed_list, s.fixed_i, 0)
				}
				if niello.clicked(button("Row 50 000")) {
					virtual.scroll_to_index(&s.fixed_list, s.fixed_i, 49_999)
				}
				if niello.clicked(button("End")) {
					virtual.scroll_to_index(&s.fixed_list, s.fixed_i, FIXED_ROWS - 1)
				}
			}
			note(fmt.tprintf("%d of %d rows declared this frame", s.fixed_declared, FIXED_ROWS))
		}
		if niello.begin(ui.column) {
			heading(fmt.tprintf("Estimated: %d paragraphs of differing height", ESTIMATED_ROWS))
			if niello.begin_section(V.list, niello.builder(build_estimated_rows, app), out = &s.est_i) {
				scrollbar(&s.est_bar, s.est_i)
			}
			if niello.begin(ui.row) {
				if niello.clicked(button("Top")) {
					virtual.scroll_to_index(&s.est_list, s.est_i, 0)
				}
				if niello.clicked(button("Item 5 000")) {
					virtual.scroll_to_index(&s.est_list, s.est_i, 4_999)
				}
			}
			note(fmt.tprintf("%d of %d items declared this frame", s.est_declared, ESTIMATED_ROWS))
		}
	}
}

// build_fixed_rows runs inside frame_end, once the list's bounds are known.
build_fixed_rows :: proc(app: ^App, sec: niello.Section) {
	s := &app.virt
	it := virtual.fixed(&s.fixed_list, sec, FIXED_ROWS, ROW_H)
	n := 0
	for i in virtual.next(&it) {
		inst := niello.show(virtual_units.row, {text = fmt.tprintf("Row %d", i + 1)}, key = niello.key_int(i))
		virtual.item(&it, inst)
		if niello.clicked(inst) {
			status_set(&app.status, "Virtual list: clicked row %d", i + 1)
		}
		n += 1
	}
	virtual.finish(&it)
	s.fixed_declared = n
}

build_estimated_rows :: proc(app: ^App, sec: niello.Section) {
	s := &app.virt
	it := virtual.estimated(&s.est_list, sec, ESTIMATED_ROWS, 48)
	n := 0
	for i in virtual.next(&it) {
		text := fmt.tprintf("%d. %s", i + 1, PARAGRAPHS[(i * 7) % len(PARAGRAPHS)])
		inst := niello.show(virtual_units.para, {text = text}, key = niello.key_int(i))
		virtual.item(&it, inst)
		if niello.clicked(inst) {
			status_set(&app.status, "Virtual list: clicked item %d", i + 1)
		}
		n += 1
	}
	virtual.finish(&it)
	s.est_declared = n
}

mint_pages_virtual :: proc(app: ^App, t: Theme) {
	V := &virtual_units
	niello.mint(&V.list, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fixed(320)), scroll = .Vertical, gap = 2,
		align = niello.align(.End, .Start), // the anchored bar: right edge, top
		color = t.bg, corner_radius = 8, padding = niello.pad_each(6, 6, 16, 6),
		smooth_scroll = true,
		groups = []niello.Group{groups.bg},
	})
	niello.mint(&V.hover, niello.NO_UNIT, {color = t.hover, groups = []niello.Group{groups.hover}})
	niello.mint(&V.row, niello.NO_UNIT, {
		size = size(grow(), fixed(ROW_H)), padding = pad_xy(10, 7), corner_radius = 4,
		font_size = 13, font_color = t.ink, focusable = true, cursor = .Pointer,
		hover = V.hover, groups = []niello.Group{groups.ink},
	})
	niello.mint(&V.para, niello.NO_UNIT, {
		size = size(grow(), fit()), padding = pad_xy(10, 8), corner_radius = 4, wrap = .Word,
		font_size = 13, font_color = t.ink, focusable = true, cursor = .Pointer,
		hover = V.hover, groups = []niello.Group{groups.ink},
	})
	scrollbar_init(&app.virt.fixed_bar, .Vertical)
	scrollbar_init(&app.virt.est_bar, .Vertical)
}

destroy_pages_virtual :: proc(app: ^App) {
	virtual.destroy(&app.virt.fixed_list)
	virtual.destroy(&app.virt.est_list)
}
