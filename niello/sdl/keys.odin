// keys.odin — SDL keyboard codes → the core's Key_Code / Modifiers.
//
// The core never sees an SDL number: every key event is translated
// here, once, at the glue boundary.
package sdl

import sdl "vendor:sdl3"
import niello "../"

// key_from_scancode names the key at a physical position.
@(private)
key_from_scancode :: proc(sc: sdl.Scancode) -> niello.Key_Code {
	#partial switch sc {
	case .A ..= .Z:
		return niello.Key_Code(int(niello.Key_Code.A) + int(sc) - int(sdl.Scancode.A))
	// SDL orders the digit row 1..9, 0.
	case ._1 ..= ._9:
		return niello.Key_Code(int(niello.Key_Code.Digit_1) + int(sc) - int(sdl.Scancode._1))
	case ._0:
		return .Digit_0
	case .F1 ..= .F12:
		return niello.Key_Code(int(niello.Key_Code.F1) + int(sc) - int(sdl.Scancode.F1))
	case .F13 ..= .F24:
		return niello.Key_Code(int(niello.Key_Code.F13) + int(sc) - int(sdl.Scancode.F13))
	// SDL orders the keypad digits 1..9, 0 as well.
	case .KP_1 ..= .KP_9:
		return niello.Key_Code(int(niello.Key_Code.Kp_1) + int(sc) - int(sdl.Scancode.KP_1))
	case .KP_0:
		return .Kp_0

	case .RETURN, .RETURN2: return .Enter
	case .ESCAPE:           return .Escape
	case .BACKSPACE:        return .Backspace
	case .TAB:              return .Tab
	case .SPACE:            return .Space

	case .MINUS:        return .Minus
	case .EQUALS:       return .Equals
	case .LEFTBRACKET:  return .Left_Bracket
	case .RIGHTBRACKET: return .Right_Bracket
	case .BACKSLASH, .NONUSHASH: return .Backslash
	case .SEMICOLON:    return .Semicolon
	case .APOSTROPHE:   return .Apostrophe
	case .GRAVE:        return .Grave
	case .COMMA:        return .Comma
	case .PERIOD:       return .Period
	case .SLASH:        return .Slash

	case .CAPSLOCK:     return .Caps_Lock
	case .SCROLLLOCK:   return .Scroll_Lock
	case .NUMLOCKCLEAR: return .Num_Lock
	case .PRINTSCREEN:  return .Print_Screen
	case .PAUSE:        return .Pause
	case .APPLICATION, .MENU: return .Menu

	case .INSERT:   return .Insert
	case .DELETE:   return .Delete
	case .HOME:     return .Home
	case .END:      return .End
	case .PAGEUP:   return .Page_Up
	case .PAGEDOWN: return .Page_Down
	case .LEFT:     return .Left
	case .RIGHT:    return .Right
	case .UP:       return .Up
	case .DOWN:     return .Down

	case .KP_DIVIDE:   return .Kp_Divide
	case .KP_MULTIPLY: return .Kp_Multiply
	case .KP_MINUS:    return .Kp_Minus
	case .KP_PLUS:     return .Kp_Plus
	case .KP_ENTER:    return .Kp_Enter
	case .KP_PERIOD:   return .Kp_Period
	case .KP_EQUALS:   return .Kp_Equals

	case .LSHIFT: return .Left_Shift
	case .RSHIFT: return .Right_Shift
	case .LCTRL:  return .Left_Ctrl
	case .RCTRL:  return .Right_Ctrl
	case .LALT:   return .Left_Alt
	case .RALT:   return .Right_Alt
	case .LGUI:   return .Left_Super
	case .RGUI:   return .Right_Super
	}
	return .Unknown
}

// key_from_keycode names a logical key. SDL keycodes are either a
// character (letters lowercase) or a scancode tagged with
// K_SCANCODE_MASK for keys that produce none.
@(private)
key_from_keycode :: proc(k: sdl.Keycode) -> niello.Key_Code {
	if k & sdl.K_EXTENDED_MASK != 0 {
		return .Unknown // SDL's extended keys (media, etc.): no name here
	}
	if k & sdl.K_SCANCODE_MASK != 0 {
		return key_from_scancode(sdl.Scancode(k & ~sdl.Keycode(sdl.K_SCANCODE_MASK)))
	}
	switch rune(k) {
	case 'a' ..= 'z':
		return niello.Key_Code(int(niello.Key_Code.A) + int(k) - 'a')
	case 'A' ..= 'Z':
		return niello.Key_Code(int(niello.Key_Code.A) + int(k) - 'A')
	case '0' ..= '9':
		return niello.Key_Code(int(niello.Key_Code.Digit_0) + int(k) - '0')
	case '\r':   return .Enter
	case '\x1b': return .Escape
	case '\b':   return .Backspace
	case '\t':   return .Tab
	case ' ':    return .Space
	case '\x7f': return .Delete
	case '-':    return .Minus
	case '=':    return .Equals
	case '[':    return .Left_Bracket
	case ']':    return .Right_Bracket
	case '\\':   return .Backslash
	case ';':    return .Semicolon
	case '\'':   return .Apostrophe
	case '`':    return .Grave
	case ',':    return .Comma
	case '.':    return .Period
	case '/':    return .Slash
	}
	return .Unknown
}

// key_event translates one SDL key event. The logical key is asked
// for unmodified (modstate {}): SDL's event keycode is shifted by
// default (Shift+1 arrives as '!'), and Key_Event.key is defined as
// independent of the modifiers. key_event = true keeps SDL's
// layout options (SDL_HINT_KEYCODE_OPTIONS) applied.
@(private)
key_event :: proc(ev: sdl.KeyboardEvent) -> niello.Key_Event {
	mods: niello.Modifiers
	if ev.mod & sdl.KMOD_SHIFT != {} { mods += {.Shift} }
	if ev.mod & sdl.KMOD_CTRL  != {} { mods += {.Ctrl} }
	if ev.mod & sdl.KMOD_ALT   != {} { mods += {.Alt} }
	if ev.mod & sdl.KMOD_GUI   != {} { mods += {.Super} }
	return niello.Key_Event{
		key      = key_from_keycode(sdl.GetKeyFromScancode(ev.scancode, {}, true)),
		physical = key_from_scancode(ev.scancode),
		mods     = mods,
		down     = ev.down,
		repeat   = ev.repeat,
	}
}
