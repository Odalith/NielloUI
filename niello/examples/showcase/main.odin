// niello/examples/showcase — one app that exercises most of NielloUI,
// for testing everything in one run.
//
// A sidebar picks a page; each page covers one area (controls, layout,
// text, keyboard input, scrolling, animation, popups, drag, images,
// async + windows). A theme switch in the header re-themes every page
// through group broadcasts, and the status bar reports what the last
// interaction did.
//
// The app's state is one App struct handed to declare by run's typed
// form; units are minted once at startup (components.odin).
//
//	odin run niello/examples/showcase
//	odin run niello/examples/showcase -define:NIELLO_DEBUG=true   (F12: debugger)
package main

import "core:fmt"
import niello "../.."
import debugui "../../debugui"
import inbox "../../inbox"
import niello_sdl "../../sdl"

Page :: enum {
	Controls,
	Layout,
	Text,
	Input,
	Scrolling,
	Animation,
	Popups,
	Drag,
	Images,
	Async_Windows,
}

PAGE_NAMES := [Page]string{
	.Controls      = "Controls",
	.Layout        = "Layout",
	.Text          = "Text",
	.Input         = "Keyboard & focus",
	.Scrolling     = "Scrolling",
	.Animation     = "Animation",
	.Popups        = "Popups",
	.Drag          = "Drag",
	.Images        = "Images",
	.Async_Windows = "Async & windows",
}

App :: struct {
	ctx:          ^niello.Context,
	page:         Page,
	dark:         bool,
	status:       Status,
	content_i:    niello.Instance,
	content_bar:  Scrollbar,
	nav_i:        [Page]niello.Instance,

	controls:     Controls_State,
	layout:       Layout_State,
	text:         Text_State,
	input:        Input_State,
	scrolling:    Scrolling_State,
	anim:         Anim_State,
	popups:       Popups_State,
	drag:         Drag_State,
	images:       Images_State,
	async:        Async_State,
}

// Shell units: the frame around the pages.
shell: struct {
	root, header, header_title, spacer, body, sidebar, nav_item, nav_item_on: niello.Unit,
	nav_hover, nav_label, content, page, status_bar: niello.Unit,
}

mint_shell :: proc(t: Theme) {
	niello.mint(&shell.root, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(percent(1), percent(1)),
		color = t.bg, groups = []niello.Group{groups.bg},
	})
	niello.mint(&shell.header, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fixed(56)),
		padding = pad_xy(18, 0), gap = 10, align = START_CENTER,
		color = t.panel, groups = []niello.Group{groups.panel},
	})
	niello.mint(&shell.header_title, ui.title, {font_size = 18})
	niello.group_add(groups.ink, shell.header_title)
	niello.mint(&shell.spacer, niello.NO_UNIT, {size = size(grow(), fixed(1))})
	niello.mint(&shell.body, niello.NO_UNIT, {layout = .Left_To_Right, size = size(grow(), grow())})
	niello.mint(&shell.sidebar, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(200), grow()),
		padding = pad(10), gap = 2,
		color = t.panel, groups = []niello.Group{groups.panel},
	})
	niello.mint(&shell.nav_hover, niello.NO_UNIT, {color = t.hover, groups = []niello.Group{groups.hover}})
	niello.mint(&shell.nav_item_on, niello.NO_UNIT, {color = t.accent})
	niello.mint(&shell.nav_item, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fixed(34)),
		padding = pad_xy(12, 0), align = START_CENTER, corner_radius = 6,
		cursor = .Pointer, focusable = true,
		hover = shell.nav_hover, focus = ui.focus_ring,
	})
	niello.mint(&shell.nav_label, ui.body, {})
	niello.group_add(groups.ink, shell.nav_label)
	// The content area scrolls vertically; align [x, y] puts its
	// anchored scrollbar at the right edge, top.
	niello.mint(&shell.content, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), grow()),
		scroll = .Vertical, smooth_scroll = true,
		align = niello.align(.End, .Start),
		padding = niello.pad_each(22, 20, 26, 24),
	})
	niello.mint(&shell.page, niello.NO_UNIT, {layout = .Top_To_Bottom, size = size(grow(), fit()), gap = 14})
	niello.mint(&shell.status_bar, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fixed(28)),
		padding = pad_xy(14, 0), gap = 18, align = START_CENTER,
		color = t.panel, groups = []niello.Group{groups.panel},
	})
}

declare :: proc(app: ^App) {
	async_drain(app)
	inspector_reap(app)

	if niello.begin(shell.root) {
		declare_header(app)
		if niello.begin(shell.body) {
			declare_sidebar(app)
			declare_content(app)
		}
		declare_status(app)
	}
	// Popups and dialogs are overlay roots: declared after the main
	// tree, they paint and hit-test above it.
	popups_overlay(app)
	drag_overlay(app)
}

declare_header :: proc(app: ^App) {
	if niello.begin(shell.header) {
		niello.show(shell.header_title, {text = "NielloUI showcase", role = .Header})
		niello.show(ui.small, {
			text = niello.NIELLO_DEBUG ? "debug build — F12 opens the debugger" : "build with -define:NIELLO_DEBUG=true for the F12 debugger",
		})
		niello.show(shell.spacer)
		if toggle(app.dark ? "Dark theme" : "Light theme", &app.dark) {
			apply_theme(app.dark ? DARK_THEME : LIGHT_THEME, 250)
			status_set(&app.status, "Theme: %s (one group broadcast per role, 250 ms glide)", app.dark ? "dark" : "light")
		}
	}
}

declare_sidebar :: proc(app: ^App) {
	if niello.begin(shell.sidebar) {
		for p in Page {
			w := niello.With{role = .TabItem, label = PAGE_NAMES[p], a11y_flags = p == app.page ? {.Selected} : {}}
			on := p == app.page
			if on {
				w.variant = shell.nav_item_on
			}
			if niello.begin(shell.nav_item, w, out = &app.nav_i[p]) {
				niello.show(on ? ui.btn_label_on : shell.nav_label, {text = PAGE_NAMES[p]})
			}
			if niello.clicked(app.nav_i[p]) && p != app.page {
				app.page = p
				// One scroller hosts every page: start each page at the top.
				niello.scroll_to(app.content_i, {0, 0})
				status_set(&app.status, "Page: %s", PAGE_NAMES[p])
			}
		}
	}
}

declare_content :: proc(app: ^App) {
	if niello.begin(shell.content, out = &app.content_i) {
		// Keyed by page: each page's instances are its own, so switching
		// pages never carries hover or animation state across.
		if niello.begin(shell.page, key = niello.key_int(int(app.page))) {
			switch app.page {
			case .Controls:      page_controls(app)
			case .Layout:        page_layout(app)
			case .Text:          page_text(app)
			case .Input:         page_input(app)
			case .Scrolling:     page_scrolling(app)
			case .Animation:     page_animation(app)
			case .Popups:        page_popups(app)
			case .Drag:          page_drag(app)
			case .Images:        page_images(app)
			case .Async_Windows: page_async(app)
			}
		}
		scrollbar(&app.content_bar, app.content_i)
	}
}

declare_status :: proc(app: ^App) {
	if niello.begin(shell.status_bar) {
		mouse := "outside"
		if p, mok := niello.mouse_position(); mok {
			mouse = fmt.tprintf("%.0f, %.0f", p.x, p.y)
		}
		niello.show(ui.small, {text = fmt.tprintf("mouse %s", mouse)})
		niello.show(ui.small, {text = fmt.tprintf("instances %d", niello.instance_count(app.ctx))})
		niello.show(ui.small, {text = status_text(&app.status)})
	}
}

// app_init mints every unit and creates the main context. Shared by
// main and the headless smoke test (showcase_test.odin).
app_init :: proc(app: ^App) {
	app.dark = true
	status_set(&app.status, "Pick a page on the left. Tab moves focus; Space/Enter activates.")
	mint_units(DARK_THEME)
	mint_shell(DARK_THEME)
	mint_pages(app)
	scrollbar_init(&app.content_bar, .Vertical)
	app.ctx = niello.context_create()
	app.async.box = inbox.create(Msg, app.ctx)
}

app_destroy :: proc(app: ^App) {
	async_shutdown(app)
	inspector_shutdown(app)
	destroy_pages(app)
	inbox.destroy(&app.async.box)
	niello.shutdown() // the main context, every unit and group, the caches
}

main :: proc() {
	app: App
	app_init(&app)
	defer app_destroy(&app)
	debugui.install() // no-op unless built with NIELLO_DEBUG
	niello_sdl.run(app.ctx, {title = "NielloUI showcase", width = 1180, height = 780}, declare, &app)
}
