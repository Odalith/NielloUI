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
		s := agent.session_open(declare, &app, ctx = app.ctx)
		defer agent.session_close(s)
		// The Layout page's spill demo overflows on purpose.
		agent.allow(s, .Overflow, layout_units.spill_box)
		for p in Page {
			agent.click(s, agent.find(s, role = .TabItem, name = PAGE_NAMES[p]))
			agent.snapshot(s, PAGE_NAMES[p])
		}
		// Hover: the tooltip shows, and the readout below the button
		// counts the hover live (it changes while the pointer rests). The
		// window is taller here so the readout is on screen: polled under
		// the fold, it would wake the app for text nobody sees.
		agent.click(s, agent.find(s, role = .TabItem, name = "Controls"))
		agent.resize(s, {1180, 1000})
		agent.allow(s, .Unsettled, agent.find(s, text = "not hovered"))
		agent.hover(s, agent.find(s, role = .Button, name = "Hover me"))
		agent.snapshot(s, "tooltip")
		testing.expect(t, agent.report(s) == 0, "the showcase has no findings")
	}
}
