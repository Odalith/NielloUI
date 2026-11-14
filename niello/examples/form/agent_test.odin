// agent_test.odin — the form through the agent harness (niello/agent):
// fill it in and submit, then submit with the name empty.
//
//	tools/agent.sh niello/examples/form
package main

import "core:testing"
import niello "../.."
import "../../agent"
import controls "../../controls"

when niello.NIELLO_DEBUG {

	@(test)
	form_submit :: proc(t: ^testing.T) {
		mint()
		app := Form{status = "Tab into a box and type."}
		defer {
			controls.text_box_destroy(&app.name)
			controls.text_box_destroy(&app.quest)
			niello.shutdown()
		}
		s := agent.session_open(declare, &app, viewport = {680, 520})
		defer agent.session_close(s)
		agent.snapshot(s, "start")

		agent.click(s, agent.find(s, role = .Edit, name = "e.g. Ada"))
		agent.type_text(s, "Ada")
		agent.press_key(s, .Enter) // Enter moves on to the quest box
		agent.type_text(s, "To seek the grail")
		agent.click(s, agent.find(s, role = .Button, name = "Submit"))
		agent.snapshot(s, "submitted")
		testing.expect(t, agent.exists(s, text = "Submitted — name: Ada · quest: To seek the grail"), "the status reports what was sent")

		agent.click(s, agent.find(s, role = .Button, name = "Clear"))
		agent.click(s, agent.find(s, role = .Button, name = "Submit"))
		agent.snapshot(s, "empty name")
		testing.expect(t, agent.exists(s, text = "The name box is empty — Tab over and type something."), "an empty name is refused")

		testing.expect(t, agent.report(s) == 0, "the form has no findings")
	}
}
