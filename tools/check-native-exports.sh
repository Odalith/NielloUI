#!/usr/bin/env bash
# Checks that a native archive defines every nui_* function native/nui.h
# declares: a release missing one links in CI's eyes and fails every app.
#
#	tools/check-native-exports.sh path/to/libniello_native.a [path/to/nui.h]
set -euo pipefail
lib="${1:?usage: tools/check-native-exports.sh <archive> [nui.h]}"
header="${2:-$(dirname "$0")/../native/nui.h}"
NM="${NM:-nm}"
# Declarations: a return type, then nui_name( at the start of a line.
wanted=$(grep -oE '^[A-Za-z_][A-Za-z0-9_ *]*[ *](nui_[a-z_0-9]+)\(' "$header" | grep -oE 'nui_[a-z_0-9]+\($' | tr -d '(' | sort -u)
defined=$("$NM" -g --defined-only "$lib" 2>/dev/null | awk '$2 == "T" {print $3}' | sort -u)
missing=$(comm -23 <(echo "$wanted") <(echo "$defined"))
count=$(echo "$wanted" | wc -l)
if [ -n "$missing" ]; then
	echo "check-native-exports: $lib lacks what nui.h declares:" >&2
	echo "$missing" | sed 's/^/  /' >&2
	exit 1
fi
echo "check-native-exports: all $count nui_* functions are defined"
