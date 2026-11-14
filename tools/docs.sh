#!/usr/bin/env bash
# Build the user documentation locally, the way CI does, and serve it with
# live reload: check the snippets, generate the API reference from the doc
# comments (tools/docgen), then build or serve the book. Needs odin and mdbook on PATH (mdbook: a release binary from
# https://github.com/rust-lang/mdBook/releases, version in
# tools/mdbook-version.txt; or cargo install mdbook).
#
#	tools/docs.sh           check snippets, then serve at http://localhost:3000
#	tools/docs.sh build     check snippets, then build into docs/book
set -euo pipefail
cd "$(dirname "$0")/.."

for d in docs/snippets/apps/*/; do
	odin check "$d" -collection:niello=niello
done
odin test docs/snippets/headless -define:ODIN_TEST_THREADS=1 -collection:niello=niello
odin run tools/docgen -out:"${TMPDIR:-/tmp}/niello-docgen" -- -out:docs/src/reference

if [[ "${1:-serve}" == "build" ]]; then
	mdbook build docs
else
	mdbook serve docs --open
fi
