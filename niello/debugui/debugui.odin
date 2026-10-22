// debugui — the Niello debugger window (TODO #18).
//
// A master debugger in the Avalonia DevTools lineage, built on
// the gated debug API (niello/debug.odin): one window, a target
// switcher over the app's live contexts, the target's node tree
// (hover a row and the node highlights in its own window,
// Clay-style), a selection panel with the effective style, and
// the §3.13 overflow report as a list whose rows highlight too.
//
// Opt-in is two unconditional lines in the app:
//
//	import debugui "niello/debugui" // (path per your layout)
//	...
//	debugui.install()
//
// In a NIELLO_DEBUG build (-define:NIELLO_DEBUG=true), F12 in
// ANY window of the app then opens the debugger targeted at
// that window (or retargets it); the glue consumes the key. In
// a prod build install() is an empty proc and the debugger
// package compiles to nothing — the engine side (snapshot,
// debug API) is gated the same way, so prod pays zero: no
// per-frame work, no state, no behavior change.
//
// The debugger styles itself with a fixed neutral look — never
// the app's groups or theme — so it stays readable whatever
// the app under it does.
//
// v1 scope notes: the tree has no collapse/expand (declaration
// culling keeps big trees cheap to paint; a 24k-node target
// still costs a 24k-row declare in this window — dev tooling,
// accepted cost). Selection is by instance: if the app's tree
// reshapes, the selection may point at a different node until
// re-clicked. If the debugger window is closed from the OS,
// the package still believes it is open (window lifecycle
// events are TODO #26) — reopen by restarting the app for now.
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
