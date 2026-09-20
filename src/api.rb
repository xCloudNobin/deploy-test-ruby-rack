# JSON API router and validated CRUD for the plain-Rack taskboard.
#
# `dispatch` is a pure function over method + path segments so the test suite
# can exercise the exact production logic without HTTP. Responses are returned
# as [status, payload, headers] and serialized by the Rack layer.
require "json"
require_relative "db"
require_relative "security"

module API
  MALFORMED = Object.new.freeze

  MUTATING_METHODS = %w[POST PATCH PUT DELETE].freeze

  METHODS_BY_ROUTE = {
    ["health/live", nil] => %w[GET],
    ["health/ready", nil] => %w[GET],
    ["meta", nil] => %w[GET],
    ["csrf", nil] => %w[GET],
    ["projects", nil] => %w[GET POST],
    ["projects", "id"] => %w[GET PATCH DELETE],
    ["tasks", nil] => %w[GET POST],
    ["tasks", "id"] => %w[GET PATCH DELETE],
  }.freeze

  module_function

  def match_route(segments)
    return nil unless segments.first == "api"

    rest = segments[1..]
    return ["meta", nil] if rest == ["meta"]
    return ["csrf", nil] if rest == ["csrf"]
    return ["projects", nil] if rest == ["projects"]
    return ["tasks", nil] if rest == ["tasks"]
    return ["health/live", nil] if rest == ["health", "live"]
    return ["health/ready", nil] if rest == ["health", "ready"]

    if rest.length == 2 && %w[projects tasks].include?(rest[0])
      return [rest[0], rest[1]]
    end

    nil
  end

  def dispatch(method, segments, query, body, json_broken, header_csrf, session_token, database_path, cfg)
    route = match_route(segments)
    return json(404, "error" => "not found") if route.nil?

    key, ident = route
    allowed = METHODS_BY_ROUTE[[key, ident.nil? ? nil : "id"]]
    return json(405, "error" => "method not allowed", "allowed" => allowed) unless allowed&.include?(method)

    return json(400, "error" => "malformed JSON body") if json_broken

    if MUTATING_METHODS.include?(method)
      csrf = header_csrf
      csrf = body["_csrf"] if body.is_a?(Hash) && body["_csrf"]
      return json(403, "error" => "invalid or missing CSRF token") unless Security.csrf_matches?(csrf, session_token)
    end

    body = body.is_a?(Hash) ? body.dup : {}
    query = query.nil? || query.empty? ? {} : query

    case key
    when "health/live" then live(cfg)
    when "health/ready" then ready(database_path)
    when "meta" then meta(session_token, cfg)
    when "csrf" then json(200, "csrf" => session_token)
    else
      handle_resource(key, ident, method, body, query, database_path)
    end
  end

  def json(status, payload, headers = {})
    [status, payload, headers]
  end

  def live(cfg)
    json(
      200,
      {
        "status" => "alive",
        "runtime" => "ruby",
        "version" => RUBY_VERSION,
        "release" => cfg.build_marker,
      }
    )
  end

  def ready(database_path)
    result = DB.probe(database_path)
    if result["ok"]
      json(200, "status" => "ready", "database" => database_path)
    else
      json(503, "status" => "unavailable", "error" => result["error"].to_s)
    end
  end

  def meta(session_token, cfg)
    json(
      200,
      {
        "release" => cfg.build_marker,
        "runtime" => { "name" => "ruby", "version" => RUBY_VERSION, "server" => "webrick" },
        "csrf" => session_token,
      }
    )
  end

  def handle_resource(key, ident, method, body, query, database_path)
    if ident.nil?
      return with_db(database_path) { |db| list_projects(db) } if key == "projects" && method == "GET"
      return with_db(database_path) { |db| create_project(db, body) } if key == "projects" && method == "POST"
      return with_db(database_path) { |db| list_tasks(db, query) } if key == "tasks" && method == "GET"
      return with_db(database_path) { |db| create_task(db, body) } if key == "tasks" && method == "POST"
    end

    pid = parse_id(ident)
    return json(400, "error" => "invalid id") if pid.nil?

    case key
    when "projects"
      return with_db(database_path) { |db| get_project(db, pid) } if method == "GET"
      return with_db(database_path) { |db| update_project(db, pid, body) } if method == "PATCH"
      return with_db(database_path) { |db| delete_project(db, pid) } if method == "DELETE"
    when "tasks"
      return with_db(database_path) { |db| get_task(db, pid) } if method == "GET"
      return with_db(database_path) { |db| update_task(db, pid, body) } if method == "PATCH"
      return with_db(database_path) { |db| delete_task(db, pid) } if method == "DELETE"
    end

    json(404, "error" => "not found")
  end

  def with_db(database_path)
    db = begin
      DB.open(database_path)
    rescue StandardError => e
      return json(503, "error" => "database unavailable", "detail" => e.message)
    end
    begin
      DB.apply_schema(db)
      DB.seed(db)
      yield(db)
    rescue StandardError => e
      json(503, "error" => "database unavailable", "detail" => e.message)
    ensure
      begin
        db.close
      rescue StandardError
        nil
      end
    end
  end

  def parse_id(value)
    return nil if value.nil?
    return nil unless value.is_a?(String) || value.is_a?(Integer)

    text = value.to_s.strip
    return nil unless text.match?(/\A[1-9]\d*\z/)

    text.to_i
  end

  def nonblank_string(value, maxlen, name, errors)
    return nil if value.nil?

    unless value.is_a?(String)
      errors[name] = "must be a string"
      return nil
    end
    if value.length > maxlen
      errors[name] = "must be at most #{maxlen} characters"
      return nil
    end
    stripped = value.strip
    if stripped.empty?
      errors[name] = "#{name} is required"
      return nil
    end
    stripped
  end

  def opt_string(value, maxlen, name, errors)
    return nil if value.nil?

    unless value.is_a?(String)
      errors[name] = "must be a string"
      return nil
    end
    if value.length > maxlen
      errors[name] = "must be at most #{maxlen} characters"
      return nil
    end
    value
  end

  def enum(value, allowed, default, name, errors)
    return default if value.nil?
    return value if allowed.include?(value)

    errors[name] = "invalid value"
    nil
  end

  def list_projects(db)
    rows = db.execute("SELECT * FROM project ORDER BY id")
    projects = rows.map { |row| project_json(row, db) }
    json(200, "projects" => projects, "count" => projects.length)
  end

  def project_json(row, db)
    total = db.get_first_value("SELECT COUNT(*) AS n FROM task WHERE project_id = ?", [row["id"]])
    open_count = db.get_first_value(
      "SELECT COUNT(*) AS n FROM task WHERE project_id = ? AND status != 'done'", [row["id"]]
    )
    {
      "id" => row["id"],
      "name" => row["name"],
      "description" => row["description"],
      "status" => row["status"],
      "created_at" => row["created_at"],
      "updated_at" => row["updated_at"],
      "task_count" => total,
      "open_count" => open_count,
    }
  end

  def get_project(db, pid)
    row = db.execute("SELECT * FROM project WHERE id = ?", [pid]).first
    return json(404, "error" => "Project not found") if row.nil?

    tasks = db.execute(
      "SELECT t.*, p.name AS project_name FROM task t"
      " JOIN project p ON p.id = t.project_id WHERE t.project_id = ? ORDER BY t.id",
      [pid]
    )
    json(200, "project" => project_json(row, db), "tasks" => tasks.map { |t| task_json(t) })
  end

  def create_project(db, body)
    errors = {}
    name = nonblank_string(body["name"], 120, "name", errors)
    description = opt_string(body["description"], 1000, "description", errors)
    status = enum(body["status"], DB::PROJECT_STATUSES, "active", "status", errors)
    return json(400, "error" => "validation failed", "fields" => errors) unless errors.empty?

    ts = DB.now_utc
    db.execute(
      "INSERT INTO project (name, description, status, created_at, updated_at)"
      " VALUES (?, ?, ?, ?, ?)",
      [name, description || "", status, ts, ts]
    )
    db.execute("COMMIT")
    row = db.execute("SELECT * FROM project WHERE id = ?", [db.last_insert_row_id]).first
    json(201, "project" => project_json(row, db))
  end

  def update_project(db, pid, body)
    row = db.execute("SELECT * FROM project WHERE id = ?", [pid]).first
    return json(404, "error" => "Project not found") if row.nil?

    errors = {}
    updates = {}
    present = body.keys & %w[name description status]
    return json(400, "error" => "no updatable fields provided") if present.empty?

    if present.include?("name")
      name = nonblank_string(body["name"], 120, "name", errors)
      updates["name"] = name if name
    end
    if present.include?("description")
      description = opt_string(body["description"], 1000, "description", errors)
      updates["description"] = description if description
    end
    if present.include?("status")
      status = enum(body["status"], DB::PROJECT_STATUSES, nil, "status", errors)
      updates["status"] = status if status
    end
    return json(400, "error" => "validation failed", "fields" => errors) unless errors.empty?

    apply_updates(db, "project", updates, pid)
    db.execute("COMMIT")
    row = db.execute("SELECT * FROM project WHERE id = ?", [pid]).first
    json(200, "project" => project_json(row, db))
  end

  def delete_project(db, pid)
    row = db.execute("SELECT * FROM project WHERE id = ?", [pid]).first
    return json(404, "error" => "Project not found") if row.nil?

    db.execute("DELETE FROM project WHERE id = ?", [pid])
    db.execute("COMMIT")
    json(204, nil)
  end

  def list_tasks(db, query)
    where = []
    params = []

    q = query["q"]
    if q
      return json(400, "error" => "invalid q parameter") unless q.is_a?(String)

      like = "%#{DB.escape_like(q)}%"
      where << "(t.title LIKE ? ESCAPE '\\' OR t.description LIKE ? ESCAPE '\\')"
      params += [like, like]
    end

    status = query["status"]
    if status
      unless DB::TASK_STATUSES.include?(status)
        return json(400, "error" => "invalid status filter", "fields" => { "status" => status })
      end
      where << "t.status = ?"
      params << status
    end

    priority = query["priority"]
    if priority
      unless DB::TASK_PRIORITIES.include?(priority)
        return json(400, "error" => "invalid priority filter", "fields" => { "priority" => priority })
      end
      where << "t.priority = ?"
      params << priority
    end

    project_id = filter_project_id(query["project_id"])
    if project_id.nil?
      return json(400, "error" => "invalid project_id filter", "fields" => { "project_id" => query["project_id"] })
    end
    if project_id != false
      where << "t.project_id = ?"
      params << project_id
    end

    sql = "SELECT t.*, p.name AS project_name FROM task t JOIN project p ON p.id = t.project_id"
    sql += " WHERE " + where.join(" AND ") unless where.empty?
    sql += " ORDER BY t.id"
    tasks = db.execute(sql, params)
    json(200, "tasks" => tasks.map { |t| task_json(t) }, "count" => tasks.length)
  end

  def filter_project_id(value)
    return false if value.nil?
    return nil unless value.is_a?(String) || value.is_a?(Integer)

    text = value.to_s.strip
    return nil unless text.match?(/\A[1-9]\d*\z/)

    text.to_i
  end

  def task_json(row)
    {
      "id" => row["id"],
      "project_id" => row["project_id"],
      "project_name" => row["project_name"],
      "title" => row["title"],
      "description" => row["description"],
      "status" => row["status"],
      "priority" => row["priority"],
      "created_at" => row["created_at"],
      "updated_at" => row["updated_at"],
    }
  end

  def create_task(db, body)
    errors = {}
    pid = parse_id(body["project_id"])
    if pid.nil?
      errors["project_id"] = "must be a positive integer"
    elsif project_exists?(db, pid).nil?
      errors["project_id"] = "unknown project"
    end
    title = nonblank_string(body["title"], 200, "title", errors)
    description = opt_string(body["description"], 1000, "description", errors)
    status = enum(body["status"], DB::TASK_STATUSES, "todo", "status", errors)
    priority = enum(body["priority"], DB::TASK_PRIORITIES, "medium", "priority", errors)
    return json(400, "error" => "validation failed", "fields" => errors) unless errors.empty?

    ts = DB.now_utc
    db.execute(
      "INSERT INTO task (project_id, title, description, status, priority,"
      " created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [pid, title, description || "", status, priority, ts, ts]
    )
    db.execute("COMMIT")
    row = db.execute(
      "SELECT t.*, p.name AS project_name FROM task t"
      " JOIN project p ON p.id = t.project_id WHERE t.id = ?",
      [db.last_insert_row_id]
    ).first
    json(201, "task" => task_json(row))
  end

  def update_task(db, pid, body)
    row = db.execute(
      "SELECT t.*, p.name AS project_name FROM task t"
      " JOIN project p ON p.id = t.project_id WHERE t.id = ?",
      [pid]
    ).first
    return json(404, "error" => "Task not found") if row.nil?

    errors = {}
    updates = {}
    present = body.keys & %w[project_id title description status priority]
    return json(400, "error" => "no updatable fields provided") if present.empty?

    if present.include?("project_id")
      new_pid = parse_id(body["project_id"])
      if new_pid.nil? || project_exists?(db, new_pid).nil?
        errors["project_id"] = "unknown or invalid project"
      else
        updates["project_id"] = new_pid
      end
    end
    if present.include?("title")
      title = nonblank_string(body["title"], 200, "title", errors)
      updates["title"] = title if title
    end
    if present.include?("description")
      description = opt_string(body["description"], 1000, "description", errors)
      updates["description"] = description if description
    end
    if present.include?("status")
      status = enum(body["status"], DB::TASK_STATUSES, nil, "status", errors)
      updates["status"] = status if status
    end
    if present.include?("priority")
      priority = enum(body["priority"], DB::TASK_PRIORITIES, nil, "priority", errors)
      updates["priority"] = priority if priority
    end
    return json(400, "error" => "validation failed", "fields" => errors) unless errors.empty?

    apply_updates(db, "task", updates, pid)
    db.execute("COMMIT")
    row = db.execute(
      "SELECT t.*, p.name AS project_name FROM task t"
      " JOIN project p ON p.id = t.project_id WHERE t.id = ?",
      [pid]
    ).first
    json(200, "task" => task_json(row))
  end

  def get_task(db, pid)
    row = db.execute(
      "SELECT t.*, p.name AS project_name FROM task t"
      " JOIN project p ON p.id = t.project_id WHERE t.id = ?",
      [pid]
    ).first
    return json(404, "error" => "Task not found") if row.nil?

    json(200, "task" => task_json(row))
  end

  def delete_task(db, pid)
    row = db.execute("SELECT 1 FROM task WHERE id = ?", [pid]).first
    return json(404, "error" => "Task not found") if row.nil?

    db.execute("DELETE FROM task WHERE id = ?", [pid])
    db.execute("COMMIT")
    json(204, nil)
  end

  def project_exists?(db, pid)
    db.execute("SELECT 1 FROM project WHERE id = ?", [pid]).first
  end

  def apply_updates(db, table, updates, pid)
    assignments = []
    params = []
    updates.each do |column, value|
      assignments << "#{column} = ?"
      params << value
    end
    assignments << "updated_at = ?"
    params << DB.now_utc
    params << pid
    db.execute("UPDATE #{table} SET #{assignments.join(', ')} WHERE id = ?", params)
  end
end