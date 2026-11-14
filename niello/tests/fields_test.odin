package tests

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strings"
import "core:testing"
import "core:unicode"
import niello ".."

// pascal turns a member name into its Field name: font_color -> Font_Color.
@(private = "file")
pascal :: proc(snake: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	up := true
	for c in snake {
		if c == '_' {
			strings.write_rune(&b, '_')
			up = true
			continue
		}
		strings.write_rune(&b, up ? unicode.to_upper(c) : c)
		up = false
	}
	return strings.to_string(b)
}

// The style field table names every field's place in Style and in
// Style_Decl. A row that points at the wrong member, or a member with
// no row, would silently write one field into another; this checks the
// table against the two structs.
@(test)
test_field_table_matches_the_structs :: proc(t: ^testing.T) {
	rows := niello.test_field_rows()
	style := reflect.struct_fields_zipped(niello.Style)
	decl := reflect.struct_fields_zipped(niello.Style_Decl)

	// Style holds style fields only: one row each, and each field is
	// named after its member (Style.font_color is Field.Font_Color), so
	// the name in set(u, .X, v) is the name in a Style_Decl.
	testing.expect_value(t, len(style), len(niello.Field))
	for sf in style {
		hits := 0
		for row, f in rows {
			if row.style_off == sf.offset {
				hits += 1
				testing.expectf(t, row.id == sf.type.id, "Style.%s: the row's type differs", sf.name)
				testing.expectf(t, row.size == sf.type.size, "Style.%s: the row's size differs", sf.name)
				name := fmt.tprintf("%v", f)
				testing.expectf(t, name == pascal(sf.name), "Style.%s is Field.%s: the field should be named %s", sf.name, name, pascal(sf.name))
			}
		}
		testing.expectf(t, hits == 1, "Style.%s has %d rows", sf.name, hits)
	}

	// Each row's Style_Decl member is Maybe(the Style member's type).
	covered := 0
	for df in decl {
		for row, f in rows {
			if row.decl_off != df.offset {
				continue
			}
			covered += 1
			testing.expectf(t, row.decl_id == df.type.id, "%v: the row's Style_Decl type differs", f)
			u, ok := runtime.type_info_base(df.type).variant.(runtime.Type_Info_Union)
			testing.expectf(t, ok && len(u.variants) == 1 && u.variants[0].id == row.id,
				"Style_Decl.%s is not Maybe of Style's type", df.name)
		}
	}
	testing.expect_value(t, covered, len(niello.Field))

	// The members of Style_Decl that are not style values.
	others := []string{
		"hover", "press", "focus", "disabled", "focusable", "focus_ring",
		"text_input", "groups", "group_masks",
	}
	testing.expect_value(t, len(decl), len(niello.Field) + len(others))
	for name in others {
		found := false
		for df in decl {
			found ||= df.name == name
		}
		testing.expectf(t, found, "Style_Decl.%s is missing", name)
	}

	// The field sets.
	testing.expect_value(t, card(niello.ALL_FIELDS), len(niello.Field))
	testing.expect(t, niello.VISUAL_FIELDS <= niello.ALL_FIELDS)
}
