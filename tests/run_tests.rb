#!/usr/bin/env ruby
# Dependency-free unit/integration suite for the plain-Rack taskboard.
#
# Exercises the exact production `API.dispatch` router with a real SQLite file
# in a temporary directory. No HTTP and no test framework: a tiny assert
# harness, exit 0 when all checks pass.
#
#   bundle exec ruby tests/run_tests.rb
require "tmpdir"
require "fileutils"
$LOAD_PATH.unshift File.expand_path("../src", __dir__)

require "api"
require "config"
require "db"

WORK = Dir.mktmpdir("ruby-rack-tests")
DB_PATH = File.join(WORK, "data", "taskboard.db")
CFG = ConfigLoader.load(
  {
    "PORT" => "0",
    "BIND_HOST" => "127.0.0.1",
    "DATA_DIR" => File.join(WORK, "data"),
    "DATABASE_PATH" => DB_PATH,
    "BUILD_MARKER" => "test-marker",
    "BASE_PATH" => "",
  },
  root: File.expand_path("..", __dir__)
)
SESSION = "session-token-abc123".freeze

$pass = 0
$fail = 0

def ok(msg)
  $pass += 1
  puts "ok   #{msg}"
end

def bad(msg)
  $fail += 1
  puts "FAIL #{msg}"
end

def assert(cond, msg)
  cond ? ok(msg) : bad(msg)
end

def assert_eq(a, b, label)
  a == b ? ok("#{label} => #{a}") : bad("#{label}: expected #{b.inspect}, got #{a.inspect}")
end

def call(method, path, kw = {})
  segments = path.split("/").reject(&:empty?)
  query = kw[:query] || {}
  body = kw.key?(:body) ? kw[:body] : {}
  broken = kw[:broken] || false
  hcsrf = kw[:hcsrf] || ""
  sess = kw[:sess] || SESSION
  API.dispatch(method, segments, query, body, broken, hcsrf, sess, DB_PATH, CFG)
end

def call_at(database_path, method, path, kw = {})
  segments = path.split("/").reject(&:empty?)
  query = kw[:query] || {}
  body = kw.key?(:body) ? kw[:body] : {}
  broken = kw[:broken] || false
  hcsrf = kw[:hcsrf] || ""
  sess = kw[:sess] || SESSION
  API.dispatch(method, segments, query, body, broken, hcsrf, sess, database_path, CFG)
end

def fresh_db_path
  path = File.join(WORK, "data", "phase-#{Time.now.to_f}.db")
  FileUtils.rm_f(path)
  path
end

def reset_db
  FileUtils.rm_rf(File.dirname(DB_PATH))
end

puts "=== ruby-rack unit/integration suite ==="

# --- Phase A: routing, health, meta, csrf (no schema needed) ---
reset_db
s, p, = call("GET", "/api/meta")
assert_eq(s, 200, "meta returns 200")
assert_eq(p["csrf"], SESSION, "meta echoes csrf for the session")
assert_eq(p["release"], "test-marker", "meta echoes release marker")
assert_eq(p["runtime"]["name"], "ruby", "meta reports ruby runtime")
assert_eq(p["runtime"]["server"], "webrick", "meta reports webrick server")

s, p, = call("GET", "/api/csrf")
assert_eq(s, 200, "csrf endpoint returns 200")
assert_eq(p["csrf"], SESSION, "csrf endpoint echoes session token")

s, p, = call("GET", "/api/health/live")
assert_eq(s, 200, "liveness returns 200")
assert_eq(p["status"], "alive", "liveness reports alive")
assert_eq(p["runtime"], "ruby", "liveness reports ruby runtime")
assert_eq(p["release"], "test-marker", "liveness reports release marker")

s, p, = call("GET", "/api/health")
assert_eq(s, 404, "incomplete health route returns 404")

s, = call("GET", "/api/nope")
assert_eq(s, 404, "unknown api route returns 404")
s, = call("GET", "/api")
assert_eq(s, 404, "bare /api returns 404")
s, p, = call("POST", "/api/meta", body: {})
assert_eq(s, 405, "method not allowed returns 405")
assert(p["allowed"] == ["GET"], "405 lists allowed methods")
s, = call("DELETE", "/api/health/live")
assert_eq(s, 405, "DELETE on health returns 405")

# --- Phase B: projects CRUD, validation, not-found ---
reset_db
db = DB.open(DB_PATH)
DB.apply_schema(db)
DB.seed(db)
db.close

s, p, = call("GET", "/api/projects")
assert_eq(s, 200, "project list returns 200")
assert_eq(p["count"], 2, "seed created exactly 2 projects")
assert_eq(p["projects"][0]["name"], "Launch checklist", "first seeded project name")
assert_eq(p["projects"][0]["task_count"], 3, "project task_count from seed")
assert_eq(p["projects"][0]["open_count"], 3, "project open_count from seed")

s, p, = call("POST", "/api/projects", body: { "name" => "  New Project  ", "status" => "archived" })
assert_eq(s, 201, "create project returns 201")
assert_eq(p["project"]["name"], "New Project", "project name is stripped")
assert_eq(p["project"]["status"], "archived", "project status accepted as archived")
pid = p["project"]["id"]
assert(pid.is_a?(Integer) && pid.positive?, "created project has a positive integer id")

s, p, = call("POST", "/api/projects", body: { "name" => "   " })
assert_eq(s, 400, "blank project name returns 400")
assert_eq(p["fields"]["name"], "name is required", "blank name error message")

s, p, = call("POST", "/api/projects", body: { "name" => 42 })
assert_eq(s, 400, "non-string project name returns 400")
assert_eq(p["fields"]["name"], "must be a string", "non-string name error message")

s, p, = call("POST", "/api/projects", body: { "name" => "x" * 121 })
assert_eq(s, 400, "over-long project name returns 400")
assert(p["fields"]["name"].include?("120"), "over-long name error mentions the limit")

s, p, = call("POST", "/api/projects", body: { "name" => "ok", "status" => "bogus" })
assert_eq(s, 400, "invalid project status returns 400")
assert_eq(p["fields"]["status"], "invalid value", "invalid status error message")

s, p, = call("GET", "/api/projects/#{pid}")
assert_eq(s, 200, "get project returns 200")
assert_eq(p["project"]["name"], "New Project", "get project echoes name")
assert(p["tasks"].is_a?(Array), "get project includes tasks array")

s, = call("GET", "/api/projects/999999")
assert_eq(s, 404, "missing project returns 404")

s, p, = call("PATCH", "/api/projects/#{pid}", body: { "name" => "Renamed" })
assert_eq(s, 200, "patch project returns 200")
assert_eq(p["project"]["name"], "Renamed", "patch project applied name")

s, = call("PATCH", "/api/projects/#{pid}", body: { "color" => "blue" })
assert_eq(s, 400, "patch with no updatable fields returns 400")

s, p, = call("PATCH", "/api/projects/#{pid}", body: { "status" => "nope" })
assert_eq(s, 400, "patch with invalid status returns 400")
assert_eq(p["fields"]["status"], "invalid value", "patch status error message")

s, = call("DELETE", "/api/projects/#{pid}")
assert_eq(s, 204, "delete project returns 204")
s, = call("GET", "/api/projects/#{pid}")
assert_eq(s, 404, "deleted project is gone")

s, = call("DELETE", "/api/projects/999999")
assert_eq(s, 404, "delete missing project returns 404")

s, = call("GET", "/api/projects/abc")
assert_eq(s, 400, "non-numeric project id returns 400")
s, = call("GET", "/api/projects/0")
assert_eq(s, 400, "zero project id returns 400")
s, = call("GET", "/api/projects/-1")
assert_eq(s, 400, "negative project id returns 400")

# --- Phase C: tasks CRUD, filters, search, persistence, cascade ---
reset_db
s, p, = call("GET", "/api/tasks")
assert_eq(s, 200, "task list returns 200")
assert_eq(p["count"], 4, "seed created exactly 4 tasks")

launch = call("GET", "/api/tasks")[1]["tasks"].count { |t| t["project_name"] == "Launch checklist" }
assert_eq(launch, 3, "Launch checklist has 3 seeded tasks")

origin = s = p = nil
s, p, = call("POST", "/api/tasks", body: { "project_id" => 1, "title" => "Integration task", "priority" => "high" })
assert_eq(s, 201, "create task returns 201")
origin = p["task"]["project_id"]
assert_eq(p["task"]["title"], "Integration task", "task title echoed")
assert_eq(p["task"]["status"], "todo", "task default status todo")
assert_eq(p["task"]["priority"], "high", "task priority accepted")
task_id = p["task"]["id"]
assert(task_id.is_a?(Integer) && task_id.positive?, "created task has positive integer id")

s, p, = call("POST", "/api/tasks", body: { "project_id" => 999999, "title" => "x" })
assert_eq(s, 400, "unknown task project returns 400")
assert_eq(p["fields"]["project_id"], "unknown project", "unknown project error message")

s, p, = call("POST", "/api/tasks", body: { "project_id" => 1, "title" => "x", "priority" => "bogus" })
assert_eq(s, 400, "invalid task priority returns 400")
assert_eq(p["fields"]["priority"], "invalid value", "invalid priority error message")

s, p, = call("POST", "/api/tasks", body: { "project_id" => 1, "title" => "" })
assert_eq(s, 400, "blank task title returns 400")
assert_eq(p["fields"]["title"], "title is required", "blank task title error message")

s, = call("POST", "/api/tasks", body: { "project_id" => 0, "title" => "x" })
assert_eq(s, 400, "non-positive task project_id returns 400")

s, p, = call("GET", "/api/tasks/#{task_id}")
assert_eq(s, 200, "get task returns 200")
assert_eq(p["task"]["project_name"], p["task"]["project_name"], "task includes project_name")

s, = call("GET", "/api/tasks/999999")
assert_eq(s, 404, "missing task returns 404")

s, p, = call("PATCH", "/api/tasks/#{task_id}", body: { "status" => "done", "priority" => "low" })
assert_eq(s, 200, "patch task returns 200")
assert_eq(p["task"]["status"], "done", "patch task status applied")
assert_eq(p["task"]["priority"], "low", "patch task priority applied")

s, p, = call("PATCH", "/api/tasks/#{task_id}", body: { "project_id" => 2 })
assert_eq(s, 200, "patch task project accepted")
assert_eq(p["task"]["project_id"], 2, "patch task moved to another project")

s, = call("PATCH", "/api/tasks/#{task_id}", body: { "title" => "x" * 201 })
assert_eq(s, 400, "over-long task title returns 400")

s, p, = call("PATCH", "/api/tasks/#{task_id}", body: { "project_id" => 999999 })
assert_eq(s, 400, "patch task invalid project returns 400")
assert_eq(p["fields"]["project_id"], "unknown or invalid project", "patch unknown project error")

s, = call("DELETE", "/api/tasks/#{task_id}")
assert_eq(s, 204, "delete task returns 204")
s, = call("GET", "/api/tasks/#{task_id}")
assert_eq(s, 404, "deleted task is gone")
s, = call("DELETE", "/api/tasks/999999")
assert_eq(s, 404, "delete missing task returns 404")

# search / filter
s, p, = call("GET", "/api/tasks", query: { "status" => "in_progress" })
assert_eq(s, 200, "status filter returns 200")
assert_eq(p["count"], 1, "status=in_progress matches the one seeded task")
assert_eq(p["tasks"][0]["title"], "Run the smoke tests", "status filter finds the right task")

s, p, = call("GET", "/api/tasks", query: { "priority" => "high" })
assert_eq(s, 200, "priority filter returns 200")
assert_eq(p["count"], 2, "priority=high matches two seeded tasks")

s, p, = call("GET", "/api/tasks", query: { "project_id" => "1" })
assert_eq(s, 200, "project_id filter returns 200")
assert_eq(p["count"], 3, "project_id=1 matches three seeded tasks")

s, p, = call("GET", "/api/tasks", query: { "q" => "smoke" })
assert_eq(s, 200, "search q returns 200")
assert_eq(p["count"], 1, "q=smoke matches the smoke task")
assert_eq(p["tasks"][0]["title"], "Run the smoke tests", "q search finds matching title")

# LIKE wildcards are escaped: literal % and _ must not act as wildcards
s, = call("POST", "/api/tasks", body: { "project_id" => 2, "title" => "fifty % done" })
assert_eq(s, 201, "create task with literal %% ok")
s, p, = call("GET", "/api/tasks", query: { "q" => "fifty %" })
assert_eq(s, 200, "search with %% literal returns 200")
assert_eq(p["count"], 1, "%% in search is treated literally (not a wildcard)")

s, = call("POST", "/api/tasks", body: { "project_id" => 2, "title" => "a_b underlined" })
assert_eq(s, 201, "create task with underscore ok")
s, p, = call("GET", "/api/tasks", query: { "q" => "a_b" })
assert_eq(s, 200, "search with underscore returns 200")
assert_eq(p["count"], 1, "_ in search is treated literally (not a wildcard)")

s, = call("GET", "/api/tasks", query: { "status" => "bogus" })
assert_eq(s, 400, "invalid status filter returns 400")
s, = call("GET", "/api/tasks", query: { "priority" => "bogus" })
assert_eq(s, 400, "invalid priority filter returns 400")
s, = call("GET", "/api/tasks", query: { "project_id" => "abc" })
assert_eq(s, 400, "invalid project_id filter returns 400")
s, = call("GET", "/api/tasks", query: { "q" => 123 })
assert_eq(s, 400, "non-string q filter returns 400")

# combined filter
s, p, = call("GET", "/api/tasks", query: { "status" => "todo", "q" => "Rotate" })
assert_eq(s, 200, "combined filter returns 200")
assert_eq(p["count"], 0, "combined filter with no match returns zero")
s, p, = call("GET", "/api/tasks", query: { "priority" => "high", "q" => "Rotate" })
assert_eq(s, 200, "combined priority+q filter returns 200")
assert_eq(p["count"], 1, "combined priority+q finds the rotation task")

# persistence: the record must survive connection close/reopen on the same path
s, p, = call("POST", "/api/tasks", body: { "project_id" => 1, "title" => "PERSIST-SURVIVOR" })
assert_eq(s, 201, "create persistence-survivor task")
db = DB.open(DB_PATH)
count = db.get_first_value("SELECT COUNT(*) FROM task WHERE title = ?", ["PERSIST-SURVIVOR"])
db.close
assert_eq(count, 1, "task persisted to the sqlite file on disk")
s, p, = call("GET", "/api/tasks", query: { "q" => "PERSIST-SURVIVOR" })
assert_eq(s, 200, "survivor readable after reopen")
assert_eq(p["count"], 1, "survivor found after connection reopen")

# cascade delete
s, p, = call("POST", "/api/projects", body: { "name" => "Cascade me" })
assert_eq(s, 201, "create project for cascade test")
cascade_pid = p["project"]["id"]
s, p, = call("POST", "/api/tasks", body: { "project_id" => cascade_pid, "title" => "doomed" })
assert_eq(s, 201, "create task inside cascade project")
cascade_task = p["task"]["id"]
s, = call("DELETE", "/api/projects/#{cascade_pid}")
assert_eq(s, 204, "delete cascade project")
s, = call("GET", "/api/tasks/#{cascade_task}")
assert_eq(s, 404, "cascade deleted the project tasks")

# schema + seed idempotency
db = DB.open(DB_PATH)
before_count = db.get_first_value("SELECT COUNT(*) FROM project")
DB.apply_schema(db)
mut = DB.seed(db)
after_count = db.get_first_value("SELECT COUNT(*) FROM project")
db.close
assert(mut["seeded"] == false, "seed is not re-applied on an already-seeded database")
assert(before_count == after_count, "schema re-apply keeps project count stable")
assert(after_count >= 3, "project population present before idempotency check")
s, p, = call("GET", "/api/meta")
assert_eq(s, 200, "meta still 200 after schema re-apply")

# readiness probe: real write+read
s, p, = call("GET", "/api/health/ready")
assert_eq(s, 200, "readiness returns 200")
assert_eq(p["status"], "ready", "readiness reports ready")

# database-unavailable readiness: parent path is a regular file
bad_db = File.join(WORK, "notadir_blocker")
File.write(bad_db, "i am a file")
s, p, = call_at(bad_db, "GET", "/api/health/ready")
assert_eq(s, 503, "readiness returns 503 when database path is unusable")
assert_eq(p["status"], "unavailable", "readiness reports unavailable")

# data route degrades to 503 when the database is unusable
s, = call_at(bad_db, "GET", "/api/tasks")
assert_eq(s, 503, "data route returns 503 when database is unusable")

# --- Phase D: CSRF enforcement ---
reset_db
s, = call("POST", "/api/projects", body: { "name" => "no csrf" })
assert_eq(s, 403, "mutation without csrf returns 403")
s, = call("POST", "/api/projects", body: { "name" => "wrong csrf" }, hcsrf: "wrong-token")
assert_eq(s, 403, "mutation with wrong csrf returns 403")
s, p, = call("POST", "/api/projects", body: { "name" => "csrf in body", "_csrf" => SESSION })
assert_eq(s, 201, "mutation with _csrf body field returns 201")
s, = call("PATCH", "/api/projects/#{p['project']['id']}", body: { "name" => "ok" }, hcsrf: SESSION)
assert_eq(s, 200, "mutation with matching header csrf returns 200")
s, = call("DELETE", "/api/projects/#{p['project']['id']}", hcsrf: SESSION)
assert_eq(s, 204, "delete with matching csrf returns 204")
s, = call("GET", "/api/projects")
assert_eq(s, 200, "read without csrf still works")

# malformed JSON is rejected before routing
s, = call("POST", "/api/projects", body: {}, broken: true)
assert_eq(s, 400, "malformed JSON body returns 400")

# --- summary ---
FileUtils.rm_rf(WORK)
printf "passed=%d failed=%d\n", $pass, $fail
exit($fail.zero? ? 0 : 1)