#!/usr/bin/env bash
# Reproducible production smoke test for the plain-Rack taskboard.
#
# 1. scripts/build.sh -> VERSION marker + runtime preflight.
# 2. Starts the REAL production process: WEBrick serving config.ru via the
#    Rackup::Handler path used by server.rb.
# 3. Bootstraps a session + CSRF token with a cookie jar, then exercises
#    liveness/readiness, project/task CRUD, search/filter and negative
#    validation cases over real HTTP against the JSON API.
# 4. Stops the process (SIGTERM -> process exit), restarts it on the SAME
#    SQLite path and proves a survivor record persisted.
# 5. Starts a process against a database path that cannot be opened (its parent
#    is a regular file) and proves readiness goes 503 while liveness stays 200
#    and the static UI still serves; then repairs the path and proves readiness
#    recovers once the database is available again.
#
# Every started server is terminated on success AND on failure (trap EXIT).
# Exit codes: 0 = all checks passed, nonzero = a check failed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
RUBY_BIN="${RUBY:-$(command -v ruby)}"
BUNDLE="${BUNDLE:-$(command -v bundle)}"
[ -n "$RUBY_BIN" ] && [ -x "$RUBY_BIN" ] || { echo "ruby executable not found" >&2; exit 1; }
[ -n "$BUNDLE" ] && [ -x "$BUNDLE" ] || { echo "bundler not found" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found" >&2; exit 1; }

"$ROOT/scripts/build.sh" >/dev/null
[ -f "$ROOT/config.ru" ] || { echo "config.ru missing" >&2; exit 1; }

WORK="$(mktemp -d /tmp/ruby-rack-smoke.XXXXXX)"
DB="$WORK/data/taskboard.db"
PIDS=()
LOGS=()
BASE="http://127.0.0.1"
JAR="$WORK/cookies.txt"
SURVIVOR_NAME="PERSIST-$(date +%s)-survivor"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $*"; }

cleanup() {
  local pid
  for pid in "${PIDS[@]:-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  sleep 0.4
  for pid in "${PIDS[@]:-}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

pick_port() {
  "$RUBY_BIN" -rsocket -e 's = TCPServer.new("127.0.0.1", 0); puts s.addr[1]; s.close'
}

start_server() { # db_path port logfile -> 0 on success
  local db_path="$1" port="$2" logfile="$3"
  mkdir -p "$(dirname "$db_path")" 2>/dev/null || true
  DATA_DIR="$(dirname "$db_path")" \
  DATABASE_PATH="$db_path" \
  PORT="$port" BIND_HOST="127.0.0.1" BUILD_MARKER="smoke-$port" \
    "$BUNDLE" exec ruby "$ROOT/server.rb" \
      >"$logfile" 2>&1 &
  PIDS+=($!)
  LOGS+=("$logfile")
  sleep 0.6
}

stop_server() { # graceful SIGTERM, wait, SIGKILL fallback; drops pid from list
  local pid target i
  target="${1:-}"
  if [ -z "$target" ]; then
    for pid in "${PIDS[@]:-}"; do
      if kill -0 "$pid" 2>/dev/null; then target="$pid"; break; fi
    done
  fi
  [ -n "$target" ] || return 0
  kill -TERM "$target" 2>/dev/null || true
  for _ in $(seq 1 60); do
    if ! kill -0 "$target" 2>/dev/null; then break; fi
    sleep 0.2
  done
  if kill -0 "$target" 2>/dev/null; then
    bad "process did not exit on SIGTERM, forcing"
    kill -9 "$target" 2>/dev/null || true
  fi
}

wait_live() { # port label [logfile]
  local port="$1" label="$2" logfile="${3:-}"
  local code=000
  for _ in $(seq 1 90); do
    code="$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "$BASE:$port/api/health/live" || true)"
    [ "$code" = "200" ] && { ok "liveness HTTP 200 ($label)"; return 0; }
    sleep 0.3
  done
  bad "server never became live (last code $code, $label)"
  if [ -n "$logfile" ] && [ -f "$logfile" ]; then tail -30 "$logfile" || true; fi
  return 1
}

expect_status() { # label url expected [method] [curl args...]
  local label="$1" url="$2" expected="$3"
  shift 3
  local method="GET"
  if [ "$#" -gt 0 ]; then method="$1"; shift; fi
  local code
  if [ "$#" -gt 0 ]; then
    code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' -X "$method" -b "$JAR" -c "$JAR" "$@" "$url" || true)"
  else
    code="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' -X "$method" -b "$JAR" -c "$JAR" "$url" || true)"
  fi
  if [ "$code" = "$expected" ]; then ok "$label ($code)"; else bad "$label: expected $expected got $code"; fi
}

body() { # url -> body
  curl -s --max-time 3 -b "$JAR" -c "$JAR" "$1"
}

json_field() { # file-or-inline-json dot.path -> value
  "$BUNDLE" exec ruby -rjson - "$1" "$2" <<'RUBY'
arg, expr = ARGV[0], ARGV[1]
d = begin
  JSON.parse(arg)
rescue JSON::ParserError
  JSON.parse(File.read(arg))
end
expr.split(".").each { |k| d = d.is_a?(Hash) ? d[k] : nil }
print d
RUBY
}

post_json() { # url payload_file out_file -> http code  (CSRF header + cookie jar)
  local csrf
  csrf="$(cat "$WORK/csrf.txt" 2>/dev/null || printf '')"
  curl -s --max-time 3 -o "$3" -w '%{http_code}' -X POST \
    -b "$JAR" -c "$JAR" \
    -H 'content-type: application/json' -H "X-CSRF-Token: $csrf" \
    --data-binary @"$2" "$1"
}

patch_json() { # url payload_file out_file -> http code
  local csrf
  csrf="$(cat "$WORK/csrf.txt" 2>/dev/null || printf '')"
  curl -s --max-time 3 -o "$3" -w '%{http_code}' -X PATCH \
    -b "$JAR" -c "$JAR" \
    -H 'content-type: application/json' -H "X-CSRF-Token: $csrf" \
    --data-binary @"$2" "$1"
}

del_json() { # url -> http code
  local csrf
  csrf="$(cat "$WORK/csrf.txt" 2>/dev/null || printf '')"
  curl -s --max-time 3 -o /dev/null -w '%{http_code}' -X DELETE \
    -b "$JAR" -c "$JAR" -H "X-CSRF-Token: $csrf" "$1"
}

printf '=== ruby-rack smoke start: %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

PORT1="$(pick_port)"
echo "phase 1: production server on 127.0.0.1:$PORT1 (webrick -> config.ru via server.rb)"
[ -f "$ROOT/config.ru" ] && ok "production entrypoint exists (config.ru)" || bad "entrypoint missing"
[ -f "$ROOT/server.rb" ] && ok "production launcher exists (server.rb)" || bad "launcher missing"
start_server "$DB" "$PORT1" "$WORK/server1.log"
wait_live "$PORT1" "phase-1" "$WORK/server1.log"

MARKER="smoke-$PORT1"
meta="$(body "$BASE:$PORT1/api/meta")"
case "$meta" in
  *"$MARKER"*) ok "release marker in /api/meta ($MARKER)";;
  *) bad "release marker missing from /api/meta: $meta";;
esac
case "$meta" in
  *'"name":"ruby"'*) ok "runtime reports ruby";;
  *) bad "runtime not reported as ruby: $meta";;
esac
case "$meta" in
  *'"server":"webrick"'*) ok "server reports webrick";;
  *) bad "server not reported as webrick: $meta";;
esac

csrf="$(body "$BASE:$PORT1/api/csrf")"
printf '%s' "$(printf '%s' "$csrf" | "$BUNDLE" exec ruby -rjson -e 'print JSON.parse(STDIN.read)["csrf"]')" > "$WORK/csrf.txt"
[ -s "$WORK/csrf.txt" ] && ok "session bootstrapped and CSRF token captured" || bad "CSRF token not captured"

ready="$(body "$BASE:$PORT1/api/health/ready")"
case "$ready" in
  *'"status":"ready"'*) ok "readiness reports ready";;
  *) bad "readiness payload: $ready";;
esac

index="$(body "$BASE:$PORT1/")"
case "$index" in
  *"Rack Taskboard"*) ok "UI served at /";;
  *) bad "UI index not served";;
esac
expect_status "client JS served" "$BASE:$PORT1/app.js" 200
expect_status "client CSS served" "$BASE:$PORT1/style.css" 200
expect_status "nested UI route /project/1 served" "$BASE:$PORT1/project/1" 200
expect_status "unknown api route is 404" "$BASE:$PORT1/api/nope" 404
expect_status "unknown static asset is 404" "$BASE:$PORT1/nope.js" 404
expect_status "unhandled method is 405" "$BASE:$PORT1/api/health/live" 405 POST
expect_status "GET /api returns 404" "$BASE:$PORT1/api" 404

if [ -f "$DB" ]; then ok "sqlite file exists at the configured persistent path ($DB)"; else bad "sqlite file missing at $DB"; fi

printf '\nphase 2: project/task CRUD over real HTTP with CSRF on 127.0.0.1:%s\n' "$PORT1"
printf '%s\n' '{"name":"HTTP Project","description":"created over the wire","status":"active"}' > "$WORK/prj.json"
code="$(post_json "$BASE:$PORT1/api/projects" "$WORK/prj.json" "$WORK/prj.out")"
[ "$code" = "201" ] && ok "POST /api/projects returns 201" || bad "POST /api/projects: expected 201 got $code"
PID="$(json_field "$WORK/prj.out" "project.id")"
[ -n "$PID" ] && [ "$PID" != "null" ] && ok "created project has id ($PID)" || bad "created project id missing"

printf '%s\n' '{"name":"   "}' > "$WORK/prj-bad.json"
code="$(post_json "$BASE:$PORT1/api/projects" "$WORK/prj-bad.json" "$WORK/prj-bad.out")"
[ "$code" = "400" ] && ok "blank project name returns 400" || bad "blank project name: expected 400 got $code"
case "$(cat "$WORK/prj-bad.out")" in
  *"name is required"*) ok "blank project name error message";;
  *) bad "blank project error payload: $(cat "$WORK/prj-bad.out")";;
esac

printf '%s\n' '{"status":"bogus"}' > "$WORK/prj-bogus.json"
code="$(post_json "$BASE:$PORT1/api/projects" "$WORK/prj-bogus.json" "$WORK/prj-bogus.out")"
[ "$code" = "400" ] && ok "invalid project status returns 400" || bad "invalid status: expected 400 got $code"

printf '%s\n' '{"status":"archived"}' > "$WORK/prj-patch.json"
code="$(patch_json "$BASE:$PORT1/api/projects/$PID" "$WORK/prj-patch.json" "$WORK/prj-patch.out")"
[ "$code" = "200" ] && ok "PATCH /api/projects/:id returns 200" || bad "PATCH project: expected 200 got $code"
case "$(cat "$WORK/prj-patch.out")" in
  *"archived"*) ok "patch project applied status archived";;
  *) bad "patch project payload: $(cat "$WORK/prj-patch.out")";;
esac

printf '%s\n' '{"title":"Wire task","description":"from the smoke test","status":"todo","priority":"high"}' > "$WORK/task.json"
jq -c --argjson pid "$PID" '.project_id = $pid' "$WORK/task.json" > "$WORK/task2.json"
code="$(post_json "$BASE:$PORT1/api/tasks" "$WORK/task2.json" "$WORK/task.out")"
[ "$code" = "201" ] && ok "POST /api/tasks returns 201" || bad "POST /api/tasks: expected 201 got $code"
TID="$(json_field "$WORK/task.out" "task.id")"
[ -n "$TID" ] && [ "$TID" != "null" ] && ok "created task has id ($TID)" || bad "created task id missing"

tasks_list="$(body "$BASE:$PORT1/api/tasks?q=Wire")"
case "$tasks_list" in
  *"Wire task"*) ok "search q=Wire returns the created task";;
  *) bad "search q=Wire did not find the task: $tasks_list";;
esac

printf '%s\n' '{"project_id":999999,"title":"x"}' > "$WORK/task-bad.json"
code="$(post_json "$BASE:$PORT1/api/tasks" "$WORK/task-bad.json" "$WORK/task-bad.out")"
[ "$code" = "400" ] && ok "unknown task project returns 400" || bad "unknown project task: expected 400 got $code"
case "$(cat "$WORK/task-bad.out")" in
  *"unknown project"*) ok "unknown project error message";;
  *) bad "unknown project error payload: $(cat "$WORK/task-bad.out")";;
esac

printf '%s\n' '{"title":"Wire task","priority":"bogus"}' > "$WORK/task-pri.json"
jq -c --argjson pid "$PID" '.project_id = $pid' "$WORK/task-pri.json" > "$WORK/task-pri2.json"
code="$(post_json "$BASE:$PORT1/api/tasks" "$WORK/task-pri2.json" "$WORK/task-pri.out")"
[ "$code" = "400" ] && ok "invalid task priority returns 400" || bad "invalid priority: expected 400 got $code"

tasks_filtered="$(body "$BASE:$PORT1/api/tasks?status=in_progress")"
case "$tasks_filtered" in
  *'"count":1'*) ok "status filter returns the single in_progress task";;
  *) bad "status filter count mismatch: $tasks_filtered";;
esac

expect_status "invalid status filter returns 400" "$BASE:$PORT1/api/tasks?status=bogus" 400
expect_status "invalid priority filter returns 400" "$BASE:$PORT1/api/tasks?priority=bogus" 400
expect_status "invalid project_id filter returns 400" "$BASE:$PORT1/api/tasks?project_id=abc" 400
expect_status "invalid resource id returns 400" "$BASE:$PORT1/api/tasks/abc" 400
expect_status "missing project returns 404" "$BASE:$PORT1/api/projects/999999" 404
expect_status "missing task returns 404" "$BASE:$PORT1/api/tasks/999999" 404

printf '%s\n' '{"status":"done"}' > "$WORK/task-patch.json"
code="$(patch_json "$BASE:$PORT1/api/tasks/$TID" "$WORK/task-patch.json" "$WORK/task-patch.out")"
[ "$code" = "200" ] && ok "PATCH /api/tasks/:id returns 200" || bad "PATCH task: expected 200 got $code"
case "$(cat "$WORK/task-patch.out")" in
  *'"status":"done"'*) ok "patch task applied status done";;
  *) bad "patch task payload: $(cat "$WORK/task-patch.out")";;
esac

code="$(del_json "$BASE:$PORT1/api/tasks/$TID")"
[ "$code" = "204" ] && ok "DELETE /api/tasks/:id returns 204" || bad "DELETE task: expected 204 got $code"
expect_status "deleted task is gone" "$BASE:$PORT1/api/tasks/$TID" 404

code="$(del_json "$BASE:$PORT1/api/projects/$PID")"
[ "$code" = "204" ] && ok "DELETE /api/projects/:id returns 204" || bad "DELETE project: expected 204 got $code"
expect_status "deleted project is gone" "$BASE:$PORT1/api/projects/$PID" 404

expect_status "mutation without CSRF token is 403" "$BASE:$PORT1/api/projects" 403 POST

printf '\nphase 3: persistence across stop/restart on the SAME sqlite path\n'
printf '%s\n' '{"title":"'"$SURVIVOR_NAME"'","description":"must survive restart","priority":"low"}' > "$WORK/surv.json"
jq -c '.project_id = 1' "$WORK/surv.json" > "$WORK/surv2.json"
code="$(post_json "$BASE:$PORT1/api/tasks" "$WORK/surv2.json" "$WORK/surv.out")"
[ "$code" = "201" ] && ok "created persistence survivor task" || bad "survivor create: expected 201 got $code"
count_before="$(json_field "$(body "$BASE:$PORT1/api/projects")" "count")"
tasks_before="$(json_field "$(body "$BASE:$PORT1/api/tasks")" "count")"

stop_server

PORT2="$(pick_port)"
start_server "$DB" "$PORT2" "$WORK/server2.log"
wait_live "$PORT2" "phase-3-restart" "$WORK/server2.log"

surv_list="$(body "$BASE:$PORT2/api/tasks?q=PERSIST-")"
case "$surv_list" in
  *"$SURVIVOR_NAME"*) ok "survivor record persisted across restart";;
  *) bad "survivor record lost after restart: $surv_list";;
esac
count_after="$(json_field "$(body "$BASE:$PORT2/api/projects")" "count")"
tasks_after="$(json_field "$(body "$BASE:$PORT2/api/tasks")" "count")"
if [ "$count_before" = "$count_after" ] && [ "$tasks_before" = "$tasks_after" ]; then
  ok "stable counts across restart (projects $count_before, tasks $tasks_before)"
else
  bad "project/task counts changed across restart (before $count_before/$tasks_before, after $count_after/$tasks_after)"
fi

printf '\nphase 4: database-unavailable readiness + recovery\n'
BLOCKER="$WORK/blocker"
printf 'i am a regular file, not a directory\n' > "$BLOCKER"
PORT3="$(pick_port)"
start_server "$BLOCKER/x.db" "$PORT3" "$WORK/server-fail.log"
wait_live "$PORT3" "phase-4-outage" "$WORK/server-fail.log"

ready_fail="$(body "$BASE:$PORT3/api/health/ready")"
case "$ready_fail" in
  *'"status":"unavailable"'*) ok "readiness reports unavailable while database path is broken";;
  *) bad "readiness did not fail: $ready_fail";;
esac
expect_status "readiness returns 503 while database unavailable" "$BASE:$PORT3/api/health/ready" 503
expect_status "data route returns 503 while database unavailable" "$BASE:$PORT3/api/tasks" 503
expect_status "liveness stays 200 during database outage" "$BASE:$PORT3/api/health/live" 200
expect_status "static UI keeps serving during database outage" "$BASE:$PORT3/" 200

rm -f "$BLOCKER"
recovered=""
for _ in $(seq 1 50); do
  recovered="$(curl -s --max-time 2 -b "$JAR" -c "$JAR" "$BASE:$PORT3/api/health/ready" || true)"
  case "$recovered" in
    *'"status":"ready"'*) break;;
    *) sleep 0.2;;
  esac
done
case "$recovered" in
  *'"status":"ready"'*) ok "readiness recovers once the database path is valid again";;
  *) bad "readiness did not recover: $recovered";;
esac

stop_server

printf '\n=== ruby-rack smoke result: passed=%d failed=%d ===\n' "$PASS" "$FAIL"
exit $((FAIL == 0 ? 0 : 1))