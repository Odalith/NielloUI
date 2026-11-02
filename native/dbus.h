// dbus.h — a minimal D-Bus wire client, no libdbus, no sd-bus.
//
// Why hand-rolled: the native backend ships as a static archive that
// consumers drop in and run flagless (TODO #11). libdbus-1 and sd-bus
// would add a system dev dependency to every consumer's build for a
// protocol surface this small: one bus connection, a handful of
// method calls, object dispatch, signals. The wire protocol is
// stable (D-Bus spec v0.32) and the implementation is validated
// empirically against a real dbus-daemon (see the scratch test
// harness), which is a stronger oracle than any binding's docs.
//
// Scope (deliberately small): little-endian only (native on every
// target that matters), Unix-socket transports only (path +
// abstract), SASL EXTERNAL auth, synchronous calls with a timeout,
// one dispatch thread owning recv. No file-descriptor passing, no
// big-endian, no TCP, no match-rule subscriptions in v1 (the AT-SPI
// exporter needs none inbound).
//
// Threading: exactly one thread may call recv (the dispatch loop);
// send is serialized by an internal mutex, so any thread may send.
// Synchronous calls block the calling thread on a condition
// variable until the dispatch thread routes the reply.
#pragma once

#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <vector>

namespace dbus {

// Message types (D-Bus spec: header byte 1).
enum : uint8_t {
	MSG_CALL   = 1,
	MSG_RETURN = 2,
	MSG_ERROR  = 3,
	MSG_SIGNAL = 4,
};

// A parsed message. `body` holds the raw body bytes; use Reader to
// walk them. Header strings are empty when the field is absent.
struct Message {
	uint8_t type = 0;
	uint32_t serial = 0;
	uint32_t reply_serial = 0;
	std::string path;
	std::string interface;
	std::string member;
	std::string destination;
	std::string sender;
	std::string signature;
	std::string error_name;
	std::vector<uint8_t> body;
};

// Writer builds D-Bus values with spec alignment. One Writer per
// body; arrays/structs/variants nest via begin/end pairs that must
// balance (unbalanced use is a caller bug, asserted in debug).
struct Writer {
	std::vector<uint8_t> buf;

	void align(size_t n);
	void raw(const void *p, size_t n);
	void u8(uint8_t v);
	void boolean(bool v);
	void u16(uint16_t v);
	void u32(uint32_t v);
	void u64(uint64_t v);
	void i16(int16_t v);
	void i32(int32_t v);
	void i64(int64_t v);
	void f64(double v);
	void str(const std::string &v); // STRING: u32 length + bytes + NUL
	void object_path(const std::string &v); // same wire form as STRING
	void signature(const std::string &v); // SIGNATURE: u8 length + bytes + NUL
	void begin_array(size_t elem_align); // writes the u32 length slot
	void end_array(); // patches the length slot
	void begin_struct(); // align 8; structs have no length prefix
	void end_struct();
	void begin_variant(const std::string &sig); // writes the signature
	void end_variant();
	void begin_dict_entry(); // align 8; a struct of key + value
	void end_dict_entry();

	// Open array frames (LIFO). A Writer is single-threaded by
	// construction, so a member stack is exact — no shared state.
	// The length counts the ELEMENTS only: the alignment pad
	// between the length slot and the first element is NOT
	// counted (gdbus/libdbus oracle: an a{sv} dict with a 4-byte
	// leading pad reports length 44, not 48 — counting the pad
	// makes the daemon read past the body and drop the sender).
	struct Array_Frame {
		size_t len_pos; // offset of the u32 length slot
		size_t data_start; // offset of the first element (aligned)
	};
	std::vector<Array_Frame> array_stack_;
};

// Reader walks a body (or any byte range) positionally, with
// bounds checks. Every read returns false on overrun; callers
// must check. `skip` advances past one value of the given
// signature, for payloads the caller does not need to inspect.
// Alignment is relative to `origin` (the buffer start): the
// header-fields buffer starts at message offset 16 and the body
// buffer starts 8-aligned, so buffer-relative alignment is
// message-relative alignment in both cases.
struct Reader {
	const uint8_t *p = nullptr;
	const uint8_t *end = nullptr;
	const uint8_t *origin = nullptr;

	Reader() = default;
	Reader(const uint8_t *begin, const uint8_t *end) : p(begin), end(end), origin(begin) {}

	bool align(size_t n);
	bool bytes(void *out, size_t n);
	bool u8(uint8_t &v);
	bool boolean(bool &v);
	bool u16(uint16_t &v);
	bool u32(uint32_t &v);
	bool u64(uint64_t &v);
	bool i16(int16_t &v);
	bool i32(int32_t &v);
	bool i64(int64_t &v);
	bool f64(double &v);
	bool str(std::string &v);
	bool object_path(std::string &v);
	bool signature(std::string &v);
	// Skip one value described by sig (sig advances past the type).
	bool skip(const char *&sig);
	bool skip_signature(const std::string &sig);
	bool at_end() const { return p == end; }
};

// Encode a complete message (16-byte header + fields + body).
// `body_sig` is the body's signature ("" for no body). For replies,
// pass reply_serial + the call's sender as destination; for
// signals, destination is "" (broadcast).
std::vector<uint8_t> encode_message(uint8_t type, const std::string &path,
                                    const std::string &interface,
                                    const std::string &member,
                                    const std::string &destination,
                                    uint32_t serial, uint32_t reply_serial,
                                    const std::string &error_name,
                                    const std::string &body_sig,
                                    const std::vector<uint8_t> &body);

// A bus connection: one socket, one dispatch thread (owned by the
// caller of run_dispatch), synchronous calls from any thread.
class Conn {
public:
	Conn() = default;
	~Conn();
	Conn(const Conn &) = delete;
	Conn &operator=(const Conn &) = delete;

	// Connect to a bus address ("unix:path=...", "unix:abstract=...",
	// comma-separated params allowed, "guid=" ignored), run SASL
	// EXTERNAL auth, and complete the Hello handshake. On success
	// unique_name() is the bus-assigned name (":1.23").
	bool connect(const char *address);
	const std::string &unique_name() const { return unique_name_; }
	bool connected() const { return fd_ >= 0; }

	// Send a pre-encoded message (thread-safe).
	bool send_raw(const std::vector<uint8_t> &bytes);
	// Send one method call; returns its serial (0 on failure).
	uint32_t send_call(const std::string &path, const std::string &interface,
	                   const std::string &member, const std::string &destination,
	                   const std::string &body_sig,
	                   const std::vector<uint8_t> &body);
	// Synchronous method call: send + wait for the reply (or error)
	// up to timeout_ms. Returns false on timeout/transport failure;
	// true when any reply arrived — the caller inspects
	// reply.type (MSG_RETURN vs MSG_ERROR) and reply.error_name.
	bool call(const std::string &path, const std::string &interface,
	          const std::string &member, const std::string &destination,
	          const std::string &body_sig, const std::vector<uint8_t> &body,
	          Message &reply, int timeout_ms = 5000);
	// Fire-and-forget signal.
	bool send_signal(const std::string &path, const std::string &interface,
	                 const std::string &member, const std::string &body_sig,
	                 const std::vector<uint8_t> &body);

	// Reply to a method call (from the dispatch thread or any
	// thread; serialized internally).
	bool send_return(const Message &call, const std::string &body_sig,
	                 const std::vector<uint8_t> &body);
	bool send_error(const Message &call, const std::string &error_name,
	                const std::string &message);

	// The dispatch loop: blocks reading messages until the
	// connection closes or shutdown() is called. Method calls and
	// signals are routed to `handler`; replies to pending
	// synchronous calls are routed internally. Run on exactly one
	// thread. (The AT-SPI exporter ignores signals; the scratch
	// test harness uses them.)
	void run_dispatch(const std::function<void(const Message &)> &handler);
	// Wake the dispatch loop and close the socket. Join the
	// dispatch thread afterwards from the caller.
	void shutdown();

private:
	int fd_ = -1;
	std::string unique_name_;
	uint32_t next_serial_ = 1;
	std::vector<uint8_t> inbuf_;
	size_t inbuf_off_ = 0;

	bool send_locked(const std::vector<uint8_t> &bytes); // caller holds write_mu_
	bool read_line(std::string &line); // CRLF-terminated, from inbuf_ + socket
	bool read_exact(uint8_t *dst, size_t n); // via inbuf_
	bool recv_one(Message &msg);

	// Write serialization (send path) + pending-call routing.
	std::mutex write_mu_;
	std::mutex pending_mu_;
	std::condition_variable pending_cv_;
	struct Pending {
		bool done = false;
		Message reply;
	};
	std::map<uint32_t, Pending> pending_;
	bool deliver_reply(const Message &msg); // true if a waiter took it
};

} // namespace dbus
