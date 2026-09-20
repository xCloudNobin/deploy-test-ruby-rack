#!/usr/bin/env bash
# Full verification for the plain-Rack taskboard fixture:
#
#   1. Creates the vendored bundle (rack, rackup, webrick, sqlite3) if the
#      project vendor/bundle is missing.
#   2. scripts/build.sh -> release marker (VERSION) + runtime preflight +
#      Ruby syntax + client JS check.
#   3. dependency-free unit/integration suite -> bundle exec ruby tests/run_tests.rb
#   4. scripts/smoke.sh -> real production server (WEBrick -> config.ru):
#      CRUD, invalid input, search/filter, restart persistence,
#      database-unavailable readiness + recovery.
#
# Usage:
#   scripts/verify.sh
#
# Exit codes: 0 = all checks passed, nonzero = a check failed. The first
# failing step aborts with its own nonzero code.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUBY_BIN="${RUBY:-$(command -v ruby)}"
BUNDLE="${BUNDLE:-$(command -v bundle)}"
[ -n "$RUBY_BIN" ] && [ -x "$RUBY_BIN" ] || { echo "ruby executable not found (install Ruby >= 3.1)" >&2; exit 1; }
[ -n "$BUNDLE" ] && [ -x "$BUNDLE" ] || { echo "bundler not found (gem install bundler)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }

step() { printf '\n=== %s ===\n' "$*"; }

cd "$ROOT"
step "provision vendored bundle (rack/rackup/webrick/sqlite3 from Gemfile.lock)"
if [ -f Gemfile.lock ] && [ -d vendor/bundle ] && "$BUNDLE" check >/dev/null 2>&1; then
  printf 'bundle already satisfied (reuse)\n'
else
  "$BUNDLE" config set --local path vendor/bundle
  "$BUNDLE" install --jobs 4
fi

step "build release marker + preflight runtime + syntax + JS check"
"$ROOT/scripts/build.sh"

step "unit/integration suite (tests/run_tests.rb)"
(cd "$ROOT" && "$BUNDLE" exec ruby tests/run_tests.rb)

step "production smoke: real process + CRUD + negatives + persistence + DB outage/recovery"
"$ROOT/scripts/smoke.sh"

step "verification complete (all steps passed)"
printf '%s\n' "ruby: $("$BUNDLE" exec ruby -e 'print RUBY_VERSION')"
printf '%s\n' "sqlite3: $("$BUNDLE" exec ruby -e 'require "sqlite3"; print SQLite3::SQLITE_VERSION')"
printf '%s\n' "release marker: $(cat "$ROOT/VERSION")"