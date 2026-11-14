package headless

import "core:testing"
import niello "niello:."
import model "../model"

// ---- units ----

@(test)
variants_copy_and_propagate_pushes :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_text()
	testing.expect_value(t, niello.style_of(model.title).font_size, 22)
	testing.expect_value(t, niello.style_of(model.title).font_color, niello.rgb(model.INK))

	model.emphasize()
	testing.expect_value(t, niello.style_of(model.body).font_color, niello.rgb(model.BLUE))
	testing.expect_value(t, niello.style_of(model.card).corner_radius, 12)
	// the variant does not follow its base...
	testing.expect_value(t, niello.style_of(model.title).font_color, niello.rgb(model.INK))
	// ...until the change is propagated
	model.follow_body()
	testing.expect_value(t, niello.style_of(model.title).font_color, niello.rgb(model.BLUE))

	// a field the variant set itself is its own
	niello.set(model.body, .Font_Size, f32(16))
	niello.propagate(model.body, {.Font_Size})
	testing.expect_value(t, niello.style_of(model.title).font_size, 22)
}

Button_App :: struct {
	i: niello.Instance,
}

declare_button :: proc(app: ^Button_App) {
	app.i = niello.show(model.button, {text = "Save"})
}

@(test)
overlays_apply_while_hovered_and_pressed :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_button()
	ctx := niello.context_create()
	app: Button_App
	step(ctx, declare_button, &app)
	c, _ := fill_of(app.i)
	testing.expect_value(t, c, niello.rgb(0xf1f3f4))

	at := center(app.i)
	step(ctx, declare_button, &app, pointer(at))
	c, _ = fill_of(app.i)
	testing.expect_value(t, c, niello.rgb(0xe8eaed))

	step(ctx, declare_button, &app, pointer(at, down = true, pressed = true))
	c, _ = fill_of(app.i)
	testing.expect_value(t, c, niello.rgb(0xd2d5da))
}

@(test)
unmint_frees :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_text()
	testing.expect(t, niello.unit_live(model.card))
	niello.unmint(model.card)
	testing.expect(t, !niello.unit_live(model.card))
}

// ---- declaring ----

@(test)
call_sites_name_instances :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_declaring()
	ctx := niello.context_create()
	app: model.Settings
	step(ctx, model.declare_settings, &app)
	save := app.save_i
	app.advanced = true // a conditional row appears before Save
	step(ctx, model.declare_settings, &app)
	testing.expect_value(t, app.save_i, save)
}

@(test)
keys_follow_items :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_declaring()
	ctx := niello.context_create()
	items := []model.Item{{id = 1, name = "a"}, {id = 2, name = "b"}, {id = 3, name = "c"}}
	step(ctx, declare_items, &items)
	b := items[1].row
	reordered := []model.Item{items[2], items[0], items[1]}
	step(ctx, declare_items, &reordered)
	testing.expect_value(t, reordered[2].row, b) // b kept its instance

	// without keys, instances belong to places in the loop
	step(ctx, declare_items_by_position, &items)
	second := items[1].row
	step(ctx, declare_items_by_position, &reordered)
	testing.expect_value(t, reordered[1].row, second) // a now holds b's old place
}

declare_items :: proc(items: ^[]model.Item) {
	model.declare_items(items^)
}

declare_items_by_position :: proc(items: ^[]model.Item) {
	model.declare_items_by_position(items^)
}

Tags :: struct {
	a, b: niello.Instance,
}

declare_tags :: proc(app: ^Tags) {
	if niello.begin(model.panel_u) {
		app.a = model.tag("one")
		app.b = model.tag("two")
	}
}

@(test)
components_forward_their_call_site :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_declaring()
	ctx := niello.context_create()
	app: Tags
	step(ctx, declare_tags, &app)
	first := app
	step(ctx, declare_tags, &app)
	testing.expect(t, app.a != app.b)
	testing.expect_value(t, app.a, first.a)
	testing.expect_value(t, app.b, first.b)
}

@(test)
begin_out_keeps_the_container :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_declaring()
	ctx := niello.context_create()
	app: model.Inbox
	step(ctx, model.declare_inbox, &app)
	testing.expect(t, app.list_i != 0)
	_, ok := niello.rect(app.list_i)
	testing.expect(t, ok)
}

// ---- With ----

Tasks_App :: struct {
	tasks:    []model.Task,
	selected: int,
}

declare_tasks :: proc(app: ^Tasks_App) {
	model.declare_tasks(app.tasks, app.selected)
}

@(test)
with_variant_and_disabled :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_with()
	ctx := niello.context_create()
	app := Tasks_App {
		tasks    = []model.Task{{id = 1, title = "Write"}, {id = 2, title = "Ship", done = true}},
		selected = 1,
	}
	step(ctx, declare_tasks, &app)
	c, _ := fill_of(app.tasks[0].row)
	testing.expect_value(t, c, niello.rgb(model.SELECTED))
	c, _ = fill_of(app.tasks[1].row)
	testing.expect_value(t, c, niello.rgb(0xffffff))
	testing.expect(t, drawn("Write"))

	// a disabled instance takes no click
	at := center(app.tasks[1].row)
	step(ctx, declare_tasks, &app, pointer(at, down = true, pressed = true))
	step(ctx, declare_tasks, &app, pointer(at, released = true))
	testing.expect(t, !niello.clicked(app.tasks[1].row))
}

Progress_App :: struct {
	buf: [64]u8,
}

declare_progress :: proc(app: ^Progress_App) {
	model.declare_progress(3, 4, app.buf[:])
}

@(test)
with_size_is_per_instance :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_with()
	ctx := niello.context_create()
	app: Progress_App
	step(ctx, declare_progress, &app)
	testing.expect(t, drawn("3 of 4 done"))
	found := false
	for cmd in niello.draw_list() {
		if cmd.tag == .Rect && cmd.color == niello.rgb(model.BLUE) {
			testing.expect_value(t, cmd.bounds.size.x, VIEWPORT.x * 0.75)
			found = true
		}
	}
	testing.expect(t, found)
}

// ---- interaction ----

@(test)
clicks_are_polled_where_declared :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_interaction()
	ctx := niello.context_create()
	app: model.Editor
	step(ctx, model.declare_toolbar, &app)
	testing.expect_value(t, app.saves, 0)

	click(ctx, model.declare_toolbar, &app, app.save_i)
	testing.expect_value(t, app.saves, 1)
	click(ctx, model.declare_toolbar, &app, app.bold_i)
	testing.expect(t, app.bold)

	// hover is seen by the next declaration
	step(ctx, model.declare_toolbar, &app, pointer(center(app.bold_i)))
	testing.expect(t, drawn("Make the selection bold"))
}

Gone_App :: struct {
	shown: bool,
	i:     niello.Instance,
}

declare_maybe :: proc(app: ^Gone_App) {
	if app.shown {
		app.i = niello.show(model.tool_u, {text = "Here"})
	}
}

@(test)
stale_handles_answer_false :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_interaction()
	ctx := niello.context_create()
	app := Gone_App{shown = true}
	step(ctx, declare_maybe, &app)
	at := center(app.i)
	step(ctx, declare_maybe, &app, pointer(at))
	testing.expect(t, niello.hovered(app.i))
	app.shown = false
	step(ctx, declare_maybe, &app, pointer(at))
	step(ctx, declare_maybe, &app, pointer(at))
	_, ok := niello.rect(app.i)
	testing.expect(t, !ok)
	testing.expect(t, !niello.hovered(app.i))
	testing.expect(t, !niello.clicked(app.i))
}

@(test)
queries_see_the_previous_frame :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_interaction()
	ctx := niello.context_create()
	niello.frame_begin(ctx, {viewport = VIEWPORT}, 1.0 / 60.0)
	i := niello.show(model.tool_u, {text = "Save"})
	_, during := niello.rect(i)
	niello.frame_end()
	_, after := niello.rect(i)
	testing.expect(t, !during) // the first declaration has no layout to ask
	testing.expect(t, after)
}

@(test)
dragging_moves_the_split :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_interaction()
	ctx := niello.context_create()
	app := model.Split{left_w = 200}
	step(ctx, model.declare_split, &app)
	at := niello.Vec2{203, 100} // on the handle
	step(ctx, model.declare_split, &app, pointer(at, down = true, pressed = true))
	for dx in ([]f32{10, 20, 30, 40}) {
		step(ctx, model.declare_split, &app, pointer(at + {dx, 0}, down = true))
	}
	step(ctx, model.declare_split, &app, pointer(at + {40, 0}, released = true))
	testing.expect(t, app.left_w > 220)
	testing.expect(t, app.left_w <= 240)
}

// ---- groups ----

@(test)
groups_broadcast_by_role :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_themed(model.LIGHT)
	before := niello.style_of(model.page_u)
	model.apply_theme(model.DARK)
	page := niello.style_of(model.page_u)
	testing.expect_value(t, page.color, model.DARK.surface)
	testing.expect_value(t, page.font_color, before.font_color) // not a member for .Font_Color
	testing.expect_value(t, niello.style_of(model.label_u).font_color, model.DARK.ink)
	testing.expect_value(t, niello.style_of(model.action_u).color, model.DARK.action)
	testing.expect_value(t, niello.style_of(model.action_u).font_color, model.DARK.surface)
	// pinned: the broadcast skips delete's color, not its text color
	testing.expect_value(t, niello.style_of(model.delete_u).color, niello.rgb(0xd93025))
	testing.expect_value(t, niello.style_of(model.delete_u).font_color, model.DARK.surface)
}

@(test)
joining_applies_nothing :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_themed(model.LIGHT)
	model.apply_theme(model.DARK)
	model.mint_dialog()
	testing.expect_value(t, niello.style_of(model.dialog_u).color, model.DARK.surface)
	testing.expect_value(t, niello.style_of(model.note_u).font_color, model.LIGHT.ink)
	model.apply_theme(model.DARK)
	testing.expect_value(t, niello.style_of(model.note_u).font_color, model.DARK.ink)
}

Page_App :: struct {}

declare_page :: proc(app: ^Page_App) {
	if niello.begin(model.page_u) {
		niello.show(model.label_u, {text = "Hello"})
	}
}

@(test)
broadcasts_glide :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_themed(model.LIGHT)
	ctx := niello.context_create()
	app: Page_App
	step(ctx, declare_page, &app)
	model.apply_theme(model.DARK, 200)
	res := step(ctx, declare_page, &app)
	testing.expect(t, res.next_wake_ms < max(u32)) // frames keep coming while it glides
	for _ in 0 ..< 30 {
		step(ctx, declare_page, &app)
	}
	testing.expect_value(t, niello.style_of(model.page_u).color, model.DARK.surface)
}

// ---- the frame ----

Idle_App :: struct {}

declare_idle :: proc() {
	if niello.begin(model.page_u) {
		niello.show(model.label_u, {text = "Idle"})
	}
}

@(test)
an_unchanged_frame_does_nothing :: proc(t: ^testing.T) {
	defer niello.shutdown()
	model.mint_themed(model.LIGHT)
	ctx := niello.context_create()
	in_ := niello.Input{viewport = VIEWPORT}
	res := model.host_frame(ctx, in_, 1.0 / 60.0, declare_idle)
	testing.expect(t, res.changed)
	res = model.host_frame(ctx, in_, 1.0 / 60.0, declare_idle)
	testing.expect(t, !res.changed)
	testing.expect_value(t, res.next_wake_ms, max(u32))

	niello.set(model.label_u, .Font_Color, model.LIGHT.action)
	res = model.host_frame(ctx, in_, 1.0 / 60.0, declare_idle)
	testing.expect(t, res.changed)
	testing.expect(t, len(res.damage) > 0)
}
