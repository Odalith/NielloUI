#!/usr/bin/env bash
# Run an app's agent scenarios (niello/agent) headless and print what they
# found. A scenario is an @(test) in the app's package, inside
# `when niello.NIELLO_DEBUG { ... }`; this builds with that define. Reports
# land in ./agent-out/<scenario>/ (snapshots, findings.txt, summary.txt),
# under the directory you run it from; set NIELLO_AGENT_OUT to put them
# elsewhere. Needs odin on PATH.
#
#	tools/agent.sh niello/examples/showcase                  every scenario (and the app's other tests)
#	tools/agent.sh niello/examples/showcase showcase_pages   one scenario
set -euo pipefail
pkg="${1:?usage: tools/agent.sh <app-package> [scenario]}"
args=(-define:ODIN_TEST_THREADS=1 -define:NIELLO_DEBUG=true)
if [[ -n "${NIELLO_AGENT_OUT:-}" ]]; then
	args+=(-define:NIELLO_AGENT_OUT="$NIELLO_AGENT_OUT")
fi
if [[ -n "${2:-}" ]]; then
	name=$(grep -m1 -h '^package ' "$pkg"/*.odin | head -1 | awk '{print $2}')
	args+=(-define:ODIN_TEST_NAMES="$name.$2")
fi
odin test "$pkg" "${args[@]}" -out:"${TMPDIR:-/tmp}/niello-agent-test"
