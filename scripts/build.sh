#!/usr/bin/env bash
# Generate the non-sensitive release marker (VERSION) and preflight the Ruby
# runtime, the pinned gems and the project sources (seen by verify.sh/smoke.sh).
#
# Resolution order for the marker:
#   1. $BUILD_MARKER (explicit), e.g. BUILD_MARKER=v1.2.3
#   2. latest git short SHA at the checkout
#   3. current UTC date as a fallback
#
# The marker is intentionally not secret; database paths and environment values
# stay out of the repository. Gem pins live in Gemfile/Gemfile.lock; the vendored
# bundle is created by scripts/verify.sh when missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUBY_BIN="${RUBY:-$(command -v ruby)}"
BUNDLE="${BUNDLE:-$(command -v bundle)}"
[ -n "$RUBY_BIN" ] && [ -x "$RUBY_BIN" ] || { echo "ruby executable not found (install Ruby >= 3.1)" >&2; exit 1; }
[ -n "$BUNDLE" ] && [ -x "$BUNDLE" ] || { echo "bundler not found (bundle install first)" >&2; exit 1; }

run_ruby() { (cd "$ROOT" && "$BUNDLE" exec ruby "$@"); }

if [ -n "${BUILD_MARKER:-}" ]; then
  MARKER="$BUILD_MARKER"
elif sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
  MARKER="$sha"
else
  MARKER="build-$(date -u +%Y%m%d-%H%M%S)"
fi

printf '%s\n' "$MARKER" > "$ROOT/VERSION"
printf 'VERSION = %s\n' "$MARKER"

printf 'preflight runtime: '
run_ruby -e '
require "rack"; require "rackup"; require "webrick"; require "sqlite3"
abort "ruby >= 3.1 required, got #{RUBY_VERSION}" if RUBY_VERSION.split(".").first(2).join(".").to_f < 3.1
puts "ruby #{RUBY_VERSION} (rack #{Rack.release}, rackup #{Rackup::VERSION}, webrick #{WEBrick::VERSION}, sqlite3 #{SQLite3::SQLITE_VERSION})"
' || { echo "gems are not installed; run scripts/verify.sh to create the vendored bundle" >&2; exit 1; }

printf 'checking Ruby syntax\n'
(cd "$ROOT" && find src -name '*.rb' -type f -print0 | xargs -0 -n1 "$RUBY_BIN" -c)
"$RUBY_BIN" -c "$ROOT/config.ru" >/dev/null
"$RUBY_BIN" -c "$ROOT/server.rb" >/dev/null
"$RUBY_BIN" -c "$ROOT/tests/run_tests.rb" >/dev/null

if NODE="$(command -v node 2>/dev/null)"; then
  printf 'client JavaScript syntax check\n'
  "$NODE" --check "$ROOT/static/app.js"
else
  printf 'node not found; skipping client JavaScript syntax check\n'
fi

printf 'release marker written and runtime preflight ok'
[ -n "${BUILD_MARKER:-}" ] && printf ' (BUILD_MARKER override)\n' || printf '\n'