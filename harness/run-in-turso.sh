#!/usr/bin/env bash
# Runs the trace replay tests inside a turso checkout at the pinned rev.
#
# The tests use private turso_core APIs and test-only hooks, so they must
# build as a module of turso_core. This script copies mbt_tests/ into the
# checkout, applies turso-hooks.patch, and runs the tests.
#
# Usage: harness/run-in-turso.sh [TURSO_DIR] [-- CARGO_TEST_ARGS...]
#
# CARGO_TEST_ARGS default to "mbt_tests". For example, this replays a folder
# of traces:
#   MBT_TRACES=$PWD/specs/traces harness/run-in-turso.sh -- \
#     mbt_tests::rows::row_traces_from_folder -- --ignored --nocapture
#
# TURSO_DIR defaults to harness/target/turso. If it does not exist, the script
# clones tursodatabase/turso there. The script resets TURSO_DIR to the pinned
# rev, so do not point it at a checkout with work in it.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
rev=$(sed -n 's/^turso_core = .*rev = "\([0-9a-f]*\)".*/\1/p' "$here/Cargo.toml")
if [ -z "$rev" ]; then
  echo "no turso_core rev in $here/Cargo.toml" >&2
  exit 1
fi

turso=$here/target/turso
if [ $# -gt 0 ] && [ "$1" != "--" ]; then
  turso=$1
  shift
fi
[ "${1:-}" = "--" ] && shift
[ $# -eq 0 ] && set -- mbt_tests

if [ ! -d "$turso/.git" ]; then
  git clone --filter=blob:none --no-checkout https://github.com/tursodatabase/turso.git "$turso"
fi
git -C "$turso" fetch --quiet origin "$rev" 2>/dev/null || true
git -C "$turso" checkout --quiet --force --detach "$rev"
git -C "$turso" clean --quiet -fd core/mvcc/database

git -C "$turso" apply "$here/turso-hooks.patch"
cp -r "$here/mbt_tests" "$turso/core/mvcc/database/mbt_tests"

cd "$turso"
cargo test -p turso_core --lib "$@"
