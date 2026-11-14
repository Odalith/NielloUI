// agent_test.odin — the showcase through the agent harness (niello/agent):
// every page, with the app's real text metrics, snapshotted and linted.
//
//	tools/agent.sh niello/examples/showcase
//
// The report lands in agent-out/showcase_pages/. The headless walk in
// showcase_test.odin is a different test: mock metrics, both builds, and
// the partial-repaint check.
package main

import "core:testing"
import niello "../.."
import "../../agent"

when niello.NIELLO_DEBUG {

	@(test)
	showcase_pages :: proc(t: ^testing.T) {
		app: App
		app_init(&app)
		defer app_destroy(&app)
		// Tall enough that every page is drawn whole: the text lints
		// check only text that is drawn.
		s := agent.session_open(declare, &app, ctx = app.ctx, viewport = {1180, 3000})
		defer agent.session_close(s)
		// Demos that overflow or trim on purpose: the Layout page's spill
		// box and its squeezed rows, the Text page's ellipsis.
		agent.allow(s, .Overflow, layout_units.spill_box)
		agent.allow(s, .Truncated, layout_units.squeeze_label)
		agent.allow(s, .Truncated, layout_units.squeeze_label_low)
		agent.allow(s, .Truncated, text_units.ellipsis)
		for p in Page {
			agent.click(s, agent.find(s, role = .TabItem, name = PAGE_NAMES[p]))
			agent.snapshot(s, PAGE_NAMES[p])
		}
		// Hover: the tooltip shows, and the readout below the button
		// counts the hover live (it changes while the pointer rests).
		agent.click(s, agent.find(s, role = .TabItem, name = "Controls"))
		agent.allow(s, .Unsettled, agent.find(s, text = "not hovered"))
		agent.hover(s, agent.find(s, role = .Button, name = "Hover me"))
		agent.snapshot(s, "tooltip")
		testing.expect(t, agent.report(s) == 0, "the showcase has no findings")
	}
}
