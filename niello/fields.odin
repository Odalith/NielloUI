#+private
package niello

import "base:intrinsics"
import "base:runtime"

// ============ the style field table ============
//
// Every style field is listed here once, in FIELD_META: where it sits in
// Style and in Style_Decl, its type, and how it animates. The procedures
// that handle fields generically (set, set_many, overlay merges, glides,
// edits, propagate) all work from this table, so a new field is the Field
// enum, its Style and Style_Decl members, and one row here (plus
// default_style when its default is not zero). FIELD_META is indexed by
// Field, so a missing row does not compile; tests/fields_test.odin checks
// that every row matches the two structs.

// Field_Kind is how a field's values compare and interpolate.
Field_Kind :: enum u8 {
	Snap,    // compared bytewise, never interpolated (enums, bools, handles)
	Color,   // interpolated per channel
	F32,     // interpolated
	U8,      // interpolated, rounded
	U16,     // interpolated, rounded
	Padding, // [4]u16, interpolated per side
	Size,    // [2]Sizing, interpolated when the kinds match (start_glide)
	Text,    // a string: compared by content, written through store_text
	Spans,   // []Text_Span: compared elementwise, written through store_spans
}

Field_Meta :: struct {
	style_off: uintptr, // offset in Style
	decl_off:  uintptr, // offset of the Maybe in Style_Decl
	size:      int,     // size of the Style member
	id:        typeid,  // type of the Style member
	decl_id:   typeid,  // type of the Style_Decl member: Maybe(id)
	kind:      Field_Kind,
}

// Field_Tag is where a Style_Decl Maybe keeps its tag (nonzero: set).
Field_Tag :: struct {
	off:  uintptr,
	size: int,
}

// FIELD_TAGS is filled at startup from the type info (init_field_tags).
FIELD_TAGS: [Field]Field_Tag

// Field_Hot is the copy path's view of a field, compact and with its size
// as a dense class (a jump table, not a compare chain): overlay merges
// copy fields for every instance with an active state.
Field_Hot :: struct {
	off:   u32,
	class: u8, // 0: 1 byte, 1: 2, 2: 4, 3: 8, 4: 16, 5: any other size
	size:  u32,
}

FIELD_HOT: [Field]Field_Hot

FIELD_META := [Field]Field_Meta {
	.Color                = {offset_of(Style, color), offset_of(Style_Decl, color), size_of(Color), typeid_of(type_of(Style{}.color)), typeid_of(type_of(Style_Decl{}.color)), .Color},
	.Font_Color           = {offset_of(Style, font_color), offset_of(Style_Decl, font_color), size_of(Color), typeid_of(type_of(Style{}.font_color)), typeid_of(type_of(Style_Decl{}.font_color)), .Color},
	.Border_Color         = {offset_of(Style, border_color), offset_of(Style_Decl, border_color), size_of(Color), typeid_of(type_of(Style{}.border_color)), typeid_of(type_of(Style_Decl{}.border_color)), .Color},
	.Text                 = {offset_of(Style, text), offset_of(Style_Decl, text), size_of(string), typeid_of(type_of(Style{}.text)), typeid_of(type_of(Style_Decl{}.text)), .Text},
	.Font                 = {offset_of(Style, font), offset_of(Style_Decl, font), size_of(Font_Handle), typeid_of(type_of(Style{}.font)), typeid_of(type_of(Style_Decl{}.font)), .Snap},
	.Font_Size            = {offset_of(Style, font_size), offset_of(Style_Decl, font_size), size_of(f32), typeid_of(type_of(Style{}.font_size)), typeid_of(type_of(Style_Decl{}.font_size)), .F32},
	.Font_Weight          = {offset_of(Style, font_weight), offset_of(Style_Decl, font_weight), size_of(Font_Weight), typeid_of(type_of(Style{}.font_weight)), typeid_of(type_of(Style_Decl{}.font_weight)), .Snap},
	.Font_Slant           = {offset_of(Style, font_slant), offset_of(Style_Decl, font_slant), size_of(Font_Slant), typeid_of(type_of(Style{}.font_slant)), typeid_of(type_of(Style_Decl{}.font_slant)), .Snap},
	.Text_Wrap            = {offset_of(Style, wrap), offset_of(Style_Decl, wrap), size_of(Text_Wrap), typeid_of(type_of(Style{}.wrap)), typeid_of(type_of(Style_Decl{}.wrap)), .Snap},
	.Whitespace           = {offset_of(Style, whitespace), offset_of(Style_Decl, whitespace), size_of(Whitespace), typeid_of(type_of(Style{}.whitespace)), typeid_of(type_of(Style_Decl{}.whitespace)), .Snap},
	.Ellipsis             = {offset_of(Style, ellipsis), offset_of(Style_Decl, ellipsis), size_of(bool), typeid_of(type_of(Style{}.ellipsis)), typeid_of(type_of(Style_Decl{}.ellipsis)), .Snap},
	.Justify              = {offset_of(Style, justify), offset_of(Style_Decl, justify), size_of(bool), typeid_of(type_of(Style{}.justify)), typeid_of(type_of(Style_Decl{}.justify)), .Snap},
	.Padding              = {offset_of(Style, padding), offset_of(Style_Decl, padding), size_of([4]u16), typeid_of(type_of(Style{}.padding)), typeid_of(type_of(Style_Decl{}.padding)), .Padding},
	.Gap                  = {offset_of(Style, gap), offset_of(Style_Decl, gap), size_of(u16), typeid_of(type_of(Style{}.gap)), typeid_of(type_of(Style_Decl{}.gap)), .U16},
	.Corner_Radius        = {offset_of(Style, corner_radius), offset_of(Style_Decl, corner_radius), size_of(u8), typeid_of(type_of(Style{}.corner_radius)), typeid_of(type_of(Style_Decl{}.corner_radius)), .U8},
	.Opacity              = {offset_of(Style, opacity), offset_of(Style_Decl, opacity), size_of(u8), typeid_of(type_of(Style{}.opacity)), typeid_of(type_of(Style_Decl{}.opacity)), .U8},
	.Layout               = {offset_of(Style, layout), offset_of(Style_Decl, layout), size_of(Layout), typeid_of(type_of(Style{}.layout)), typeid_of(type_of(Style_Decl{}.layout)), .Snap},
	.Align                = {offset_of(Style, align), offset_of(Style_Decl, align), size_of([2]Align_Kind), typeid_of(type_of(Style{}.align)), typeid_of(type_of(Style_Decl{}.align)), .Snap},
	.Size                 = {offset_of(Style, size), offset_of(Style_Decl, size), size_of(Size), typeid_of(type_of(Style{}.size)), typeid_of(type_of(Style_Decl{}.size)), .Size},
	.Scroll               = {offset_of(Style, scroll), offset_of(Style_Decl, scroll), size_of(Scroll), typeid_of(type_of(Style{}.scroll)), typeid_of(type_of(Style_Decl{}.scroll)), .Snap},
	.Overflow             = {offset_of(Style, overflow), offset_of(Style_Decl, overflow), size_of(Overflow), typeid_of(type_of(Style{}.overflow)), typeid_of(type_of(Style_Decl{}.overflow)), .Snap},
	.Border_Width         = {offset_of(Style, border_width), offset_of(Style_Decl, border_width), size_of(u16), typeid_of(type_of(Style{}.border_width)), typeid_of(type_of(Style_Decl{}.border_width)), .U16},
	.Overlay_Color        = {offset_of(Style, overlay_color), offset_of(Style_Decl, overlay_color), size_of(Color), typeid_of(type_of(Style{}.overlay_color)), typeid_of(type_of(Style_Decl{}.overlay_color)), .Color},
	.Overlay_Border_Color = {offset_of(Style, overlay_border_color), offset_of(Style_Decl, overlay_border_color), size_of(Color), typeid_of(type_of(Style{}.overlay_border_color)), typeid_of(type_of(Style_Decl{}.overlay_border_color)), .Color},
	.Overlay_Border_Width = {offset_of(Style, overlay_border_width), offset_of(Style_Decl, overlay_border_width), size_of(u16), typeid_of(type_of(Style{}.overlay_border_width)), typeid_of(type_of(Style_Decl{}.overlay_border_width)), .U16},
	.Text_Spans           = {offset_of(Style, text_spans), offset_of(Style_Decl, text_spans), size_of([]Text_Span), typeid_of(type_of(Style{}.text_spans)), typeid_of(type_of(Style_Decl{}.text_spans)), .Spans},
	.Cursor               = {offset_of(Style, cursor), offset_of(Style_Decl, cursor), size_of(Cursor_Kind), typeid_of(type_of(Style{}.cursor)), typeid_of(type_of(Style_Decl{}.cursor)), .Snap},
	.Scroll_Chain         = {offset_of(Style, scroll_chain), offset_of(Style_Decl, scroll_chain), size_of(bool), typeid_of(type_of(Style{}.scroll_chain)), typeid_of(type_of(Style_Decl{}.scroll_chain)), .Snap},
	.Smooth_Scroll        = {offset_of(Style, smooth_scroll), offset_of(Style_Decl, smooth_scroll), size_of(bool), typeid_of(type_of(Style{}.smooth_scroll)), typeid_of(type_of(Style_Decl{}.smooth_scroll)), .Snap},
	.Smooth_Ms            = {offset_of(Style, smooth_ms), offset_of(Style_Decl, smooth_ms), size_of(u16), typeid_of(type_of(Style{}.smooth_ms)), typeid_of(type_of(Style_Decl{}.smooth_ms)), .Snap},
	.Overscroll           = {offset_of(Style, overscroll), offset_of(Style_Decl, overscroll), size_of(bool), typeid_of(type_of(Style{}.overscroll)), typeid_of(type_of(Style_Decl{}.overscroll)), .Snap},
	.Overscroll_Px        = {offset_of(Style, overscroll_px), offset_of(Style_Decl, overscroll_px), size_of(u16), typeid_of(type_of(Style{}.overscroll_px)), typeid_of(type_of(Style_Decl{}.overscroll_px)), .Snap},
	.Image                = {offset_of(Style, image), offset_of(Style_Decl, image), size_of(Image), typeid_of(type_of(Style{}.image)), typeid_of(type_of(Style_Decl{}.image)), .Snap},
	.Image_Fit            = {offset_of(Style, image_fit), offset_of(Style_Decl, image_fit), size_of(Image_Fit), typeid_of(type_of(Style{}.image_fit)), typeid_of(type_of(Style_Decl{}.image_fit)), .Snap},
	.Image_Interp         = {offset_of(Style, image_interp), offset_of(Style_Decl, image_interp), size_of(Image_Interp), typeid_of(type_of(Style{}.image_interp)), typeid_of(type_of(Style_Decl{}.image_interp)), .Snap},
}

// init_field_tags records where each Style_Decl Maybe keeps its tag, so
// reading a decl is a load instead of a reflection call.
@(init)
init_field_tags :: proc "contextless" () {
	for m, f in FIELD_META {
		u := runtime.type_info_base(type_info_of(m.decl_id)).variant.(runtime.Type_Info_Union)
		FIELD_TAGS[f] = {u.tag_offset, u.tag_type.size if u.tag_type != nil else 0}
		class: u8
		switch m.size {
		case 1:  class = 0
		case 2:  class = 1
		case 4:  class = 2
		case 8:  class = 3
		case 16: class = 4
		case:    class = 5
		}
		FIELD_HOT[f] = {u32(m.style_off), class, u32(m.size)}
	}
}

// copy_bytes and equal_bytes move and compare a field's bytes in place:
// the fields are 1 to 16 bytes, which a libc call would dwarf.
copy_bytes :: #force_inline proc "contextless" (dst, src: rawptr, size: int) {
	switch size {
	case 1:
		(^u8)(dst)^ = (^u8)(src)^
	case 2:
		intrinsics.unaligned_store((^u16)(dst), intrinsics.unaligned_load((^u16)(src)))
	case 4:
		intrinsics.unaligned_store((^u32)(dst), intrinsics.unaligned_load((^u32)(src)))
	case 8:
		intrinsics.unaligned_store((^u64)(dst), intrinsics.unaligned_load((^u64)(src)))
	case 16:
		intrinsics.unaligned_store((^[2]u64)(dst), intrinsics.unaligned_load((^[2]u64)(src)))
	case:
		intrinsics.mem_copy_non_overlapping(dst, src, size)
	}
}

equal_bytes :: #force_inline proc "contextless" (a, b: rawptr, size: int) -> bool {
	switch size {
	case 1:
		return (^u8)(a)^ == (^u8)(b)^
	case 2:
		return intrinsics.unaligned_load((^u16)(a)) == intrinsics.unaligned_load((^u16)(b))
	case 4:
		return intrinsics.unaligned_load((^u32)(a)) == intrinsics.unaligned_load((^u32)(b))
	case 8:
		return intrinsics.unaligned_load((^u64)(a)) == intrinsics.unaligned_load((^u64)(b))
	case 16:
		return intrinsics.unaligned_load((^[2]u64)(a)) == intrinsics.unaligned_load((^[2]u64)(b))
	}
	return runtime.memory_compare(a, b, size) == 0
}

// field_ptr is the address of field f inside style s.
field_ptr :: #force_inline proc(s: ^Style, f: Field) -> rawptr #no_bounds_check {
	return rawptr(uintptr(s) + FIELD_META[f].style_off)
}

// field_of reads field f of s as a typed value.
field_of :: #force_inline proc(s: ^Style, f: Field, $T: typeid) -> ^T {
	return (^T)(field_ptr(s, f))
}

// decl_value is the value decl sets for f, or ok = false when the Maybe is
// empty. The value aliases decl.
decl_value :: proc(decl: ^Style_Decl, f: Field) -> (v: any, ok: bool) {
	m := &FIELD_META[f]
	maybe := rawptr(uintptr(decl) + m.decl_off)
	tag := rawptr(uintptr(maybe) + FIELD_TAGS[f].off)
	set: bool
	switch FIELD_TAGS[f].size {
	case 1:
		set = (^u8)(tag)^ != 0
	case 2:
		set = intrinsics.unaligned_load((^u16)(tag)) != 0
	case 4:
		set = intrinsics.unaligned_load((^u32)(tag)) != 0
	case 8:
		set = intrinsics.unaligned_load((^u64)(tag)) != 0
	case:
		panic("niello: a Style_Decl field is not a tagged Maybe")
	}
	if !set {
		return nil, false
	}
	return any{maybe, m.id}, true // a Maybe's value sits at its start
}

// explicit_fields reports which fields a decl sets. Recorded at mint for
// propagate; also what group_apply broadcasts.
explicit_fields :: proc(d: Style_Decl) -> Fields {
	d := d
	f: Fields
	for field in Field {
		if _, ok := decl_value(&d, field); ok {
			f += {field}
		}
	}
	return f
}

// style_set_any writes one field of a bare style (no unit bookkeeping, no
// cloning): v must hold the field's type.
style_set_any :: proc(s: ^Style, f: Field, v: any) {
	m := FIELD_META[f]
	assert(v.id == m.id, "niello.set: value type does not match the field")
	copy_bytes(field_ptr(s, f), v.data, m.size)
}

// copy_field copies field f from src to dst (strings and spans alias).
copy_field :: #force_inline proc(dst, src: ^Style, f: Field) #no_bounds_check {
	h := FIELD_HOT[f]
	d := rawptr(uintptr(dst) + uintptr(h.off))
	s := rawptr(uintptr(src) + uintptr(h.off))
	switch h.class {
	case 0:
		(^u8)(d)^ = (^u8)(s)^
	case 1:
		intrinsics.unaligned_store((^u16)(d), intrinsics.unaligned_load((^u16)(s)))
	case 2:
		intrinsics.unaligned_store((^u32)(d), intrinsics.unaligned_load((^u32)(s)))
	case 3:
		intrinsics.unaligned_store((^u64)(d), intrinsics.unaligned_load((^u64)(s)))
	case 4:
		intrinsics.unaligned_store((^[2]u64)(d), intrinsics.unaligned_load((^[2]u64)(s)))
	case:
		intrinsics.mem_copy_non_overlapping(d, s, int(h.size))
	}
}

// field_equal compares field f across two styles (edit diffs, propagate,
// no-op writes).
field_equal :: proc(a, b: ^Style, f: Field) -> bool {
	switch FIELD_META[f].kind {
	case .Text:
		return field_of(a, f, string)^ == field_of(b, f, string)^
	case .Spans:
		sa, sb := field_of(a, f, []Text_Span)^, field_of(b, f, []Text_Span)^
		if len(sa) != len(sb) {
			return false
		}
		for i in 0 ..< len(sa) {
			if sa[i] != sb[i] {
				return false
			}
		}
		return true
	case .F32:
		return field_of(a, f, f32)^ == field_of(b, f, f32)^
	case .Size:
		// typed: Sizing has padding bytes, and -0 equals 0
		return field_of(a, f, Size)^ == field_of(b, f, Size)^
	case .Snap, .Color, .U8, .U16, .Padding:
		return equal_bytes(field_ptr(a, f), field_ptr(b, f), FIELD_META[f].size)
	}
	return true
}

// field_animatable reports whether a field's values interpolate. The rest
// (text, enums, bools, handles) snap at t=0. Size is conditionally
// animatable: start_glide demotes it to a snap when the kinds differ.
field_animatable :: #force_inline proc(f: Field) -> bool {
	#partial switch FIELD_META[f].kind {
	case .Snap, .Text, .Spans:
		return false
	}
	return true
}

// lerp_field writes the interpolation of a's and b's f into dst at t. A
// field that does not interpolate takes b's value.
lerp_field :: proc(dst, a, b: ^Style, f: Field, t: f32) {
	switch FIELD_META[f].kind {
	case .Color:
		field_of(dst, f, Color)^ = lerp_color(field_of(a, f, Color)^, field_of(b, f, Color)^, t)
	case .F32:
		field_of(dst, f, f32)^ = lerp_f32(field_of(a, f, f32)^, field_of(b, f, f32)^, t)
	case .U8:
		field_of(dst, f, u8)^ = lerp_u8(field_of(a, f, u8)^, field_of(b, f, u8)^, t)
	case .U16:
		field_of(dst, f, u16)^ = lerp_u16(field_of(a, f, u16)^, field_of(b, f, u16)^, t)
	case .Padding:
		pa, pb, pd := field_of(a, f, [4]u16), field_of(b, f, [4]u16), field_of(dst, f, [4]u16)
		for i in 0 ..< 4 {
			pd[i] = lerp_u16(pa[i], pb[i], t)
		}
	case .Size:
		za, zb, zd := field_of(a, f, Size), field_of(b, f, Size), field_of(dst, f, Size)
		for ax in 0 ..< 2 {
			sa, sb := za[ax], zb[ax]
			zd[ax] = Sizing{
				kind     = sa.kind,
				value    = lerp_f32(sa.value, sb.value, t),
				min      = lerp_f32(sa.min, sb.min, t),
				weight   = lerp_f32(sa.weight, sb.weight, t),
				priority = sa.priority if t < 1 else sb.priority, // an order: snaps
				// max is INF in most styles; only lerp two finite,
				// differing ceilings, never arithmetic on INF.
				max      = sa.max if sa.max == sb.max else sb.max,
			}
		}
	case .Snap, .Text, .Spans:
		copy_field(dst, b, f)
	}
}
