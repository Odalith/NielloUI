#!/usr/bin/env bash
# Builds dist/niello-native-linux-x64.zip — the fat prebuilt archive
# (nui_native + Skia + Dawn + skcms + wuffs + SkShaper + HarfBuzz) plus include/nui.h, in
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
# The pin is the provenance contract (audit ci-B7): a build at any
# other rev produces a valid-looking zip from the wrong sources,
# and CI already enforces this — fail here too, before the
# 30-90 minute build, not after it.
PINNED="$(tr -d '[:space:]' < "$ROOT/tools/skia-rev.txt")"
if [ "$REV" != "$PINNED" ]; then
  echo "build-native: error: Skia checkout is at $REV, but tools/skia-rev.txt pins $PINNED" >&2
  echo "build-native: fix with: git -C \"$SKIA_DIR\" checkout $PINNED && (cd \"$SKIA_DIR\" && python3 tools/git-sync-deps)" >&2
  exit 1
fi
echo "build-native: skia rev $REV (matches tools/skia-rev.txt)"

# 1. Configure + build Skia with Dawn/Graphite — the ruled
#    linux-x64 args (F1b/F4; build-native.md §2). Deliberately
#    diverges from the §0 tested args: bundled deps + DNG/PIEX
#    trim. The Metal/D3D12 flags belong to the other platforms'
#    args blocks, inside the quotes; they are not missing here,
#    they are not Linux's.
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
  skia_use_dng_sdk=false
  skia_use_piex=false
  skia_use_system_expat=false
  skia_use_system_freetype2=false
  skia_use_system_libjpeg_turbo=false
  skia_use_system_libpng=false
  skia_use_system_libwebp=false
  skia_use_system_zlib=false
  skia_use_system_harfbuzz=false
  skia_use_system_icu=false
  cc="clang"
  cxx="clang++"
'
ninja -C "$OUT" skia modules/skshaper

# 2. SkShaper must be BUILT, not merely present in the graph —
#    `ninja skia` never builds it: it lives under the `modules`
#    aggregate, as its own libskshaper.a. nui_measure_word and
#    nui_line_height shape with it, and a release whose text
#    callbacks link-fail is worse than no release (§3). The check
#    is the archive itself: if the modules/skshaper target is not
#    in the graph at all, the ninja step above fails first with
#    "unknown target", which means a GN condition (harfbuzz)
#    excluded it — see §3.
if [ ! -f "$SKIA_DIR/$OUT/libskshaper.a" ]; then
	echo "build-native: libskshaper.a not built — see build-native.md §3" >&2
	exit 1
fi

# 3. nui_native against this out dir.
cmake -S "$ROOT/native" -B "$WORK/nui" \
	-DSKIA_DIR="$SKIA_DIR" \
	-DNIELLO_SKIA_OUT="niello-${PLAT}" \
	-DCMAKE_BUILD_TYPE=Release
cmake --build "$WORK/nui" -j

# 4. Merge the fat archive: exactly the set app links name.
MRI="$WORK/merge.mri"
{
	echo "CREATE $WORK/libniello_native.a"
	for a in libskia.a libdawn_combined.a libskcms.a libwuffs.a libskshaper.a libharfbuzz.a; do
		if [ ! -f "$SKIA_DIR/$OUT/$a" ]; then
			echo "build-native: expected archive missing: $OUT/$a" >&2
			exit 1
		fi
		echo "ADDLIB $SKIA_DIR/$OUT/$a"
	done
	echo "ADDLIB $WORK/nui/libnui_native.a"
	echo "SAVE"
	echo "END"
} > "$MRI"
ar -M < "$MRI"

# 5. Zip in the third_party layout, with provenance.
STAGE="$WORK/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/lib" "$STAGE/include"
cp "$WORK/libniello_native.a" "$STAGE/lib/"
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
