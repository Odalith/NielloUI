package agent

import "base:runtime"
import "core:strings"
import niello ".."

when niello.NIELLO_DEBUG {

	// Target is a control found on the current screen: its instance, where it
	// is, and how the report names it. ok is false when the search found no
	// single match; acting on such a target does nothing (the search already
	// recorded why).
	Target :: struct {
		ok:       bool,
		instance: niello.Instance,
		rect:     niello.Rect,
		role:     niello.A11y_Role,
		name:     string,
		state:    niello.A11y_State,
		desc:     string, // as the report writes it: Button "Save"
		loc:      runtime.Source_Code_Location, // where it was declared
	}

	// find looks for exactly one control on the current screen. role and name
	// match its accessibility role and name (name exactly); text matches what
	// a node shows, exactly, for nodes with no role (a plain label). Give any
	// of them; each one given must match. No match, or more than one, is a
	// finding listing the nearest candidates, and the result is not ok.
	find :: proc(s: ^Session, role := niello.A11y_Role.None, name := "", text := "", loc := #caller_location) -> Target {
		matches := find_all(s, role, name, text)
		what := query_desc(role, name, text)
		if len(matches) == 1 {
			return matches[0]
		}
		if len(matches) == 0 {
			add_finding(s, .Not_Found, .Error, 0, loc, "no %s on screen%s", what, candidates(s, role, name, text))
		} else {
			b := strings.builder_make(context.temp_allocator)
			for m, k in matches {
				if k > 0 {
					strings.write_string(&b, "; ")
				}
				strings.write_string(&b, m.desc)
				strings.write_string(&b, " at ")
				strings.write_string(&b, loc_string(m.loc))
			}
			add_finding(s, .Ambiguous, .Error, 0, loc, "%d controls match %s: %s (give a name, or a key that sets them apart)", len(matches), what, strings.to_string(b))
		}
		return {}
	}

	// find_all is every control on the current screen matching the query, as
	// find takes it, in declaration order. The slice is the frame's: valid
	// until the next action.
	find_all :: proc(s: ^Session, role := niello.A11y_Role.None, name := "", text := "") -> []Target {
		out := make([dynamic]Target, context.temp_allocator)
		if role != .None || name != "" {
			for n in niello.a11y_tree(s.ctx) {
				if role != .None && n.role != role {
					continue
				}
				if name != "" && n.name != name {
					continue
				}
				if text != "" && !node_text_is(s, n.instance, text) {
					continue
				}
				append(&out, target_of(s, n))
			}
			return out[:]
		}
		if text == "" {
			return nil
		}
		for n in niello.debug_tree(s.ctx) {
			if .Culled in n.flags || n.text != text {
				continue
			}
			t := Target{ok = true, instance = n.instance, rect = n.rect, name = n.text, loc = n.loc}
			if a, ok := a11y_node(s, n.instance); ok {
				t = target_of(s, a)
			} else {
				t.desc = fmt_temp("Text %s", quote(n.text))
			}
			append(&out, t)
		}
		return out[:]
	}

	// exists reports whether exactly one control matches, without recording a
	// finding when none does.
	exists :: proc(s: ^Session, role := niello.A11y_Role.None, name := "", text := "") -> bool {
		return len(find_all(s, role, name, text)) == 1
	}

	@(private)
	target_of :: proc(s: ^Session, n: niello.A11y_Node) -> Target {
		t := Target{ok = true, instance = n.instance, rect = n.rect, role = n.role, name = n.name, state = n.state}
		t.desc = n.name != "" ? fmt_temp("%v %s", n.role, quote(n.name)) : fmt_temp("%v", n.role)
		if d, ok := debug_node(s, n.instance); ok {
			t.loc = d.loc
		}
		return t
	}

	@(private)
	a11y_node :: proc(s: ^Session, i: niello.Instance) -> (niello.A11y_Node, bool) {
		for n in niello.a11y_tree(s.ctx) {
			if n.instance == i {
				return n, true
			}
		}
		return {}, false
	}

	@(private)
	debug_node :: proc(s: ^Session, i: niello.Instance) -> (niello.Debug_Node, bool) {
		for n in niello.debug_tree(s.ctx) {
			if n.instance == i {
				return n, true
			}
		}
		return {}, false
	}

	// node_text_is: does i, or a node under it, show exactly text?
	@(private)
	node_text_is :: proc(s: ^Session, i: niello.Instance, text: string) -> bool {
		tree := niello.debug_tree(s.ctx)
		root := -1
		for n, k in tree {
			if n.instance == i {
				root = k
				break
			}
		}
		if root < 0 {
			return false
		}
		for k in root ..< len(tree) {
			if k > root && !descends(tree, k, root) {
				break
			}
			if tree[k].text == text {
				return true
			}
		}
		return false
	}

	@(private)
	descends :: proc(tree: []niello.Debug_Node, k, root: int) -> bool {
		for p := tree[k].parent; p >= 0; p = tree[p].parent {
			if p == root {
				return true
			}
		}
		return false
	}

	@(private)
	query_desc :: proc(role: niello.A11y_Role, name, text: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		if role != .None {
			strings.write_string(&b, fmt_temp("%v", role))
		} else {
			strings.write_string(&b, "control")
		}
		if name != "" {
			strings.write_string(&b, fmt_temp(" named %s", quote(name)))
		}
		if text != "" {
			strings.write_string(&b, fmt_temp(" showing %s", quote(text)))
		}
		return strings.to_string(b)
	}

	// candidates lists what is there instead: the same role with any name, or
	// any role with that name or text (at most a handful).
	@(private)
	candidates :: proc(s: ^Session, role: niello.A11y_Role, name, text: string) -> string {
		MAX :: 6
		b := strings.builder_make(context.temp_allocator)
		n := 0
		want := name != "" ? name : text
		for a in niello.a11y_tree(s.ctx) {
			near := (role != .None && a.role == role) ||
				(want != "" && a.name != "" && (strings.contains(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(want, context.temp_allocator)) ||
				 strings.contains(strings.to_lower(want, context.temp_allocator), strings.to_lower(a.name, context.temp_allocator))))
			if !near {
				continue
			}
			strings.write_string(&b, n == 0 ? "; on screen: " : ", ")
			t := target_of(s, a)
			strings.write_string(&b, t.desc)
			n += 1
			if n == MAX {
				strings.write_string(&b, ", …")
				break
			}
		}
		if n == 0 {
			strings.write_string(&b, "; nothing similar is on screen")
		}
		return strings.to_string(b)
	}

}
