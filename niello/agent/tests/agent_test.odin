// agent_test.odin — the agent harness on a small fixture app: finding
// controls, acting on them, the lints, settling and the snapshot text.
//
//	odin test niello/agent/tests -define:ODIN_TEST_THREADS=1 -define:NIELLO_DEBUG=true
package agent_tests

import "core:fmt"
import "core:strings"
import "core:testing"
import niello "../.."
import "../../agent"
import controls "../../controls"

// The harness exists in debug builds only.
when niello.NIELLO_DEBUG {

	// Fx is the fixture app: a shopping list with an entry box, and switches
	// that seed one defect each.
	Fx :: struct {
		ctx:        ^niello.Context,
		name:       controls.Text_Box,
		items:      [dynamic]string,
		adds:       int,
		narrow:     bool, // a label too long for its fixed box: truncated
		spill:      bool, // a child wider than its fixed parent: overflow
		twins:      bool, // two buttons with one name: ambiguous
		cover:      bool, // a popup over the Add button: covered
		spin:       bool, // text that changes every frame: unsettled
		poll_hover: bool, // reads hover_duration without showing it: idle wakes
		flat:       bool, // a slider given a fit() height: collapsed
		volume:     controls.Slider,
		frame_n:    int,
		add_i:      niello.Instance,
	}

	fx_root, fx_title, fx_item, fx_narrow, fx_tight, fx_wide, fx_cover, fx_glider, fx_glide_to: niello.Unit

	fx_setup :: proc(a: ^Fx) {
		niello.measure_word_hook = nil
		niello.line_height_hook = nil
		controls.init()
		niello.mint(&fx_root, niello.NO_UNIT, {layout = .Top_To_Bottom, size = niello.size(niello.grow(), niello.grow()), padding = niello.pad(16), gap = 8}, name = "fx_root")
		niello.mint(&fx_title, niello.NO_UNIT, {font_size = 20}, name = "fx_title")
		niello.mint(&fx_item, niello.NO_UNIT, {}, name = "fx_item")
		niello.mint(&fx_narrow, niello.NO_UNIT, {size = niello.size(niello.fixed(60), niello.fit())}, name = "fx_narrow")
		niello.mint(&fx_tight, niello.NO_UNIT, {size = niello.size(niello.fixed(50), niello.fixed(20))}, name = "fx_tight")
		niello.mint(&fx_wide, niello.NO_UNIT, {size = niello.size(niello.fixed(100), niello.fixed(10))}, name = "fx_wide")
		niello.mint(&fx_cover, niello.NO_UNIT, {size = niello.size(niello.fixed(400), niello.fixed(200)), color = niello.Color{0, 0, 0, 255}}, name = "fx_cover")
		niello.mint(&fx_glider, niello.NO_UNIT, {size = niello.size(niello.fixed(10), niello.fixed(10)), color = niello.Color{255, 0, 0, 255}}, name = "fx_glider")
		niello.mint(&fx_glide_to, fx_glider, {color = niello.Color{0, 0, 255, 255}}, name = "fx_glide_to")
		a.ctx = niello.test_context()
	}

	fx_teardown :: proc(a: ^Fx) {
		controls.text_box_destroy(&a.name)
		for it in a.items {
			delete(it)
		}
		delete(a.items)
	}

	fx_declare :: proc(a: ^Fx) {
		a.frame_n += 1
		if niello.begin(fx_root) {
			niello.show(fx_title, {text = "Shopping"})
			r := controls.text_box(&a.name, "Item name")
			a.add_i = controls.button("Add item")
			if (niello.clicked(a.add_i) || r.submitted) && len(controls.text_box_text(&a.name)) > 0 {
				append(&a.items, strings.clone(controls.text_box_text(&a.name)))
				controls.text_box_set(&a.name, "")
				a.adds += 1
			}
			for it, k in a.items {
				niello.show(fx_item, {text = it}, niello.key_int(k))
			}
			controls.button("Delete", disabled = true)
			niello.show(fx_glider)
			if a.narrow {
				niello.show(fx_narrow, {text = "a label far too long for it"})
			}
			if a.spill {
				if niello.begin(fx_tight) {
					niello.show(fx_wide)
				}
			}
			if a.twins {
				controls.button("Same")
				controls.button("Same")
			}
			if a.spin {
				niello.show(fx_item, {text = fmt.tprintf("frame %d", a.frame_n)})
			}
			if a.flat {
				controls.slider(&a.volume, "Volume", with = {size = niello.size(niello.fixed(200), niello.fit())})
			}
			if a.poll_hover {
				_ = niello.hover_duration(a.add_i)
			}
		}
		if a.cover {
			if niello.begin_popup(fx_cover, 0, .At, opts = {at = {0, 0}, stay = true}) {
			}
		}
	}

	has :: proc(s: ^agent.Session, kind: agent.Finding_Kind) -> int {
		n := 0
		for f in s.findings {
			if f.kind == kind {
				n += 1
			}
		}
		return n
	}

	@(test)
	test_find_click_and_type :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		fx_setup(&a)
		defer fx_teardown(&a)
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-find")
		defer agent.session_close(s)

		box := agent.find(s, role = .Edit, name = "Item name")
		testing.expect(t, box.ok, "the entry box is found by role and name")
		testing.expect(t, agent.click(s, box), "and clicked")
		agent.type_text(s, "Milk")
		testing.expect_value(t, controls.text_box_text(&a.name), "Milk")
		testing.expect(t, agent.click(s, agent.find(s, role = .Button, name = "Add item")), "Add is clicked")
		testing.expect_value(t, a.adds, 1)
		testing.expect(t, agent.find(s, text = "Milk").ok, "the new item shows")

		// Enter in the box submits too.
		agent.click(s, box)
		agent.type_text(s, "Eggs")
		agent.press_key(s, .Enter)
		testing.expect_value(t, a.adds, 2)
		testing.expect_value(t, len(s.findings), 0)
	}

	@(test)
	test_find_reports_missing_and_ambiguous :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		a.twins = true
		fx_setup(&a)
		defer fx_teardown(&a)
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-missing")
		defer agent.session_close(s)

		missing := agent.find(s, role = .Button, name = "Add")
		testing.expect(t, !missing.ok, "no button is named Add")
		testing.expect(t, !agent.click(s, missing), "acting on a missing target does nothing")
		testing.expect_value(t, has(s, .Not_Found), 1)
		msg := s.findings[0].message
		testing.expectf(t, strings.contains(msg, `Button "Add item"`), "the finding lists the nearest candidates: %s", msg)
		testing.expectf(t, s.findings[0].loc.line > 0, "it points at the find call")

		testing.expect(t, !agent.find(s, role = .Button, name = "Same").ok, "two buttons named Same")
		testing.expect_value(t, has(s, .Ambiguous), 1)

		testing.expect(t, !agent.click(s, agent.find(s, role = .Button, name = "Delete")), "a disabled button is not clicked")
		testing.expect_value(t, has(s, .Disabled_Target), 1)
		testing.expect(t, agent.report(s) == 3, "three errors fail the report")
	}

	@(test)
	test_lints_find_seeded_defects :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		fx_setup(&a)
		defer fx_teardown(&a)
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-lints")
		defer agent.session_close(s)

		agent.snapshot(s, "clean")
		testing.expect_value(t, len(s.findings), 0)

		a.narrow = true
		a.spill = true
		agent.settle(s)
		agent.snapshot(s, "defects")
		testing.expect_value(t, has(s, .Truncated), 1)
		testing.expect_value(t, has(s, .Overflow), 1)
		for f in s.findings {
			testing.expectf(t, f.loc.line > 0, "%v points at code", f.kind)
			testing.expect_value(t, f.snapshot, "defects")
		}
		// The same defect seen again is not recorded twice.
		agent.snapshot(s, "again")
		testing.expect_value(t, len(s.findings), 2)

		// An explicit allow exempts a unit.
		b: Fx
		b.narrow = true
		b.ctx = a.ctx
		s2 := agent.session_open(fx_declare, &b, ctx = a.ctx, name = "agent-test-allow")
		defer agent.session_close(s2)
		defer fx_teardown(&b)
		agent.allow(s2, .Truncated, fx_narrow)
		agent.lint(s2)
		testing.expect_value(t, has(s2, .Truncated), 0)
	}

	// Two sessions under one name in a run get a folder each.
	@(test)
	test_session_names_stay_apart :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		fx_setup(&a)
		defer fx_teardown(&a)
		s1 := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-twice")
		s2 := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-twice")
		testing.expect(t, s1.dir != s2.dir, "each session has its own folder")
		testing.expect_value(t, s2.name, "agent-test-twice-2")
		agent.session_close(s2)
		agent.session_close(s1)
	}

	// A control laid out with no area: here a slider whose With.size gives
	// its track a fit() height, which measures 0.
	@(test)
	test_collapsed_control :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		a.flat = true
		fx_setup(&a)
		defer fx_teardown(&a)
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-collapsed")
		defer agent.session_close(s)
		agent.lint(s)
		testing.expect_value(t, has(s, .Collapsed), 1)
		if len(s.findings) > 0 {
			testing.expectf(t, strings.contains(s.findings[0].message, `Slider "Volume"`), "names the control: %s", s.findings[0].message)
		}
	}

	@(test)
	test_covered_target :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		a.cover = true
		fx_setup(&a)
		defer fx_teardown(&a)
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-cover")
		defer agent.session_close(s)
		testing.expect(t, !agent.click(s, agent.find(s, role = .Button, name = "Add item")), "a covered button is not clicked")
		testing.expect_value(t, has(s, .Covered_Target), 1)
		testing.expect_value(t, a.adds, 0)
	}

	@(test)
	test_settle :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		fx_setup(&a)
		defer fx_teardown(&a)
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-settle")
		defer agent.session_close(s)

		// A 2 s glide finishes within settle, in simulated time.
		niello.tween(fx_glider, fx_glide_to, 2000)
		time := s.time
		testing.expect(t, agent.settle(s), "a glide settles")
		testing.expectf(t, s.time - time > 1.9 && s.time - time < 2.2, "when it ends (%.2f s)", s.time - time)
		testing.expect_value(t, niello.test_style(fx_glider).color, niello.Color{0, 0, 255, 255})

		a.spin = true
		testing.expect(t, !agent.settle(s), "text changing every frame never settles")
		testing.expect_value(t, has(s, .Unsettled), 1)
		a.spin = false
		agent.settle(s)

		a.poll_hover = true
		agent.hover(s, agent.find(s, role = .Button, name = "Add item"))
		testing.expect_value(t, has(s, .Idle_Wakes), 1)
		testing.expect_value(t, s.findings[len(s.findings) - 1].severity, agent.Severity.Warning)
	}

	@(test)
	test_snapshot_text :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		fx_setup(&a)
		defer fx_teardown(&a)
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-snapshot")
		defer agent.session_close(s)
		agent.click(s, agent.find(s, role = .Edit, name = "Item name"))
		agent.type_text(s, "Milk")
		a.narrow = true
		agent.settle(s)
		agent.lint(s)
		got := agent.dump(s, "typed", false)
		want := `# typed: 1180x780 DIP, focus: Edit "Item name"
Text "Shopping" @16,16 80x20
Edit "Item name" = "Milk" [focused] @16,44 1148x30
Button "Add item" @16,82 84x30
Button "Delete" [disabled] @16,120 70x30
Text "a label far too long for it" @16,176 60x16 !Truncated
`
		testing.expectf(t, got == want, "snapshot text:\n%s", got)
	}

}

// Pictures: with a render hook (niello/sdl's, faked here) and real
// metrics (faked too), a snapshot renders the window and crop a control's
// surroundings; without a hook, none are made and the summary says why.
when niello.NIELLO_DEBUG {
	Px_Call :: struct {
		origin, size: niello.Vec2,
		scale:        f32,
		file:         string,
		cmds:         int,
	}
	px_calls: [dynamic]Px_Call

	px_render :: proc(cmds: []niello.Draw_Cmd, origin, size: niello.Vec2, scale: f32, path: string) -> bool {
		slash := strings.last_index_byte(path, '/')
		append(&px_calls, Px_Call{origin, size, scale, strings.clone(path[slash + 1:]), len(cmds)})
		return true
	}

	px_measure :: proc(font: niello.Font_Handle, weight: niello.Font_Weight, slant: niello.Font_Slant, size: f32, text: string) -> f32 {
		return f32(len(text)) * size * 0.5
	}

	@(test)
	test_pictures :: proc(t: ^testing.T) {
		niello.test_reset()
		defer niello.test_teardown()
		a: Fx
		fx_setup(&a)
		defer fx_teardown(&a)
		defer {
			for c in px_calls {
				delete(c.file)
			}
			delete(px_calls)
			px_calls = nil
			niello.render_png_hook = nil
			niello.measure_word_hook = nil
		}

		// No render hook: no pictures, and the summary says why.
		s0 := agent.session_open(fx_declare, &a, ctx = a.ctx, name = "agent-test-nopics")
		agent.snapshot(s0, "plain")
		testing.expect_value(t, s0.pictures, 0)
		testing.expect(t, !agent.crop(s0, agent.find(s0, role = .Button, name = "Add item"), "add"), "no crop without a hook")
		agent.session_close(s0)

		niello.render_png_hook = px_render
		niello.measure_word_hook = px_measure
		s := agent.session_open(fx_declare, &a, ctx = a.ctx, viewport = {600, 400}, name = "agent-test-pics")
		defer agent.session_close(s)
		agent.snapshot(s, "start")
		testing.expect_value(t, len(px_calls), 1)
		if len(px_calls) == 1 {
			c := px_calls[0]
			testing.expect_value(t, c.origin, niello.Vec2{0, 0})
			testing.expect_value(t, c.size, niello.Vec2{600, 400})
			testing.expect_value(t, c.scale, f32(agent.PICTURE_SCALE))
			testing.expect_value(t, c.file, "01-start.png")
			testing.expect(t, c.cmds > 0, "the frame's draw list")
		}
		add := agent.find(s, role = .Button, name = "Add item")
		testing.expect(t, agent.crop(s, add, "add button", margin = 10), "a crop is written")
		if len(px_calls) == 2 {
			c := px_calls[1]
			testing.expect_value(t, c.origin, add.rect.pos - {10, 10})
			testing.expect_value(t, c.size, add.rect.size + {20, 20})
			testing.expect_value(t, c.file, "02-add-button.png")
		}
		testing.expect_value(t, s.pictures, 2)
	}
}
