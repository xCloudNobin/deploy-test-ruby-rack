# SQLite persistence layer built on the sqlite3 gem (bundled precompiled
# native binary; SQLite 3.53.2 in this verification).
#
# Provides the idempotent schema, a one-time repeatable seed, normalized
# parameterized queries, the readiness probe and LIKE-wildcard escaping. The
# database is opened lazily per request, so a missing/unusable database path is
# surfaced by data routes and readiness as 503 while liveness keeps serving.
require "sqlite3"
require "fileutils"

module DB
  PROJECT_STATUSES = %w[active archived].freeze
  TASK_STATUSES = %w[todo in_progress done].freeze
  TASK_PRIORITIES = %w[low medium high].freeze

  SEED_PROJECTS = [
    ["Launch checklist", "Everything that must be true before the release ships.", "active"],
    ["Housekeeping", "Small maintenance tasks that keep the workspace tidy.", "active"],
  ].freeze

  SEED_TASKS = [
    ["Launch checklist", "Write the release notes", "Summarize what changed and how.", "todo", "medium"],
    ["Launch checklist", "Run the smoke tests", "scripts/verify.sh must pass end to end.", "in_progress", "high"],
    ["Launch checklist", "Announce the launch", "Tell the world it is live.", "todo", "low"],
    ["Housekeeping", "Rotate the access keys", "Replace the expiring credentials.", "done", "high"],
  ].freeze

  SCHEMA = <<~SQL
    CREATE TABLE IF NOT EXISTS project (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'active',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS task (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id  INTEGER NOT NULL REFERENCES project(id) ON DELETE CASCADE,
        title       TEXT NOT NULL,
        description TEXT NOT NULL DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'todo',
        priority    TEXT NOT NULL DEFAULT 'medium',
        created_at  TEXT NOT NULL,
        updated_at  TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS seed_flag (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        applied_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS heartbeat (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts INTEGER NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_task_project ON task(project_id);
    CREATE INDEX IF NOT EXISTS idx_task_status ON task(status);
    CREATE INDEX IF NOT EXISTS idx_task_priority ON task(priority);
  SQL

  module_function

  def now_utc
    Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  def open(database_path)
    parent = File.dirname(File.expand_path(database_path))
    FileUtils.mkdir_p(parent) unless Dir.exist?(parent)
    db = SQLite3::Database.new(database_path, timeout: 5000)
    db.results_as_hash = true
    db.busy_timeout = 5000
    db.execute("PRAGMA foreign_keys = ON")
    db.execute("PRAGMA journal_mode = WAL")
    db
  end

  def apply_schema(db)
    db.execute_batch(SCHEMA)
  end

  def seed(db)
    applied = db.get_first_value("SELECT COUNT(*) AS n FROM seed_flag")
    if applied.to_i.positive?
      projects = db.get_first_value("SELECT COUNT(*) AS n FROM project")
      tasks = db.get_first_value("SELECT COUNT(*) AS n FROM task")
      return { "seeded" => false, "projects" => projects, "tasks" => tasks }
    end
    ts = now_utc
    project_ids = {}
    SEED_PROJECTS.each do |name, description, status|
      db.execute(
        "INSERT INTO project (name, description, status, created_at, updated_at)"
        " VALUES (?, ?, ?, ?, ?)",
        [name, description, status, ts, ts]
      )
      project_ids[name] = db.last_insert_row_id
    end
    SEED_TASKS.each do |project, title, description, status, priority|
      db.execute(
        "INSERT INTO task (project_id, title, description, status, priority,"
        " created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
        [project_ids[project], title, description, status, priority, ts, ts]
      )
    end
    db.execute("INSERT INTO seed_flag (id, applied_at) VALUES (1, ?)", [ts])
    db.execute("COMMIT")
    { "seeded" => true, "projects" => SEED_PROJECTS.length, "tasks" => SEED_TASKS.length }
  end

  # Readiness probe: fresh connection, schema, then a real write + read cycle.
  def probe(database_path)
    db = begin
      open(database_path)
    rescue StandardError => e
      return { "ok" => false, "error" => e.message }
    end
    begin
      apply_schema(db)
      ts = Time.now.to_i
      db.execute("INSERT INTO heartbeat (ts) VALUES (?)", [ts])
      row = db.get_first_value("SELECT ts FROM heartbeat WHERE id = ?", [db.last_insert_row_id])
      if row.nil? || row.to_i != ts
        return { "ok" => false, "error" => "heartbeat write/read-back failed" }
      end
      db.execute("DELETE FROM heartbeat WHERE id = ?", [db.last_insert_row_id])
      db.execute("COMMIT")
      { "ok" => true }
    rescue StandardError => e
      begin
        db.execute("ROLLBACK")
      rescue StandardError
        nil
      end
      { "ok" => false, "error" => e.message }
    ensure
      begin
        db.close
      rescue StandardError
        nil
      end
    end
  end

  def escape_like(term)
    term.to_s.chars.map { |ch| { "\\" => "\\\\", "%" => "\\%", "_" => "\\_" }[ch] || ch }.join
  end
end