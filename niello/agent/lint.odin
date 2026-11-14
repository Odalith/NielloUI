package agent

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import niello ".."

when niello.NIELLO_DEBUG {

	// OVERFLOW_MIN is how far, in DIP, content must run past its box before
	// overflow is a finding: less than half a pixel at 1x does not show.
	OVERFLOW_MIN :: 0.5

	// Finding_Kind is what a finding is about.
	Finding_Kind :: enum {
		Not_Found,       // find matched nothing
		Ambiguous,       // find matched more than one control
		Disabled_Target, // an action on a disabled control
		Covered_Target,  // an action on a control the pointer can't reach
		Overflow,        // children, or a node's own text, run past its box
		Truncated,       // a line of text is cut short with an ellipsis
		Collapsed,       // an interactive control with no width or height
		Unsettled,       // the screen keeps changing
		Idle_Wakes,      // nothing changes, yet the app keeps asking for frames
	}

	// Severity is how much a finding matters: an Error fails the report.
	Severity :: enum {
		Error,
		Warning,
	}

	// Finding is one problem the session found: what, where on screen
	// (instance), and the line of code that declared it (loc, when known).
	// snapshot is the label of the snapshot it was found in ("" when an action
	// found it).
	Finding :: struct {
		kind:     Finding_Kind,
		severity: Severity,
		message:  string,
		instance: niello.Instance,
		unit:     niello.Unit,
		loc:      runtime.Source_Code_Location,
		snapshot: string,
	}

	@(private)
	Finding_Key :: struct {
		kind:     Finding_Kind,
		instance: niello.Instance,
		axis:     int,
	}

	@(private)
	Allow :: struct {
		kind:     Finding_Kind,
		unit:     niello.Unit,
		instance: niello.Instance,
	}

	// allow exempts nodes from findings of one kind, for content that
	// overflows, truncates or keeps changing on purpose: every node of a
	// unit, or one target (an instance keeps its identity as its text
	// changes). The exemption is explicit and listed in the summary.
	allow :: proc {
		allow_unit,
		allow_target,
	}

	// allow_unit exempts every node of unit from findings of kind.
	allow_unit :: proc(s: ^Session, kind: Finding_Kind, unit: niello.Unit) {
		append(&s.allows, Allow{kind = kind, unit = unit})
	}

	// allow_target exempts the one node t from findings of kind.
	allow_target :: proc(s: ^Session, kind: Finding_Kind, t: Target) {
		if t.ok {
			append(&s.allows, Allow{kind = kind, instance = t.instance})
		}
	}

	@(private)
	allowed :: proc(s: ^Session, kind: Finding_Kind, unit: niello.Unit, inst: niello.Instance) -> bool {
		for a in s.allows {
			if a.kind != kind {
				continue
			}
			if (a.unit != niello.NO_UNIT && a.unit == unit) || (a.instance != 0 && a.instance == inst) {
				return true
			}
		}
		return false
	}

	@(private)
	add_finding :: proc(
		s: ^Session,
		kind: Finding_Kind,
		sev: Severity,
		inst: niello.Instance,
		loc: runtime.Source_Code_Location,
		format: string,
		args: ..any,
		axis := 0,
		label := "",
	) {
		loc := loc
		unit: niello.Unit
		if inst != 0 {
			if d, ok := debug_node(s, inst); ok {
				unit = d.unit
				if loc.line == 0 {
					loc = d.loc
				}
			}
		}
		if allowed(s, kind, unit, inst) {
			return
		}
		key := Finding_Key{kind, inst, axis}
		if inst != 0 {
			if key in s.seen {
				return
			}
			s.seen[key] = true
		}
		append(&s.findings, Finding{
			kind = kind, severity = sev, message = fmt_alloc(s, format, ..args),
			instance = inst, unit = unit, loc = loc, snapshot = strings.clone(label, s.alloc),
		})
	}

	// lint checks the current screen and records what is wrong with it:
	// content overflowing its box (scrolling and clipping boxes excepted:
	// there the excess is by design), text truncated with an ellipsis, and
	// interactive controls laid out with no area. Children are checked across the whole tree; text only where it is
	// drawn, so text scrolled out of view is checked once it is scrolled
	// in (snapshot tags and counts it). A
	// problem already found on the same node is not recorded again. snapshot
	// calls it; call it yourself to check a screen without a snapshot. Returns
	// every finding so far.
	lint :: proc(s: ^Session, label := "") -> []Finding {
		tree := niello.debug_tree(s.ctx)
		// Text is judged as drawn: each text command points into its
		// node's text, which names the node. A truncated command is a
		// trimmed line; the commands' bounds are the text's ink, which
		// overflows when it runs past the node's box.
		ink := text_ink(tree)
		for n, k in tree {
			if .Culled in n.flags {
				continue
			}
			// A node inside a control (a button's label) is reported as
			// the control's, at the line that declared the control: the
			// label's own line is inside the component.
			o := owner(tree, k, s)
			if ink[k].cut {
				add_finding(s, .Truncated, .Error, n.instance, tree[o].loc, "%s is cut short: %s does not fit its %.0f DIP width (it needs %.0f more)",
					describe_in(s, tree, k, o), quote(n.text), n.rect.size.x, n.spill.x, axis = 0, label = label)
				continue
			}
			if .Clip in n.flags {
				continue
			}
			for axis in 0 ..< 2 {
				if axis == 0 ? .Scroll_X in n.flags : .Scroll_Y in n.flags {
					continue
				}
				over := n.overfl[axis]
				what := "its children run"
				if ink[k].drawn {
					lo, hi := n.rect.pos[axis], n.rect.pos[axis] + n.rect.size[axis]
					past := max(ink[k].box.pos[axis] + ink[k].box.size[axis] - hi, lo - ink[k].box.pos[axis], 0)
					if past > over {
						over = past
						what = "its text runs"
					}
				}
				if over > OVERFLOW_MIN {
					dir := axis == 0 ? "across" : "down"
					add_finding(s, .Overflow, .Error, n.instance, tree[o].loc, "%s overflows: %s %.1f DIP past its box (%s), %.0fx%.0f at %.0f,%.0f",
						describe_in(s, tree, k, o), what, over, dir, n.rect.size.x, n.rect.size.y, n.rect.pos.x, n.rect.pos.y, axis = axis + 1, label = label)
				}
			}
		}
		// A control a user should reach, laid out with no area: it can't
		// be seen or clicked (fit() with nothing inside measures 0).
		for a in niello.a11y_tree(s.ctx) {
			if !interactive(a) || (a.rect.size.x >= 1 && a.rect.size.y >= 1) {
				continue
			}
			add_finding(s, .Collapsed, .Error, a.instance, {}, "%s has no area (%.0fx%.0f at %.0f,%.0f): it can't be seen or clicked; a fit() size with nothing inside measures 0",
				describe(s, a.instance), a.rect.size.x, a.rect.size.y, a.rect.pos.x, a.rect.pos.y, label = label)
		}
		return s.findings[:]
	}

	// interactive: is this a control a user acts on (a Tab stop, or a role
	// that takes input)?
	@(private)
	interactive :: proc(a: niello.A11y_Node) -> bool {
		if .Focusable in a.state {
			return true
		}
		#partial switch a.role {
		case .Button, .CheckBox, .ComboBox, .Edit, .Slider, .Spinner, .RadioButton, .TabItem, .MenuItem, .Hyperlink, .SplitButton:
			return true
		}
		return false
	}

	@(private)
	Ink :: struct {
		box:   niello.Rect, // the union of its text commands' bounds
		drawn: bool,        // it drew text this frame
		cut:   bool,        // a line of it was trimmed
	}

	// text_ink is each node's drawn text, from this frame's draw list.
	@(private)
	text_ink :: proc(tree: []niello.Debug_Node) -> []Ink {
		ink := make([]Ink, len(tree), context.temp_allocator)
		Span :: struct {
			lo, hi: uintptr,
			k:      int,
		}
		spans := make([dynamic]Span, context.temp_allocator)
		for n, k in tree {
			if len(n.text) > 0 && .Culled not_in n.flags {
				lo := uintptr(raw_data(n.text))
				append(&spans, Span{lo, lo + uintptr(len(n.text)), k})
			}
		}
		slice.sort_by(spans[:], proc(a, b: Span) -> bool {return a.lo < b.lo})
		for c in niello.draw_list() {
			if c.tag != .Text {
				continue
			}
			p := uintptr(c.text_ptr)
			// The last span starting at or before p.
			at, _ := slice.binary_search_by(spans[:], p, proc(sp: Span, p: uintptr) -> slice.Ordering {
				return sp.lo <= p ? .Less : .Greater
			})
			at -= 1
			if at < 0 || p >= spans[at].hi {
				continue
			}
			e := &ink[spans[at].k]
			if !e.drawn {
				e.box = c.bounds
				e.drawn = true
			} else {
				lo := niello.Vec2{min(e.box.pos.x, c.bounds.pos.x), min(e.box.pos.y, c.bounds.pos.y)}
				hi := niello.Vec2{
					max(e.box.pos.x + e.box.size.x, c.bounds.pos.x + c.bounds.size.x),
					max(e.box.pos.y + e.box.size.y, c.bounds.pos.y + c.bounds.size.y),
				}
				e.box = {lo, hi - lo}
			}
			e.cut ||= c.truncated
		}
		return ink
	}

	// owner is the node a finding on tree[k] is reported against: the nearest
	// node at or above it with an accessibility role (the control it is part
	// of), or k itself when there is none.
	@(private)
	owner :: proc(tree: []niello.Debug_Node, k: int, s: ^Session) -> int {
		for o := k; o >= 0; o = tree[o].parent {
			if a, ok := a11y_node(s, tree[o].instance); ok && a.role != .None {
				return o
			}
		}
		return k
	}

	// describe_in names tree[k] within its owner tree[o]: the owner itself,
	// or "text "Save…" in Button "Save"".
	@(private)
	describe_in :: proc(s: ^Session, tree: []niello.Debug_Node, k, o: int) -> string {
		if o == k {
			return describe(s, tree[k].instance)
		}
		return fmt_temp("%s in %s", describe(s, tree[k].instance), describe(s, tree[o].instance))
	}

	// describe names a node as the report writes it: its role and name, its
	// text, or its unit's name.
	@(private)
	describe :: proc(s: ^Session, i: niello.Instance) -> string {
		if a, ok := a11y_node(s, i); ok && a.role != .None {
			if a.name != "" {
				return fmt_temp("%v %s", a.role, quote(a.name))
			}
			return fmt_temp("%v", a.role)
		}
		if d, ok := debug_node(s, i); ok {
			if len(d.text) > 0 {
				return fmt_temp("text %s", quote(short(d.text)))
			}
			if nm := niello.debug_unit_name(d.unit); nm != "" {
				return fmt_temp("%s", nm)
			}
			return fmt_temp("unit #%d", int(d.unit))
		}
		return fmt_temp("instance %d", int(i))
	}

	@(private)
	short :: proc(text: string) -> string {
		MAX :: 40
		if len(text) <= MAX {
			return text
		}
		cut := MAX
		for cut > 0 && (text[cut] & 0xC0) == 0x80 {
			cut -= 1
		}
		return fmt_temp("%s…", text[:cut])
	}

	// report writes the session's results to its folder (findings.txt and
	// summary.txt beside the snapshots), prints a one-line summary, and
	// returns the number of errors: 0 is a pass.
	report :: proc(s: ^Session) -> (errors: int) {
		warnings := 0
		fb := strings.builder_make(context.temp_allocator)
		for f in s.findings {
			if f.severity == .Error {
				errors += 1
			} else {
				warnings += 1
			}
			write_finding(&fb, f)
		}
		write_file(s, "findings.txt", strings.to_string(fb))

		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "scenario: %s\n", s.name)
		fmt.sbprintf(&sb, "result:   %s (%d errors, %d warnings)\n", errors == 0 ? "PASS" : "FAIL", errors, warnings)
		fmt.sbprintf(&sb, "viewport: %vx%v DIP\n", s.viewport.x, s.viewport.y)
		fmt.sbprintf(&sb, "metrics:  %s\n", metrics_desc(s))
		fmt.sbprintf(&sb, "frames:   %d (%.2f s simulated)\n", s.frames, s.time)
		fmt.sbprintf(&sb, "snapshots: %d\n", s.snapshots)
		for a in s.allows {
			if a.instance != 0 {
				fmt.sbprintf(&sb, "allowed:  %v on %s\n", a.kind, describe(s, a.instance))
			} else {
				fmt.sbprintf(&sb, "allowed:  %v on %s\n", a.kind, unit_desc(a.unit))
			}
		}
		if len(s.steps) > 0 {
			strings.write_string(&sb, "steps:\n")
			for st in s.steps {
				fmt.sbprintf(&sb, "  %s\n", st)
			}
		}
		write_file(s, "summary.txt", strings.to_string(sb))

		fmt.printf("agent: %s: %s, %d errors, %d warnings -> %s/\n", s.name, errors == 0 ? "PASS" : "FAIL", errors, warnings, s.dir)
		for f in s.findings {
			line := strings.builder_make(context.temp_allocator)
			write_finding(&line, f)
			fmt.printf("  %s", strings.to_string(line))
		}
		return
	}

	@(private)
	write_finding :: proc(b: ^strings.Builder, f: Finding) {
		where_ := f.loc.line > 0 ? loc_string(f.loc) : "-"
		fmt.sbprintf(b, "%s: %s %v", where_, f.severity == .Error ? "error" : "warning", f.kind)
		if f.snapshot != "" {
			fmt.sbprintf(b, " [%s]", f.snapshot)
		}
		fmt.sbprintf(b, ": %s\n", f.message)
	}

	@(private)
	metrics_desc :: proc(s: ^Session) -> string {
		if s.metrics == .Mock || niello.measure_word_hook == nil {
			return "mock (fixed-width text; real fonts differ)"
		}
		return "real (the app's text measurement)"
	}

	@(private)
	unit_desc :: proc(u: niello.Unit) -> string {
		nm := niello.debug_unit_name(u)
		file, line, ok := niello.debug_unit_loc(u)
		if !ok {
			return fmt_temp("unit #%d", int(u))
		}
		return fmt_temp("%s (minted at %s)", nm != "" ? nm : fmt_temp("unit #%d", int(u)), loc_string({file_path = file, line = line}))
	}

	// write_file writes one file of the report; a failure is printed, since
	// a scenario's own result does not depend on it.
	@(private)
	write_file :: proc(s: ^Session, file, text: string) {
		if err := os.write_entire_file(path(s, file), text); err != nil {
			fmt.eprintf("agent: can't write %s: %v\n", path(s, file), err)
		}
	}

	@(private)
	path :: proc(s: ^Session, file: string) -> string {
		return strings.concatenate({s.dir, "/", file}, context.temp_allocator)
	}

	// loc_string is file:line, the file relative to the repository (the
	// nearest folder above the working directory holding .git; without
	// one, the working directory), or as given when it lies outside it.
	@(private)
	loc_string :: proc(loc: runtime.Source_Code_Location) -> string {
		if loc.line == 0 {
			return "-"
		}
		file := loc.file_path
		if root := repo_root(); root != "" && strings.has_prefix(file, root) && len(file) > len(root) && (file[len(root)] == '/' || file[len(root)] == '\\') {
			file = file[len(root) + 1:]
		}
		return fmt_temp("%s:%d", file, loc.line)
	}

	@(private)
	repo_root_cache: string
	@(private)
	repo_root_done: bool

	@(private)
	repo_root :: proc() -> string {
		if repo_root_done {
			return repo_root_cache
		}
		repo_root_done = true
		// Kept for the process: the heap, not the caller's allocator.
		dir, err := os.get_working_directory(runtime.heap_allocator())
		if err != nil {
			return ""
		}
		d := dir
		for {
			if os.exists(strings.concatenate({d, "/.git"}, context.temp_allocator)) {
				repo_root_cache = d
				return d
			}
			cut := strings.last_index_any(d, "/\\")
			if cut <= 0 {
				break
			}
			d = d[:cut]
		}
		// No repository: paths are relative to the working directory.
		repo_root_cache = dir
		return dir
	}

	// quote is text in double quotes, as the report writes it: quotes,
	// backslashes and control characters escaped, everything else as is
	// (an em dash stays an em dash).
	@(private)
	quote :: proc(text: string) -> string {
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '"')
		for r in text {
			switch r {
			case '"':
				strings.write_string(&b, `\"`)
			case '\\':
				strings.write_string(&b, `\\`)
			case '\n':
				strings.write_string(&b, `\n`)
			case '\t':
				strings.write_string(&b, `\t`)
			case:
				if r < 0x20 {
					fmt.sbprintf(&b, "\\x%02x", r)
				} else {
					strings.write_rune(&b, r)
				}
			}
		}
		strings.write_byte(&b, '"')
		return strings.to_string(b)
	}

	@(private)
	fmt_temp :: proc(format: string, args: ..any) -> string {
		return fmt.aprintf(format, ..args, allocator = context.temp_allocator)
	}

	@(private)
	fmt_alloc :: proc(s: ^Session, format: string, args: ..any) -> string {
		return fmt.aprintf(format, ..args, allocator = s.alloc)
	}

}
