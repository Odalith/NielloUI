package niello

// a11y.odin — the accessibility mirror (TODO #23, M1).
//
// Design (§3.9, brief Accessibility_Plan.md, RULED 2026-10-27):
// semantics are declared in With (role, description, value, flags;
// label is the accessible name). At every frame_end, the engine
// maintains one per-context mirror tree, keyed by instance
// identity, updated incrementally: a node's payload (strings,
// role, value, flags) is rebuilt only when its semantics digest
// changes — pass F's stamp model applied to semantics. Engine-known
// state (disabled, focused, offscreen, scrollable) and rects are
// refreshed every frame, since they change without the semantics
// moving. The mirror is the one tree every consumer reads:
// platform exporters (M2+), the debugger, and the headless test
// query API. It is UNGATED: screen readers are prod behavior.
//
// Rulings: F1(b) role vocabulary is Avalonia's AutomationControlType
// enum verbatim, 43 values in Avalonia's order; F2(a) With fields;
// F3(a) value struct + flags bitset; F4(a) incremental mirror;
// F5(a) mirror always maintained, exporter push gated on a listener;
// F6(a) AT-SPI first; F7(c) read-only v1; F8(a) label, else node
// text, else empty; F9(a) headless query API over the mirror.
//
// String ownership: With label/description/value text are copied
// into the frame arena at declare time (declare.odin), so the
// stored With is safe to read at frame_end. The mirror clones them
// into owned storage here, because the mirror outlives the frame
// arena; clones are freed when the node's payload is rebuilt, when
// the node leaves the tree, or at context teardown. Readers borrow
// the entry strings through A11y_Node; they are valid until the
// next frame_end.

import "core:strings"

// A11y_Role is what kind of control an instance is, for assistive
// technology (With.role). .None, the zero value, declares no role.
A11y_Role :: enum {
	None,
	Button,
	Calendar,
	CheckBox,
	ComboBox,
	ComboBoxItem,
	Edit,
	Hyperlink,
	Image,
	ListItem,
	List,
	Menu,
	MenuBar,
	MenuItem,
	ProgressBar,
	RadioButton,
	ScrollBar,
	Slider,
	Spinner,
	StatusBar,
	Tab,
	TabItem,
	Text,
	ToolBar,
	ToolTip,
	Tree,
	TreeItem,
	Custom,
	Group,
	Thumb,
	DataGrid,
	DataItem,
	Document,
	SplitButton,
	Window,
	Pane,
	Header,
	HeaderItem,
	Table,
	TitleBar,
	Separator,
	Expander,
	ScrollViewer,
}

// A11y_Flag is state only the control knows, declared in With.a11y_flags:
// a toggle that is on (Checked), a selected row, a read-only field.
A11y_Flag :: enum {
	Checked,
	Selected,
	Expanded,
	ReadOnly,
	Required,
	Multiline,
}

// A11y_Flags is a set of A11y_Flag.
A11y_Flags :: bit_set[A11y_Flag]

// A11y_Value is the value of a control that has one: the text of an Edit,
// the number and range of a Slider, ProgressBar or Spinner. The zero value
// is unset.
A11y_Value :: struct {
	text:    string, // "" = unset; copied, like With.text
	num:     f32,
	has_num: bool,
	min:     f32,
	max:     f32,
}

// A11y_State_Flag is state the engine knows and reports by itself in the
// accessibility tree.
//
// The order is read by the native AT-SPI exporter: new flags go at the end.
A11y_State_Flag :: enum {
	Disabled, // disabled, itself or through an ancestor
	Focused, // this instance holds input focus
	Offscreen, // zero-area rect, or fully outside the viewport
	Scroll_X, // scrollable on the X axis
	Scroll_Y, // scrollable on the Y axis
	Focusable, // a Tab stop
}

// A11y_State is a set of A11y_State_Flag.
A11y_State :: bit_set[A11y_State_Flag]

// A11y_Node is one node of the accessibility tree (a11y_tree): an instance
// with semantics. Its strings are valid until the context's next frame_end;
// parent indexes the same slice.
A11y_Node :: struct {
	instance:    Instance,
	parent:      int, // -1 for roots
	unit:        Unit,
	role:        A11y_Role,
	name:        string,
	description: string,
	value:       A11y_Value, // value.text borrowed
	flags:       A11y_Flags,
	state:       A11y_State,
	rect:        Rect,
}

// A11y_Entry is the mirror store's per-instance payload: the
// strings are OWNED (cloned at build, freed on rebuild/removal/
// teardown), and digest is the semantics stamp the incremental
// update compares against.
@(private)
A11y_Entry :: struct {
	gen:         u64, // mirror build that last saw this instance
	digest:      u64, // semantics stamp at the last payload build
	role:        A11y_Role,
	name:        string, // owned
	description: string, // owned
	value:       A11y_Value, // value.text owned
	flags:       A11y_Flags,
	unit:        Unit,
}

// a11y_tree returns ctx's accessibility tree as of its last frame: the
// instances that declared semantics (With.role, label, value…), in
// declaration order, parents before children. The platform exporters (AT-SPI
// on Linux) read it; so can tests. Valid until ctx's next frame_end.
a11y_tree :: proc(ctx: ^Context) -> []A11y_Node {
	if ctx == nil || ctx.a11y_off {
		return nil
	}
	return ctx.a11y_order[:]
}

// a11y_generation is a number that changes whenever ctx's accessibility
// tree does (a node added, removed or moved; a name, value, state or rect
// changed), and only then. A platform exporter compares it with the last
// one it sent and skips unchanged frames.
a11y_generation :: proc(ctx: ^Context) -> u64 {
	if ctx == nil {
		return 0
	}
	return ctx.a11y_version
}

// set_a11y turns ctx's accessibility tree on or off. It is on by default;
// a host turns it off where nothing reads it (no platform exporter, or no
// accessibility bus), which saves its upkeep every frame. Off, a11y_tree
// returns nil; turned on again, the next frame builds it afresh.
set_a11y :: proc(ctx: ^Context, on: bool) {
	if ctx == nil || ctx.a11y_off == !on {
		return
	}
	ctx.a11y_off = !on
	if !on {
		for _, e in ctx.a11y_entries {
			ee := e
			a11y_free_entry(&ee)
		}
		clear(&ctx.a11y_entries)
		clear(&ctx.a11y_order)
		clear(&ctx.a11y_prev)
	}
	ctx.a11y_version += 1
}

// a11y_declared: does this With carry any semantics? A node with
// none of these does not enter the mirror.
@(private)
a11y_declared :: proc(w: With) -> bool {
	if w.role != .None {
		return true
	}
	if w.label != nil {
		return true
	}
	if w.description != nil {
		return true
	}
	if len(w.value.text) > 0 || w.value.has_num {
		return true
	}
	if w.a11y_flags != {} {
		return true
	}
	return false
}

// a11y_sem_digest folds the node's own semantics fields into one
// stamp. It does NOT cover the fallback name's subtree text —
// that is compared directly at build time (see a11y_mirror_build),
// since descendant text can change without this node's own
// fields moving.
@(private)
a11y_sem_digest :: proc(w: ^With) -> u64 {
	d := u64(14695981039346656037) // FNV-1a offset basis
	d = hash_mix(d, u64(w.role))
	if lb, ok := w.label.?; ok {
		d = hash_mix(d, str_hash(lb))
	}
	if desc, ok := w.description.?; ok {
		d = hash_mix(d, str_hash(desc))
	}
	d = hash_mix(d, str_hash(w.value.text))
	d = hash_mix(d, u64(transmute(u32)(w.value.num)))
	d = hash_mix(d, u64(transmute(u32)(w.value.min)))
	d = hash_mix(d, u64(transmute(u32)(w.value.max)))
	if w.value.has_num {
		d = hash_mix(d, 1)
	}
	if .Checked in w.a11y_flags {
		d = hash_mix(d, 11)
	}
	if .Selected in w.a11y_flags {
		d = hash_mix(d, 12)
	}
	if .Expanded in w.a11y_flags {
		d = hash_mix(d, 13)
	}
	if .ReadOnly in w.a11y_flags {
		d = hash_mix(d, 14)
	}
	if .Required in w.a11y_flags {
		d = hash_mix(d, 15)
	}
	if .Multiline in w.a11y_flags {
		d = hash_mix(d, 16)
	}
	return d
}

// Fallback-name gathering (F8a): the node's own text first, then
// descendant text in declaration order, joined with single
// spaces. Capped — 16 text pieces, 512 bytes — so a label-less
// role on a huge subtree cannot turn the mirror build into an
// unbounded join. A container that needs a longer name declares
// a label; the cap is an implementation bound, not a contract.
@(private)
A11Y_NAME_MAX_PIECES :: 16
@(private)
A11Y_NAME_MAX_BYTES :: 512

@(private)
a11y_take_piece :: proc(buf: []u8, n: int, pieces: int, s: string) -> (int, int) {
	if len(s) == 0 || pieces >= A11Y_NAME_MAX_PIECES || n >= len(buf) {
		return n, pieces
	}
	nn := n
	if pieces > 0 {
		buf[nn] = ' '
		nn += 1
		if nn >= len(buf) {
			return nn, pieces + 1
		}
	}
	take := min(len(s), len(buf)-nn)
	copy(buf[nn:], s[:take])
	return nn + take, pieces + 1
}

@(private)
a11y_is_descendant :: proc(j, ancestor: int) -> bool {
	p := g.nodes[j].parent
	for p >= 0 {
		if p == ancestor {
			return true
		}
		p = g.nodes[p].parent
	}
	return false
}

// a11y_gather_text returns the fallback name as a slice of buf:
// the caller clones it before buf is reused. Subtrees are
// contiguous in declaration order (depth-first pre-order), so
// the scan stops at the first node outside the subtree.
@(private)
a11y_gather_text :: proc(frame_idx: int, buf: []u8) -> string {
	n := 0
	pieces := 0
	n, pieces = a11y_take_piece(buf, n, pieces, g.nodes[frame_idx].text)
	for j in frame_idx + 1 ..< len(g.nodes) {
		if !a11y_is_descendant(j, frame_idx) {
			break
		}
		if pieces >= A11Y_NAME_MAX_PIECES || n >= len(buf) {
			break
		}
		n, pieces = a11y_take_piece(buf, n, pieces, g.nodes[j].text)
	}
	return string(buf[:n])
}

@(private)
a11y_build_entry :: proc(nd: ^Frame_Node, w: ^With, digest: u64, name: string) -> A11y_Entry {
	e: A11y_Entry
	e.digest = digest
	e.role = w.role
	e.name = strings.clone(name)
	if d, ok := w.description.?; ok {
		e.description = strings.clone(d)
	}
	e.value = w.value
	if len(e.value.text) > 0 {
		e.value.text = strings.clone(e.value.text)
	}
	e.flags = w.a11y_flags
	e.unit = nd.unit
	return e
}

@(private)
a11y_free_entry :: proc(e: ^A11y_Entry) {
	if len(e.name) > 0 {
		delete(e.name)
	}
	if len(e.description) > 0 {
		delete(e.description)
	}
	if len(e.value.text) > 0 {
		delete(e.value.text)
	}
	e^ = {}
}

// a11y_free_mirror frees every entry string and the mirror
// containers. Called from free_context (teardown); safe on a
// context whose mirror was never built.
@(private)
a11y_free_mirror :: proc(ctx: ^Context) {
	for _, e in ctx.a11y_entries {
		ee := e
		a11y_free_entry(&ee)
	}
	delete(ctx.a11y_entries)
	delete(ctx.a11y_order)
	delete(ctx.a11y_idx)
	delete(ctx.a11y_prev)
	delete(ctx.a11y_dead)
	ctx.a11y_entries = nil
	ctx.a11y_order = nil
	ctx.a11y_idx = nil
	ctx.a11y_prev = nil
	ctx.a11y_dead = nil
}

// a11y_state_for derives the engine-known state for one frame
// node from the committed record and the resolved style.
@(private)
a11y_state_for :: proc(i: int, nd: ^Frame_Node, rec: ^Inst_Rec) -> A11y_State {
	state: A11y_State
	if g.disabled_flags[i] {
		state += {.Disabled}
	}
	if g.focus_id == nd.identity && nd.identity != 0 {
		state += {.Focused}
	}
	if nd.focusable {
		state += {.Focusable}
	}
	s := node_style(i)
	if scrollable_axis(s, X_AXIS) {
		state += {.Scroll_X}
	}
	if scrollable_axis(s, Y_AXIS) {
		state += {.Scroll_Y}
	}
	r := rec.rect
	if r.size.x <= 0 || r.size.y <= 0 ||
		r.pos.x >= g.viewport.x || r.pos.y >= g.viewport.y ||
		r.pos.x+r.size.x <= 0 || r.pos.y+r.size.y <= 0 {
		state += {.Offscreen}
	}
	return state
}

// a11y_mirror_build refreshes the bound context's mirror.
// Called from frame_end after the commit, next to
// debug_snapshot_build — ungated (F5a). Per node: skip nodes
// with no semantics and nodes with no committed record (culled);
// rebuild the payload only when the semantics digest moved (or
// the fallback name's gathered text moved); refresh state and
// rect every frame; sweep entries whose instances left the tree. The
// build is compared with the previous one, and a11y_version bumps only
// when they differ, so an exporter can skip unchanged frames.
@(private)
a11y_mirror_build :: proc() {
	if g.a11y_off {
		return
	}
	g.a11y_gen += 1
	gen := g.a11y_gen
	g.a11y_order, g.a11y_prev = g.a11y_prev, g.a11y_order
	clear(&g.a11y_order)
	changed := false
	if len(g.a11y_idx) < len(g.nodes) {
		resize(&g.a11y_idx, len(g.nodes))
	}
	for i in 0 ..< len(g.nodes) {
		g.a11y_idx[i] = -1
	}
	buf: [A11Y_NAME_MAX_BYTES]u8
	for i in 0 ..< len(g.nodes) {
		nd := &g.nodes[i]
		w := node_with(nd)
		if w == nil || !a11y_declared(w^) {
			continue
		}
		rec, ok := g.instances[nd.identity]
		if !ok {
			continue // culled: no committed record, no mirror node
		}
		// Mirror parent: nearest declared ancestor. Frame parent
		// links walk up to it; a11y_idx maps frame indices to
		// order indices for nodes already visited (parents
		// precede children in declaration order).
		parent := -1
		p := nd.parent
		for p >= 0 {
			if g.a11y_idx[p] >= 0 {
				parent = g.a11y_idx[p]
				break
			}
			p = g.nodes[p].parent
		}
		digest := a11y_sem_digest(w)
		ent, exists := g.a11y_entries[nd.identity]
		need := !exists || ent.digest != digest
		name := ""
		has_label := false
		if lb, ok := w.label.?; ok {
			name = lb
			has_label = true
		}
		if !need && !has_label {
			// Fallback name: descendant text may have changed
			// without this node's digest moving. Compare the
			// fresh gather (capped) against the stored name.
			if gathered := a11y_gather_text(i, buf[:]); gathered != ent.name {
				need = true
				name = gathered
			}
		}
		if need {
			if exists {
				a11y_free_entry(&ent)
			}
			if !has_label {
				name = a11y_gather_text(i, buf[:])
			}
			ent = a11y_build_entry(nd, w, digest, name)
			changed = true
		}
		ent.gen = gen
		g.a11y_entries[nd.identity] = ent
		k := len(g.a11y_order)
		g.a11y_idx[i] = k
		node := A11y_Node{
			instance = nd.identity,
			parent = parent,
			unit = nd.unit,
			role = ent.role,
			name = ent.name,
			description = ent.description,
			value = ent.value,
			flags = ent.flags,
			state = a11y_state_for(i, nd, &rec),
			rect = rec.rect,
		}
		// Unchanged payloads keep the same entry strings, so comparing
		// the rest of the node (and the rebuilt flag above) is enough.
		if !changed {
			if k >= len(g.a11y_prev) {
				changed = true
			} else {
				p := &g.a11y_prev[k]
				changed = p.instance != node.instance || p.parent != node.parent ||
					p.unit != node.unit || p.state != node.state || p.rect != node.rect
			}
		}
		append(&g.a11y_order, node)
	}
	if len(g.a11y_order) != len(g.a11y_prev) {
		changed = true
	}
	// Sweep: entries not seen this build left the tree. Collect
	// first — deleting during map iteration is not safe.
	clear(&g.a11y_dead)
	for id, ent in g.a11y_entries {
		if ent.gen != gen {
			append(&g.a11y_dead, id)
		}
	}
	for id in g.a11y_dead {
		ent := g.a11y_entries[id]
		a11y_free_entry(&ent)
		delete_key(&g.a11y_entries, id)
		changed = true
	}
	if changed {
		g.a11y_version += 1
	}
}
