// docgen writes the book's API reference (docs/src/reference/*.md) from the
// packages' doc comments. Run it from the repository root:
//
//	odin run tools/docgen -- [-out:docs/src/reference] [-odin:odin] [-source:URL]
//
// For each public package it runs `odin doc <dir> -doc-format`, reads the
// exported declarations and their doc comments, takes each declaration's
// text from the source, and writes one page per package: an index, then
// every type, procedure, constant and variable with its declaration
// (highlighted, with the names it uses linked), its documentation and a
// link to its source line. Every declaration has an anchor named after it,
// so a guide links reference/niello.md#begin.
//
// Doc comments are plain text. In them, a tab-indented block becomes a code
// block, a name with an underscore or a call becomes code, and a name the
// reference documents becomes a link to it.
package docgen

import "core:fmt"
import doc "core:odin/doc-format"
import tok "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"

// Package is one documented package.
Package :: struct {
	dir:         string, // relative to the repository root
	alias:       string, // the name apps import it as
	import_path: string, // the import an app writes
	slug:        string, // its page: <out>/<slug>.md
}

// The public packages, in the order the reference lists them.
PACKAGES := []Package{
	{"niello", "niello", "niello:.", "niello"},
	{"niello/sdl", "niello_sdl", "niello:sdl", "sdl"},
	{"niello/controls", "controls", "niello:controls", "controls"},
	{"niello/virtual", "virtual", "niello:virtual", "virtual"},
	{"niello/inbox", "inbox", "niello:inbox", "inbox"},
	{"niello/debugui", "debugui", "niello:debugui", "debugui"},
}

Kind :: enum {
	Type,
	Procedure,
	Constant,
	Variable,
}

KIND_TITLE := [Kind]string {
	.Type      = "Types",
	.Procedure = "Procedures",
	.Constant  = "Constants",
	.Variable  = "Variables",
}

Entry :: struct {
	name:    string,
	kind:    Kind,
	docs:    string,
	comment: string,
	file:    string, // relative to the repository root
	line:    int,
	decl:    string, // the declaration's source text
	debug:   bool,   // declared only in debug builds (NIELLO_DEBUG)
}

Page :: struct {
	using pkg: Package,
	docs:      string,
	entries:   [dynamic]Entry,
	names:     map[string]Kind,
}

pages: [dynamic]Page

// Lowercase single-word names that are also ordinary English in the docs'
// prose ("is still held", "the next frame"). They are linked in prose only
// when written as a call or qualified (niello.set); everywhere else they
// read as words.
ENGLISH :: []string {
	"align", "as", "begin", "builder", "button", "clicked", "create",
	"current", "destroy", "dragging", "edit", "end", "estimated", "finish",
	"fit", "fixed", "focus", "focused", "grow", "hovered", "insert",
	"install", "invalidate", "item", "key", "measure", "next", "open", "pad",
	"pending", "percent", "pin", "pressed", "rect", "remove", "run",
	"scrollbar", "send", "set", "show", "size", "slider", "spacing", "theme",
	"transient",
}

main :: proc() {
	out_dir := "docs/src/reference"
	odin_exe := "odin"
	source := "https://github.com/Odalith/NielloUI/blob/main"
	for arg in os.args[1:] {
		switch {
		case strings.has_prefix(arg, "-out:"):
			out_dir = arg[len("-out:"):]
		case strings.has_prefix(arg, "-odin:"):
			odin_exe = arg[len("-odin:"):]
		case strings.has_prefix(arg, "-source:"):
			source = strings.trim_right(arg[len("-source:"):], "/")
		case:
			fail("unknown argument %q (expected -out:, -odin: or -source:)", arg)
		}
	}

	root, werr := os.get_working_directory(context.allocator)
	if werr != nil {
		fail("cannot read the working directory: %v", werr)
	}
	tmp, terr := os.make_directory_temp("", "niello-docgen-*", context.allocator)
	if terr != nil {
		fail("cannot make a temporary directory: %v", terr)
	}
	defer os.remove_all(tmp)

	// The reference documents the debug build, which declares everything,
	// and marks what a plain build lacks.
	for spec in PACKAGES {
		page := load(odin_exe, root, tmp, spec, true)
		plain := load(odin_exe, root, tmp, spec, false)
		for &e in page.entries {
			e.debug = !(e.name in plain.names)
		}
		append(&pages, page)
	}

	os.remove_all(out_dir)
	if err := os.make_directory_all(out_dir); err != nil {
		fail("cannot make %s: %v", out_dir, err)
	}
	total := 0
	for &page in pages {
		b := strings.builder_make()
		write_page(&b, &page, source)
		path := fmt.tprintf("%s/%s.md", out_dir, page.slug)
		if err := os.write_entire_file(path, strings.to_string(b)); err != nil {
			fail("cannot write %s: %v", path, err)
		}
		total += len(page.entries)
	}
	fmt.printfln("docgen: %d packages, %d declarations -> %s", len(pages), total, out_dir)
}

fail :: proc(format: string, args: ..any) -> ! {
	fmt.eprint("docgen: ")
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

// ============ reading a package ============

// load runs odin doc on one package and collects its exported declarations.
// -all-packages is required: without it the compiler's doc writer asserts on
// declarations whose types come from packages it did not write.
load :: proc(odin_exe, root, tmp: string, spec: Package, debug: bool) -> Page {
	base := fmt.tprintf("%s/%s-%v", tmp, spec.slug, debug)
	state, _, stderr, err := os.process_exec({
		command = {
			odin_exe, "doc", spec.dir, "-doc-format", "-all-packages",
			fmt.tprintf("-define:NIELLO_DEBUG=%v", debug), fmt.tprintf("-out:%s", base),
		},
	}, context.allocator)
	if err != nil {
		fail("cannot run %s: %v", odin_exe, err)
	}
	if !state.success {
		fail("odin doc %s failed:\n%s", spec.dir, string(stderr))
	}
	data, rerr := os.read_entire_file_from_path(fmt.tprintf("%s.odin-doc", base), context.allocator)
	if rerr != nil {
		fail("cannot read the doc file for %s: %v", spec.dir, rerr)
	}
	h, herr := doc.read_from_bytes(data)
	if herr != nil {
		fail("bad doc file for %s: %v", spec.dir, herr)
	}

	str :: proc(h: ^doc.Header, s: doc.String) -> string {
		return strings.clone(doc.from_string(h, s))
	}
	files := doc.from_array(h, h.files)
	ents := doc.from_array(h, h.entities)

	page := Page{pkg = spec}
	for p in doc.from_array(h, h.pkgs) {
		if .Init not_in p.flags {
			continue
		}
		page.docs = str(h, p.docs)
		for se in doc.from_array(h, p.entries) {
			e := ents[se.entity]
			if .Private in e.flags {
				continue
			}
			kind: Kind
			#partial switch e.kind {
			case .Type_Name:
				kind = .Type
			case .Procedure, .Proc_Group:
				kind = .Procedure
			case .Constant:
				kind = .Constant
			case .Variable:
				kind = .Variable
			case:
				continue
			}
			abs := doc.from_string(h, files[e.pos.file].name)
			rel := strings.trim_prefix(abs, root)
			rel = strings.trim_left(rel, "/\\")
			src := source_of(abs)
			entry := Entry {
				name    = str(h, se.name),
				kind    = kind,
				docs    = str(h, e.docs),
				comment = str(h, e.comment),
				file    = strings.clone(rel),
				line    = int(e.pos.line),
				decl    = declaration(src, int(e.pos.offset), int(e.pos.column)),
			}
			append(&page.entries, entry)
			page.names[entry.name] = kind
		}
	}
	slice.sort_by(page.entries[:], proc(a, b: Entry) -> bool {
		la, lb := strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)
		if la != lb {
			return la < lb
		}
		return a.name < b.name
	})
	return page
}

sources: map[string]string

source_of :: proc(path: string) -> string {
	if s, ok := sources[path]; ok {
		return s
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fail("cannot read %s: %v", path, err)
	}
	sources[strings.clone(path)] = string(data)
	return string(data)
}

quiet :: proc(pos: tok.Pos, format: string, args: ..any) {}

// declaration returns a declaration's text as written, from its name to the
// end of its value: a procedure stops before its body, everything else at
// the end of the statement. Trailing comments are left out; comments inside
// (a struct's field docs) are kept. Continuation lines lose the
// declaration's own indentation (one inside a when block), and tabs are
// expanded to 4 columns.
declaration :: proc(src: string, offset, column: int) -> string {
	text := src[offset:]
	t: tok.Tokenizer
	tok.init(&t, text, "", quiet)
	t.flags += {.Insert_Semicolon}
	depth := 0
	end := 0
	// 0: no proc seen; 1: `proc` seen; 2: inside its parameters; 3: past them
	proc_state := 0
	scan: for {
		k := tok.scan(&t)
		#partial switch k.kind {
		case .EOF:
			break scan
		case .Semicolon:
			if depth == 0 {
				break scan
			}
		case .Comment:
			if depth == 0 {
				continue
			}
		case .Open_Paren, .Open_Bracket, .Open_Brace:
			if depth == 0 {
				if k.kind == .Open_Brace && proc_state == 3 {
					break scan // the body
				}
				if proc_state == 1 {
					proc_state = 2 if k.kind == .Open_Paren else 0
				}
			}
			depth += 1
		case .Close_Paren, .Close_Bracket, .Close_Brace:
			depth -= 1
			if depth == 0 && proc_state == 2 {
				proc_state = 3
			}
		case .Proc:
			if depth == 0 && proc_state == 0 {
				proc_state = 1
			}
		case .Undef:
			if depth == 0 {
				break scan // a foreign declaration's ---
			}
		}
		end = k.pos.offset + len(k.text)
	}
	decl := text[:end]

	b := strings.builder_make()
	indent := column - 1
	for line, i in strings.split_lines(decl, context.temp_allocator) {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		l := line
		if i > 0 {
			// drop the declaration's own indentation, counted in columns
			cut := 0
			for cut < len(l) && cut < indent && (l[cut] == '\t' || l[cut] == ' ') {
				cut += 1
			}
			l = l[cut:]
		}
		col := 0
		for c in l {
			if c == '\t' {
				n := 4 - col % 4
				for _ in 0 ..< n {
					strings.write_byte(&b, ' ')
				}
				col += n
			} else {
				strings.write_rune(&b, c)
				col += 1
			}
		}
	}
	out := strings.trim_right_space(strings.to_string(b))
	// inlining is an implementation detail, not part of the API
	out, _ = strings.replace_all(out, "#force_inline ", "")
	return align_body(out)
}

// Body_Line is one line of a struct or enum body, split for alignment.
Body_Line :: struct {
	indent:  int,
	name:    string, // up to and including the colon of `name: T`; "" when none
	code:    string, // the rest of the code
	comment: string, // `// ...`, or ""
}

// align_body re-aligns a struct or enum body the way odinfmt does: in each
// run of field lines (broken by a blank line or a comment of its own), the
// types start in one column and the trailing comments in another, and a
// comment continuing on the next line keeps the comment column. A body with
// anything else in it (nested blocks, a field spanning lines) is left as
// written.
align_body :: proc(text: string) -> string {
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) < 3 || !strings.has_suffix(lines[0], "{") || lines[len(lines) - 1] != "}" {
		return text
	}
	body := make([]Body_Line, len(lines) - 2, context.temp_allocator)
	for line, i in lines[1:len(lines) - 1] {
		l := &body[i]
		trimmed := strings.trim_left_space(line)
		l.indent = len(line) - len(trimmed)
		if trimmed == "" {
			continue
		}
		code := trimmed
		if c := comment_start(trimmed); c >= 0 {
			code = strings.trim_right_space(trimmed[:c])
			l.comment = trimmed[c:]
		}
		if code != "" && l.indent != 4 {
			return text // nested or continued code
		}
		if code != "" && (strings.count(code, "{") != strings.count(code, "}") || strings.count(code, "(") != strings.count(code, ")")) {
			return text
		}
		if colon := strings.index_byte(code, ':'); colon > 0 && code[colon + 1:colon + 2] != ":" && code[colon + 1:colon + 2] != "=" {
			l.name = code[:colon + 1]
			l.code = strings.trim_left_space(code[colon + 1:])
		} else {
			l.code = code
		}
	}

	b := strings.builder_make()
	strings.write_string(&b, lines[0])
	strings.write_byte(&b, '\n')
	for start := 0; start < len(body); {
		// a run: field lines and the comment lines continuing them
		end := start
		name_w, code_w := 0, 0
		for end < len(body) {
			l := body[end]
			is_field := l.name != "" || l.code != ""
			continues := !is_field && l.comment != "" && l.indent > 4 && end > start
			if !is_field && !continues {
				break
			}
			if is_field {
				name_w = max(name_w, len(l.name))
			}
			end += 1
		}
		for l in body[start:end] {
			if l.name != "" || l.code != "" {
				code_w = max(code_w, field_width(l, name_w))
			}
		}
		if end == start {
			// a blank line or a comment of its own
			l := body[start]
			if l.comment != "" {
				strings.write_string(&b, "    ")
				strings.write_string(&b, l.comment)
			}
			strings.write_byte(&b, '\n')
			start += 1
			continue
		}
		for l in body[start:end] {
			strings.write_string(&b, "    ")
			n := 0
			if l.name != "" || l.code != "" {
				if l.name != "" {
					strings.write_string(&b, l.name)
					pad_to(&b, len(l.name), name_w + 1)
					strings.write_string(&b, l.code)
				} else {
					strings.write_string(&b, l.code)
				}
				n = field_width(l, name_w)
			}
			if l.comment != "" {
				pad_to(&b, n, code_w + 1)
				strings.write_string(&b, l.comment)
			}
			strings.write_byte(&b, '\n')
		}
		start = end
	}
	strings.write_string(&b, "}")
	return strings.to_string(b)

	field_width :: proc(l: Body_Line, name_w: int) -> int {
		if l.name == "" {
			return strings.rune_count(l.code)
		}
		return name_w + 1 + strings.rune_count(l.code)
	}
	pad_to :: proc(b: ^strings.Builder, at, to: int) {
		for _ in at ..< max(to, at + 1) {
			strings.write_byte(b, ' ')
		}
	}
}

// comment_start is the index of a line's `//` comment, outside strings; -1
// when there is none.
comment_start :: proc(s: string) -> int {
	quote: u8 = 0
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case quote != 0:
			if c == '\\' {
				i += 1
			} else if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'' || c == '`':
			quote = c
		case c == '/' && i + 1 < len(s) && s[i + 1] == '/':
			return i
		}
	}
	return -1
}

// ============ links ============

page_by_alias :: proc(alias: string) -> ^Page {
	for &p in pages {
		if p.alias == alias {
			return &p
		}
	}
	return nil
}

page_by_dir :: proc(dir: string) -> ^Page {
	for &p in pages {
		if p.dir == dir {
			return &p
		}
	}
	return nil
}

// href is the link from page `from` to name on page `to`.
href :: proc(from, to: ^Page, name: string) -> string {
	if from == to {
		return fmt.tprintf("#%s", name)
	}
	if name == "" {
		return fmt.tprintf("%s.md", to.slug)
	}
	return fmt.tprintf("%s.md#%s", to.slug, name)
}

// ============ code ============

BUILTIN_TYPES :: []string {
	"bool", "b8", "b16", "b32", "b64", "int", "i8", "i16", "i32", "i64", "i128",
	"uint", "u8", "u16", "u32", "u64", "u128", "uintptr", "f16", "f32", "f64",
	"complex64", "complex128", "quaternion256", "rune", "string", "cstring",
	"rawptr", "any", "byte", "typeid", "Maybe",
}

html_escape :: proc(b: ^strings.Builder, s: string) {
	for c in s {
		switch c {
		case '&':
			strings.write_string(b, "&amp;")
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '"':
			strings.write_string(b, "&quot;")
		case:
			strings.write_rune(b, c)
		}
	}
}

span :: proc(b: ^strings.Builder, class, text: string) {
	fmt.sbprintf(b, `<span class="hljs-%s">`, class)
	html_escape(b, text)
	strings.write_string(b, "</span>")
}

// write_code writes Odin source as a highlighted block, with the names the
// reference documents linked. The first identifier is the declared name
// (self), shown as a title and not linked.
write_code :: proc(b: ^strings.Builder, src: string, page: ^Page, self: string) {
	toks: [dynamic]tok.Token
	defer delete(toks)
	t: tok.Tokenizer
	tok.init(&t, src, "", quiet)
	for {
		k := tok.scan(&t)
		if k.kind == .EOF {
			break
		}
		append(&toks, k)
	}
	// significant neighbours, skipping comments
	prev_of :: proc(toks: []tok.Token, i: int) -> int {
		for j := i - 1; j >= 0; j -= 1 {
			if toks[j].kind != .Comment {
				return j
			}
		}
		return -1
	}
	next_of :: proc(toks: []tok.Token, i: int) -> int {
		for j := i + 1; j < len(toks); j += 1 {
			if toks[j].kind != .Comment {
				return j
			}
		}
		return -1
	}
	kind_at :: proc(toks: []tok.Token, i: int) -> tok.Token_Kind {
		return toks[i].kind if i >= 0 else .Invalid
	}

	strings.write_string(b, `<pre class="docgen"><code class="nohighlight hljs">`)
	at := 0
	titled := false
	for k, i in toks {
		html_escape(b, src[at:k.pos.offset])
		at = k.pos.offset + len(k.text)
		p, n := prev_of(toks[:], i), next_of(toks[:], i)
		#partial switch k.kind {
		case .Comment:
			span(b, "comment", k.text)
		case .String, .Rune:
			span(b, "string", k.text)
		case .Integer, .Float, .Imag:
			span(b, "number", k.text)
		case .Hash, .At:
			span(b, "meta", k.text)
		case .Ident:
			name := k.text
			switch {
			case kind_at(toks[:], p) == .Hash:
				span(b, "meta", name) // #caller_location, #config
			case kind_at(toks[:], p) == .At:
				span(b, "meta", name)
			case !titled && name == self:
				titled = true
				span(b, "title", name)
			case name == "true" || name == "false" || name == "nil":
				span(b, "literal", name)
			case slice.contains(BUILTIN_TYPES, name):
				span(b, "type", name)
			case:
				if target, anchor := code_link(toks[:], i, p, n, page, self); target != nil {
					fmt.sbprintf(b, `<a href="%s">`, href(page, target, anchor))
					html_escape(b, name)
					strings.write_string(b, "</a>")
				} else {
					html_escape(b, name)
				}
			}
		case:
			if tok.Token_Kind.B_Keyword_Begin < k.kind && k.kind < tok.Token_Kind.B_Keyword_End {
				span(b, "keyword", k.text)
			} else {
				html_escape(b, k.text)
			}
		}
	}
	html_escape(b, src[at:])
	strings.write_string(b, "</code></pre>\n")
}

// code_link decides whether identifier i links, and where: a documented name
// of this page, or alias.name of another documented package. Names being
// declared (fields, parameters: `x: T`, `a, b: T`) and fields of a compound
// literal (`{body = 14}`) do not link.
code_link :: proc(toks: []tok.Token, i, p, n: int, page: ^Page, self: string) -> (^Page, string) {
	name := toks[i].text
	pk := toks[p].kind if p >= 0 else tok.Token_Kind.Invalid
	nk := toks[n].kind if n >= 0 else tok.Token_Kind.Invalid
	if pk == .Period {
		// alias.name
		q := p - 1
		for q >= 0 && toks[q].kind == .Comment {
			q -= 1
		}
		if q >= 0 && toks[q].kind == .Ident {
			if q == 0 || toks[q - 1].kind != .Period {
				if target := page_by_alias(toks[q].text); target != nil && name in target.names {
					return target, name
				}
			}
		}
		return nil, ""
	}
	if nk == .Period && page_by_alias(name) != nil {
		return nil, "" // the alias of a qualified name
	}
	if !(name in page.names) || name == self {
		return nil, ""
	}
	// declared names: `x: T`, `a, b: T` — but never a type (`p: T, q: U`)
	declared_after :: proc(k: tok.Token_Kind) -> bool {
		#partial switch k {
		case .Colon, .Pointer, .Close_Bracket, .Period, .Eq, .Arrow_Right, .Ellipsis, .Dollar:
			return false
		}
		return true
	}
	if declared_after(pk) {
		j := i + 1
		for j < len(toks) && toks[j].kind == .Comment {
			j += 1
		}
		for j + 1 < len(toks) && toks[j].kind == .Comma && toks[j + 1].kind == .Ident {
			j += 2
		}
		if j < len(toks) && toks[j].kind == .Colon {
			return nil, ""
		}
	}
	if nk == .Eq && (pk == .Open_Brace || pk == .Comma) {
		return nil, "" // {field = value}
	}
	return page, name
}

// ============ prose ============

is_word_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

is_word :: proc(c: u8) -> bool {
	return is_word_start(c) || (c >= '0' && c <= '9')
}

// write_prose turns a doc comment into Markdown. Tab-indented blocks become
// Odin code blocks; the rest is prose (see write_paragraph).
write_prose :: proc(b: ^strings.Builder, text: string, page: ^Page, self: string) {
	lines := strings.split_lines(strings.trim_right_space(text), context.temp_allocator)
	para := strings.builder_make(context.temp_allocator)
	flush :: proc(b, para: ^strings.Builder, page: ^Page, self: string) {
		if strings.builder_len(para^) > 0 {
			write_paragraph(b, strings.to_string(para^), page, self)
			strings.write_string(b, "\n\n")
			strings.builder_reset(para)
		}
	}
	for i := 0; i < len(lines); {
		line := lines[i]
		if strings.has_prefix(line, "\t") {
			flush(b, &para, page, self)
			// the block: tab-indented lines and the blank lines between them
			j := i
			last := i
			for j < len(lines) && (strings.has_prefix(lines[j], "\t") || strings.trim_space(lines[j]) == "") {
				if strings.has_prefix(lines[j], "\t") {
					last = j
				}
				j += 1
			}
			first := strings.trim_space(line)
			lang := "sh" if strings.has_prefix(first, "odin ") || strings.has_prefix(first, "./") || strings.has_prefix(first, "tools/") else "odin"
			fmt.sbprintf(b, "```%s\n", lang)
			for k in i ..= last {
				l := lines[k]
				if strings.has_prefix(l, "\t") {
					l = l[1:]
				}
				strings.write_string(b, l)
				strings.write_byte(b, '\n')
			}
			strings.write_string(b, "```\n\n")
			i = last + 1
			continue
		}
		if strings.trim_space(line) == "" {
			flush(b, &para, page, self)
		} else {
			if strings.builder_len(para) > 0 {
				strings.write_byte(&para, '\n')
			}
			strings.write_string(&para, line)
		}
		i += 1
	}
	flush(b, &para, page, self)
}

// write_paragraph writes one prose paragraph as Markdown. Characters
// Markdown would read as markup are escaped. Code-like words become code:
// a call (name(args)), a qualified name (niello.begin), a name with an
// underscore. A documented name becomes a link — capitalised ones not at a
// sentence start (where "With" is English), lowercase ones unless they are
// also English words (ENGLISH), and calls and qualified names always.
// niello/<pkg> links to that package's page.
write_paragraph :: proc(b: ^strings.Builder, s: string, page: ^Page, self: string) {
	sentence_start := true
	parens := 0 // inside (...): a list of names reads as names
	for i := 0; i < len(s); {
		c := s[i]
		if c == '`' {
			// an existing code span: verbatim, linked when it is exactly a
			// documented name (`begin_section`, `niello.begin`)
			end := strings.index_byte(s[i + 1:], '`')
			if end >= 0 {
				inner := s[i + 1:i + 1 + end]
				target: ^Page
				anchor := inner
				if dot := strings.index_byte(inner, '.'); dot > 0 {
					if tp := page_by_alias(inner[:dot]); tp != nil && inner[dot + 1:] in tp.names {
						target, anchor = tp, inner[dot + 1:]
					}
				} else if inner in page.names && inner != self {
					target = page
				}
				if target != nil {
					fmt.sbprintf(b, "[`%s`](%s)", inner, href(page, target, anchor))
				} else {
					strings.write_string(b, s[i:i + end + 2])
				}
				i += end + 2
				sentence_start = false
				continue
			}
		}
		if is_word_start(c) && (i == 0 || !is_word(s[i - 1]) && s[i - 1] != '.') {
			j := i
			for j < len(s) && is_word(s[j]) {
				j += 1
			}
			word := s[i:j]

			// a URL: verbatim
			if j + 2 < len(s) && s[j] == ':' && s[j + 1] == '/' && s[j + 2] == '/' {
				k := j
				for k < len(s) && s[k] != ' ' && s[k] != '\n' && s[k] != ')' {
					k += 1
				}
				fmt.sbprintf(b, "<%s>", s[i:k])
				i = k
				sentence_start = false
				continue
			}

			// niello/<pkg>: a package path
			// a package's path links to its page; a file path
			// (third_party/native/README.md) is code; words joined by a
			// slash (load/crop) stay words
			if j + 1 < len(s) && s[j] == '/' && is_word_start(s[j + 1]) {
				k := j + 1
				for k < len(s) && (is_word(s[k]) || s[k] == '/' || s[k] == '.' && k + 1 < len(s) && is_word(s[k + 1])) {
					k += 1
				}
				for k > j && s[k - 1] == '/' {
					k -= 1
				}
				path := s[i:k]
				if target := page_by_dir(path); target != nil {
					fmt.sbprintf(b, "[`%s`](%s)", path, href(page, target, ""))
					i = k
					sentence_start = false
					continue
				} else if strings.contains_any(path, "_.") {
					fmt.sbprintf(b, "`%s`", path)
					i = k
					sentence_start = false
					continue
				}
			}

			target: ^Page
			anchor: string
			k := j
			// alias.name
			if j + 1 < len(s) && s[j] == '.' && is_word_start(s[j + 1]) {
				if tp := page_by_alias(word); tp != nil {
					m := j + 1
					for m < len(s) && is_word(s[m]) {
						m += 1
					}
					if s[j + 1:m] in tp.names {
						target, anchor = tp, s[j + 1:m]
						k = m
					}
				}
			}
			if target == nil && !(word in page.names) && word != self {
				// a core name in a satellite package's docs: a type with a
				// field (With.size)
				// or a core name with an underscore (begin_section)
				if core := &pages[0]; core != page && word in core.names {
					capital := word[0] >= 'A' && word[0] <= 'Z'
					dotted := capital && core.names[word] == .Type && j < len(s) && s[j] == '.'
					if strings.contains_rune(word, '_') || dotted {
						target, anchor = core, word
						if j + 1 < len(s) && s[j] == '.' && is_word_start(s[j + 1]) {
							m := j + 1
							for m < len(s) && is_word(s[m]) {
								m += 1
							}
							k = m
						}
					}
				}
			}
			if target == nil && word in page.names {
				target, anchor = page, word
				// Type.field: the field, linked to its type
				if page.names[word] == .Type && j + 1 < len(s) && s[j] == '.' && is_word_start(s[j + 1]) {
					m := j + 1
					for m < len(s) && is_word(s[m]) {
						m += 1
					}
					k = m
				}
			}
			// a dotted chain (decl.group_masks, app.list_i): code, the head
			// linked when it is documented
			if k == j && j + 1 < len(s) && s[j] == '.' && is_word_start(s[j + 1]) && len(word) > 1 {
				m := j
				for m + 1 < len(s) && s[m] == '.' && is_word_start(s[m + 1]) {
					m += 1
					for m < len(s) && is_word(s[m]) {
						m += 1
					}
				}
				k = m
			}
			// a call: name(...) on one paragraph, when name is documented
			// or has an underscore
			is_call := false
			if k < len(s) && s[k] == '(' && (target != nil || strings.contains_rune(word, '_')) {
				depth := 0
				m := k
				for m < len(s) {
					if s[m] == '(' {
						depth += 1
					} else if s[m] == ')' {
						depth -= 1
						if depth == 0 {
							break
						}
					}
					m += 1
				}
				if m < len(s) && m - i <= 80 {
					is_call = true
					k = m + 1
				}
			}
			code := s[i:k]
			qualified := target != nil && target != page || k > j && !is_call
			link := target != nil && !(target == page && anchor == self)
			if link && !is_call && !qualified {
				capital := word[0] >= 'A' && word[0] <= 'Z'
				title_case := capital && strings.to_upper(word, context.temp_allocator) != word
				if title_case && sentence_start && !strings.contains_rune(word, '_') {
					link = false
				} else if !capital && !strings.contains_rune(word, '_') && slice.contains(ENGLISH, word) && !(parens > 0 && list_item(s, i, k)) {
					link = false
				}
			}
			// the entry's own name is code where the doc opens with it
			// ("clicked reports…"), a word elsewhere ("was clicked")
			opening := i == 0 && target == page && anchor == self
			as_code := link || is_call || qualified || strings.contains_rune(word, '_') || opening
			code = strings.join(strings.split(code, "\n", context.temp_allocator), " ", context.temp_allocator)
			switch {
			case link:
				fmt.sbprintf(b, "[`%s`](%s)", code, href(page, target, anchor))
			case as_code:
				fmt.sbprintf(b, "`%s`", code)
			case:
				strings.write_string(b, code)
			}
			i = k
			sentence_start = false
			continue
		}
		if (c == '#' || c == '$') && i + 1 < len(s) && is_word_start(s[i + 1]) && (i == 0 || !is_word(s[i - 1])) {
			// a directive (#load, #caller_location) or a parameter ($T)
			m := i + 1
			for m < len(s) && is_word(s[m]) {
				m += 1
			}
			if m < len(s) && s[m] == '(' {
				if close := strings.index_byte(s[m:], ')'); close >= 0 && close < 60 {
					m += close + 1
				}
			}
			fmt.sbprintf(b, "`%s`", s[i:m])
			i = m
			sentence_start = false
			continue
		}
		if c == '-' && i + 1 < len(s) && is_word_start(s[i + 1]) && (i == 0 || s[i - 1] == ' ' || s[i - 1] == '\n' || s[i - 1] == '(') {
			// a command-line flag: -define:NIELLO_DEBUG=true
			m := i + 1
			for m < len(s) && s[m] != ' ' && s[m] != '\n' && s[m] != ')' && s[m] != ',' {
				m += 1
			}
			for m > i + 1 && (s[m - 1] == '.' || s[m - 1] == ';' || s[m - 1] == ':') {
				m -= 1
			}
			if strings.contains_any(s[i:m], ":=") {
				fmt.sbprintf(b, "`%s`", s[i:m])
				i = m
				sentence_start = false
				continue
			}
		}
		if c == '^' && i + 1 < len(s) && is_word_start(s[i + 1]) {
			// a pointer type: ^Context
			m := i + 1
			for m < len(s) && (is_word(s[m]) || s[m] == '.' && m + 1 < len(s) && is_word_start(s[m + 1])) {
				m += 1
			}
			name := s[i + 1:m]
			if name in page.names && page.names[name] == .Type && name != self {
				fmt.sbprintf(b, "[`%s`](%s)", s[i:m], href(page, page, name))
			} else {
				fmt.sbprintf(b, "`%s`", s[i:m])
			}
			i = m
			sentence_start = false
			continue
		}
		if c == '@' && i + 1 < len(s) && s[i + 1] == '(' {
			// an attribute: @(deferred_out)
			if close := strings.index_byte(s[i:], ')'); close >= 0 && close < 60 {
				fmt.sbprintf(b, "`%s`", s[i:i + close + 1])
				i += close + 1
				sentence_start = false
				continue
			}
		}
		if c == '.' && i + 1 < len(s) && is_word_start(s[i + 1]) && (i == 0 || !is_word(s[i - 1]) && s[i - 1] != ')' && s[i - 1] != '`' && s[i - 1] != '.') {
			// an enum literal: .Font_Size
			m := i + 1
			for m < len(s) && is_word(s[m]) {
				m += 1
			}
			fmt.sbprintf(b, "`%s`", s[i:m])
			i = m
			sentence_start = false
			continue
		}
		switch c {
		case '*', '[', ']', '\\', '_':
			strings.write_byte(b, '\\')
			strings.write_byte(b, c)
		case '<':
			strings.write_string(b, "&lt;")
		case '>':
			strings.write_string(b, "&gt;")
		case '#':
			if i == 0 || s[i - 1] == '\n' {
				strings.write_byte(b, '\\')
			}
			strings.write_byte(b, c)
		case:
			strings.write_byte(b, c)
		}
		if c == '(' {
			parens += 1
		} else if c == ')' && parens > 0 {
			parens -= 1
		} else if c == '\n' && i + 1 < len(s) && s[i + 1] == '\n' {
			parens = 0
		}
		switch c {
		case '.', '!', '?', ':':
			sentence_start = true
		case ' ', '\n', '\t', '(', ')', '"', '-':
		case:
			sentence_start = false
		}
		i += 1
	}
}

// list_item reports that s[i:k] stands alone as an item of a parenthesised
// list: "(clicked, hovered, pressed…)", not "(a size, a variant)".
list_item :: proc(s: string, i, k: int) -> bool {
	p := i - 1
	for p >= 0 && (s[p] == ' ' || s[p] == '\n') {
		p -= 1
	}
	if p < 0 || (s[p] != '(' && s[p] != ',') {
		return false
	}
	if k >= len(s) {
		return false
	}
	rest := s[k:]
	return strings.has_prefix(rest, ",") || strings.has_prefix(rest, ")") || strings.has_prefix(rest, "…")
}

// ============ pages ============

write_page :: proc(b: ^strings.Builder, page: ^Page, source: string) {
	strings.write_string(b, "<!-- Generated by tools/docgen from the doc comments in ")
	strings.write_string(b, page.dir)
	strings.write_string(b, ". Do not edit: change the comments and regenerate. -->\n\n")
	fmt.sbprintf(b, "# %s\n\n", page.dir)
	fmt.sbprintf(b, "```odin\nimport %s \"%s\"\n```\n\n", page.alias, page.import_path)
	write_prose(b, page.docs, page, "")

	// the index
	strings.write_string(b, "## Index\n\n")
	for kind in Kind {
		first := true
		for e in page.entries {
			if e.kind != kind {
				continue
			}
			if first {
				fmt.sbprintf(b, "**%s:** ", KIND_TITLE[kind])
				first = false
			} else {
				strings.write_string(b, " · ")
			}
			fmt.sbprintf(b, "[`%s`](#%s)", e.name, e.name)
			if e.debug {
				strings.write_string(b, "<sup>debug</sup>")
			}
		}
		if !first {
			strings.write_string(b, "\n\n")
		}
	}

	for kind in Kind {
		first := true
		for e in page.entries {
			if e.kind != kind {
				continue
			}
			if first {
				fmt.sbprintf(b, "## %s\n\n", KIND_TITLE[kind])
				first = false
			}
			fmt.sbprintf(b, "### %s {{#%s}}\n\n", e.name, e.name)
			write_code(b, e.decl, page, e.name)
			strings.write_byte(b, '\n')
			if e.debug {
				strings.write_string(b, "*Debug builds only* (`-define:NIELLO_DEBUG=true`).\n\n")
			}
			docs := e.docs if e.docs != "" else e.comment
			if strings.trim_space(docs) != "" {
				write_prose(b, docs, page, e.name)
			}
			fmt.sbprintf(b, "<sub>[%s:%d](%s/%s#L%d)</sub>\n\n", e.file, e.line, source, e.file, e.line)
		}
	}
}
