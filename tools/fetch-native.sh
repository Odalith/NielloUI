#!/usr/bin/env bash
# Downloads the prebuilt native backend for the current platform from the
# NielloUI GitHub Releases page and unpacks it under third_party/native/.
set -euo pipefail

cd "$(dirname "$0")/.."

case "$(uname -s)" in
	Linux)  PLAT="linux-x64" ;;
	Darwin) PLAT="macos-arm64" ;;
	*)      echo "fetch-native: unsupported OS '$(uname -s)' (Windows: use tools/fetch-native.ps1)" >&2; exit 1 ;;
esac

VER="${NIELLO_NATIVE_VERSION:-latest}"
DEST="third_party/native/${PLAT}"

if [ "${VER}" = "latest" ]; then
	URL="https://github.com/Odalith/NielloUI/releases/latest/download/niello-native-${PLAT}.zip"
else
	URL="https://github.com/Odalith/NielloUI/releases/download/${VER}/niello-native-${PLAT}.zip"
fi

echo "fetch-native: ${PLAT} -> ${DEST}"
mkdir -p "${DEST}"
curl -fL --retry 3 -o /tmp/niello-native.zip "${URL}" || {
	echo "fetch-native: download failed — no release published yet? (tried ${URL})" >&2
	exit 1
}
unzip -o -q /tmp/niello-native.zip -d "${DEST}"
rm /tmp/niello-native.zip
echo "fetch-native: done. Contents:"
find "${DEST}" -type f | head
