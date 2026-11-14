// Package debugui is NielloUI's debugger window: a live view of any of the
// app's windows, with its node tree (hover a row and the node highlights in
// its window), the selected node's effective style and declared values, and
// the overflow report (what does not fit, and by how much).
//
//	debugui.install() // once, in main
//
// Build with -define:NIELLO_DEBUG=true and press F12 in any window to open
// the debugger on it (open does the same from code). Without the define,
// install and open do nothing and the package and the engine's debug
// support compile away entirely.
//
// The debugger has its own fixed look, untouched by the app's theme. It
// closes when the last app window does.
package debugui

import niello ".."

// install registers the F12 summon hook in debug builds; in
// prod builds it does nothing at all. Call once from main.
install :: proc() {
	when niello.NIELLO_DEBUG {
		install_impl()
	}
}

// open is the programmatic form of F12 (a menu item, a button):
// opens the debugger targeted at ctx, or retargets it. A no-op
// in prod builds.
open :: proc(ctx: ^niello.Context) {
	when niello.NIELLO_DEBUG {
		summon(ctx)
	}
}
