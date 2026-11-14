package model

import "core:fmt"
import niello "niello:."

SELECTED :: 0xd3e3fd

tasks_u, task_u, task_selected, track_u, fill_u: niello.Unit

mint_with :: proc() {
	niello.mint(&tasks_u, niello.NO_UNIT, {layout = .Top_To_Bottom, gap = 2})
	niello.mint(&task_u, niello.NO_UNIT, {padding = niello.pad_xy(8, 4), color = niello.rgb(0xffffff)})
	niello.mint(&task_selected, niello.NO_UNIT, {color = niello.rgb(SELECTED)})
	niello.mint(&track_u, niello.NO_UNIT, {size = niello.size(niello.grow(), niello.fixed(6)), color = niello.rgb(0xe0e0e0)})
	niello.mint(&fill_u, niello.NO_UNIT, {color = niello.rgb(BLUE)})
}

// ANCHOR: tasks
Task :: struct {
	id:    int,
	title: string,
	done:  bool,
	row:   niello.Instance,
}

declare_tasks :: proc(tasks: []Task, selected: int) {
	if niello.begin(tasks_u) {
		for &t in tasks {
			t.row = niello.show(task_u, {
				text     = t.title,
				variant  = task_selected if t.id == selected else niello.NO_UNIT,
				disabled = t.done,
			}, niello.key_int(t.id))
		}
	}
}
// ANCHOR_END: tasks

// ANCHOR: progress
// declare_progress shows one track and its fill. The fill's width is the
// instance's own; every progress bar shares the two units.
declare_progress :: proc(done, total: int, buf: []u8) {
	frac := f32(done) / f32(max(total, 1))
	if niello.begin(track_u) {
		niello.show(fill_u, {size = niello.size(niello.percent(frac), niello.grow())})
	}
	niello.show(task_u, {text = fmt.bprintf(buf, "%d of %d done", done, total)})
}
// ANCHOR_END: progress
