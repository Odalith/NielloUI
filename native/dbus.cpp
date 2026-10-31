// dbus.cpp — a minimal D-Bus wire client. See dbus.h for the
// rationale (no libdbus/sd-bus dependency) and the threading model.
//
// Alignment rule used throughout: every Writer aligns relative to
// the start of its own buffer. The header-fields buffer starts at
// message offset 16 (8-aligned) and the body buffer starts at the
// first 8-aligned offset after the header, so buffer-relative
// alignment equals message-relative alignment everywhere. The
// receiver (a real dbus-daemon, in the scratch test) is the oracle
// that this layout is right.
#include "dbus.h"

#include <cerrno>
#include <chrono>
#include <cstring>
#include <unistd.h>

#include <sys/socket.h>
#include <sys/un.h>

namespace dbus {

// ---------------------------------------------------------------------------
// Writer

void Writer::align(size_t n) {
	size_t off = buf.size() % n;
	if (off != 0) {
		buf.insert(buf.end(), n - off, 0);
	}
}

void Writer::raw(const void *p, size_t n) {
	const uint8_t *b = static_cast<const uint8_t *>(p);
	buf.insert(buf.end(), b, b + n);
}

void Writer::u8(uint8_t v) { raw(&v, 1); }

void Writer::boolean(bool v) {
	u32(v ? 1 : 0);
}

void Writer::u16(uint16_t v) {
	align(2);
	// Little-endian: the host is little-endian on every target that
	// matters; encode explicitly so a big-endian host still speaks
	// the protocol.
	uint8_t b[2] = {uint8_t(v & 0xff), uint8_t((v >> 8) & 0xff)};
	raw(b, 2);
}

void Writer::u32(uint32_t v) {
	align(4);
	uint8_t b[4] = {uint8_t(v & 0xff), uint8_t((v >> 8) & 0xff),
	                uint8_t((v >> 16) & 0xff), uint8_t((v >> 24) & 0xff)};
	raw(b, 4);
}

void Writer::u64(uint64_t v) {
	align(8);
	uint8_t b[8];
	for (int i = 0; i < 8; i++) {
		b[i] = uint8_t((v >> (8 * i)) & 0xff);
	}
	raw(b, 8);
}

void Writer::i16(int16_t v) { u16(static_cast<uint16_t>(v)); }
void Writer::i32(int32_t v) { u32(static_cast<uint32_t>(v)); }
void Writer::i64(int64_t v) { u64(static_cast<uint64_t>(v)); }

void Writer::f64(double v) {
	uint64_t bits = 0;
	static_assert(sizeof(bits) == sizeof(v));
	std::memcpy(&bits, &v, sizeof(v));
	u64(bits);
}

void Writer::str(const std::string &v) {
	u32(static_cast<uint32_t>(v.size()));
	raw(v.data(), v.size());
	u8(0);
}

void Writer::object_path(const std::string &v) { str(v); }

void Writer::signature(const std::string &v) {
	u8(static_cast<uint8_t>(v.size()));
	raw(v.data(), v.size());
	u8(0);
}

void Writer::begin_array(size_t elem_align) {
	// The length prefix is a u32 (4-aligned). The elements start
	// at the first elem_align-aligned offset after the slot, and
	// the length counts the elements only — the pad in between
	// is not counted (see Array_Frame in dbus.h).
	align(4);
	size_t len_pos = buf.size();
	u32(0); // patched by end_array
	align(elem_align);
	array_stack_.push_back({len_pos, buf.size()});
}

void Writer::end_array() {
	Array_Frame fr = array_stack_.back();
	array_stack_.pop_back();
	uint32_t len = static_cast<uint32_t>(buf.size() - fr.data_start);
	buf[fr.len_pos + 0] = uint8_t(len & 0xff);
	buf[fr.len_pos + 1] = uint8_t((len >> 8) & 0xff);
	buf[fr.len_pos + 2] = uint8_t((len >> 16) & 0xff);
	buf[fr.len_pos + 3] = uint8_t((len >> 24) & 0xff);
}

void Writer::begin_struct() { align(8); }
void Writer::end_struct() {}

void Writer::begin_variant(const std::string &sig) { signature(sig); }
void Writer::end_variant() {}

void Writer::begin_dict_entry() { align(8); }
void Writer::end_dict_entry() {}

// ---------------------------------------------------------------------------
// Reader

bool Reader::align(size_t n) {
	size_t off = static_cast<size_t>(p - origin) % n;
	if (off == 0) {
		return true;
	}
	size_t pad = n - off;
	if (static_cast<size_t>(end - p) < pad) {
		return false;
	}
	p += pad;
	return true;
}

bool Reader::bytes(void *out, size_t n) {
	if (static_cast<size_t>(end - p) < n) {
		return false;
	}
	std::memcpy(out, p, n);
	p += n;
	return true;
}

bool Reader::u8(uint8_t &v) { return bytes(&v, 1); }

bool Reader::boolean(bool &v) {
	uint32_t x = 0;
	if (!u32(x)) {
		return false;
	}
	v = x != 0;
	return true;
}

bool Reader::u16(uint16_t &v) {
	if (!align(2)) {
		return false;
	}
	uint8_t b[2];
	if (!bytes(b, 2)) {
		return false;
	}
	v = uint16_t(b[0] | (b[1] << 8));
	return true;
}

bool Reader::u32(uint32_t &v) {
	if (!align(4)) {
		return false;
	}
	uint8_t b[4];
	if (!bytes(b, 4)) {
		return false;
	}
	v = uint32_t(b[0]) | (uint32_t(b[1]) << 8) | (uint32_t(b[2]) << 16) |
	    (uint32_t(b[3]) << 24);
	return true;
}

bool Reader::u64(uint64_t &v) {
	if (!align(8)) {
		return false;
	}
	uint8_t b[8];
	if (!bytes(b, 8)) {
		return false;
	}
	v = 0;
	for (int i = 0; i < 8; i++) {
		v |= uint64_t(b[i]) << (8 * i);
	}
	return true;
}

bool Reader::i16(int16_t &v) {
	uint16_t x = 0;
	if (!u16(x)) {
		return false;
	}
	v = static_cast<int16_t>(x);
	return true;
}

bool Reader::i32(int32_t &v) {
	uint32_t x = 0;
	if (!u32(x)) {
		return false;
	}
	v = static_cast<int32_t>(x);
	return true;
}

bool Reader::i64(int64_t &v) {
	uint64_t x = 0;
	if (!u64(x)) {
		return false;
	}
	v = static_cast<int64_t>(x);
	return true;
}

bool Reader::f64(double &v) {
	uint64_t bits = 0;
	if (!u64(bits)) {
		return false;
	}
	std::memcpy(&v, &bits, sizeof(v));
	return true;
}

bool Reader::str(std::string &v) {
	uint32_t len = 0;
	if (!u32(len)) {
		return false;
	}
	if (static_cast<size_t>(end - p) < len + 1) {
		return false;
	}
	v.assign(reinterpret_cast<const char *>(p), len);
	p += len;
	if (*p != 0) {
		return false;
	}
	p += 1;
	return true;
}

bool Reader::object_path(std::string &v) { return str(v); }

bool Reader::signature(std::string &v) {
	uint8_t len = 0;
	if (!u8(len)) {
		return false;
	}
	if (static_cast<size_t>(end - p) < len + 1) {
		return false;
	}
	v.assign(reinterpret_cast<const char *>(p), len);
	p += len;
	if (*p != 0) {
		return false;
	}
	p += 1;
	return true;
}

// Advance a signature pointer past one complete type, without
// touching any bytes. Used to find an array's element type.
namespace {
bool sig_advance(const char *&s) {
	if (s == nullptr || *s == '\0') {
		return false;
	}
	char c = *s++;
	switch (c) {
	case 'a':
		return sig_advance(s);
	case '(':
		while (*s != '\0' && *s != ')') {
			if (!sig_advance(s)) {
				return false;
			}
		}
		if (*s != ')') {
			return false;
		}
		s++;
		return true;
	case '{':
		while (*s != '\0' && *s != '}') {
			if (!sig_advance(s)) {
				return false;
			}
		}
		if (*s != '}') {
			return false;
		}
		s++;
		return true;
	default:
		return true; // basic type: one char
	}
}

// Alignment of the complete type starting at s (s is not advanced).
size_t sig_align(const char *s) {
	if (s == nullptr || *s == '\0') {
		return 1;
	}
	switch (*s) {
	case 'y':
	case 'b':
	case 'v':
	case 'g':
		return 1;
	case 'n':
	case 'q':
		return 2;
	case 'i':
	case 'u':
	case 'h':
	case 's':
	case 'o':
	case 'a':
		return 4;
	case 'x':
	case 't':
	case 'd':
	case '(':
	case '{':
		return 8;
	default:
		return 1;
	}
}
}

bool Reader::skip(const char *&sig) {
	if (sig == nullptr || *sig == '\0') {
		return false;
	}
	char c = *sig++;
	switch (c) {
	case 'y': {
		uint8_t x = 0;
		return u8(x);
	}
	case 'b': {
		bool x = false;
		return boolean(x);
	}
	case 'n': {
		int16_t x = 0;
		return i16(x);
	}
	case 'q': {
		uint16_t x = 0;
		return u16(x);
	}
	case 'i': {
		int32_t x = 0;
		return i32(x);
	}
	case 'u':
	case 'h': {
		uint32_t x = 0;
		return u32(x);
	}
	case 'x': {
		int64_t x = 0;
		return i64(x);
	}
	case 't': {
		uint64_t x = 0;
		return u64(x);
	}
	case 'd': {
		double x = 0;
		return f64(x);
	}
	case 's':
	case 'o': {
		std::string x;
		return str(x);
	}
	case 'g': {
		std::string x;
		return signature(x);
	}
	case 'v': {
		std::string vsig;
		if (!signature(vsig)) {
			return false;
		}
		const char *inner = vsig.c_str();
		return skip(inner);
	}
	case 'a': {
		// Array: u32 byte length counting the ELEMENTS only,
		// starting at the first element-aligned offset after the
		// slot — the pad between slot and first element is not
		// counted. Align to the element type first, then the
		// length spans exactly the elements.
		uint32_t len = 0;
		if (!u32(len)) {
			return false;
		}
		const char *elem = sig;
		if (!sig_advance(sig)) {
			return false;
		}
		if (!align(sig_align(elem))) {
			return false;
		}
		const uint8_t *arr_end = p + len;
		if (arr_end > end) {
			return false;
		}
		while (p < arr_end) {
			const char *e = elem;
			if (!skip(e)) {
				return false;
			}
		}
		return p == arr_end;
	}
	case '(': {
		// Struct: 8-aligned, fields until ')'.
		if (!align(8)) {
			return false;
		}
		while (*sig != ')' && *sig != '\0') {
			if (!skip(sig)) {
				return false;
			}
		}
		if (*sig != ')') {
			return false;
		}
		sig++;
		return true;
	}
	case '{': {
		// Dict entry: 8-aligned, key + value until '}'.
		if (!align(8)) {
			return false;
		}
		while (*sig != '}' && *sig != '\0') {
			if (!skip(sig)) {
				return false;
			}
		}
		if (*sig != '}') {
			return false;
		}
		sig++;
		return true;
	}
	default:
		return false;
	}
}

bool Reader::skip_signature(const std::string &sig) {
	const char *s = sig.c_str();
	while (*s != '\0') {
		if (!skip(s)) {
			return false;
		}
	}
	return true;
}

// ---------------------------------------------------------------------------
// Message encoding

std::vector<uint8_t> encode_message(uint8_t type, const std::string &path,
                                    const std::string &interface,
                                    const std::string &member,
                                    const std::string &destination,
                                    uint32_t serial, uint32_t reply_serial,
                                    const std::string &error_name,
                                    const std::string &body_sig,
                                    const std::vector<uint8_t> &body) {
	// The header fields array has NO separate length prefix: the
	// fixed header's last word (bytes 12-15) IS the array length,
	// and the elements start at message offset 16. The fields
	// Writer therefore starts at offset 0 == message offset 16
	// (8-aligned), so buffer-relative struct alignment is
	// message-relative alignment. (An earlier version wrote a
	// spurious u32 prefix here; the daemon dropped every message
	// for it. The fake-bus capture of libdbus's Hello is the
	// oracle for this layout.)
	Writer fields;
	auto field = [&](uint8_t code, const std::string &sig,
	                 const std::function<void(Writer &)> &write_value) {
		fields.begin_struct();
		fields.u8(code);
		fields.begin_variant(sig);
		write_value(fields);
		fields.end_variant();
		fields.end_struct();
	};
	if (!path.empty()) {
		field(1, "o", [&](Writer &w) { w.object_path(path); });
	}
	if (!interface.empty()) {
		field(2, "s", [&](Writer &w) { w.str(interface); });
	}
	if (!member.empty()) {
		field(3, "s", [&](Writer &w) { w.str(member); });
	}
	if (!error_name.empty()) {
		field(4, "s", [&](Writer &w) { w.str(error_name); });
	}
	if (reply_serial != 0) {
		field(5, "u", [&](Writer &w) { w.u32(reply_serial); });
	}
	if (!destination.empty()) {
		field(6, "s", [&](Writer &w) { w.str(destination); });
	}
	if (!body_sig.empty()) {
		field(8, "g", [&](Writer &w) { w.signature(body_sig); });
	}

	std::vector<uint8_t> out;
	out.reserve(16 + fields.buf.size() + 8 + body.size());
	out.push_back('l');
	out.push_back(type);
	out.push_back(0); // flags
	out.push_back(1); // version
	auto put32 = [&](uint32_t v) {
		out.push_back(uint8_t(v & 0xff));
		out.push_back(uint8_t((v >> 8) & 0xff));
		out.push_back(uint8_t((v >> 16) & 0xff));
		out.push_back(uint8_t((v >> 24) & 0xff));
	};
	put32(static_cast<uint32_t>(body.size()));
	put32(serial);
	put32(static_cast<uint32_t>(fields.buf.size())); // elements only, no prefix
	out.insert(out.end(), fields.buf.begin(), fields.buf.end());
	size_t body_start = out.size();
	size_t pad = (8 - (body_start % 8)) % 8;
	out.insert(out.end(), pad, 0);
	out.insert(out.end(), body.begin(), body.end());
	return out;
}

// ---------------------------------------------------------------------------
// Conn

Conn::~Conn() { shutdown(); }

namespace {
std::string hex_encode(const std::string &s) {
	static const char *digits = "0123456789abcdef";
	std::string out;
	out.reserve(s.size() * 2);
	for (char ch : s) {
		uint8_t b = static_cast<uint8_t>(ch);
		out += digits[b >> 4];
		out += digits[b & 0xf];
	}
	return out;
}

bool parse_address(const char *address, bool &abstract, std::string &name) {
	// "unix:path=/x,guid=...", "unix:abstract=/tmp/dbus-...,guid=..."
	std::string a = address ? address : "";
	if (a.compare(0, 5, "unix:") != 0) {
		return false;
	}
	size_t pos = 5;
	while (pos <= a.size()) {
		size_t comma = a.find(',', pos);
		std::string param =
		    a.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
		if (param.compare(0, 5, "path=") == 0) {
			abstract = false;
			name = param.substr(5);
			return true;
		}
		if (param.compare(0, 9, "abstract=") == 0) {
			abstract = true;
			name = param.substr(9);
			return true;
		}
		if (comma == std::string::npos) {
			break;
		}
		pos = comma + 1;
	}
	return false;
}
}

bool Conn::send_locked(const std::vector<uint8_t> &bytes) {
	if (fd_ < 0) {
		return false;
	}
	size_t sent = 0;
	while (sent < bytes.size()) {
		ssize_t n = ::send(fd_, bytes.data() + sent, bytes.size() - sent, MSG_NOSIGNAL);
		if (n < 0) {
			if (errno == EINTR) {
				continue;
			}
			return false;
		}
		if (n == 0) {
			return false;
		}
		sent += static_cast<size_t>(n);
	}
	return true;
}

bool Conn::send_raw(const std::vector<uint8_t> &bytes) {
	std::lock_guard<std::mutex> lock(write_mu_);
	return send_locked(bytes);
}

bool Conn::read_exact(uint8_t *dst, size_t n) {
	size_t got = 0;
	while (got < n) {
		// Drain the pending buffer first.
		if (inbuf_off_ < inbuf_.size()) {
			size_t avail = inbuf_.size() - inbuf_off_;
			size_t take = avail < (n - got) ? avail : (n - got);
			std::memcpy(dst + got, inbuf_.data() + inbuf_off_, take);
			inbuf_off_ += take;
			got += take;
			if (inbuf_off_ == inbuf_.size()) {
				inbuf_.clear();
				inbuf_off_ = 0;
			}
			continue;
		}
		uint8_t tmp[8192];
		ssize_t r = ::recv(fd_, tmp, sizeof(tmp), 0);
		if (r < 0) {
			if (errno == EINTR) {
				continue;
			}
			return false;
		}
		if (r == 0) {
			return false; // EOF: peer closed
		}
		inbuf_.assign(tmp, tmp + r);
		inbuf_off_ = 0;
	}
	return true;
}

bool Conn::read_line(std::string &line) {
	line.clear();
	for (;;) {
		// Scan the pending buffer for CRLF.
		for (size_t i = inbuf_off_; i + 1 < inbuf_.size(); i++) {
			if (inbuf_[i] == '\r' && inbuf_[i + 1] == '\n') {
				line.assign(reinterpret_cast<const char *>(inbuf_.data() + inbuf_off_),
				            i - inbuf_off_);
				inbuf_off_ = i + 2;
				if (inbuf_off_ == inbuf_.size()) {
					inbuf_.clear();
					inbuf_off_ = 0;
				}
				return true;
			}
		}
		if (line.size() + (inbuf_.size() - inbuf_off_) > 4096) {
			return false; // absurd line: protocol violation
		}
		uint8_t tmp[1024];
		ssize_t r = ::recv(fd_, tmp, sizeof(tmp), 0);
		if (r < 0) {
			if (errno == EINTR) {
				continue;
			}
			return false;
		}
		if (r == 0) {
			return false;
		}
		inbuf_.insert(inbuf_.end(), tmp, tmp + r);
	}
}

bool Conn::connect(const char *address) {
	bool abstract = false;
	std::string name;
	if (!parse_address(address, abstract, name)) {
		return false;
	}
	// Reuse after shutdown(): drop any buffered partial message and
	// stale pending-call state from the previous connection, so a
	// reconnect starts clean. (No waiter can be outstanding here:
	// callers join the dispatch thread before reconnecting.)
	inbuf_.clear();
	inbuf_off_ = 0;
	{
		std::lock_guard<std::mutex> lock(pending_mu_);
		pending_.clear();
	}
	int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
	if (fd < 0) {
		return false;
	}
	sockaddr_un addr{};
	addr.sun_family = AF_UNIX;
	socklen_t addrlen = 0;
	if (abstract) {
		if (name.size() + 1 >= sizeof(addr.sun_path)) {
			::close(fd);
			return false;
		}
		addr.sun_path[0] = '\0';
		std::memcpy(addr.sun_path + 1, name.data(), name.size());
		addrlen = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + 1 + name.size());
	} else {
		if (name.size() >= sizeof(addr.sun_path)) {
			::close(fd);
			return false;
		}
		std::memcpy(addr.sun_path, name.data(), name.size());
		addrlen = static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + name.size() + 1);
	}
	if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), addrlen) != 0) {
		::close(fd);
		return false;
	}
	fd_ = fd;

	// SASL EXTERNAL: NUL byte (credentials travel via the socket),
	// then AUTH with the hex-encoded decimal UID as initial response.
	{
		uint8_t nul = 0;
		if (!send_locked(std::vector<uint8_t>{nul})) {
			shutdown();
			return false;
		}
		std::string uid = std::to_string(static_cast<long long>(::getuid()));
		std::string auth = "AUTH EXTERNAL " + hex_encode(uid) + "\r\n";
		if (!send_locked(std::vector<uint8_t>(auth.begin(), auth.end()))) {
			shutdown();
			return false;
		}
		std::string line;
		if (!read_line(line) || line.compare(0, 2, "OK") != 0) {
			shutdown();
			return false;
		}
		std::string begin = "BEGIN\r\n";
		if (!send_locked(std::vector<uint8_t>(begin.begin(), begin.end()))) {
			shutdown();
			return false;
		}
	}

	// Hello, exchanged synchronously: no dispatch thread yet.
	{
		Writer body;
		uint32_t serial = next_serial_++;
		auto bytes = encode_message(MSG_CALL, "/org/freedesktop/DBus",
		                            "org.freedesktop.DBus", "Hello",
		                            "org.freedesktop.DBus", serial, 0, "", "",
		                            body.buf);
		if (!send_locked(bytes)) {
			shutdown();
			return false;
		}
		for (;;) {
			Message msg;
			if (!recv_one(msg)) {
				shutdown();
				return false;
			}
			if (msg.type == MSG_RETURN && msg.reply_serial == serial) {
				Reader r(msg.body.data(), msg.body.data() + msg.body.size());
				if (!r.str(unique_name_) || unique_name_.empty()) {
					shutdown();
					return false;
				}
				break;
			}
			if (msg.type == MSG_ERROR && msg.reply_serial == serial) {
				shutdown();
				return false;
			}
			// Anything else before Hello is unexpected; ignore it.
		}
	}
	return true;
}

bool Conn::recv_one(Message &msg) {
	uint8_t hdr[16];
	if (!read_exact(hdr, 16)) {
		return false;
	}
	if (hdr[0] != 'l' || hdr[3] != 1 || hdr[1] < 1 || hdr[1] > 4) {
		return false;
	}
	auto u32le = [&](int at) {
		return uint32_t(hdr[at]) | (uint32_t(hdr[at + 1]) << 8) |
		       (uint32_t(hdr[at + 2]) << 16) | (uint32_t(hdr[at + 3]) << 24);
	};
	uint32_t body_len = u32le(4);
	uint32_t serial = u32le(8);
	uint32_t fields_len = u32le(12);
	if (fields_len > (1u << 20) || body_len > (16u << 20)) {
		return false;
	}
	// Fields array: exactly fields_len bytes of elements, no
	// length prefix (the fixed header carries the length).
	std::vector<uint8_t> fbuf(fields_len);
	if (!read_exact(fbuf.data(), fbuf.size())) {
		return false;
	}
	{
		// Parse with buffer-relative alignment: the buffer starts
		// at message offset 16 (8-aligned), so buffer-relative
		// struct alignment is message-relative alignment.
		Reader r(fbuf.data(), fbuf.data() + fbuf.size());
		const uint8_t *fields_end = fbuf.data() + fbuf.size();
		while (r.p < fields_end) {
			if (!r.align(8)) {
				return false;
			}
			uint8_t code = 0;
			if (!r.u8(code)) {
				return false;
			}
			std::string sig;
			if (!r.signature(sig)) {
				return false;
			}
			// Read the variant value per its signature.
			if (sig == "o" || sig == "s") {
				std::string v;
				if (!r.str(v)) {
					return false;
				}
				switch (code) {
				case 1:
					msg.path = v;
					break;
				case 2:
					msg.interface = v;
					break;
				case 3:
					msg.member = v;
					break;
				case 4:
					msg.error_name = v;
					break;
				case 6:
					msg.destination = v;
					break;
				case 7:
					msg.sender = v;
					break;
				default:
					break;
				}
			} else if (sig == "u") {
				uint32_t v = 0;
				if (!r.u32(v)) {
					return false;
				}
				if (code == 5) {
					msg.reply_serial = v;
				}
			} else if (sig == "g") {
				std::string v;
				if (!r.signature(v)) {
					return false;
				}
				if (code == 8) {
					msg.signature = v;
				}
			} else {
				// Unknown field type: skip one value of the signature.
				const char *s = sig.c_str();
				if (!r.skip(s)) {
					return false;
				}
			}
		}
	}
	// Body starts at the first 8-aligned offset after the header.
	size_t header_total = 16 + fields_len;
	size_t pad = (8 - (header_total % 8)) % 8;
	if (pad > 0) {
		uint8_t dummy[8];
		if (!read_exact(dummy, pad)) {
			return false;
		}
	}
	msg.body.resize(body_len);
	if (body_len > 0 && !read_exact(msg.body.data(), body_len)) {
		return false;
	}
	msg.type = hdr[1];
	msg.serial = serial;
	return true;
}

uint32_t Conn::send_call(const std::string &path, const std::string &interface,
                         const std::string &member, const std::string &destination,
                         const std::string &body_sig,
                         const std::vector<uint8_t> &body) {
	std::lock_guard<std::mutex> lock(write_mu_);
	uint32_t serial = next_serial_++;
	auto bytes = encode_message(MSG_CALL, path, interface, member, destination,
	                            serial, 0, "", body_sig, body);
	if (!send_locked(bytes)) {
		return 0;
	}
	return serial;
}

bool Conn::call(const std::string &path, const std::string &interface,
                const std::string &member, const std::string &destination,
                const std::string &body_sig, const std::vector<uint8_t> &body,
                Message &reply, int timeout_ms) {
	// Reserve the serial and register the pending entry BEFORE
	// sending: a reply that arrives between send and registration
	// would otherwise be dropped as unsolicited and the call
	// would time out despite the reply having arrived. (This race
	// bit the AT-SPI Embed handshake: the registry answers fast
	// enough to win it reliably under load.)
	uint32_t serial;
	{
		std::lock_guard<std::mutex> lock(pending_mu_);
		serial = next_serial_++;
		pending_.emplace(serial, Pending{});
	}
	bool sent;
	{
		std::lock_guard<std::mutex> lock(write_mu_);
		auto bytes = encode_message(MSG_CALL, path, interface, member, destination,
		                            serial, 0, "", body_sig, body);
		sent = send_locked(bytes);
	}
	if (!sent) {
		std::lock_guard<std::mutex> plock(pending_mu_);
		pending_.erase(serial);
		return false;
	}
	std::unique_lock<std::mutex> lock(pending_mu_);
	bool ok = pending_cv_.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] {
		auto it = pending_.find(serial);
		return it == pending_.end() || it->second.done;
	});
	auto it = pending_.find(serial);
	if (it == pending_.end()) {
		return false; // connection died under us
	}
	if (!ok || !it->second.done) {
		pending_.erase(it);
		return false; // timeout
	}
	reply = it->second.reply;
	pending_.erase(it);
	return true;
}

bool Conn::deliver_reply(const Message &msg) {
	std::lock_guard<std::mutex> lock(pending_mu_);
	auto it = pending_.find(msg.reply_serial);
	if (it == pending_.end()) {
		return false;
	}
	it->second.done = true;
	it->second.reply = msg;
	pending_cv_.notify_all();
	return true;
}

bool Conn::send_signal(const std::string &path, const std::string &interface,
                       const std::string &member, const std::string &body_sig,
                       const std::vector<uint8_t> &body) {
	std::lock_guard<std::mutex> lock(write_mu_);
	uint32_t serial = next_serial_++;
	auto bytes = encode_message(MSG_SIGNAL, path, interface, member, "", serial,
	                            0, "", body_sig, body);
	return send_locked(bytes);
}

bool Conn::send_return(const Message &call, const std::string &body_sig,
                       const std::vector<uint8_t> &body) {
	std::lock_guard<std::mutex> lock(write_mu_);
	uint32_t serial = next_serial_++;
	auto bytes = encode_message(MSG_RETURN, "", "", "", call.sender, serial,
	                            call.serial, "", body_sig, body);
	return send_locked(bytes);
}

bool Conn::send_error(const Message &call, const std::string &error_name,
                      const std::string &message) {
	Writer body;
	body.str(message);
	std::lock_guard<std::mutex> lock(write_mu_);
	uint32_t serial = next_serial_++;
	auto bytes = encode_message(MSG_ERROR, "", "", "", call.sender, serial,
	                            call.serial, error_name, "s", body.buf);
	return send_locked(bytes);
}

void Conn::run_dispatch(const std::function<void(const Message &)> &handler) {
	for (;;) {
		Message msg;
		if (!recv_one(msg)) {
			break;
		}
		if (msg.type == MSG_RETURN || msg.type == MSG_ERROR) {
			if (deliver_reply(msg)) {
				continue;
			}
			// Unsolicited reply: drop.
			continue;
		}
		if ((msg.type == MSG_SIGNAL || msg.type == MSG_CALL) && handler) {
			handler(msg);
		}
	}
	// The connection died: wake any synchronous waiters so they
	// fail promptly instead of waiting out their timeout.
	{
		std::lock_guard<std::mutex> lock(pending_mu_);
		pending_.clear();
		pending_cv_.notify_all();
	}
}

void Conn::shutdown() {
	if (fd_ >= 0) {
		::shutdown(fd_, SHUT_RDWR);
		::close(fd_);
		fd_ = -1;
	}
}

} // namespace dbus
