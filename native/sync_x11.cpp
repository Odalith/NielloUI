// sync_x11.cpp — F3 PROTOTYPE (TODO #19): X11 _NET_WM_SYNC_REQUEST
// participation, implemented against Xlib/XSync on a PRIVATE Display
// connection.
//
// Why a private connection: SDL owns the window's connection and
// SDL3 removed the SYSWM event, so app code cannot see the
// sync-request ClientMessage through SDL at all. This connection
// never touches SDL's queue; it only ever receives SendEvent
// ClientMessages addressed to the window (plus nothing else — no
// event mask is selected). Whether KWin's SendEvent reaches a
// second connection is THE open question this prototype answers:
// setup logs under NUI_TRACE, requests and acks log once each, and
// a drag that never paces means the messages are not arriving.
//
// Why two counters: the _NET_WM_SYNC_REQUEST_COUNTER property may
// hold the basic counter alone or basic + extended (GIMP publishes
// two). Both are set to the same serial, so either variant of the
// request unblocks the compositor.
//
// Safety contract: the counter is NEVER set without a received
// serial, and never set to 0. If setup fails partway, or no request
// is ever seen, the window behaves exactly as before participation
// (KWin's timeout fallback paces the resize instead). The hi/lo
// order in XSyncIntsToValue is (lo, hi) — swapping them hangs the
// UI until the WM timeout (xfwm4 report); the call below passes
// them in that order, from data.l[2] (low) and data.l[3] (high).

#include "sync_x11.h"

#include <cstdio>
#include <new>

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/extensions/sync.h>

struct SyncX11 {
    Display* display = nullptr;
    Window window = 0;
    XSyncCounter counter = 0;
    XSyncCounter counter_ext = 0;
    Atom request_atom = 0;
    Atom protocols_atom = 0;
    Atom counter_atom = 0;
    uint32_t pending_lo = 0;
    uint32_t pending_hi = 0;
    bool pending = false;
    bool trace = false;
    bool logged_request = false;
    bool logged_ack = false;
};

namespace {

void DestroyCounters(Display* display, XSyncCounter counter,
                     XSyncCounter counter_ext) noexcept {
    if (counter) {
        (void)XSyncDestroyCounter(display, counter);
    }
    if (counter_ext) {
        (void)XSyncDestroyCounter(display, counter_ext);
    }
}

} // namespace

SyncX11* SyncX11_Create(uint64_t window_xid, bool trace) noexcept {
    if (!window_xid) return nullptr;

    Display* display = XOpenDisplay(nullptr);
    if (!display) return nullptr;

    int major = 0, minor = 0;
    if (!XSyncInitialize(display, &major, &minor)) {
        XCloseDisplay(display);
        return nullptr;
    }

    XSyncValue zero{};
    XSyncIntsToValue(&zero, 0, 0);
    XSyncCounter counter = XSyncCreateCounter(display, zero);
    XSyncCounter counter_ext = XSyncCreateCounter(display, zero);
    if (!counter || !counter_ext) {
        DestroyCounters(display, counter, counter_ext);
        XCloseDisplay(display);
        return nullptr;
    }

    const Atom request_atom =
        XInternAtom(display, "_NET_WM_SYNC_REQUEST", False);
    const Atom counter_atom =
        XInternAtom(display, "_NET_WM_SYNC_REQUEST_COUNTER", False);
    const Atom protocols_atom = XInternAtom(display, "WM_PROTOCOLS", False);
    if (!request_atom || !counter_atom || !protocols_atom) {
        DestroyCounters(display, counter, counter_ext);
        XCloseDisplay(display);
        return nullptr;
    }

    const Window xid = static_cast<Window>(window_xid);
    const XID ids[2] = {counter, counter_ext};
    XChangeProperty(display, xid, counter_atom, XA_CARDINAL, 32,
                    PropModeReplace,
                    reinterpret_cast<const unsigned char*>(ids), 2);

    // Append the protocol, preserving SDL's existing entries.
    Atom* list = nullptr;
    int count = 0;
    if (XGetWMProtocols(display, xid, &list, &count)) {
        bool present = false;
        for (int i = 0; i < count; ++i) {
            if (list[i] == request_atom) present = true;
        }
        if (!present) {
            Atom* grown = new (std::nothrow) Atom[count + 1];
            if (!grown) {
                XFree(list);
                DestroyCounters(display, counter, counter_ext);
                XCloseDisplay(display);
                return nullptr;
            }
            for (int i = 0; i < count; ++i) grown[i] = list[i];
            grown[count] = request_atom;
            XSetWMProtocols(display, xid, grown, count + 1);
            delete[] grown;
        }
        XFree(list);
    } else {
        Atom only = request_atom;
        XSetWMProtocols(display, xid, &only, 1);
    }
    XFlush(display);

    SyncX11* sync = new (std::nothrow) SyncX11();
    if (!sync) {
        DestroyCounters(display, counter, counter_ext);
        XCloseDisplay(display);
        return nullptr;
    }
    sync->display = display;
    sync->window = xid;
    sync->counter = counter;
    sync->counter_ext = counter_ext;
    sync->request_atom = request_atom;
    sync->protocols_atom = protocols_atom;
    sync->counter_atom = counter_atom;
    sync->trace = trace;

    if (trace) {
        std::fprintf(stderr,
                     "nui: sync: participation active window=%llu "
                     "counter=%lu ext=%lu\n",
                     static_cast<unsigned long long>(window_xid),
                     static_cast<unsigned long>(counter),
                     static_cast<unsigned long>(counter_ext));
    }
    return sync;
}

void SyncX11_Destroy(SyncX11* sync) noexcept {
    if (!sync) return;
    Display* display = sync->display;
    const Window xid = sync->window;

    // Restore WM_PROTOCOLS without our entry; delete the property
    // outright if nothing else remains.
    Atom* list = nullptr;
    int count = 0;
    if (XGetWMProtocols(display, xid, &list, &count)) {
        int kept = 0;
        for (int i = 0; i < count; ++i) {
            if (list[i] != sync->request_atom) ++kept;
        }
        if (kept == count) {
            // Our entry was never there; leave the list alone.
        } else if (kept > 0) {
            Atom* shrunk = new (std::nothrow) Atom[kept];
            if (shrunk) {
                int out = 0;
                for (int i = 0; i < count; ++i) {
                    if (list[i] != sync->request_atom) shrunk[out++] = list[i];
                }
                XSetWMProtocols(display, xid, shrunk, kept);
                delete[] shrunk;
            }
        } else {
            XDeleteProperty(display, xid, sync->protocols_atom);
        }
        XFree(list);
    }
    XDeleteProperty(display, xid, sync->counter_atom);
    DestroyCounters(display, sync->counter, sync->counter_ext);
    XCloseDisplay(display);
    delete sync;
}

void SyncX11_Poll(SyncX11* sync) noexcept {
    if (!sync) return;
    // XPending flushes output and returns the queued count without
    // blocking, so XNextEvent below can never stall the frame.
    while (XPending(sync->display) > 0) {
        XEvent event{};
        XNextEvent(sync->display, &event);
        if (event.type != ClientMessage) continue;
        const XClientMessageEvent& message = event.xclient;
        if (message.message_type != sync->protocols_atom) continue;
        if (message.data.l[0] !=
            static_cast<long>(sync->request_atom)) {
            continue;
        }
        // EWMH: data.l[2] = low 32 bits, data.l[3] = high 32 bits
        // of the serial. Latest wins (ack compression).
        sync->pending_lo = static_cast<uint32_t>(message.data.l[2]);
        sync->pending_hi = static_cast<uint32_t>(message.data.l[3]);
        sync->pending = true;
        if (sync->trace && !sync->logged_request) {
            sync->logged_request = true;
            std::fprintf(stderr,
                         "nui: sync: request seen serial hi=%u lo=%u\n",
                         sync->pending_hi, sync->pending_lo);
        }
    }
}

void SyncX11_Ack(SyncX11* sync) noexcept {
    if (!sync || !sync->pending) return;
    XSyncValue value{};
    // XSyncIntsToValue takes (lo, hi). Swapping them hangs the UI
    // until the WM timeout — see the file header.
    XSyncIntsToValue(&value, sync->pending_lo,
                     static_cast<int>(sync->pending_hi));
    (void)XSyncSetCounter(sync->display, sync->counter, value);
    (void)XSyncSetCounter(sync->display, sync->counter_ext, value);
    XFlush(sync->display);
    sync->pending = false;
    if (sync->trace && !sync->logged_ack) {
        sync->logged_ack = true;
        std::fprintf(stderr, "nui: sync: ack sent\n");
    }
}
