package headless

import niello "niello:."

VIEWPORT :: niello.Vec2{480, 320}

// step runs one frame of ctx with declare and its state.
step :: proc(ctx: ^niello.Context, declare: proc(app: ^$T), app: ^T, input: niello.Input = {}) -> niello.Frame_Result {
	input := input
	input.viewport = VIEWPORT
	niello.frame_begin(ctx, input, 1.0 / 60.0)
	declare(app)
	return niello.frame_end()
}

// pointer is input with the pointer at p and the left button's state.
pointer :: proc(p: niello.Vec2, down := false, pressed := false, released := false) -> niello.Input {
	in_: niello.Input
	in_.mouse = p
	in_.mouse_valid = true
	if down {
		in_.buttons_down = {.Left}
	}
	if pressed {
		in_.buttons_pressed = {.Left}
	}
	if released {
		in_.buttons_released = {.Left}
	}
	return in_
}

// center is the middle of instance i's last committed rect.
center :: proc(i: niello.Instance) -> niello.Vec2 {
	r, _ := niello.rect(i)
	return r.pos + r.size / 2
}

// click presses and releases the left button over i, one frame each.
click :: proc(ctx: ^niello.Context, declare: proc(app: ^$T), app: ^T, i: niello.Instance) {
	at := center(i)
	step(ctx, declare, app, pointer(at, down = true, pressed = true))
	step(ctx, declare, app, pointer(at, released = true))
}

// fill_of is the fill color drawn for instance i this frame.
fill_of :: proc(i: niello.Instance) -> (niello.Color, bool) {
	r, ok := niello.rect(i)
	if !ok {
		return {}, false
	}
	for cmd in niello.draw_list() {
		if cmd.tag == .Rect && cmd.bounds == r {
			return cmd.color, true
		}
	}
	return {}, false
}

// drawn reports that this frame draws text s.
drawn :: proc(s: string) -> bool {
	for cmd in niello.draw_list() {
		if cmd.tag == .Text && string(cmd.text_ptr[:cmd.text_len]) == s {
			return true
		}
	}
	return false
}
