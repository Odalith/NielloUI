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
import controls "../../controls"
import debugui "../../debugui"
import inbox "../../inbox"
import niello_sdl "../../sdl"

Page :: enum {
	Controls,
	Layout,
	Text,
	Input,
	Scrolling,
	Virtual,
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
	.Virtual       = "Virtual lists",
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
	text_scale:   controls.Slider, // the header's text-size slider (a factor)
	spacing:      controls.Slider, // the header's spacing slider (a factor)
	status:       Status,
	content_i:    niello.Instance,
	content_bar:  controls.Scrollbar,
	nav_list_i:   niello.Instance,
	nav_bar:      controls.Scrollbar,
	nav_i:        [Page]niello.Instance,

	controls:     Controls_State,
	layout:       Layout_State,
	text:         Text_State,
	input:        Input_State,
	scrolling:    Scrolling_State,
	virt:         Virtual_State,
	anim:         Anim_State,
	popups:       Popups_State,
	drag:         Drag_State,
	images:       Images_State,
	async:        Async_State,
}

// Shell units: the frame around the pages.
// nav_gap is a spacing token of the showcase's own (the gap between the
// sidebar's page items): an app adds tokens the way controls does, a
// group per token, and broadcasts it with the same factor.
nav_gap: niello.Group
NAV_GAP :: u16(2)

shell: struct {
	root, sidebar, brand, brand_title, brand_sub, section_label: niello.Unit,
	nav_list, nav_item, nav_item_on, nav_hover, nav_label, nav_label_on, nav_mark, nav_mark_off: niello.Unit,
	display, display_title, display_label, vdivider, hdivider: niello.Unit,
	main, content, page, status_bar: niello.Unit,
}

mint_shell :: proc(t: Theme) {
	G := &controls.groups
	as :: controls.as
	// One row: the sidebar, a hairline, and the main column (the pages over
	// the status bar). A style has no one-sided border, so the hairlines
	// are 1-DIP nodes of the raised color.
	niello.mint(&shell.root, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(percent(1), percent(1)),
		color = t.bg, groups = []niello.Group{G.bg},
	})
	niello.mint(&shell.vdivider, niello.NO_UNIT, {size = size(fixed(1), grow()), color = t.raised, groups = []niello.Group{G.raised}})
	niello.mint(&shell.hdivider, niello.NO_UNIT, {size = size(grow(), fixed(1)), color = t.raised, groups = []niello.Group{G.raised}})
	niello.mint(&shell.main, niello.NO_UNIT, {layout = .Top_To_Bottom, size = size(grow(), grow())})

	// The sidebar: the brand, the page list, the Display panel. Its width
	// and padding are fixed (see declare_display); the page list grows into
	// the space between and scrolls when its items no longer fit.
	nav_gap = niello.group_new("showcase.nav_gap")
	accent_soft = niello.group_new("showcase.accent_soft")
	niello.mint(&shell.sidebar, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(fixed(224), grow()),
		padding = niello.pad_each(12, 18, 12, 12), gap = 6,
		color = t.panel,
		group_masks = []niello.Group_Mask{as(G.panel, .Color)},
	})
	niello.mint(&shell.brand, niello.NO_UNIT, {layout = .Top_To_Bottom, size = size(grow(), fit()), padding = niello.pad_each(10, 0, 10, 12), gap = 2})
	niello.mint(&shell.brand_title, niello.NO_UNIT, {
		font_size = 18, font_weight = .Bold, font_color = t.ink,
		group_masks = []niello.Group_Mask{as(G.ink, .Font_Color)},
	})
	niello.mint(&shell.brand_sub, niello.NO_UNIT, {
		font_size = 12, font_color = t.dim,
		group_masks = []niello.Group_Mask{as(G.dim, .Font_Color)},
	})
	niello.mint(&shell.section_label, niello.NO_UNIT, {
		padding = niello.pad_each(10, 6, 10, 2),
		font_size = 11, font_weight = .SemiBold, font_color = t.dim,
		group_masks = []niello.Group_Mask{as(G.dim, .Font_Color)},
	})
	niello.mint(&shell.nav_list, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), grow()),
		gap = NAV_GAP, scroll = .Vertical,
		align = niello.align(.End, .Start), // the anchored bar: right edge, top
		group_masks = []niello.Group_Mask{as(nav_gap, .Gap)},
	})
	// A page item: a mark (an accent bar on the current page, an empty slot
	// on the rest, so labels line up) and the label. The current page is
	// an accent-tinted fill with a bolder label, readable under the hover
	// fill too.
	niello.mint(&shell.nav_hover, niello.NO_UNIT, {color = t.raised, groups = []niello.Group{G.raised}})
	niello.mint(&shell.nav_item_on, niello.NO_UNIT, {color = ACCENT_SOFT_DARK, groups = []niello.Group{accent_soft}})
	niello.mint(&shell.nav_item, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fit()),
		padding = pad_xy(controls.DEFAULT_SPACING.control_pad[0], controls.DEFAULT_SPACING.control_pad[1]),
		gap = 10, align = START_CENTER, corner_radius = 8,
		cursor = .Pointer, focusable = true,
		hover = shell.nav_hover,
		group_masks = []niello.Group_Mask{as(G.control_pad, .Padding)},
	})
	niello.mint(&shell.nav_mark_off, niello.NO_UNIT, {size = size(fixed(3), fixed(16)), corner_radius = 2})
	niello.mint(&shell.nav_mark, shell.nav_mark_off, {color = t.accent, groups = []niello.Group{G.accent}})
	niello.mint(&shell.nav_label, ui.body, {
		font_color = t.dim,
		group_masks = []niello.Group_Mask{as(G.dim, .Font_Color), as(G.body, .Font_Size)},
	})
	niello.mint(&shell.nav_label_on, ui.body, {
		font_weight = .SemiBold,
		group_masks = []niello.Group_Mask{as(G.ink, .Font_Color), as(G.body, .Font_Size)},
	})

	// The Display panel: fixed geometry (see declare_display). An inset
	// (bg) box with a hairline edge: on a raised one, the sliders' raised
	// tracks vanished (found in an agent-harness picture).
	niello.mint(&shell.display, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fit()), padding = pad(12), gap = 8,
		color = t.bg, corner_radius = 10, border_width = 1, border_color = LINE_DARK,
		group_masks = []niello.Group_Mask{as(G.bg, .Color), as(line, .Border_Color)},
	})
	niello.mint(&shell.display_title, niello.NO_UNIT, {
		font_size = 11, font_weight = .SemiBold, font_color = t.dim,
		group_masks = []niello.Group_Mask{as(G.dim, .Font_Color)},
	})
	niello.mint(&shell.display_label, niello.NO_UNIT, {
		font_size = 12, font_color = t.ink,
		group_masks = []niello.Group_Mask{as(G.ink, .Font_Color)},
	})

	// The pages scroll vertically; align [x, y] puts the anchored
	// scrollbar at the right edge, top.
	niello.mint(&shell.content, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), grow()),
		scroll = .Vertical, smooth_scroll = true,
		align = niello.align(.End, .Start),
		padding = niello.pad_each(32, 28, 34, 32),
	})
	niello.mint(&shell.page, niello.NO_UNIT, {
		layout = .Top_To_Bottom, size = size(grow(), fit()), gap = controls.DEFAULT_SPACING.gap + 4,
		group_masks = []niello.Group_Mask{as(G.gap, .Gap)},
	})
	niello.mint(&shell.status_bar, niello.NO_UNIT, {
		layout = .Left_To_Right, size = size(grow(), fit()),
		padding = pad_xy(32, 7), gap = 20, align = START_CENTER,
		color = t.bg, groups = []niello.Group{G.bg},
	})
}

declare :: proc(app: ^App) {
	async_drain(app)
	inspector_reap(app)

	if niello.begin(shell.root) {
		// The sidebar runs the window's full height, and the status bar sits
		// under the pages only: the Display panel at the sidebar's foot then
		// has fixed edges to hold to (see declare_display).
		declare_sidebar(app)
		niello.show(shell.vdivider)
		if niello.begin(shell.main) {
			declare_content(app)
			niello.show(shell.hdivider)
			declare_status(app)
		}
	}
	// Popups and dialogs are overlay roots: declared after the main
	// tree, they paint and hit-test above it.
	popups_overlay(app)
	drag_overlay(app)
}

declare_sidebar :: proc(app: ^App) {
	if niello.begin(shell.sidebar) {
		if niello.begin(shell.brand) {
			niello.show(shell.brand_title, {text = "NielloUI", role = .Header})
			niello.show(shell.brand_sub, {text = "Component showcase"})
		}
		niello.show(shell.section_label, {text = "PAGES"})
		if niello.begin(shell.nav_list, out = &app.nav_list_i) {
			declare_nav(app)
			controls.scrollbar(&app.nav_bar, app.nav_list_i)
		}
		declare_display(app)
	}
}

// declare_nav declares the page list's items.
declare_nav :: proc(app: ^App) {
	for p in Page {
		w := niello.With{role = .TabItem, label = PAGE_NAMES[p], a11y_flags = p == app.page ? {.Selected} : {}}
		on := p == app.page
		if on {
			w.variant = shell.nav_item_on
		}
		if niello.begin(shell.nav_item, w, out = &app.nav_i[p]) {
			niello.show(on ? shell.nav_mark : shell.nav_mark_off)
			niello.show(on ? shell.nav_label_on : shell.nav_label, {text = PAGE_NAMES[p]})
		}
		if niello.clicked(app.nav_i[p]) && p != app.page {
			app.page = p
			// One scroller hosts every page: start each page at the top.
			niello.scroll_to(app.content_i, {0, 0})
			status_set(&app.status, "Page: %s", PAGE_NAMES[p])
		}
	}
}

// declare_display is the sidebar's Display panel: the text-size and
// spacing sliders. Text size and spacing are broadcasts, like the theme:
// one apply call each, through the type and spacing roles every unit
// joined at mint, applied live while a slider is dragged.
//
// A slider must not move while it is dragged, so nothing that decides
// where these sit scales with them: the sidebar's width and padding are
// fixed, the fill above pins the panel to the bottom however tall the nav
// items grow, the panel's own labels are a fixed size (theme colors, no
// type role), each value label sits on its own line above its slider, the
// sidebar's bottom edge is the window's (the status bar is under the
// content, not under the sidebar), and the page list above the panel
// scrolls rather than push it when its items outgrow the space.
declare_display :: proc(app: ^App) {
	if niello.begin(shell.display) {
		niello.show(shell.display_title, {text = "DISPLAY", role = .Header})
		if controls.toggle_switch("Dark theme", &app.dark) {
			apply_showcase_theme(app.dark, 250)
			status_set(&app.status, "Theme: %s (one group broadcast per role, 250 ms glide)", app.dark ? "dark" : "light")
		}
		niello.show(shell.display_label, {text = fmt.tprintf("Text size · %.0f%%", app.text_scale.value * 100)})
		if controls.slider(&app.text_scale, "Text size") {
			controls.apply_type(controls.scale_type(controls.DEFAULT_TYPE, app.text_scale.value))
			status_set(&app.status, "Text size %.0f%% (one broadcast per type role)", app.text_scale.value * 100)
		}
		niello.show(shell.display_label, {text = fmt.tprintf("Spacing · %.0f%%", app.spacing.value * 100)})
		if controls.slider(&app.spacing, "Spacing") {
			controls.apply_spacing(controls.scale_spacing(controls.DEFAULT_SPACING, app.spacing.value))
			// The showcase's own token rides the same factor.
			niello.group_set(nav_gap, .Gap, u16(f32(NAV_GAP) * app.spacing.value + 0.5))
			status_set(&app.status, "Spacing %.0f%% (one broadcast per spacing role)", app.spacing.value * 100)
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
			case .Virtual:       page_virtual(app)
			case .Animation:     page_animation(app)
			case .Popups:        page_popups(app)
			case .Drag:          page_drag(app)
			case .Images:        page_images(app)
			case .Async_Windows: page_async(app)
			}
		}
		controls.scrollbar(&app.content_bar, app.content_i)
	}
}

declare_status :: proc(app: ^App) {
	if niello.begin(shell.status_bar) {
		mouse := "outside"
		if p, mok := niello.mouse_position(); mok {
			mouse = fmt.tprintf("%.0f, %.0f", p.x, p.y)
		}
		niello.show(ui.small, {text = niello.NIELLO_DEBUG ? "Debug build · F12 debugger" : "Release build"})
		niello.show(ui.small, {text = fmt.tprintf("mouse %s", mouse)})
		niello.show(ui.small, {text = fmt.tprintf("instances %d", niello.instance_count(app.ctx))})
		niello.show(ui.small, {text = status_text(&app.status)})
	}
}

// app_init mints every unit and creates the main context. Shared by
// main and the headless smoke test (showcase_test.odin).
app_init :: proc(app: ^App) {
	app.dark = true
	app.text_scale = controls.Slider{value = 1, min = 0.75, max = 1.75, step = 0.05}
	app.spacing = controls.Slider{value = 1, min = 0.5, max = 2, step = 0.1}
	status_set(&app.status, "Pick a page on the left. Tab moves focus; Space/Enter activates.")
	controls.init(DARK_THEME) // the shipped controls and the theme's role groups
	mint_units(DARK_THEME)
	mint_shell(DARK_THEME)
	mint_pages(app)
	app.ctx = niello.context_create()
	app.controls.city.selected = -1 // nothing chosen yet: the placeholder shows
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
