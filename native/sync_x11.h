// sync_x11.h — F3 PROTOTYPE (TODO #19): X11 _NET_WM_SYNC_REQUEST
// participation for one backend window, behind a plain interface so
// Xlib's macros (None, Status, Window, ...) never reach nui.cpp.
//
// Linux-only: compiled into nui_native on Linux (see CMakeLists);
// nui.cpp calls these only under __linux__. All functions are
// no-ops on a null handle and never throw. When setup fails the
// handle is null and behaviour is exactly as before participation.
#ifndef NIELLO_SYNC_X11_H
#define NIELLO_SYNC_X11_H

#include <cstdint>

struct SyncX11;

// Open a private X connection, create the basic + extended XSync
// counters, publish them, and list _NET_WM_SYNC_REQUEST in
// WM_PROTOCOLS. Returns nullptr on any failure (inert). `trace`
// enables one-line stderr diagnostics (setup, first request, first
// ack) in the NUI_TRACE style; production logic never reads them.
SyncX11* SyncX11_Create(uint64_t window_xid, bool trace) noexcept;
// Undo Create: restore WM_PROTOCOLS, delete the counter property,
// destroy both counters, close the connection. Safe on nullptr.
void SyncX11_Destroy(SyncX11* sync) noexcept;
// Drain queued ClientMessages on the private connection; stash the
// latest sync-request serial (compression is allowed by the
// protocol: the latest serial supersedes earlier ones).
void SyncX11_Poll(SyncX11* sync) noexcept;
// Set both counters to the stashed serial, after a successful
// present. No-op when no request is pending.
void SyncX11_Ack(SyncX11* sync) noexcept;

#endif // NIELLO_SYNC_X11_H
