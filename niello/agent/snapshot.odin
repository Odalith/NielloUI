package agent

import "core:fmt"
import "core:strings"
import niello ".."

when niello.NIELLO_DEBUG {

	// snapshot writes the current screen to NN-label.txt in the session's
	// folder and lints it. The dump is one line per thing a user perceives:
	// each control (its accessibility role, name, value and state) and each
	// piece of text, indented under the control it belongs to, with its rect
	// and the file:line that declared it. Containers with nothing to say are
	// left out; their contents move up a level. Lines with a finding end in
	// "!kind". When the session makes pictures, it also writes
	// NN-label.png: the screen as the window would show it, at 2 pixels per
	// DIP. Text the renderer did not draw (scrolled or clipped out of
	// view) is tagged [out of view] and counted at the end: the text lints
	// check only what is drawn. Returns the dump (valid until the next
	// frame).
	snapshot :: proc(s: ^Session, label: string) -> string {
		lint(s, label)
		s.snapshots += 1
		text := dump(s, label, true)
		base := fmt_temp("%02d-%s", s.snapshots, file_safe(label))
		write_file(s, fmt_temp("%s.txt", base), text)
		if picture(s, fmt_temp("%s.png", base), {0, 0}, s.viewport) {
			log_step(s, "snapshot %s.txt, %s.png", base, base)
		} else {
			log_step(s, "snapshot %s.txt", base)
		}
		return text
	}

	// crop writes a close-up of target t to NN-label.png: its rect with
	// margin DIP around it, within the window, at the pictures' scale (2
	// pixels per DIP). For looking at one control closely. Reports whether
	// a picture was written: none when the session makes no pictures (see
	// summary.txt) or t was not found.
	crop :: proc(s: ^Session, t: Target, label: string, margin: f32 = 16) -> bool {
		if !t.ok {
			return false
		}
		lo := niello.Vec2{max(t.rect.pos.x - margin, 0), max(t.rect.pos.y - margin, 0)}
		hi := niello.Vec2{
			min(t.rect.pos.x + t.rect.size.x + margin, s.viewport.x),
			min(t.rect.pos.y + t.rect.size.y + margin, s.viewport.y),
		}
		if hi.x <= lo.x || hi.y <= lo.y {
			return false
		}
		s.snapshots += 1
		name := fmt_temp("%02d-%s.png", s.snapshots, file_safe(label))
		ok := picture(s, name, lo, hi - lo)
		if ok {
			log_step(s, "crop %s: %s", t.desc, name)
		}
		return ok
	}

	// picture renders the current frame's region at origin, size DIP, to a
	// PNG in the session's folder, when the session makes pictures.
	@(private)
	picture :: proc(s: ^Session, name: string, origin, size: niello.Vec2) -> bool {
		if s.picture_scale <= 0 || niello.render_png_hook == nil {
			return false
		}
		if !niello.render_png_hook(niello.draw_list(), origin, size, s.picture_scale, path(s, name)) {
			fmt.eprintf("agent: can't write the picture %s\n", path(s, name))
			return false
		}
		s.pictures += 1
		return true
	}

	// dump renders the current screen as snapshot writes it. locs: include
	// each line's file:line.
	dump :: proc(s: ^Session, label: string, locs: bool) -> string {
		tree := niello.debug_tree(s.ctx)
		b := strings.builder_make(context.temp_allocator)
		focus := "none"
		for a in niello.a11y_tree(s.ctx) {
			if .Focused in a.state {
				focus = describe(s, a.instance)
			}
		}
		fmt.sbprintf(&b, "# %s: %vx%v DIP, focus: %s\n", label, s.viewport.x, s.viewport.y, focus)

		// What each node is to the dump: shown (a line), and its depth in
		// shown lines.
		depth := make([]int, len(tree), context.temp_allocator)
		// The nearest shown control's name and value: text repeating either
		// is not shown again (a button's label, an entry box's text).
		name_of := make([]string, len(tree), context.temp_allocator)
		value_of := make([]string, len(tree), context.temp_allocator)
		// Text the renderer did not draw (scrolled or clipped out of view)
		// is not checked for truncation or overflow: say so.
		ink := text_ink(tree)
		unseen := 0
		for n, k in tree {
			if len(n.text) > 0 && .Culled not_in n.flags && !ink[k].drawn {
				unseen += 1
			}
		}
		flagged := make(map[niello.Instance]bool, context.temp_allocator)
		for f in s.findings {
			flagged[f.instance] = true
		}
		for n, k in tree {
			up := n.parent >= 0 ? depth[n.parent] : 0
			inherited := n.parent >= 0 ? name_of[n.parent] : ""
			inherited_value := n.parent >= 0 ? value_of[n.parent] : ""
			depth[k] = up
			name_of[k] = inherited
			value_of[k] = inherited_value
			if .Culled in n.flags {
				continue
			}
			a, has_a := a11y_node(s, n.instance)
			line := strings.builder_make(context.temp_allocator)
			switch {
			case has_a:
				write_a11y(&line, a)
				name_of[k] = a.name
				value_of[k] = a.value.text
			case .Popup in n.flags:
				strings.write_string(&line, "Popup")
			case len(n.text) > 0 && n.text != inherited && n.text != inherited_value:
				fmt.sbprintf(&line, "Text %s", quote(n.text))
			case n.instance in flagged:
				// A plain container with a finding: shown by its unit's
				// name, so the finding has a line to sit on.
				nm := niello.debug_unit_name(n.unit)
				fmt.sbprintf(&line, "Box %s", nm != "" ? nm : fmt_temp("unit #%d", int(n.unit)))
			case:
				continue
			}
			r := n.rect
			fmt.sbprintf(&line, " @%.0f,%.0f %.0fx%.0f", r.pos.x, r.pos.y, r.size.x, r.size.y)
			if has_a && len(n.text) > 0 && n.text != a.name {
				fmt.sbprintf(&line, " text %s", quote(n.text))
			}
			if len(n.text) > 0 && !ink[k].drawn {
				strings.write_string(&line, " [out of view]")
			}
			for f in s.findings {
				if f.instance == n.instance {
					fmt.sbprintf(&line, " !%v", f.kind)
				}
			}
			for _ in 0 ..< up {
				strings.write_string(&b, "  ")
			}
			strings.write_string(&b, strings.to_string(line))
			if locs && n.loc.line > 0 {
				strings.write_string(&b, "  ")
				strings.write_string(&b, loc_string(n.loc))
			}
			strings.write_byte(&b, '\n')
			depth[k] = up + 1
		}
		if unseen > 0 {
			fmt.sbprintf(&b, "# %d text nodes out of view: not checked for truncation or text overflow (scroll them in, or open the session with a taller viewport)\n", unseen)
		}
		return strings.to_string(b)
	}

	@(private)
	write_a11y :: proc(b: ^strings.Builder, a: niello.A11y_Node) {
		fmt.sbprintf(b, "%v", a.role)
		if a.name != "" {
			fmt.sbprintf(b, " %s", quote(a.name))
		}
		v := a.value
		if v.text != "" {
			fmt.sbprintf(b, " = %s", quote(v.text))
		} else if v.has_num {
			fmt.sbprintf(b, " = %g (%g..%g)", v.num, v.min, v.max)
		}
		tags := make([dynamic]string, context.temp_allocator)
		for f in niello.A11y_Flag {
			if f in a.flags {
				append(&tags, strings.to_lower(fmt_temp("%v", f), context.temp_allocator))
			}
		}
		if .Focused in a.state {
			append(&tags, "focused")
		}
		if .Disabled in a.state {
			append(&tags, "disabled")
		}
		if .Offscreen in a.state {
			append(&tags, "offscreen")
		}
		if len(tags) > 0 {
			fmt.sbprintf(b, " [%s]", strings.join(tags[:], ", ", context.temp_allocator))
		}
	}

	@(private)
	file_safe :: proc(label: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		for c in label {
			ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
			strings.write_rune(&b, ok ? c : '-')
		}
		return strings.to_string(b)
	}

}
