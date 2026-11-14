// Package agent is a build harness for coding agents (and people) making a
// Niello app: it runs the app's own declare proc headless, acts on it the
// way a user does, and writes down what it sees and what is wrong, so an
// agent can work in a loop of write, run, look, fix.
//
//	when niello.NIELLO_DEBUG {
//		@(test)
//		add_item :: proc(t: ^testing.T) {
//			app: App
//			app_init(&app)
//			defer app_destroy(&app)
//			s := agent.session_open(declare, &app, ctx = app.ctx)
//			defer agent.session_close(s)
//			agent.snapshot(s, "start")
//			agent.click(s, agent.find(s, role = .Button, name = "Add item"))
//			agent.type_text(s, "Milk")
//			agent.press_key(s, .Enter)
//			agent.snapshot(s, "added")
//			testing.expect(t, agent.report(s) == 0)
//		}
//	}
//
// A session drives frames itself, with a fixed viewport and simulated time
// (settle runs it until the screen is still, jumping straight to each
// deadline, so a delay finishes without waiting). Controls are found by what a user sees: their
// accessibility role and name, or their text, never by coordinates. A
// snapshot writes the screen as indented text, one node per line with its
// rect, state and the file:line that declared it, and checks it: overflow,
// truncated text, a screen that never settles. Every problem is a Finding
// pointing at code; nothing is guessed, and a target that is missing or
// ambiguous is a finding too, never a silent pick.
//
// report writes everything to agent-out/<scenario>/ (set the folder with
// -define:NIELLO_AGENT_OUT=path): the snapshots, findings.txt and
// summary.txt. tools/agent.sh runs an app's scenarios and prints them.
//
// The harness exists in debug builds (-define:NIELLO_DEBUG=true) only: it
// reads the debug snapshot, and a release build pays nothing for it. A
// scenario file wraps its tests in when niello.NIELLO_DEBUG { … }, so the
// app's release test run skips them; tools/agent.sh builds with the
// define. Text is measured with whatever metrics the app has wired:
// importing niello/sdl wires the real ones, the same the window draws with.
package agent

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import niello ".."

when niello.NIELLO_DEBUG {

	// NIELLO_AGENT_OUT is the folder reports are written under, one subfolder
	// per scenario.
	NIELLO_AGENT_OUT :: #config(NIELLO_AGENT_OUT, "agent-out")

	// DEFAULT_VIEWPORT is a session's window size, in DIP, unless it is given
	// one.
	DEFAULT_VIEWPORT :: niello.Vec2{1180, 780}

	// SETTLE_SECONDS is the most simulated time settle runs before it reports
	// the screen as unsettled: longer than any glide or delay a UI means.
	SETTLE_SECONDS :: 10

	// Metrics is how a session measures text.
	Metrics :: enum {
		App,  // the app's own: real fonts when it imports niello/sdl
		Mock, // the core's mock metrics (fixed widths): reproducible anywhere
	}

	// Session is one headless run of an app: its context, the pointer, the
	// simulated clock and what it has found. Open one with session_open; every
	// other proc in the package takes it.
	Session :: struct {
		name:        string, // the scenario's name: its report folder
		ctx:         ^niello.Context,
		own_ctx:     bool,
		declare:     proc(state: rawptr),
		plain:       proc(),
		state:       rawptr,
		viewport:    niello.Vec2,
		dt:          f32,
		mouse:       niello.Vec2,
		mouse_valid: bool,
		res:         niello.Frame_Result,
		frames:      int,
		time:        f64, // simulated seconds since the session opened
		findings:    [dynamic]Finding,
		seen:        map[Finding_Key]bool,
		allows:      [dynamic]Allow,
		snapshots:   int,
		steps:       [dynamic]string, // what the scenario did, in order
		dir:         string,
		metrics:     Metrics,
		saved_hooks: [2]rawptr,
		arena:       virtual.Arena,
		alloc:       runtime.Allocator,
	}

	// session_open starts a headless run of an app's typed declare proc
	// (declare receives state every frame), as niello/sdl's run takes it;
	// session_open_plain takes a plain one. ctx is the app's context when
	// it keeps one (pass it, so the app's queries see the session's
	// frames); without one the session makes its own. name names the
	// scenario and its report folder; it defaults to the calling
	// procedure's name. The session runs the first frames and settles
	// before it returns.
	session_open :: proc(
		declare: proc(state: ^$T),
		state: ^T,
		ctx: ^niello.Context = nil,
		viewport := DEFAULT_VIEWPORT,
		metrics := Metrics.App,
		name := "",
		loc := #caller_location,
	) -> ^Session {
		s := session_new(ctx, viewport, metrics, name != "" ? name : loc.procedure)
		s.declare = transmute(proc(state: rawptr))declare
		s.state = state
		settle(s)
		return s
	}

	// session_open_plain is session_open for a plain declare proc (one that
	// keeps its state in package variables).
	session_open_plain :: proc(
		declare: proc(),
		ctx: ^niello.Context = nil,
		viewport := DEFAULT_VIEWPORT,
		metrics := Metrics.App,
		name := "",
		loc := #caller_location,
	) -> ^Session {
		s := session_new(ctx, viewport, metrics, name != "" ? name : loc.procedure)
		s.plain = declare
		settle(s)
		return s
	}

	@(private)
	session_new :: proc(ctx: ^niello.Context, viewport: niello.Vec2, metrics: Metrics, name: string) -> ^Session {
		s := new(Session)
		_ = virtual.arena_init_growing(&s.arena)
		s.alloc = virtual.arena_allocator(&s.arena)
		s.name = strings.clone(name, s.alloc)
		s.ctx = ctx
		if ctx == nil {
			s.ctx = niello.context_create()
			s.own_ctx = true
		}
		s.viewport = viewport
		s.dt = 1.0 / 60
		s.metrics = metrics
		s.findings = make([dynamic]Finding, s.alloc)
		s.seen = make(map[Finding_Key]bool, s.alloc)
		s.allows = make([dynamic]Allow, s.alloc)
		s.steps = make([dynamic]string, s.alloc)
		s.saved_hooks = {rawptr(niello.measure_word_hook), rawptr(niello.line_height_hook)}
		if metrics == .Mock {
			niello.measure_word_hook = nil
			niello.line_height_hook = nil
		}
		s.dir = strings.concatenate({NIELLO_AGENT_OUT, "/", s.name}, s.alloc)
		os.remove_all(s.dir)
		os.make_directory_all(s.dir)
		return s
	}

	// session_close ends a session: it restores the text metrics it replaced
	// and frees what it holds. A context the session made is destroyed; the
	// app's own is left as it is. Call report before it to write the results.
	session_close :: proc(s: ^Session) {
		if s == nil {
			return
		}
		niello.measure_word_hook = auto_cast s.saved_hooks[0]
		niello.line_height_hook = auto_cast s.saved_hooks[1]
		if s.own_ctx {
			niello.context_destroy(s.ctx)
		}
		virtual.arena_destroy(&s.arena)
		free(s)
	}

	// frame runs one frame with inp (the session fills in the viewport, the
	// pointer and window focus), dt seconds after the last.
	@(private)
	frame :: proc(s: ^Session, inp: niello.Input = {}, dt: f32 = 0) -> niello.Frame_Result {
		inp := inp
		dt := dt > 0 ? dt : s.dt
		inp.viewport = s.viewport
		inp.window_focused = true
		inp.mouse = s.mouse
		inp.mouse_valid = s.mouse_valid
		niello.frame_begin(s.ctx, inp, dt)
		if s.declare != nil {
			s.declare(s.state)
		} else if s.plain != nil {
			s.plain()
		}
		s.res = niello.frame_end()
		s.frames += 1
		s.time += f64(dt)
		return s.res
	}

	// step runs n frames of no input, each a frame interval (1/60 s) apart.
	step :: proc(s: ^Session, n := 1) {
		for _ in 0 ..< n {
			frame(s)
		}
	}

	// wait lets seconds of simulated time pass with no input: a tooltip's
	// delay, a timer.
	wait :: proc(s: ^Session, seconds: f32) {
		left := seconds
		for left > 0 {
			dt := min(left, s.dt)
			frame(s, {}, dt)
			left -= dt
		}
	}

	// settle runs frames until the screen is still: a frame that changes
	// nothing with no deadline pending. Animations run at 60 frames a second
	// of simulated time; a wait with nothing animating (a delay, a timer) jumps
	// straight to its deadline. Reports whether it settled within
	// SETTLE_SECONDS; when not, it records a finding: the screen keeps
	// changing, or the app keeps asking for frames that change nothing.
	settle :: proc(s: ^Session) -> bool {
		start := s.time
		busy: f64
		changed_at: niello.Rect // what the last changing frame repainted
		for s.time - start < SETTLE_SECONDS {
			dt := s.dt
			if w := s.res.next_wake_ms; w != max(u32) && !s.res.changed {
				dt = max(dt, f32(w) / 1000)
			}
			res := frame(s, {}, dt)
			if !res.changed {
				if res.next_wake_ms == max(u32) {
					return true
				}
			} else if s.time - start > SETTLE_SECONDS - 1 {
				busy += f64(dt) // changes in the last second
				if len(res.repaint) > 0 {
					changed_at = res.repaint[0]
				}
			}
		}
		after := len(s.steps) > 0 ? fmt_temp("after %s", s.steps[len(s.steps) - 1]) : "at start"
		if busy == 0 {
			add_finding(s, .Idle_Wakes, .Warning, 0, {}, "the screen is still, but the app keeps asking for frames: a deadline re-arms every %d ms with nothing changing", s.res.next_wake_ms, label = after)
		} else {
			r := changed_at
			add_finding(s, .Unsettled, .Error, damaged_node(s, r), {}, "%s keeps changing: still repainting %.0fx%.0f at %.0f,%.0f after %d s", describe(s, damaged_node(s, r)), r.size.x, r.size.y, r.pos.x, r.pos.y, SETTLE_SECONDS, label = after)
		}
		return false
	}

	// damaged_node is the deepest node whose rect holds r's center: the best
	// pointer at what keeps changing.
	@(private)
	damaged_node :: proc(s: ^Session, r: niello.Rect) -> niello.Instance {
		c := r.pos + r.size / 2
		best: niello.Instance
		for n in niello.debug_tree(s.ctx) {
			if .Culled in n.flags {
				continue
			}
			if c.x >= n.rect.pos.x && c.y >= n.rect.pos.y && c.x < n.rect.pos.x + n.rect.size.x && c.y < n.rect.pos.y + n.rect.size.y {
				best = n.instance
			}
		}
		return best
	}

	// resize changes the session's viewport and settles.
	resize :: proc(s: ^Session, viewport: niello.Vec2) {
		s.viewport = viewport
		log_step(s, "resize %vx%v", viewport.x, viewport.y)
		settle(s)
	}

	// hover moves the pointer to the center of t and settles. A target the
	// pointer cannot reach there (something covers it) is a finding.
	hover :: proc(s: ^Session, t: Target) -> bool {
		if !t.ok {
			return false
		}
		log_step(s, "hover %s", t.desc)
		ok := move_to(s, t)
		settle(s)
		return ok
	}

	// move_to scrolls t into view, as a user would before pointing at it,
	// then moves the pointer to its center.
	@(private)
	move_to :: proc(s: ^Session, t: Target) -> bool {
		t := reveal(s, t)
		s.mouse = t.rect.pos + t.rect.size / 2
		s.mouse_valid = true
		frame(s)
		if !node_hovered(s, t.instance) {
			c := s.mouse
			if c.x < 0 || c.y < 0 || c.x >= s.viewport.x || c.y >= s.viewport.y {
				add_finding(s, .Covered_Target, .Error, t.instance, t.loc, "%s can't be reached: its center %v is outside the %vx%v window, and no scroller brings it in", t.desc, c, s.viewport.x, s.viewport.y)
				return false
			}
			top := hovered_top(s)
			by := "nothing"
			if top != 0 {
				by = describe(s, top)
			}
			add_finding(s, .Covered_Target, .Error, t.instance, t.loc, "%s can't be reached at its center %v: the pointer lands on %s", t.desc, c, by)
			return false
		}
		return true
	}

	// reveal scrolls each scroller holding t, innermost first, just far
	// enough to show t whole (its start, when it is larger than the view),
	// and settles. Returns t where it is now.
	@(private)
	reveal :: proc(s: ^Session, t: Target) -> Target {
		t := t
		moved := false
		for depth := 0; ; depth += 1 {
			tree := niello.debug_tree(s.ctx)
			k := -1
			for n, j in tree {
				if n.instance == t.instance {
					k = j
					break
				}
			}
			if k < 0 {
				break
			}
			t.rect = tree[k].rect
			// The depth-th scrolling ancestor, innermost first.
			p := tree[k].parent
			for seen := 0; p >= 0; p = tree[p].parent {
				if .Scroll_X in tree[p].flags || .Scroll_Y in tree[p].flags {
					if seen == depth {
						break
					}
					seen += 1
				}
			}
			if p < 0 {
				break
			}
			view := tree[p].rect
			off := niello.scroll_offset(tree[p].instance)
			delta: niello.Vec2
			for axis in 0 ..< 2 {
				if axis == 0 ? .Scroll_X not_in tree[p].flags : .Scroll_Y not_in tree[p].flags {
					continue
				}
				lo, hi := t.rect.pos[axis], t.rect.pos[axis] + t.rect.size[axis]
				vlo, vhi := view.pos[axis], view.pos[axis] + view.size[axis]
				if lo < vlo || t.rect.size[axis] > view.size[axis] {
					delta[axis] = lo - vlo
				} else if hi > vhi {
					delta[axis] = hi - vhi
				}
			}
			if delta != {} {
				niello.scroll_to(tree[p].instance, off + delta)
				frame(s)
				moved = true
			}
		}
		if moved {
			log_step(s, "scroll %s into view", t.desc)
			settle(s)
			if d, ok := debug_node(s, t.instance); ok {
				t.rect = d.rect
			}
		}
		return t
	}

	@(private)
	node_hovered :: proc(s: ^Session, i: niello.Instance) -> bool {
		for n in niello.debug_tree(s.ctx) {
			if n.instance == i {
				return .Hovered in n.flags
			}
		}
		return false
	}

	// hovered_top is the deepest hovered node: what the pointer is on.
	@(private)
	hovered_top :: proc(s: ^Session) -> niello.Instance {
		top: niello.Instance
		depth := -1
		tree := niello.debug_tree(s.ctx)
		for n in tree {
			if .Hovered in n.flags {
				d := 0
				for p := n.parent; p >= 0; p = tree[p].parent {
					d += 1
				}
				if d > depth {
					top, depth = n.instance, d
				}
			}
		}
		return top
	}

	// click presses and releases the left button on the center of t, then
	// settles. Clicking a target that is disabled, or covered by something
	// else, is a finding, and nothing is clicked. Reports whether it clicked.
	click :: proc(s: ^Session, t: Target) -> bool {
		if !t.ok {
			return false
		}
		log_step(s, "click %s", t.desc)
		if .Disabled in t.state {
			add_finding(s, .Disabled_Target, .Error, t.instance, t.loc, "%s is disabled: the click does nothing", t.desc)
			return false
		}
		if !move_to(s, t) {
			return false
		}
		frame(s, {buttons_down = {.Left}, buttons_pressed = {.Left}, clicks = 1})
		frame(s, {buttons_released = {.Left}})
		settle(s)
		return true
	}

	// type_text types text into whatever holds keyboard focus, as one burst
	// of typed characters, then settles.
	type_text :: proc(s: ^Session, text: string) {
		log_step(s, "type %s", quote(text))
		frame(s, {text = text})
		settle(s)
	}

	// press_key presses and releases key with mods held, then settles.
	press_key :: proc(s: ^Session, key: niello.Key_Code, mods: niello.Modifiers = {}) {
		if mods != {} {
			log_step(s, "press %v+%v", mods, key)
		} else {
			log_step(s, "press %v", key)
		}
		down := [1]niello.Key_Event{{key = key, physical = key, mods = mods, down = true}}
		frame(s, {keys = down[:]})
		up := [1]niello.Key_Event{{key = key, physical = key, mods = mods}}
		frame(s, {keys = up[:]})
		settle(s)
	}

	@(private)
	log_step :: proc(s: ^Session, format: string, args: ..any) {
		append(&s.steps, fmt_alloc(s, format, ..args))
	}

}
