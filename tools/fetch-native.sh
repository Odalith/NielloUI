#!/usr/bin/env bash
# Downloads the prebuilt native backend for the current platform from the
# NielloUI GitHub Releases page and unpacks it under third_party/native/.
# On Linux it also fetches the bundled SDL3 (from the same release) into
# third_party/sdl3/linux-x64/ and creates the libSDL3.so link-time symlink.
#
# Usage:
#   tools/fetch-native.sh [--version <tag>] [--sdl | --no-sdl]
#                         [--sdl-only | --native-only] [--help]
#
# Defaults: the native backend always; SDL3 too on Linux (the bundled
# SDL3 is the default path) — pass --no-sdl to use a system SDL3 instead.
# Version: --version wins, else $NIELLO_NATIVE_VERSION, else latest.
# Both downloads share the same version semantics. The SDL3 zip first
# shipped in release native-v0.1.1; pinning an older version with SDL3
# enabled fails loudly.
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: tools/fetch-native.sh [--version <tag>] [--sdl | --no-sdl]
                             [--sdl-only | --native-only] [--help]
  --version <tag>  Release tag (e.g. native-v0.1.1); default:
                   $NIELLO_NATIVE_VERSION, else latest.
  --sdl            Fetch the bundled SDL3 (default on Linux).
  --no-sdl         Skip SDL3 (e.g. to use a system SDL3).
  --sdl-only       Fetch only SDL3, not the native backend.
  --native-only    Fetch only the native backend (same as --no-sdl).
EOF
}

cd "$(dirname "$0")/.."

case "$(uname -s)" in
	Linux)  PLAT="linux-x64" ;;
	Darwin) PLAT="macos-arm64" ;;
	*)      echo "fetch-native: unsupported OS '$(uname -s)' (Windows: use tools/fetch-native.ps1)" >&2; exit 1 ;;
esac

VER="${NIELLO_NATIVE_VERSION:-latest}"
WANT_NATIVE=1
if [ "${PLAT}" = "linux-x64" ]; then WANT_SDL=1; else WANT_SDL=0; fi

while [ $# -gt 0 ]; do
	case "$1" in
		--version)
			[ $# -ge 2 ] || { echo "fetch-native: --version needs a tag argument" >&2; exit 1; }
			VER="$2"; shift 2 ;;
		--version=*) VER="${1#--version=}"; shift ;;
		--sdl)         WANT_SDL=1; shift ;;
		--no-sdl)      WANT_SDL=0; shift ;;
		--sdl-only)    WANT_NATIVE=0; WANT_SDL=1; shift ;;
		--native-only) WANT_NATIVE=1; WANT_SDL=0; shift ;;
		-h|--help)     usage; exit 0 ;;
		*) echo "fetch-native: unknown argument '$1' (see --help)" >&2; exit 1 ;;
	esac
done

if [ "${WANT_SDL}" = "1" ] && [ "${PLAT}" != "linux-x64" ]; then
	echo "fetch-native: the bundled SDL3 is Linux-only for now; on macOS use a system SDL3 (e.g. brew install sdl3), or pass --no-sdl" >&2
	exit 1
fi

release_url() {
	if [ "${VER}" = "latest" ]; then
		echo "https://github.com/Odalith/NielloUI/releases/latest/download/$1"
	else
		echo "https://github.com/Odalith/NielloUI/releases/download/${VER}/$1"
	fi
}

# $1 = release asset name, $2 = destination dir, $3 = temp file,
# $4 = hint printed when the download fails.
fetch_zip() {
	local url tmp
	url="$(release_url "$1")"
	tmp="$3"
	echo "fetch-native: $1 -> $2"
	mkdir -p "$2"
	curl -fL --retry 3 -o "${tmp}" "${url}" || {
		echo "fetch-native: download failed — $4 (tried ${url})" >&2
		exit 1
	}
	unzip -o -q "${tmp}" -d "$2"
	rm "${tmp}"
}

if [ "${WANT_NATIVE}" = "1" ]; then
	DEST="third_party/native/${PLAT}"
	fetch_zip "niello-native-${PLAT}.zip" "${DEST}" /tmp/niello-native.zip \
		"no release published yet?"
	echo "fetch-native: native contents:"
	find "${DEST}" -type f | head
fi

if [ "${WANT_SDL}" = "1" ]; then
	DEST="third_party/sdl3/${PLAT}"
	fetch_zip "niello-sdl3-${PLAT}.zip" "${DEST}" /tmp/niello-sdl3.zip \
		"the SDL3 zip first shipped in release native-v0.1.1"
	# The zip ships only the versioned runtime name (libSDL3.so.0);
	# link time needs the libSDL3.so dev symlink pointing at it.
	if [ ! -f "${DEST}/lib/libSDL3.so.0" ]; then
		echo "fetch-native: ${DEST}/lib/libSDL3.so.0 missing after unpack — corrupt SDL3 zip?" >&2
		exit 1
	fi
	ln -sf libSDL3.so.0 "${DEST}/lib/libSDL3.so"
	echo "fetch-native: SDL3 contents:"
	find "${DEST}" -type f -o -type l | head
	echo "fetch-native: link with -L${DEST}/lib; ship libSDL3.so.0 beside your binary (\$ORIGIN rpath)."
fi

echo "fetch-native: done."
