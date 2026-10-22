#!/usr/bin/env bash
# Builds dist/niello-native-linux-x64.zip — the fat prebuilt archive
# (nui_render + Skia + Dawn + skcms + wuffs) plus include/nui.h, in
# the third_party/native layout (see tools/build-native.md, which
# this script follows step for step).
#
# Maintainers only; app authors use tools/fetch-native.sh.
#
# Requires:
#   SKIA_DIR — a Skia checkout, depot_tools-synced (externals in)
#   the checkout's bin/gn, ninja, clang/clang++, cmake, ar, zip
# A cold Skia+Dawn build is 30-90 minutes; re-runs are incremental
# in the same out dir.
set -euo pipefail

: "${SKIA_DIR:?set SKIA_DIR to your Skia checkout}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLAT="linux-x64"
OUT="out/niello-${PLAT}"
WORK="$ROOT/build/native-${PLAT}"
DIST="$ROOT/dist"
mkdir -p "$WORK" "$DIST"

REV="$(git -C "$SKIA_DIR" rev-parse HEAD)"
echo "build-native: skia rev $REV"

# 1. Configure + build Skia with Dawn/Graphite — the tested
#    linux-x64 args (build-native.md §2). The Metal/D3D12 flags
#    belong to the other platforms' args blocks, inside the
#    quotes; they are not missing here, they are not Linux's.
cd "$SKIA_DIR"
bin/gn gen "$OUT" --args='
  is_official_build=true
  is_debug=false
  skia_enable_graphite=true
  skia_enable_ganesh=false
  skia_use_vulkan=true
  skia_use_dawn=true
  dawn_enable_vulkan=true
  skia_use_webgpu=true
  skia_use_vma=true
  skia_use_partition_alloc=false
  cc="clang"
  cxx="clang++"
'
ninja -C "$OUT" skia

# 2. SkShaper must be in the graph — nui_measure_word and
#    nui_line_height shape with it, and a release whose text
#    callbacks link-fail is worse than no release (§3).
if ! ninja -C "$OUT" -t targets all | grep -qi skshaper; then
	echo "build-native: SkShaper not in the build graph — see build-native.md §3" >&2
	exit 1
fi

# 3. nui_render against this out dir.
cmake -S "$ROOT/native" -B "$WORK/nui" \
	-DSKIA_DIR="$SKIA_DIR" \
	-DNIELLO_SKIA_OUT="niello-${PLAT}" \
	-DCMAKE_BUILD_TYPE=Release
cmake --build "$WORK/nui" -j

# 4. Merge the fat archive: exactly the set app links name.
MRI="$WORK/merge.mri"
{
	echo "CREATE $WORK/libniello_render.a"
	for a in libskia.a libdawn_combined.a libskcms.a libwuffs.a; do
		if [ ! -f "$SKIA_DIR/$OUT/$a" ]; then
			echo "build-native: expected archive missing: $OUT/$a" >&2
			exit 1
		fi
		echo "ADDLIB $SKIA_DIR/$OUT/$a"
	done
	echo "ADDLIB $WORK/nui/libnui_render.a"
	echo "SAVE"
	echo "END"
} > "$MRI"
ar -M < "$MRI"

# 5. Zip in the third_party layout, with provenance.
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/include"
cp "$WORK/libniello_render.a" "$STAGE/lib/"
cp "$ROOT/native/nui.h" "$STAGE/include/"
{
	echo "platform: $PLAT"
	echo "skia_rev: $REV"
	echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "host: $(uname -srm)"
} > "$STAGE/BUILD-INFO.txt"
rm -f "$DIST/niello-native-${PLAT}.zip"
(cd "$STAGE" && zip -qr "$DIST/niello-native-${PLAT}.zip" .)
echo "build-native: wrote $DIST/niello-native-${PLAT}.zip"
