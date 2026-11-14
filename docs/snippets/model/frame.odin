package model

import niello "niello:."

// ANCHOR: host
// host_frame runs one frame of ctx the way a host does; niello/sdl's run
// does this for every window. declare is the app's UI.
host_frame :: proc(
	ctx: ^niello.Context,
	input: niello.Input,
	dt: f32,
	declare: proc(),
) -> niello.Frame_Result {
	niello.frame_begin(ctx, input, dt) // apply input against the last frame's layout
	declare() // declare this frame's UI
	res := niello.frame_end() // lay out, animate, find what changed
	if res.changed {
		cmds := niello.draw_list() // what to draw; res.damage is where it changed
		_ = cmds // a host renders the commands here
	}
	// Then sleep until input arrives, or res.next_wake_ms passes.
	return res
}
// ANCHOR_END: host
