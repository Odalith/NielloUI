// atspi.cpp — AT-SPI exporter (Linux only, TODO #23 M2).
//
// Serves the semantics mirror (niello/a11y.odin, M1) to assistive
// technology over D-Bus: the application object, one window object
// per context, one object per mirror node, and the cache object the
// registry reads. The Odin side calls nui_atspi_sync after every
// frame_end; this side diffs the rows against its shadow and emits
// the AT-SPI change signals.
//
// Transport is the hand-rolled wire client (dbus.h): no libdbus, no
// sd-bus, so the static archive stays dependency-free (TODO #11).
// The exporter is inert when no accessibility bus answers —
// nui_atspi_start returns 0, sync is a no-op — so a machine without
// at-spi2-core pays nothing.
//
// Threading: the D-Bus dispatch thread owns recv and answers method
// calls from a SNAPSHOT of the shadow (copied under the mutex, then
// the lock is released before any reply is built or sent). The main
// thread mutates the shadow in sync and collects outbound signals
// under the lock, then sends them after unlocking. No thread ever
// holds the shadow mutex across a socket write, and no lock order
// beyond shadow-then-send exists, so the two threads cannot deadlock.
//
// Contract notes (verified against the AT-SPI sources during M2
// recon; the residual Orca-time risks are listed in the M2 report):
//   - GetState / cache states are a u64 BITMASK, bit N = state N,
//     sent as an `au` of exactly TWO u32s, low word first. libatspi
//     rebuilds the bitmap as states[1] << 32 | states[0] and warns
//     (and drops the states) for any other element count — an
//     enum-value list, however correct-looking, makes Orca see
//     every object with no states at all. (Confirmed by Orca,
//     2026-10-31: "expected 2 values in states array; got 4..7".)
//   - GetExtents returns ONE struct (iiii), not four outs.
//   - GetItems' parent field is the application object for every
//     item (GTK4 cache convention); the application item itself
//     has the null parent. The Accessible Parent property still
//     reports the real parent.
//   - StateChanged carries the state NAME as its detail string and
//     enabled as detail1; ChildrenChanged carries "add"/"remove"
//     and the index in parent. Both share the (s i i v a{sv}) body.

#include "nui.h"
#include "dbus.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

namespace {

// ---------------------------------------------------------------------------
// AT-SPI enums (verified values; only the emitted subset is named).

enum : uint32_t {
	ATSPI_ROLE_INVALID        = 0,
	ATSPI_ROLE_CALENDAR       = 5,
	ATSPI_ROLE_CHECK_BOX      = 7,
	ATSPI_ROLE_COLUMN_HEADER  = 10,
	ATSPI_ROLE_COMBO_BOX      = 11,
	ATSPI_ROLE_FILLER         = 20,
	ATSPI_ROLE_IMAGE          = 27,
	ATSPI_ROLE_LIST           = 31,
	ATSPI_ROLE_LIST_ITEM      = 32,
	ATSPI_ROLE_MENU           = 33,
	ATSPI_ROLE_MENU_BAR       = 34,
	ATSPI_ROLE_MENU_ITEM      = 35,
	ATSPI_ROLE_PAGE_TAB       = 37,
	ATSPI_ROLE_PAGE_TAB_LIST  = 38,
	ATSPI_ROLE_PANEL          = 39,
	ATSPI_ROLE_PROGRESS_BAR   = 42,
	ATSPI_ROLE_PUSH_BUTTON    = 43,
	ATSPI_ROLE_RADIO_BUTTON   = 44,
	ATSPI_ROLE_SCROLL_BAR     = 48,
	ATSPI_ROLE_SCROLL_PANE    = 49,
	ATSPI_ROLE_SEPARATOR      = 50,
	ATSPI_ROLE_SLIDER         = 51,
	ATSPI_ROLE_SPIN_BUTTON    = 52,
	ATSPI_ROLE_STATUS_BAR     = 54,
	ATSPI_ROLE_TABLE          = 55,
	ATSPI_ROLE_TEXT           = 61,
	ATSPI_ROLE_TOGGLE_BUTTON  = 62,
	ATSPI_ROLE_TOOL_BAR       = 63,
	ATSPI_ROLE_TOOL_TIP       = 64,
	ATSPI_ROLE_TREE           = 65,
	ATSPI_ROLE_UNKNOWN        = 67,
	ATSPI_ROLE_WINDOW         = 69,
	ATSPI_ROLE_HEADER         = 71,
	ATSPI_ROLE_APPLICATION    = 75,
	ATSPI_ROLE_ENTRY          = 79,
	ATSPI_ROLE_DOCUMENT_FRAME = 82,
	ATSPI_ROLE_LINK           = 88,
	ATSPI_ROLE_TABLE_ROW      = 90,
	ATSPI_ROLE_TREE_ITEM      = 91,
	ATSPI_ROLE_GROUPING       = 99,
	ATSPI_ROLE_TITLE_BAR      = 104,
};

// Odin A11y_Role ordinal (Avalonia's 43-value order) -> AT-SPI role.
// Judgment calls (no exact AT-SPI counterpart) are marked.
const uint32_t kRoleMap[43] = {
	ATSPI_ROLE_INVALID,        // None
	ATSPI_ROLE_PUSH_BUTTON,    // Button
	ATSPI_ROLE_CALENDAR,       // Calendar
	ATSPI_ROLE_CHECK_BOX,      // CheckBox
	ATSPI_ROLE_COMBO_BOX,      // ComboBox
	ATSPI_ROLE_LIST_ITEM,      // ComboBoxItem
	ATSPI_ROLE_ENTRY,          // Edit
	ATSPI_ROLE_LINK,           // Hyperlink
	ATSPI_ROLE_IMAGE,          // Image
	ATSPI_ROLE_LIST_ITEM,      // ListItem
	ATSPI_ROLE_LIST,           // List
	ATSPI_ROLE_MENU,           // Menu
	ATSPI_ROLE_MENU_BAR,       // MenuBar
	ATSPI_ROLE_MENU_ITEM,      // MenuItem
	ATSPI_ROLE_PROGRESS_BAR,   // ProgressBar
	ATSPI_ROLE_RADIO_BUTTON,   // RadioButton
	ATSPI_ROLE_SCROLL_BAR,     // ScrollBar
	ATSPI_ROLE_SLIDER,         // Slider
	ATSPI_ROLE_SPIN_BUTTON,    // Spinner
	ATSPI_ROLE_STATUS_BAR,     // StatusBar
	ATSPI_ROLE_PAGE_TAB_LIST,  // Tab
	ATSPI_ROLE_PAGE_TAB,       // TabItem
	ATSPI_ROLE_TEXT,           // Text
	ATSPI_ROLE_TOOL_BAR,       // ToolBar
	ATSPI_ROLE_TOOL_TIP,       // ToolTip
	ATSPI_ROLE_TREE,           // Tree
	ATSPI_ROLE_TREE_ITEM,      // TreeItem
	ATSPI_ROLE_UNKNOWN,        // Custom (judgment)
	ATSPI_ROLE_GROUPING,       // Group
	ATSPI_ROLE_FILLER,         // Thumb (judgment)
	ATSPI_ROLE_TABLE,          // DataGrid
	ATSPI_ROLE_TABLE_ROW,      // DataItem (judgment)
	ATSPI_ROLE_DOCUMENT_FRAME, // Document (judgment)
	ATSPI_ROLE_PUSH_BUTTON,    // SplitButton (judgment)
	ATSPI_ROLE_WINDOW,         // Window
	ATSPI_ROLE_PANEL,          // Pane
	ATSPI_ROLE_HEADER,         // Header
	ATSPI_ROLE_COLUMN_HEADER,  // HeaderItem (judgment)
	ATSPI_ROLE_TABLE,          // Table
	ATSPI_ROLE_TITLE_BAR,      // TitleBar
	ATSPI_ROLE_SEPARATOR,      // Separator
	ATSPI_ROLE_TOGGLE_BUTTON,  // Expander (judgment)
	ATSPI_ROLE_SCROLL_PANE,    // ScrollViewer
};

const char *atspi_role_name(uint32_t role) {
	switch (role) {
	case ATSPI_ROLE_INVALID:        return "invalid";
	case ATSPI_ROLE_CALENDAR:       return "calendar";
	case ATSPI_ROLE_CHECK_BOX:      return "check box";
	case ATSPI_ROLE_COLUMN_HEADER:  return "column header";
	case ATSPI_ROLE_COMBO_BOX:      return "combo box";
	case ATSPI_ROLE_FILLER:         return "filler";
	case ATSPI_ROLE_IMAGE:          return "image";
	case ATSPI_ROLE_LIST:           return "list";
	case ATSPI_ROLE_LIST_ITEM:      return "list item";
	case ATSPI_ROLE_MENU:           return "menu";
	case ATSPI_ROLE_MENU_BAR:       return "menu bar";
	case ATSPI_ROLE_MENU_ITEM:      return "menu item";
	case ATSPI_ROLE_PAGE_TAB:       return "page tab";
	case ATSPI_ROLE_PAGE_TAB_LIST:  return "page tab list";
	case ATSPI_ROLE_PANEL:          return "panel";
	case ATSPI_ROLE_PROGRESS_BAR:   return "progress bar";
	case ATSPI_ROLE_PUSH_BUTTON:    return "push button";
	case ATSPI_ROLE_RADIO_BUTTON:   return "radio button";
	case ATSPI_ROLE_SCROLL_BAR:     return "scroll bar";
	case ATSPI_ROLE_SCROLL_PANE:    return "scroll pane";
	case ATSPI_ROLE_SEPARATOR:      return "separator";
	case ATSPI_ROLE_SLIDER:         return "slider";
	case ATSPI_ROLE_SPIN_BUTTON:    return "spin button";
	case ATSPI_ROLE_STATUS_BAR:     return "status bar";
	case ATSPI_ROLE_TABLE:          return "table";
	case ATSPI_ROLE_TEXT:           return "text";
	case ATSPI_ROLE_TOGGLE_BUTTON:  return "toggle button";
	case ATSPI_ROLE_TOOL_BAR:       return "tool bar";
	case ATSPI_ROLE_TOOL_TIP:       return "tool tip";
	case ATSPI_ROLE_TREE:           return "tree";
	case ATSPI_ROLE_UNKNOWN:        return "unknown";
	case ATSPI_ROLE_WINDOW:         return "window";
	case ATSPI_ROLE_HEADER:         return "header";
	case ATSPI_ROLE_APPLICATION:    return "application";
	case ATSPI_ROLE_ENTRY:          return "entry";
	case ATSPI_ROLE_DOCUMENT_FRAME: return "document frame";
	case ATSPI_ROLE_LINK:           return "link";
	case ATSPI_ROLE_TABLE_ROW:      return "table row";
	case ATSPI_ROLE_TREE_ITEM:      return "tree item";
	case ATSPI_ROLE_GROUPING:       return "grouping";
	case ATSPI_ROLE_TITLE_BAR:      return "title bar";
	default:                        return "unknown";
	}
}

enum : uint32_t {
	ATSPI_STATE_INVALID       = 0,
	ATSPI_STATE_CHECKED       = 4,
	ATSPI_STATE_EDITABLE      = 7,
	ATSPI_STATE_ENABLED       = 8,
	ATSPI_STATE_EXPANDABLE    = 9,
	ATSPI_STATE_EXPANDED      = 10,
	ATSPI_STATE_FOCUSABLE     = 11,
	ATSPI_STATE_FOCUSED       = 12,
	ATSPI_STATE_HORIZONTAL    = 14,
	ATSPI_STATE_MULTI_LINE    = 17,
	ATSPI_STATE_SELECTABLE    = 22,
	ATSPI_STATE_SELECTED      = 23,
	ATSPI_STATE_SENSITIVE     = 24,
	ATSPI_STATE_SHOWING       = 25,
	ATSPI_STATE_SINGLE_LINE   = 26,
	ATSPI_STATE_VERTICAL      = 29,
	ATSPI_STATE_VISIBLE       = 30,
	ATSPI_STATE_REQUIRED      = 33,
};

const char *atspi_state_name(uint32_t state) {
	switch (state) {
	case ATSPI_STATE_CHECKED:      return "checked";
	case ATSPI_STATE_EDITABLE:     return "editable";
	case ATSPI_STATE_ENABLED:      return "enabled";
	case ATSPI_STATE_EXPANDABLE:   return "expandable";
	case ATSPI_STATE_EXPANDED:     return "expanded";
	case ATSPI_STATE_FOCUSABLE:    return "focusable";
	case ATSPI_STATE_FOCUSED:      return "focused";
	case ATSPI_STATE_HORIZONTAL:   return "horizontal";
	case ATSPI_STATE_MULTI_LINE:   return "multi-line";
	case ATSPI_STATE_SELECTABLE:   return "selectable";
	case ATSPI_STATE_SELECTED:     return "selected";
	case ATSPI_STATE_SENSITIVE:    return "sensitive";
	case ATSPI_STATE_SHOWING:      return "showing";
	case ATSPI_STATE_SINGLE_LINE:  return "single-line";
	case ATSPI_STATE_VERTICAL:     return "vertical";
	case ATSPI_STATE_VISIBLE:      return "visible";
	case ATSPI_STATE_REQUIRED:     return "required";
	default:                       return "invalid";
	}
}

// Odin A11y_Flag bit positions (ORDER IS ABI — see nui.h).
enum : uint32_t {
	FLAG_CHECKED   = 1u << 0,
	FLAG_SELECTED  = 1u << 1,
	FLAG_EXPANDED  = 1u << 2,
	FLAG_READONLY  = 1u << 3,
	FLAG_REQUIRED  = 1u << 4,
	FLAG_MULTILINE = 1u << 5,
};

// Odin A11y_State_Flag bit positions (ORDER IS ABI — see nui.h).
enum : uint32_t {
	STATE_DISABLED  = 1u << 0,
	STATE_FOCUSED   = 1u << 1,
	STATE_OFFSCREEN = 1u << 2,
	STATE_SCROLL_X  = 1u << 3,
	STATE_SCROLL_Y  = 1u << 4,
	STATE_FOCUSABLE = 1u << 5,
};

// Odin A11y_Role ordinals needed by the state rules.
enum : uint32_t {
	ODIN_ROLE_EDIT       = 6,
	ODIN_ROLE_LIST_ITEM  = 9,
	ODIN_ROLE_TREE_ITEM  = 26,
};

// ---------------------------------------------------------------------------
// Shadow tree: the last synced mirror, per window.

struct Shadow_Node {
	uint64_t id = 0;
	int32_t parent = -1; // index into the window's nodes
	uint32_t role = 0; // AT-SPI role (mapped)
	uint32_t odin_role = 0; // Odin A11y_Role ordinal
	std::string name, description, value_text;
	uint32_t flags = 0, state = 0; // Odin bit positions
	float x = 0, y = 0, w = 0, h = 0; // DIP, window-relative
	bool has_value = false;
	float value_num = 0, value_min = 0, value_max = 0;
};

struct Shadow_Window {
	std::string title;
	int win_x = 0, win_y = 0;
	int win_w = 0, win_h = 0; // DIP size (window node's extents)
	std::vector<Shadow_Node> nodes; // declaration order, parents first
};

// AT-SPI states for a node, as a u64 bitmask: bit N = state N.
// The wire form is exactly two u32s, low word first (see the
// contract note at the top of this file).
uint64_t atspi_state_bits_for(const Shadow_Node &n) {
	uint64_t bits = 0;
	auto set_state = [&bits](uint32_t s) { bits |= (1ULL << s); };
	if ((n.flags & FLAG_CHECKED) != 0) {
		set_state(ATSPI_STATE_CHECKED);
	}
	if (n.odin_role == ODIN_ROLE_EDIT && (n.flags & FLAG_READONLY) == 0) {
		set_state(ATSPI_STATE_EDITABLE);
	}
	if ((n.state & STATE_DISABLED) == 0) {
		set_state(ATSPI_STATE_ENABLED);
	}
	if ((n.flags & FLAG_EXPANDED) != 0) {
		set_state(ATSPI_STATE_EXPANDABLE);
		set_state(ATSPI_STATE_EXPANDED);
	}
	if ((n.state & STATE_FOCUSABLE) != 0) {
		set_state(ATSPI_STATE_FOCUSABLE);
	}
	if ((n.state & STATE_FOCUSED) != 0) {
		set_state(ATSPI_STATE_FOCUSED);
	}
	if ((n.state & STATE_SCROLL_X) != 0) {
		set_state(ATSPI_STATE_HORIZONTAL);
	}
	if ((n.flags & FLAG_MULTILINE) != 0) {
		set_state(ATSPI_STATE_MULTI_LINE);
	}
	if (n.odin_role == ODIN_ROLE_LIST_ITEM || n.odin_role == ODIN_ROLE_TREE_ITEM) {
		set_state(ATSPI_STATE_SELECTABLE);
	}
	if ((n.flags & FLAG_SELECTED) != 0) {
		set_state(ATSPI_STATE_SELECTED);
	}
	if ((n.state & STATE_DISABLED) == 0) {
		set_state(ATSPI_STATE_SENSITIVE);
	}
	if ((n.state & STATE_OFFSCREEN) == 0) {
		set_state(ATSPI_STATE_SHOWING);
	}
	if (n.odin_role == ODIN_ROLE_EDIT && (n.flags & FLAG_MULTILINE) == 0) {
		set_state(ATSPI_STATE_SINGLE_LINE);
	}
	if ((n.state & STATE_SCROLL_Y) != 0) {
		set_state(ATSPI_STATE_VERTICAL);
	}
	if ((n.state & STATE_OFFSCREEN) == 0) {
		set_state(ATSPI_STATE_VISIBLE);
	}
	if ((n.flags & FLAG_REQUIRED) != 0) {
		set_state(ATSPI_STATE_REQUIRED);
	}
	return bits;
}

// States for the synthetic window node and the application object:
// present, enabled, sensitive, visible.
uint64_t atspi_chrome_state_bits() {
	return (1ULL << ATSPI_STATE_ENABLED) | (1ULL << ATSPI_STATE_SENSITIVE) |
	       (1ULL << ATSPI_STATE_SHOWING) | (1ULL << ATSPI_STATE_VISIBLE);
}

// Every state this exporter can emit, for bit-diffing a state set.
const uint32_t kEmittedStates[] = {
    ATSPI_STATE_CHECKED,     ATSPI_STATE_EDITABLE,    ATSPI_STATE_ENABLED,
    ATSPI_STATE_EXPANDABLE,  ATSPI_STATE_EXPANDED,    ATSPI_STATE_FOCUSABLE,
    ATSPI_STATE_FOCUSED,     ATSPI_STATE_HORIZONTAL,  ATSPI_STATE_MULTI_LINE,
    ATSPI_STATE_SELECTABLE,  ATSPI_STATE_SELECTED,    ATSPI_STATE_SENSITIVE,
    ATSPI_STATE_SHOWING,     ATSPI_STATE_SINGLE_LINE, ATSPI_STATE_VERTICAL,
    ATSPI_STATE_VISIBLE,     ATSPI_STATE_REQUIRED,
};

// ---------------------------------------------------------------------------
// Exporter state.

const char *kRootPath = "/org/a11y/atspi/accessible/root";
const char *kCachePath = "/org/a11y/atspi/cache";
const char *kNullPath = "/org/a11y/atspi/null";

const char *kIfAccessible = "org.a11y.atspi.Accessible";
const char *kIfComponent = "org.a11y.atspi.Component";
const char *kIfValue = "org.a11y.atspi.Value";
const char *kIfApplication = "org.a11y.atspi.Application";
const char *kIfSocket = "org.a11y.atspi.Socket";
const char *kIfCache = "org.a11y.atspi.Cache";
const char *kIfProperties = "org.freedesktop.DBus.Properties";
const char *kIfIntrospectable = "org.freedesktop.DBus.Introspectable";
const char *kIfPeer = "org.freedesktop.DBus.Peer";

const char *kErrUnknownMethod = "org.freedesktop.DBus.Error.UnknownMethod";
const char *kErrInvalidArgs = "org.freedesktop.DBus.Error.InvalidArgs";
const char *kErrPropertyReadOnly = "org.freedesktop.DBus.Error.PropertyReadOnly";

struct Exporter {
	std::mutex mu;
	bool running = false;
	dbus::Conn bus;
	std::thread dispatch_thread;
	std::string app_name;
	std::string unique_name; // this connection's name on the a11y bus
	std::string bus_address; // the a11y bus address we connected to
	std::string registry_sender, registry_path; // Embed reply; empty = unembedded
	int32_t app_id = 0; // set by the registry via Properties.Set
	std::string locale; // $LANG or "C"
	std::string machine_id; // /etc/machine-id or ""
	bool ready_sent = false;
	std::map<int, Shadow_Window> windows; // keyed by ctx id
};

Exporter g_exp;
std::mutex g_start_mu; // serializes start/stop

std::string node_path(int ctx, uint64_t id) {
	char buf[160];
	std::snprintf(buf, sizeof(buf), "/org/a11y/atspi/accessible/%d/%llx", ctx,
	              static_cast<unsigned long long>(id));
	return buf;
}

std::string window_path(int ctx) {
	char buf[128];
	std::snprintf(buf, sizeof(buf), "/org/a11y/atspi/accessible/%d/window", ctx);
	return buf;
}

// Object references: a struct of (owning connection NAME, object
// path) — signature "(so)", name first. The order matters: the
// daemon validates the object-path field and drops the connection
// when it holds a bus name instead (the first integration run died
// on exactly this swap).
void write_ref(dbus::Writer &w, const std::string &path, const std::string &sender) {
	w.begin_struct();
	w.str(sender);
	w.object_path(path);
	w.end_struct();
}

void write_null_ref(dbus::Writer &w) { write_ref(w, kNullPath, ""); }

void write_app_ref(dbus::Writer &w, const std::string &unique_name) {
	write_ref(w, kRootPath, unique_name);
}

// --- Tree navigation over a shadow window (caller holds the mutex
// for the live shadow, or works on a snapshot copy). ---

std::vector<int> children_of(const Shadow_Window &win, int parent_index) {
	std::vector<int> out;
	for (int i = 0; i < static_cast<int>(win.nodes.size()); i++) {
		if (win.nodes[static_cast<size_t>(i)].parent == parent_index) {
			out.push_back(i);
		}
	}
	return out;
}

int index_in_parent(const Shadow_Window &win, int node_index) {
	int parent = win.nodes[static_cast<size_t>(node_index)].parent;
	std::vector<int> sibs = children_of(win, parent);
	for (int i = 0; i < static_cast<int>(sibs.size()); i++) {
		if (sibs[static_cast<size_t>(i)] == node_index) {
			return i;
		}
	}
	return -1;
}

int find_node(const Shadow_Window &win, uint64_t id) {
	for (int i = 0; i < static_cast<int>(win.nodes.size()); i++) {
		if (win.nodes[static_cast<size_t>(i)].id == id) {
			return i;
		}
	}
	return -1;
}

// Index of a window among the application object's children (map order).
int window_index(const std::map<int, Shadow_Window> &windows, int ctx) {
	int i = 0;
	for (const auto &kv : windows) {
		if (kv.first == ctx) {
			return i;
		}
		i++;
	}
	return -1;
}

// --- Snapshots: method calls read a copy taken under the mutex, so
// handlers never hold the lock across a reply build or send. ---

struct Snapshot {
	std::string app_name, unique_name, bus_address;
	std::string registry_sender, registry_path;
	int32_t app_id = 0;
	std::string locale, machine_id;
	std::map<int, Shadow_Window> windows;
};

Snapshot take_snapshot() {
	Snapshot snap;
	std::lock_guard<std::mutex> lock(g_exp.mu);
	snap.app_name = g_exp.app_name;
	snap.unique_name = g_exp.unique_name;
	snap.bus_address = g_exp.bus_address;
	snap.registry_sender = g_exp.registry_sender;
	snap.registry_path = g_exp.registry_path;
	snap.app_id = g_exp.app_id;
	snap.locale = g_exp.locale;
	snap.machine_id = g_exp.machine_id;
	snap.windows = g_exp.windows;
	return snap;
}

enum class Target_Kind { Unknown, Root, Cache, Window, Node };

struct Target {
	Target_Kind kind = Target_Kind::Unknown;
	int ctx = 0;
	int index = -1; // node index within the window, for Node
};

Target resolve_target(const Snapshot &snap, const std::string &path) {
	Target t;
	if (path == kRootPath) {
		t.kind = Target_Kind::Root;
		return t;
	}
	if (path == kCachePath) {
		t.kind = Target_Kind::Cache;
		return t;
	}
	const std::string prefix = "/org/a11y/atspi/accessible/";
	if (path.compare(0, prefix.size(), prefix) != 0) {
		return t;
	}
	std::string rest = path.substr(prefix.size());
	size_t slash = rest.find('/');
	if (slash == std::string::npos) {
		return t;
	}
	int ctx = std::atoi(rest.substr(0, slash).c_str());
	std::string tail = rest.substr(slash + 1);
	auto it = snap.windows.find(ctx);
	if (it == snap.windows.end()) {
		return t;
	}
	if (tail == "window") {
		t.kind = Target_Kind::Window;
		t.ctx = ctx;
		return t;
	}
	// Hex instance id (node_path uses %llx).
	uint64_t id = std::strtoull(tail.c_str(), nullptr, 16);
	int idx = find_node(it->second, id);
	if (idx < 0) {
		return t;
	}
	t.kind = Target_Kind::Node;
	t.ctx = ctx;
	t.index = idx;
	return t;
}

void write_string_array(dbus::Writer &w, const std::vector<std::string> &v) {
	w.begin_array(4);
	for (const std::string &s : v) {
		w.str(s);
	}
	w.end_array();
}

void write_state_array(dbus::Writer &w, uint64_t bits) {
	w.begin_array(4);
	w.u32(static_cast<uint32_t>(bits & 0xffffffffULL));
	w.u32(static_cast<uint32_t>(bits >> 32));
	w.end_array();
}

std::vector<std::string> interfaces_for(Target_Kind kind, bool has_value) {
	switch (kind) {
	case Target_Kind::Root:
		return {kIfAccessible, kIfApplication, kIfSocket};
	case Target_Kind::Window:
		return {kIfAccessible, kIfComponent};
	case Target_Kind::Node: {
		std::vector<std::string> ifs = {kIfAccessible, kIfComponent};
		if (has_value) {
			ifs.push_back(kIfValue);
		}
		return ifs;
	}
	case Target_Kind::Cache:
		return {kIfCache};
	default:
		return {};
	}
}

// Parent reference for a node or window node, following the REAL
// tree (the cache's parent field is a different rule — see
// write_cache_item). The window node's parent is the application
// object; the application object's parent is the registry root when
// embedded, else the null reference.
void write_parent_ref(dbus::Writer &w, const Snapshot &snap, const Target &t) {
	if (t.kind == Target_Kind::Root) {
		if (!snap.registry_path.empty()) {
			write_ref(w, snap.registry_path, snap.registry_sender);
		} else {
			write_null_ref(w);
		}
		return;
	}
	if (t.kind == Target_Kind::Window) {
		write_app_ref(w, snap.unique_name);
		return;
	}
	const Shadow_Window &win = snap.windows.at(t.ctx);
	const Shadow_Node &n = win.nodes[static_cast<size_t>(t.index)];
	if (n.parent < 0) {
		write_ref(w, window_path(t.ctx), snap.unique_name);
	} else {
		const Shadow_Node &p = win.nodes[static_cast<size_t>(n.parent)];
		write_ref(w, node_path(t.ctx, p.id), snap.unique_name);
	}
}

// Object reference of a target.
void write_target_ref(dbus::Writer &w, const Snapshot &snap, const Target &t) {
	switch (t.kind) {
	case Target_Kind::Root:
		write_app_ref(w, snap.unique_name);
		return;
	case Target_Kind::Cache:
		write_ref(w, kCachePath, snap.unique_name);
		return;
	case Target_Kind::Window:
		write_ref(w, window_path(t.ctx), snap.unique_name);
		return;
	case Target_Kind::Node: {
		const Shadow_Node &n = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)];
		write_ref(w, node_path(t.ctx, n.id), snap.unique_name);
		return;
	}
	default:
		write_null_ref(w);
		return;
	}
}

// Children of a target, as targets (window children for Root, node
// children for Window/Node).
std::vector<Target> children_targets(const Snapshot &snap, const Target &t) {
	std::vector<Target> out;
	if (t.kind == Target_Kind::Root) {
		for (const auto &kv : snap.windows) {
			Target c;
			c.kind = Target_Kind::Window;
			c.ctx = kv.first;
			out.push_back(c);
		}
		return out;
	}
	if (t.kind != Target_Kind::Window && t.kind != Target_Kind::Node) {
		return out;
	}
	const Shadow_Window &win = snap.windows.at(t.ctx);
	int parent_index = (t.kind == Target_Kind::Window) ? -1 : t.index;
	for (int idx : children_of(win, parent_index)) {
		Target c;
		c.kind = Target_Kind::Node;
		c.ctx = t.ctx;
		c.index = idx;
		out.push_back(c);
	}
	return out;
}

int child_count(const Snapshot &snap, const Target &t) {
	if (t.kind == Target_Kind::Root) {
		return static_cast<int>(snap.windows.size());
	}
	return static_cast<int>(children_targets(snap, t).size());
}

// One cache item tuple: (obj, app, parent, index, childcount,
// interfaces, name, role, description, states). The parent field
// is the application object for every item except the application
// item itself, whose parent is null (GTK4 cache convention).
void write_cache_item(dbus::Writer &w, const Snapshot &snap, const Target &t) {
	w.begin_struct();
	write_target_ref(w, snap, t);
	write_app_ref(w, snap.unique_name);
	if (t.kind == Target_Kind::Root) {
		write_null_ref(w);
	} else {
		write_app_ref(w, snap.unique_name);
	}
	int index = -1, count = 0;
	std::vector<std::string> ifs;
	std::string name, description;
	uint32_t role = ATSPI_ROLE_INVALID;
	uint64_t states;
	if (t.kind == Target_Kind::Root) {
		index = -1;
		count = static_cast<int>(snap.windows.size());
		ifs = interfaces_for(t.kind, false);
		name = snap.app_name;
		role = ATSPI_ROLE_APPLICATION;
		states = atspi_chrome_state_bits();
	} else if (t.kind == Target_Kind::Window) {
		const Shadow_Window &win = snap.windows.at(t.ctx);
		index = window_index(snap.windows, t.ctx);
		count = static_cast<int>(children_of(win, -1).size());
		ifs = interfaces_for(t.kind, false);
		name = win.title;
		role = ATSPI_ROLE_WINDOW;
		states = atspi_chrome_state_bits();
	} else {
		const Shadow_Window &win = snap.windows.at(t.ctx);
		const Shadow_Node &n = win.nodes[static_cast<size_t>(t.index)];
		index = index_in_parent(win, t.index);
		count = static_cast<int>(children_of(win, t.index).size());
		ifs = interfaces_for(t.kind, n.has_value);
		name = n.name;
		description = n.description;
		role = n.role;
		states = atspi_state_bits_for(n);
	}
	w.i32(static_cast<int32_t>(index));
	w.i32(static_cast<int32_t>(count));
	write_string_array(w, ifs);
	w.str(name);
	w.u32(role);
	w.str(description);
	write_state_array(w, states);
	w.end_struct();
}

// --- Introspection ---

const char *kXmlDoctype =
    "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\" "
    "\"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">";

const char *kXmlIntro =
    "<interface name=\"org.freedesktop.DBus.Introspectable\">"
    "<method name=\"Introspect\"><arg type=\"s\" direction=\"out\"/></method>"
    "</interface>";

const char *kXmlProps =
    "<interface name=\"org.freedesktop.DBus.Properties\">"
    "<method name=\"Get\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/>"
    "<arg type=\"v\" direction=\"out\"/></method>"
    "<method name=\"Set\"><arg type=\"s\" direction=\"in\"/><arg type=\"s\" direction=\"in\"/>"
    "<arg type=\"v\" direction=\"in\"/></method>"
    "<method name=\"GetAll\"><arg type=\"s\" direction=\"in\"/>"
    "<arg type=\"a{sv}\" direction=\"out\"/></method>"
    "<signal name=\"PropertiesChanged\"><arg type=\"s\"/><arg type=\"a{sv}\"/><arg type=\"as\"/></signal>"
    "</interface>";

const char *kXmlPeer =
    "<interface name=\"org.freedesktop.DBus.Peer\">"
    "<method name=\"Ping\"/>"
    "<method name=\"GetMachineId\"><arg type=\"s\" direction=\"out\"/></method>"
    "</interface>";

const char *kXmlAccessible =
    "<interface name=\"org.a11y.atspi.Accessible\">"
    "<method name=\"GetChildAtIndex\"><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"(so)\" direction=\"out\"/></method>"
    "<method name=\"GetChildren\"><arg type=\"a(so)\" direction=\"out\"/></method>"
    "<method name=\"GetIndexInParent\"><arg type=\"i\" direction=\"out\"/></method>"
    "<method name=\"GetRelationSet\"><arg type=\"a(ua(so))\" direction=\"out\"/></method>"
    "<method name=\"GetRole\"><arg type=\"u\" direction=\"out\"/></method>"
    "<method name=\"GetRoleName\"><arg type=\"s\" direction=\"out\"/></method>"
    "<method name=\"GetLocalizedRoleName\"><arg type=\"s\" direction=\"out\"/></method>"
    "<method name=\"GetState\"><arg type=\"au\" direction=\"out\"/></method>"
    "<method name=\"GetAttributes\"><arg type=\"a{ss}\" direction=\"out\"/></method>"
    "<method name=\"GetInterfaces\"><arg type=\"as\" direction=\"out\"/></method>"
    "<method name=\"GetApplication\"><arg type=\"(so)\" direction=\"out\"/></method>"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<property name=\"Name\" type=\"s\" access=\"read\"/>"
    "<property name=\"Description\" type=\"s\" access=\"read\"/>"
    "<property name=\"Parent\" type=\"(so)\" access=\"read\"/>"
    "<property name=\"ChildCount\" type=\"i\" access=\"read\"/>"
    "<property name=\"Locale\" type=\"s\" access=\"read\"/>"
    "<property name=\"AccessibleId\" type=\"s\" access=\"read\"/>"
    "<property name=\"HelpText\" type=\"s\" access=\"read\"/>"
    "</interface>";

const char *kXmlComponent =
    "<interface name=\"org.a11y.atspi.Component\">"
    "<method name=\"Contains\"><arg type=\"i\" direction=\"in\"/><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"u\" direction=\"in\"/><arg type=\"b\" direction=\"out\"/></method>"
    "<method name=\"GetAccessibleAtPoint\"><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"i\" direction=\"in\"/><arg type=\"u\" direction=\"in\"/>"
    "<arg type=\"(so)\" direction=\"out\"/></method>"
    "<method name=\"GetExtents\"><arg type=\"u\" direction=\"in\"/>"
    "<arg type=\"(iiii)\" direction=\"out\"/></method>"
    "<method name=\"GetPosition\"><arg type=\"u\" direction=\"in\"/>"
    "<arg type=\"i\" direction=\"out\"/><arg type=\"i\" direction=\"out\"/></method>"
    "<method name=\"GetSize\"><arg type=\"i\" direction=\"out\"/>"
    "<arg type=\"i\" direction=\"out\"/></method>"
    "<method name=\"GetLayer\"><arg type=\"u\" direction=\"out\"/></method>"
    "<method name=\"GetMDIZOrder\"><arg type=\"n\" direction=\"out\"/></method>"
    "<method name=\"GrabFocus\"><arg type=\"b\" direction=\"out\"/></method>"
    "<method name=\"GetAlpha\"><arg type=\"d\" direction=\"out\"/></method>"
    "<method name=\"SetExtents\"><arg type=\"i\" direction=\"in\"/><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"i\" direction=\"in\"/><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"u\" direction=\"in\"/><arg type=\"b\" direction=\"out\"/></method>"
    "<method name=\"SetPosition\"><arg type=\"i\" direction=\"in\"/><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"u\" direction=\"in\"/><arg type=\"b\" direction=\"out\"/></method>"
    "<method name=\"SetSize\"><arg type=\"i\" direction=\"in\"/><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"b\" direction=\"out\"/></method>"
    "<method name=\"ScrollTo\"><arg type=\"u\" direction=\"in\"/>"
    "<arg type=\"b\" direction=\"out\"/></method>"
    "<method name=\"ScrollToPoint\"><arg type=\"u\" direction=\"in\"/>"
    "<arg type=\"i\" direction=\"in\"/><arg type=\"i\" direction=\"in\"/>"
    "<arg type=\"b\" direction=\"out\"/></method>"
    "</interface>";

const char *kXmlValue =
    "<interface name=\"org.a11y.atspi.Value\">"
    "<method name=\"GetMinimumValue\"><arg type=\"d\" direction=\"out\"/></method>"
    "<method name=\"GetMaximumValue\"><arg type=\"d\" direction=\"out\"/></method>"
    "<method name=\"GetCurrentValue\"><arg type=\"d\" direction=\"out\"/></method>"
    "<method name=\"SetCurrentValue\"><arg type=\"d\" direction=\"in\"/>"
    "<arg type=\"b\" direction=\"out\"/></method>"
    "<method name=\"GetMinimumIncrement\"><arg type=\"d\" direction=\"out\"/></method>"
    "</interface>";

const char *kXmlApplication =
    "<interface name=\"org.a11y.atspi.Application\">"
    "<method name=\"GetLocale\"><arg type=\"u\" direction=\"in\"/>"
    "<arg type=\"s\" direction=\"out\"/></method>"
    "<method name=\"GetApplicationBusAddress\"><arg type=\"s\" direction=\"out\"/></method>"
    "<property name=\"ToolkitName\" type=\"s\" access=\"read\"/>"
    "<property name=\"Version\" type=\"s\" access=\"read\"/>"
    "<property name=\"AtspiVersion\" type=\"s\" access=\"read\"/>"
    "<property name=\"Id\" type=\"i\" access=\"readwrite\"/>"
    "</interface>";

const char *kXmlSocket =
    "<interface name=\"org.a11y.atspi.Socket\">"
    "<method name=\"Embedded\"><arg type=\"s\" direction=\"in\"/></method>"
    "</interface>";

const char *kXmlCache =
    "<interface name=\"org.a11y.atspi.Cache\">"
    "<method name=\"GetItems\">"
    "<arg type=\"a((so)(so)(so)iiassusau)\" direction=\"out\"/></method>"
    "<property name=\"version\" type=\"u\" access=\"read\"/>"
    "<signal name=\"AddAccessible\"><arg type=\"((so)(so)(so)iiassusau)\"/></signal>"
    "<signal name=\"RemoveAccessible\"><arg type=\"(so)\"/></signal>"
    "<signal name=\"Ready\"/>"
    "</interface>";

std::string introspect_xml(const Snapshot &snap, const Target &t) {
	std::string xml = kXmlDoctype;
	xml += "<node>";
	switch (t.kind) {
	case Target_Kind::Root:
		xml += kXmlAccessible;
		xml += kXmlApplication;
		xml += kXmlSocket;
		break;
	case Target_Kind::Window:
		xml += kXmlAccessible;
		xml += kXmlComponent;
		break;
	case Target_Kind::Node: {
		xml += kXmlAccessible;
		xml += kXmlComponent;
		const Shadow_Node &n = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)];
		if (n.has_value) {
			xml += kXmlValue;
		}
		break;
	}
	case Target_Kind::Cache:
		xml += kXmlCache;
		break;
	default:
		break;
	}
	xml += kXmlIntro;
	xml += kXmlProps;
	xml += kXmlPeer;
	xml += "</node>";
	return xml;
}

// --- Properties ---

std::string accessible_name(const Snapshot &snap, const Target &t) {
	if (t.kind == Target_Kind::Root) {
		return snap.app_name;
	}
	if (t.kind == Target_Kind::Window) {
		return snap.windows.at(t.ctx).title;
	}
	return snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)].name;
}

std::string accessible_id(const Snapshot &snap, const Target &t) {
	if (t.kind == Target_Kind::Root) {
		return "root";
	}
	if (t.kind == Target_Kind::Window) {
		char buf[64];
		std::snprintf(buf, sizeof(buf), "window:%d", t.ctx);
		return buf;
	}
	const Shadow_Node &n = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)];
	char buf[32];
	std::snprintf(buf, sizeof(buf), "%llx", static_cast<unsigned long long>(n.id));
	return buf;
}

// Append one property's value as a variant. False when the
// (interface, name) pair is not a property of this target.
bool append_property(dbus::Writer &w, const Snapshot &snap, const Target &t,
                     const std::string &iface, const std::string &name) {
	if (iface == kIfAccessible) {
		if (name == "version") {
			w.begin_variant("u");
			w.u32(2);
			w.end_variant();
			return true;
		}
		if (name == "Name") {
			w.begin_variant("s");
			w.str(accessible_name(snap, t));
			w.end_variant();
			return true;
		}
		if (name == "Description") {
			w.begin_variant("s");
			w.str(t.kind == Target_Kind::Node
			          ? snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)].description
			          : std::string());
			w.end_variant();
			return true;
		}
		if (name == "Parent") {
			w.begin_variant("(so)");
			write_parent_ref(w, snap, t);
			w.end_variant();
			return true;
		}
		if (name == "ChildCount") {
			w.begin_variant("i");
			w.i32(static_cast<int32_t>(child_count(snap, t)));
			w.end_variant();
			return true;
		}
		if (name == "Locale") {
			w.begin_variant("s");
			w.str(snap.locale);
			w.end_variant();
			return true;
		}
		if (name == "AccessibleId") {
			w.begin_variant("s");
			w.str(accessible_id(snap, t));
			w.end_variant();
			return true;
		}
		if (name == "HelpText") {
			w.begin_variant("s");
			w.str("");
			w.end_variant();
			return true;
		}
		return false;
	}
	if (iface == kIfApplication && t.kind == Target_Kind::Root) {
		if (name == "ToolkitName") {
			w.begin_variant("s");
			w.str("NielloUI");
			w.end_variant();
			return true;
		}
		if (name == "Version") {
			w.begin_variant("s");
			w.str("1.0");
			w.end_variant();
			return true;
		}
		if (name == "AtspiVersion") {
			w.begin_variant("s");
			w.str("2.0");
			w.end_variant();
			return true;
		}
		if (name == "Id") {
			w.begin_variant("i");
			w.i32(snap.app_id);
			w.end_variant();
			return true;
		}
		return false;
	}
	if (iface == kIfCache && t.kind == Target_Kind::Cache && name == "version") {
		w.begin_variant("u");
		w.u32(2);
		w.end_variant();
		return true;
	}
	return false;
}

std::vector<std::string> property_names(const std::string &iface, Target_Kind kind) {
	if (iface == kIfAccessible &&
	    (kind == Target_Kind::Root || kind == Target_Kind::Window || kind == Target_Kind::Node)) {
		return {"version", "Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId",
		        "HelpText"};
	}
	if (iface == kIfApplication && kind == Target_Kind::Root) {
		return {"ToolkitName", "Version", "AtspiVersion", "Id"};
	}
	if (iface == kIfCache && kind == Target_Kind::Cache) {
		return {"version"};
	}
	return {};
}

// --- Method call handling ---

dbus::Reader body_reader(const dbus::Message &msg) {
	return dbus::Reader(msg.body.data(), msg.body.data() + msg.body.size());
}

bool send_reply(const dbus::Message &call, const std::string &sig, const dbus::Writer &w) {
	return g_exp.bus.send_return(call, sig, w.buf);
}

bool send_empty(const dbus::Message &call) {
	dbus::Writer w;
	return g_exp.bus.send_return(call, "", w.buf);
}

bool send_fail(const dbus::Message &call, const char *err, const std::string &text) {
	return g_exp.bus.send_error(call, err, text);
}

bool send_invalid_args(const dbus::Message &call) {
	return send_fail(call, kErrInvalidArgs, "Invalid arguments");
}

bool send_unknown_method(const dbus::Message &call) {
	return send_fail(call, kErrUnknownMethod, "Unknown method");
}

void handle_accessible(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	dbus::Reader r = body_reader(msg);
	dbus::Writer w;
	if (msg.member == "GetChildAtIndex") {
		int32_t index = 0;
		if (!r.i32(index)) {
			send_invalid_args(msg);
			return;
		}
		std::vector<Target> kids = children_targets(snap, t);
		if (index < 0 || index >= static_cast<int32_t>(kids.size())) {
			send_fail(msg, kErrInvalidArgs, "Child index out of range");
			return;
		}
		write_target_ref(w, snap, kids[static_cast<size_t>(index)]);
		send_reply(msg, "(so)", w);
		return;
	}
	if (msg.member == "GetChildren") {
		w.begin_array(8);
		for (const Target &c : children_targets(snap, t)) {
			write_target_ref(w, snap, c);
		}
		w.end_array();
		send_reply(msg, "a(so)", w);
		return;
	}
	if (msg.member == "GetIndexInParent") {
		int32_t index = -1;
		if (t.kind == Target_Kind::Window) {
			index = static_cast<int32_t>(window_index(snap.windows, t.ctx));
		} else if (t.kind == Target_Kind::Node) {
			index = static_cast<int32_t>(
			    index_in_parent(snap.windows.at(t.ctx), t.index));
		}
		w.i32(index);
		send_reply(msg, "i", w);
		return;
	}
	if (msg.member == "GetRelationSet") {
		w.begin_array(8);
		w.end_array();
		send_reply(msg, "a(ua(so))", w);
		return;
	}
	if (msg.member == "GetRole") {
		uint32_t role = ATSPI_ROLE_INVALID;
		if (t.kind == Target_Kind::Root) {
			role = ATSPI_ROLE_APPLICATION;
		} else if (t.kind == Target_Kind::Window) {
			role = ATSPI_ROLE_WINDOW;
		} else {
			role = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)].role;
		}
		w.u32(role);
		send_reply(msg, "u", w);
		return;
	}
	if (msg.member == "GetRoleName" || msg.member == "GetLocalizedRoleName") {
		uint32_t role = ATSPI_ROLE_INVALID;
		if (t.kind == Target_Kind::Root) {
			role = ATSPI_ROLE_APPLICATION;
		} else if (t.kind == Target_Kind::Window) {
			role = ATSPI_ROLE_WINDOW;
		} else {
			role = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)].role;
		}
		w.str(atspi_role_name(role));
		send_reply(msg, "s", w);
		return;
	}
	if (msg.member == "GetState") {
		uint64_t bits;
		if (t.kind == Target_Kind::Node) {
			bits = atspi_state_bits_for(
			    snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)]);
		} else {
			bits = atspi_chrome_state_bits();
		}
		write_state_array(w, bits);
		send_reply(msg, "au", w);
		return;
	}
	if (msg.member == "GetAttributes") {
		w.begin_array(8);
		w.end_array();
		send_reply(msg, "a{ss}", w);
		return;
	}
	if (msg.member == "GetInterfaces") {
		bool has_value = false;
		if (t.kind == Target_Kind::Node) {
			has_value = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)].has_value;
		}
		write_string_array(w, interfaces_for(t.kind, has_value));
		send_reply(msg, "as", w);
		return;
	}
	if (msg.member == "GetApplication") {
		write_app_ref(w, snap.unique_name);
		send_reply(msg, "(so)", w);
		return;
	}
	send_unknown_method(msg);
}

// Geometry in window-relative DIP, then expressed in the requested
// coordinate space (0 screen, 1 window, 2 parent).
struct FRect {
	float x, y, w, h;
};

FRect target_rect(const Snapshot &snap, const Target &t) {
	if (t.kind == Target_Kind::Window) {
		const Shadow_Window &win = snap.windows.at(t.ctx);
		return {0, 0, static_cast<float>(win.win_w), static_cast<float>(win.win_h)};
	}
	const Shadow_Node &n = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)];
	return {n.x, n.y, n.w, n.h};
}

FRect parent_rect(const Snapshot &snap, const Target &t) {
	if (t.kind != Target_Kind::Node) {
		return {0, 0, 0, 0};
	}
	const Shadow_Window &win = snap.windows.at(t.ctx);
	const Shadow_Node &n = win.nodes[static_cast<size_t>(t.index)];
	if (n.parent < 0) {
		return {0, 0, static_cast<float>(win.win_w), static_cast<float>(win.win_h)};
	}
	const Shadow_Node &p = win.nodes[static_cast<size_t>(n.parent)];
	return {p.x, p.y, p.w, p.h};
}

bool point_to_window(const Snapshot &snap, const Target &t, uint32_t coord, int32_t px, int32_t py,
                     float &wx, float &wy) {
	const Shadow_Window &win = snap.windows.at(t.ctx);
	if (coord == 0) { // screen
		wx = static_cast<float>(px) - static_cast<float>(win.win_x);
		wy = static_cast<float>(py) - static_cast<float>(win.win_y);
		return true;
	}
	if (coord == 1) { // window
		wx = static_cast<float>(px);
		wy = static_cast<float>(py);
		return true;
	}
	if (coord == 2) { // parent
		FRect pr = parent_rect(snap, t);
		wx = static_cast<float>(px) + pr.x;
		wy = static_cast<float>(py) + pr.y;
		return true;
	}
	return false;
}

FRect rect_in_coords(const Snapshot &snap, const Target &t, uint32_t coord, bool &ok) {
	FRect r = target_rect(snap, t);
	ok = true;
	if (coord == 0) {
		const Shadow_Window &win = snap.windows.at(t.ctx);
		r.x += static_cast<float>(win.win_x);
		r.y += static_cast<float>(win.win_y);
	} else if (coord == 1) {
		// as-is
	} else if (coord == 2) {
		FRect pr = parent_rect(snap, t);
		r.x -= pr.x;
		r.y -= pr.y;
	} else {
		ok = false;
	}
	return r;
}

bool rect_contains(const FRect &r, float wx, float wy) {
	return wx >= r.x && wx < r.x + r.w && wy >= r.y && wy < r.y + r.h;
}

// Deepest descendant of parent_index containing the point, or -1.
// Children are visited last-declared-first (topmost first).
int deepest_at(const Shadow_Window &win, int parent_index, float wx, float wy) {
	std::vector<int> kids = children_of(win, parent_index);
	for (auto it = kids.rbegin(); it != kids.rend(); ++it) {
		const Shadow_Node &n = win.nodes[static_cast<size_t>(*it)];
		if (!rect_contains({n.x, n.y, n.w, n.h}, wx, wy)) {
			continue;
		}
		int deeper = deepest_at(win, *it, wx, wy);
		return deeper >= 0 ? deeper : *it;
	}
	return -1;
}

void handle_component(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	dbus::Reader r = body_reader(msg);
	dbus::Writer w;
	if (msg.member == "Contains") {
		int32_t px = 0, py = 0;
		uint32_t coord = 0;
		if (!r.i32(px) || !r.i32(py) || !r.u32(coord)) {
			send_invalid_args(msg);
			return;
		}
		float wx = 0, wy = 0;
		if (!point_to_window(snap, t, coord, px, py, wx, wy)) {
			send_invalid_args(msg);
			return;
		}
		w.boolean(rect_contains(target_rect(snap, t), wx, wy));
		send_reply(msg, "b", w);
		return;
	}
	if (msg.member == "GetAccessibleAtPoint") {
		int32_t px = 0, py = 0;
		uint32_t coord = 0;
		if (!r.i32(px) || !r.i32(py) || !r.u32(coord)) {
			send_invalid_args(msg);
			return;
		}
		float wx = 0, wy = 0;
		if (!point_to_window(snap, t, coord, px, py, wx, wy)) {
			send_invalid_args(msg);
			return;
		}
		const Shadow_Window &win = snap.windows.at(t.ctx);
		int parent_index = (t.kind == Target_Kind::Window) ? -1 : t.index;
		int hit = deepest_at(win, parent_index, wx, wy);
		if (hit >= 0) {
			Target c;
			c.kind = Target_Kind::Node;
			c.ctx = t.ctx;
			c.index = hit;
			write_target_ref(w, snap, c);
		} else if (rect_contains(target_rect(snap, t), wx, wy)) {
			write_target_ref(w, snap, t);
		} else {
			write_null_ref(w);
		}
		send_reply(msg, "(so)", w);
		return;
	}
	if (msg.member == "GetExtents") {
		uint32_t coord = 0;
		if (!r.u32(coord)) {
			send_invalid_args(msg);
			return;
		}
		bool ok = false;
		FRect rc = rect_in_coords(snap, t, coord, ok);
		if (!ok) {
			send_invalid_args(msg);
			return;
		}
		w.begin_struct();
		w.i32(static_cast<int32_t>(std::lround(rc.x)));
		w.i32(static_cast<int32_t>(std::lround(rc.y)));
		w.i32(static_cast<int32_t>(std::lround(rc.w)));
		w.i32(static_cast<int32_t>(std::lround(rc.h)));
		w.end_struct();
		send_reply(msg, "(iiii)", w);
		return;
	}
	if (msg.member == "GetPosition") {
		uint32_t coord = 0;
		if (!r.u32(coord)) {
			send_invalid_args(msg);
			return;
		}
		bool ok = false;
		FRect rc = rect_in_coords(snap, t, coord, ok);
		if (!ok) {
			send_invalid_args(msg);
			return;
		}
		w.i32(static_cast<int32_t>(std::lround(rc.x)));
		w.i32(static_cast<int32_t>(std::lround(rc.y)));
		send_reply(msg, "ii", w);
		return;
	}
	if (msg.member == "GetSize") {
		FRect rc = target_rect(snap, t);
		w.i32(static_cast<int32_t>(std::lround(rc.w)));
		w.i32(static_cast<int32_t>(std::lround(rc.h)));
		send_reply(msg, "ii", w);
		return;
	}
	if (msg.member == "GetLayer") {
		w.u32(3); // WIDGET
		send_reply(msg, "u", w);
		return;
	}
	if (msg.member == "GetMDIZOrder") {
		w.i16(-1);
		send_reply(msg, "n", w);
		return;
	}
	if (msg.member == "GrabFocus") {
		w.boolean(false); // read-only v1: activation rides the keyboard path
		send_reply(msg, "b", w);
		return;
	}
	if (msg.member == "GetAlpha") {
		w.f64(1.0);
		send_reply(msg, "d", w);
		return;
	}
	if (msg.member == "SetExtents") {
		int32_t x = 0, y = 0, ww = 0, hh = 0;
		uint32_t coord = 0;
		if (!r.i32(x) || !r.i32(y) || !r.i32(ww) || !r.i32(hh) || !r.u32(coord)) {
			send_invalid_args(msg);
			return;
		}
		w.boolean(false);
		send_reply(msg, "b", w);
		return;
	}
	if (msg.member == "SetPosition") {
		int32_t x = 0, y = 0;
		uint32_t coord = 0;
		if (!r.i32(x) || !r.i32(y) || !r.u32(coord)) {
			send_invalid_args(msg);
			return;
		}
		w.boolean(false);
		send_reply(msg, "b", w);
		return;
	}
	if (msg.member == "SetSize") {
		int32_t ww = 0, hh = 0;
		if (!r.i32(ww) || !r.i32(hh)) {
			send_invalid_args(msg);
			return;
		}
		w.boolean(false);
		send_reply(msg, "b", w);
		return;
	}
	if (msg.member == "ScrollTo") {
		uint32_t kind = 0;
		if (!r.u32(kind)) {
			send_invalid_args(msg);
			return;
		}
		w.boolean(false);
		send_reply(msg, "b", w);
		return;
	}
	if (msg.member == "ScrollToPoint") {
		uint32_t coord = 0;
		int32_t x = 0, y = 0;
		if (!r.u32(coord) || !r.i32(x) || !r.i32(y)) {
			send_invalid_args(msg);
			return;
		}
		w.boolean(false);
		send_reply(msg, "b", w);
		return;
	}
	send_unknown_method(msg);
}

void handle_value(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	const Shadow_Node &n = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)];
	dbus::Reader r = body_reader(msg);
	dbus::Writer w;
	if (msg.member == "GetCurrentValue") {
		w.f64(static_cast<double>(n.value_num));
		send_reply(msg, "d", w);
		return;
	}
	if (msg.member == "GetMinimumValue") {
		w.f64(static_cast<double>(n.value_min));
		send_reply(msg, "d", w);
		return;
	}
	if (msg.member == "GetMaximumValue") {
		w.f64(static_cast<double>(n.value_max));
		send_reply(msg, "d", w);
		return;
	}
	if (msg.member == "SetCurrentValue") {
		double v = 0;
		if (!r.f64(v)) {
			send_invalid_args(msg);
			return;
		}
		w.boolean(false); // read-only v1
		send_reply(msg, "b", w);
		return;
	}
	if (msg.member == "GetMinimumIncrement") {
		w.f64(0);
		send_reply(msg, "d", w);
		return;
	}
	send_unknown_method(msg);
}

void handle_application(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	(void)t;
	dbus::Reader r = body_reader(msg);
	dbus::Writer w;
	if (msg.member == "GetLocale") {
		uint32_t lcid = 0;
		if (!r.u32(lcid)) {
			send_invalid_args(msg);
			return;
		}
		w.str(snap.locale);
		send_reply(msg, "s", w);
		return;
	}
	if (msg.member == "GetApplicationBusAddress") {
		w.str(snap.bus_address);
		send_reply(msg, "s", w);
		return;
	}
	send_unknown_method(msg);
}

void handle_socket(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	(void)snap;
	(void)t;
	dbus::Reader r = body_reader(msg);
	if (msg.member == "Embedded") {
		std::string path;
		if (!r.str(path)) {
			send_invalid_args(msg);
			return;
		}
		// Confirmation from the registry that our plug was embedded.
		// Nothing to record: the Embed reply already gave us the
		// registry root. Return void.
		send_empty(msg);
		return;
	}
	send_unknown_method(msg);
}

void handle_cache(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	(void)t;
	dbus::Writer w;
	if (msg.member == "GetItems") {
		w.begin_array(8);
		Target root;
		root.kind = Target_Kind::Root;
		write_cache_item(w, snap, root);
		for (const auto &kv : snap.windows) {
			Target win_t;
			win_t.kind = Target_Kind::Window;
			win_t.ctx = kv.first;
			write_cache_item(w, snap, win_t);
			for (int i = 0; i < static_cast<int>(kv.second.nodes.size()); i++) {
				Target node_t;
				node_t.kind = Target_Kind::Node;
				node_t.ctx = kv.first;
				node_t.index = i;
				write_cache_item(w, snap, node_t);
			}
		}
		w.end_array();
		send_reply(msg, "a((so)(so)(so)iiassusau)", w);
		return;
	}
	send_unknown_method(msg);
}

void handle_properties(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	dbus::Reader r = body_reader(msg);
	dbus::Writer w;
	if (msg.member == "Get") {
		std::string iface, name;
		if (!r.str(iface) || !r.str(name)) {
			send_invalid_args(msg);
			return;
		}
		if (!append_property(w, snap, t, iface, name)) {
			send_fail(msg, kErrInvalidArgs, "Unknown interface or property");
			return;
		}
		send_reply(msg, "v", w);
		return;
	}
	if (msg.member == "GetAll") {
		std::string iface;
		if (!r.str(iface)) {
			send_invalid_args(msg);
			return;
		}
		std::vector<std::string> names = property_names(iface, t.kind);
		if (names.empty()) {
			send_fail(msg, kErrInvalidArgs, "Unknown interface");
			return;
		}
		w.begin_array(8);
		for (const std::string &name : names) {
			w.begin_dict_entry();
			w.str(name);
			append_property(w, snap, t, iface, name);
			w.end_dict_entry();
		}
		w.end_array();
		send_reply(msg, "a{sv}", w);
		return;
	}
	if (msg.member == "Set") {
		std::string iface, name;
		if (!r.str(iface) || !r.str(name)) {
			send_invalid_args(msg);
			return;
		}
		// The only writable property: Application:Id, set by the
		// registry after Embed. Every other Set is read-only.
		if (iface == kIfApplication && t.kind == Target_Kind::Root && name == "Id") {
			std::string vsig;
			if (!r.signature(vsig) || vsig != "i") {
				send_invalid_args(msg);
				return;
			}
			int32_t id = 0;
			if (!r.i32(id)) {
				send_invalid_args(msg);
				return;
			}
			{
				std::lock_guard<std::mutex> lock(g_exp.mu);
				g_exp.app_id = id;
			}
			send_empty(msg);
			return;
		}
		// The property must exist to be read-only rather than unknown.
		dbus::Writer probe;
		if (append_property(probe, snap, t, iface, name)) {
			send_fail(msg, kErrPropertyReadOnly, "Property is read-only");
		} else {
			send_fail(msg, kErrInvalidArgs, "Unknown interface or property");
		}
		return;
	}
	send_unknown_method(msg);
}

void handle_peer(const dbus::Message &msg, const Snapshot &snap, const Target &t) {
	(void)t;
	dbus::Writer w;
	if (msg.member == "Ping") {
		send_empty(msg);
		return;
	}
	if (msg.member == "GetMachineId") {
		w.str(snap.machine_id);
		send_reply(msg, "s", w);
		return;
	}
	send_unknown_method(msg);
}

void handle_message(const dbus::Message &msg) {
	if (msg.type != dbus::MSG_CALL) {
		return; // inbound signals: none needed in v1
	}
	Snapshot snap = take_snapshot();
	Target t = resolve_target(snap, msg.path);
	if (msg.interface == kIfIntrospectable && msg.member == "Introspect") {
		if (t.kind == Target_Kind::Unknown) {
			send_unknown_method(msg);
			return;
		}
		dbus::Writer w;
		w.str(introspect_xml(snap, t));
		send_reply(msg, "s", w);
		return;
	}
	if (msg.interface == kIfProperties) {
		if (t.kind == Target_Kind::Unknown) {
			send_unknown_method(msg);
			return;
		}
		handle_properties(msg, snap, t);
		return;
	}
	if (msg.interface == kIfPeer) {
		if (t.kind == Target_Kind::Unknown) {
			send_unknown_method(msg);
			return;
		}
		handle_peer(msg, snap, t);
		return;
	}
	if (msg.interface == kIfAccessible) {
		if (t.kind != Target_Kind::Root && t.kind != Target_Kind::Window &&
		    t.kind != Target_Kind::Node) {
			send_unknown_method(msg);
			return;
		}
		handle_accessible(msg, snap, t);
		return;
	}
	if (msg.interface == kIfComponent) {
		if (t.kind != Target_Kind::Window && t.kind != Target_Kind::Node) {
			send_unknown_method(msg);
			return;
		}
		handle_component(msg, snap, t);
		return;
	}
	if (msg.interface == kIfValue) {
		if (t.kind != Target_Kind::Node) {
			send_unknown_method(msg);
			return;
		}
		const Shadow_Node &n = snap.windows.at(t.ctx).nodes[static_cast<size_t>(t.index)];
		if (!n.has_value) {
			send_unknown_method(msg);
			return;
		}
		handle_value(msg, snap, t);
		return;
	}
	if (msg.interface == kIfApplication) {
		if (t.kind != Target_Kind::Root) {
			send_unknown_method(msg);
			return;
		}
		handle_application(msg, snap, t);
		return;
	}
	if (msg.interface == kIfSocket) {
		if (t.kind != Target_Kind::Root) {
			send_unknown_method(msg);
			return;
		}
		handle_socket(msg, snap, t);
		return;
	}
	if (msg.interface == kIfCache) {
		if (t.kind != Target_Kind::Cache) {
			send_unknown_method(msg);
			return;
		}
		handle_cache(msg, snap, t);
		return;
	}
	send_unknown_method(msg);
}

} // namespace

namespace {

// --- Change signals ---

struct Pending_Signal {
	std::string path, interface, member, sig;
	std::vector<uint8_t> body;
};

// The shared (s i i v a{sv}) event body: detail string, two integer
// details, a variant payload, and an empty properties dict.
std::vector<uint8_t> event_body(const std::string &detail, int32_t d1, int32_t d2,
                                const std::string &vsig,
                                const std::function<void(dbus::Writer &)> &write_value) {
	dbus::Writer w;
	w.str(detail);
	w.i32(d1);
	w.i32(d2);
	w.begin_variant(vsig);
	if (write_value) {
		write_value(w);
	}
	w.end_variant();
	w.begin_array(8);
	w.end_array();
	return w.buf;
}

Pending_Signal property_change_signal(const std::string &path, const std::string &prop,
                                      const std::string &vsig,
                                      const std::function<void(dbus::Writer &)> &write_value) {
	return {path, "org.a11y.atspi.Event.Object", "PropertyChange", "siiva{sv}",
	        event_body(prop, 0, 0, vsig, write_value)};
}

Pending_Signal state_changed_signal(const std::string &path, uint32_t state, bool enabled) {
	return {path, "org.a11y.atspi.Event.Object", "StateChanged", "siiva{sv}",
	        event_body(atspi_state_name(state), enabled ? 1 : 0, 0, "b",
	                   [enabled](dbus::Writer &w) { w.boolean(enabled); })};
}

Pending_Signal children_changed_signal(const std::string &parent_path, const std::string &op,
                                       int32_t index, const std::string &child_path,
                                       const std::string &sender) {
	return {parent_path, "org.a11y.atspi.Event.Object", "ChildrenChanged", "siiva{sv}",
	        event_body(op, index, 0, "(so)",
	                   [&](dbus::Writer &w) { write_ref(w, child_path, sender); })};
}

Pending_Signal focus_signal(const std::string &path) {
	return {path, "org.a11y.atspi.Event.Focus", "Focus", "siiva{sv}",
	        event_body("", 0, 0, "s", [](dbus::Writer &w) { w.str(""); })};
}

Pending_Signal cache_add_signal(const Snapshot &snap, const Target &t) {
	dbus::Writer w;
	write_cache_item(w, snap, t);
	return {kCachePath, kIfCache, "AddAccessible", "((so)(so)(so)iiassusau)", w.buf};
}

Pending_Signal cache_remove_signal(const std::string &path, const std::string &sender) {
	dbus::Writer w;
	write_ref(w, path, sender);
	return {kCachePath, kIfCache, "RemoveAccessible", "(so)", w.buf};
}

Pending_Signal ready_signal() {
	dbus::Writer w;
	return {kCachePath, kIfCache, "Ready", "", w.buf};
}

std::string borrowed_or_empty(const char *s) { return s ? s : ""; }

// Path of a node's parent: the window path for roots, else the
// parent node's path.
std::string parent_path_for(const Shadow_Window &win, int ctx, int node_index) {
	const Shadow_Node &n = win.nodes[static_cast<size_t>(node_index)];
	if (n.parent < 0) {
		return window_path(ctx);
	}
	return node_path(ctx, win.nodes[static_cast<size_t>(n.parent)].id);
}

// Parent identity for structural comparison: 0 = the window node
// (instance 0 never enters the mirror — it means "no instance").
uint64_t parent_id_of(const Shadow_Window &win, const Shadow_Node &n) {
	if (n.parent < 0) {
		return 0;
	}
	return win.nodes[static_cast<size_t>(n.parent)].id;
}

// --- Sync: diff ABI rows against the shadow, emit signals ---

void exporter_sync(int32_t ctx_id, const UiA11yNode *nodes, int32_t count,
                   const char *window_title, int32_t win_x, int32_t win_y, int32_t win_w,
                   int32_t win_h) {
	Shadow_Window nw;
	nw.title = borrowed_or_empty(window_title);
	nw.win_x = win_x;
	nw.win_y = win_y;
	nw.win_w = win_w;
	nw.win_h = win_h;
	if (count > 0) {
		nw.nodes.reserve(static_cast<size_t>(count));
	}
	for (int32_t i = 0; i < count; i++) {
		const UiA11yNode &src = nodes[static_cast<size_t>(i)];
		Shadow_Node n;
		n.id = src.id;
		n.parent = src.parent;
		n.odin_role = src.role;
		n.role = src.role < 43 ? kRoleMap[src.role] : ATSPI_ROLE_INVALID;
		n.name = borrowed_or_empty(src.name);
		n.description = borrowed_or_empty(src.description);
		n.flags = src.flags;
		n.state = src.state;
		n.x = src.x;
		n.y = src.y;
		n.w = src.w;
		n.h = src.h;
		n.has_value = src.has_value != 0;
		n.value_num = src.value_num;
		n.value_min = src.value_min;
		n.value_max = src.value_max;
		n.value_text = borrowed_or_empty(src.value_text);
		nw.nodes.push_back(std::move(n));
	}

	std::vector<Pending_Signal> out;
	{
		std::lock_guard<std::mutex> lock(g_exp.mu);
		if (!g_exp.running) {
			return;
		}
		auto it = g_exp.windows.find(ctx_id);
		bool is_new_window = (it == g_exp.windows.end());
		Shadow_Window old = is_new_window ? Shadow_Window{} : it->second;

		// Removals, from the OLD tree (old parents and indices).
		for (int i = 0; i < static_cast<int>(old.nodes.size()); i++) {
			const Shadow_Node &on = old.nodes[static_cast<size_t>(i)];
			if (find_node(nw, on.id) >= 0) {
				continue;
			}
			out.push_back(cache_remove_signal(node_path(ctx_id, on.id), g_exp.unique_name));
			out.push_back(children_changed_signal(parent_path_for(old, ctx_id, i), "remove",
			                                      index_in_parent(old, i),
			                                      node_path(ctx_id, on.id), g_exp.unique_name));
		}

		// Install the new tree, then snapshot the exporter state for
		// building add signals against the new tree.
		g_exp.windows[ctx_id] = nw;
		Snapshot snap;
		snap.app_name = g_exp.app_name;
		snap.unique_name = g_exp.unique_name;
		snap.bus_address = g_exp.bus_address;
		snap.registry_sender = g_exp.registry_sender;
		snap.registry_path = g_exp.registry_path;
		snap.app_id = g_exp.app_id;
		snap.locale = g_exp.locale;
		snap.machine_id = g_exp.machine_id;
		snap.windows = g_exp.windows;

		if (is_new_window) {
			Target win_t;
			win_t.kind = Target_Kind::Window;
			win_t.ctx = ctx_id;
			out.push_back(cache_add_signal(snap, win_t));
			out.push_back(children_changed_signal(
			    kRootPath, "add", window_index(snap.windows, ctx_id), window_path(ctx_id),
			    g_exp.unique_name));
		} else if (old.title != nw.title) {
			out.push_back(property_change_signal(
			    window_path(ctx_id), "accessible-name", "s",
			    [&](dbus::Writer &w) { w.str(nw.title); }));
		}

		// Additions, from the NEW tree.
		for (int i = 0; i < static_cast<int>(nw.nodes.size()); i++) {
			const Shadow_Node &nn = nw.nodes[static_cast<size_t>(i)];
			if (find_node(old, nn.id) >= 0) {
				continue;
			}
			Target node_t;
			node_t.kind = Target_Kind::Node;
			node_t.ctx = ctx_id;
			node_t.index = i;
			out.push_back(cache_add_signal(snap, node_t));
			out.push_back(children_changed_signal(parent_path_for(nw, ctx_id, i), "add",
			                                      index_in_parent(nw, i),
			                                      node_path(ctx_id, nn.id), g_exp.unique_name));
		}

		// Changes to nodes present in both trees.
		for (int i = 0; i < static_cast<int>(nw.nodes.size()); i++) {
			const Shadow_Node &nn = nw.nodes[static_cast<size_t>(i)];
			int j = find_node(old, nn.id);
			if (j < 0) {
				continue;
			}
			const Shadow_Node &on = old.nodes[static_cast<size_t>(j)];
			// Structural: role, value-interface presence, or parent
			// identity changed. Re-announce as remove + add; the
			// add carries the new name, state, and value.
			if (on.role != nn.role || on.odin_role != nn.odin_role ||
			    on.has_value != nn.has_value || parent_id_of(old, on) != parent_id_of(nw, nn)) {
				out.push_back(cache_remove_signal(node_path(ctx_id, nn.id), g_exp.unique_name));
				out.push_back(children_changed_signal(parent_path_for(old, ctx_id, j), "remove",
				                                      index_in_parent(old, j),
				                                      node_path(ctx_id, nn.id),
				                                      g_exp.unique_name));
				Target node_t;
				node_t.kind = Target_Kind::Node;
				node_t.ctx = ctx_id;
				node_t.index = i;
				out.push_back(cache_add_signal(snap, node_t));
				out.push_back(children_changed_signal(parent_path_for(nw, ctx_id, i), "add",
				                                      index_in_parent(nw, i),
				                                      node_path(ctx_id, nn.id),
				                                      g_exp.unique_name));
				continue;
			}
			std::string path = node_path(ctx_id, nn.id);
			if (on.name != nn.name) {
				out.push_back(property_change_signal(
				    path, "accessible-name", "s", [&](dbus::Writer &w) { w.str(nn.name); }));
			}
			if (on.description != nn.description) {
				out.push_back(property_change_signal(
				    path, "accessible-description", "s",
				    [&](dbus::Writer &w) { w.str(nn.description); }));
			}
			if (nn.has_value && (on.value_num != nn.value_num || on.value_min != nn.value_min ||
			                     on.value_max != nn.value_max)) {
				out.push_back(property_change_signal(
				    path, "accessible-value", "d",
				    [&](dbus::Writer &w) { w.f64(static_cast<double>(nn.value_num)); }));
			}
			// Rect-only changes are silent: no signal (the shadow
			// already holds the new rect for queries).
			uint64_t old_bits = atspi_state_bits_for(on);
			uint64_t new_bits = atspi_state_bits_for(nn);
			uint64_t changed = old_bits ^ new_bits;
			for (uint32_t s : kEmittedStates) {
				if ((changed & (1ULL << s)) == 0) {
					continue;
				}
				bool enabled = (new_bits & (1ULL << s)) != 0;
				out.push_back(state_changed_signal(path, s, enabled));
				if (s == ATSPI_STATE_FOCUSED && enabled) {
					out.push_back(focus_signal(path));
				}
			}
		}

		if (!g_exp.ready_sent) {
			out.push_back(ready_signal());
			g_exp.ready_sent = true;
		}
	}

	for (const Pending_Signal &sig : out) {
		g_exp.bus.send_signal(sig.path, sig.interface, sig.member, sig.sig, sig.body);
	}
}

void exporter_remove_window(int32_t ctx_id) {
	std::vector<Pending_Signal> out;
	{
		std::lock_guard<std::mutex> lock(g_exp.mu);
		if (!g_exp.running) {
			return;
		}
		auto it = g_exp.windows.find(ctx_id);
		if (it == g_exp.windows.end()) {
			return;
		}
		Shadow_Window old = it->second;
		int widx = window_index(g_exp.windows, ctx_id);
		for (int i = static_cast<int>(old.nodes.size()) - 1; i >= 0; --i) {
			out.push_back(
			    cache_remove_signal(node_path(ctx_id, old.nodes[static_cast<size_t>(i)].id),
			                        g_exp.unique_name));
		}
		out.push_back(cache_remove_signal(window_path(ctx_id), g_exp.unique_name));
		out.push_back(children_changed_signal(kRootPath, "remove", widx, window_path(ctx_id),
		                                      g_exp.unique_name));
		g_exp.windows.erase(it);
	}
	for (const Pending_Signal &sig : out) {
		g_exp.bus.send_signal(sig.path, sig.interface, sig.member, sig.sig, sig.body);
	}
}

} // namespace

namespace {

std::string read_machine_id() {
	FILE *f = std::fopen("/etc/machine-id", "r");
	if (f == nullptr) {
		return "";
	}
	char buf[128] = {};
	if (std::fgets(buf, sizeof(buf), f) == nullptr) {
		std::fclose(f);
		return "";
	}
	std::fclose(f);
	std::string s = buf;
	while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) {
		s.pop_back();
	}
	return s;
}

// Resolve the accessibility bus address:
//   1. NIELLO_ATSPI_BUS_ADDRESS (explicit override, the test seam —
//      skips discovery entirely, so a private daemon can stand in
//      for the session bus + registry).
//   2. org.a11y.Bus.GetAddress on the session bus.
//   3. $AT_SPI_BUS_ADDRESS.
// False when none answers: the exporter stays inert.
bool discover_address(std::string &out) {
	const char *override_env = std::getenv("NIELLO_ATSPI_BUS_ADDRESS");
	if (override_env != nullptr && *override_env != '\0') {
		out = override_env;
		return true;
	}
	std::string session_addr;
	const char *env = std::getenv("DBUS_SESSION_BUS_ADDRESS");
	if (env != nullptr && *env != '\0') {
		session_addr = env;
	} else {
		char buf[160];
		std::snprintf(buf, sizeof(buf), "unix:path=/run/user/%d/bus", static_cast<int>(::getuid()));
		session_addr = buf;
	}
	dbus::Conn c;
	if (c.connect(session_addr.c_str())) {
		// Synchronous calls need the dispatch loop running to route
		// their replies: run it on a scratch thread for this one call.
		std::thread dispatch([&] { c.run_dispatch([](const dbus::Message &) {}); });
		dbus::Writer w;
		dbus::Message reply;
		bool ok = c.call("/org/a11y/bus", "org.a11y.Bus", "GetAddress", "org.a11y.Bus", "",
		                 w.buf, reply, 2000);
		c.shutdown();
		dispatch.join();
		if (ok && reply.type == dbus::MSG_RETURN) {
			dbus::Reader r(reply.body.data(), reply.body.data() + reply.body.size());
			std::string addr;
			if (r.str(addr) && !addr.empty()) {
				out = addr;
				return true;
			}
		}
	}
	const char *fallback = std::getenv("AT_SPI_BUS_ADDRESS");
	if (fallback != nullptr && *fallback != '\0') {
		out = fallback;
		return true;
	}
	return false;
}

int32_t exporter_start(const char *app_name) {
	std::lock_guard<std::mutex> start_lock(g_start_mu);
	{
		std::lock_guard<std::mutex> lock(g_exp.mu);
		if (g_exp.running) {
			return 1;
		}
	}
	std::string address;
	if (!discover_address(address)) {
		return 0; // inert: no accessibility bus
	}
	std::string unique_name;
	{
		std::lock_guard<std::mutex> lock(g_exp.mu);
		if (g_exp.running) {
			return 1;
		}
		if (!g_exp.bus.connect(address.c_str())) {
			return 0;
		}
		g_exp.app_name = app_name ? app_name : "";
		g_exp.unique_name = g_exp.bus.unique_name();
		g_exp.bus_address = address;
		const char *lang = std::getenv("LANG");
		g_exp.locale = (lang != nullptr && *lang != '\0') ? lang : "C";
		g_exp.machine_id = read_machine_id();
		unique_name = g_exp.unique_name;
		g_exp.dispatch_thread = std::thread([] { g_exp.bus.run_dispatch(handle_message); });
	}
	// Embed with the registry (the dispatch thread routes the reply).
	// Failure leaves us unembedded but live: direct queries work,
	// discovery through the registry does not. The registry sets
	// Application:Id on us via Properties.Set when it accepts us.
	{
		dbus::Writer w;
		w.begin_struct();
		w.str(unique_name);
		w.object_path(kRootPath);
		w.end_struct();
		dbus::Message reply;
		bool ok = g_exp.bus.call(kRootPath, kIfSocket, "Embed", "org.a11y.atspi.Registry", "(so)",
		                         w.buf, reply, 2000);
		if (ok && reply.type == dbus::MSG_RETURN) {
			dbus::Reader r(reply.body.data(), reply.body.data() + reply.body.size());
			std::string path, sender;
			if (r.align(8) && r.str(sender) && r.object_path(path)) {
				std::lock_guard<std::mutex> lock(g_exp.mu);
				g_exp.registry_path = path;
				g_exp.registry_sender = sender;
			}
		}
	}
	{
		std::lock_guard<std::mutex> lock(g_exp.mu);
		g_exp.running = true;
	}
	return 1;
}

void exporter_stop() {
	std::lock_guard<std::mutex> start_lock(g_start_mu);
	std::thread to_join;
	{
		std::lock_guard<std::mutex> lock(g_exp.mu);
		if (!g_exp.running) {
			return;
		}
		g_exp.running = false;
		g_exp.bus.shutdown();
		to_join = std::move(g_exp.dispatch_thread);
	}
	// Join without the mutex: the dispatch thread's handler takes
	// snapshots under it, and joining while holding it would
	// deadlock against a handler in flight.
	if (to_join.joinable()) {
		to_join.join();
	}
	{
		std::lock_guard<std::mutex> lock(g_exp.mu);
		g_exp.windows.clear();
		g_exp.app_id = 0;
		g_exp.registry_sender.clear();
		g_exp.registry_path.clear();
		g_exp.ready_sent = false;
	}
}

} // namespace

// --- C ABI (nui.h) ---

int32_t nui_atspi_start(const char *app_name) { return exporter_start(app_name); }

void nui_atspi_stop(void) { exporter_stop(); }

void nui_atspi_sync(int32_t ctx_id, const UiA11yNode *nodes, int32_t count,
                    const char *window_title, int32_t win_x, int32_t win_y, int32_t win_w,
                    int32_t win_h) {
	exporter_sync(ctx_id, nodes, count, window_title, win_x, win_y, win_w, win_h);
}

void nui_atspi_remove_window(int32_t ctx_id) { exporter_remove_window(ctx_id); }





