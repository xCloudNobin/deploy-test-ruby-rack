# Rack application for the plain-Rack taskboard.
#
# A Rack callable (env -> [status, headers, body]). Every request opens a fresh
# SQLite connection to the configured DATABASE_PATH, so liveness keeps
# answering while an unavailable or broken database makes data routes and
# readiness report 503. Serves the SPA shell, the JSON API and the static
# assets; logs one line per request to stdout.
require "json"
require "cgi"
require "rack"
require_relative "config"
require_relative "db"
require_relative "security"
require_relative "api"

CONTENT_TYPES = {
  ".js" => "text/javascript; charset=utf-8",
  ".css" => "text/css; charset=utf-8",
  ".html" => "text/html; charset=utf-8",
}.freeze

STATUS_TEXT = {
  200 => "OK",
  201 => "Created",
  204 => "No Content",
  400 => "Bad Request",
  403 => "Forbidden",
  404 => "Not Found",
  405 => "Method Not Allowed",
  503 => "Service Unavailable",
}.freeze

class App
  def initialize(cfg = nil)
    @cfg = cfg || ConfigLoader.load
  end

  attr_reader :cfg

  def call(env)
    method = env["REQUEST_METHOD"] || "GET"
    raw_path = env["PATH_INFO"].to_s
    raw_path = "/" if raw_path.empty?
    query = parse_query(env["QUERY_STRING"].to_s)
    cfg = @cfg

    if !cfg.base_path.empty? && raw_path.start_with?(cfg.base_path)
      raw_path = raw_path[cfg.base_path.length..] || ""
      raw_path = "/" if raw_path.empty?
    end

    cookies = Security.parse_cookies(env["HTTP_COOKIE"])
    session_token = cookies[Security::SESSION_COOKIE]
    set_cookie = nil
    if session_token.nil? || session_token.empty?
      session_token = Security.new_token
      set_cookie = Security.set_cookie_header(session_token)
    end

    status, payload, headers = route(method, raw_path, query, session_token, env, cfg)

    headers = headers.dup
    headers["set-cookie"] = set_cookie if set_cookie
    body = payload.nil? ? [] : [payload]
    status_text = STATUS_TEXT[status] || "Unknown"
    log(env, method, raw_path, status)
    [status, headers, body]
  rescue StandardError => e
    log(env, method, raw_path || "/", 500)
    warn("internal error: #{e.class}: #{e.message}\n#{e.backtrace&.join("\n")}")
    [500, { "content-type" => "text/plain; charset=utf-8" }, ["Internal Server Error\n"]]
  end

  private

  def route(method, raw_path, query, session_token, env, cfg)
    if raw_path == "/api" || raw_path.start_with?("/api/")
      serve_api(method, raw_path, query, session_token, env, cfg)
    elsif static_route?(raw_path)
      serve_static(cfg, raw_path)
    else
      [200, render_shell(cfg, session_token), { "content-type" => "text/html; charset=utf-8" }]
    end
  end

  def serve_api(method, raw_path, query, session_token, env, cfg)
    segments = raw_path.split("/").reject(&:empty?)
    header_csrf = env["HTTP_X_CSRF_TOKEN"].to_s
    body, json_broken = read_json_body(env)
    status, payload, headers = API.dispatch(
      method, segments, query, body, json_broken, header_csrf, session_token,
      cfg.database_path, cfg
    )
    return [status, nil, headers] if payload.nil?

    headers = headers.merge("content-type" => "application/json; charset=utf-8")
    [status, JSON.generate(payload), headers]
  end

  def read_json_body(env)
    input = env["rack.input"]
    raw = begin
      input.read.to_s
    rescue StandardError
      ""
    end
    return [nil, false] if raw.strip.empty?

    begin
      [JSON.parse(raw.force_encoding("UTF-8")), false]
    rescue JSON::ParserError, EncodingError
      [API::MALFORMED, true]
    end
  end

  def serve_static(cfg, raw_path)
    basename = File.basename(raw_path)
    allowed = %w[app.js style.css]
    return [404, nil, { "content-type" => "text/plain; charset=utf-8" }] unless allowed.include?(basename)

    file_path = File.join(cfg.static_dir, basename)
    payload = begin
      File.binread(file_path)
    rescue StandardError
      return [404, nil, { "content-type" => "text/plain; charset=utf-8" }]
    end
    ext = File.extname(basename)
    [200, payload, { "content-type" => CONTENT_TYPES.fetch(ext, "application/octet-stream") }]
  end

  def static_route?(raw_path)
    return true if raw_path == "/app.js" || raw_path == "/style.css"

    File.basename(raw_path).include?(".")
  end

  def render_shell(cfg, session_token)
    boot = {
      "csrf" => session_token,
      "release" => cfg.build_marker,
      "runtime" => "ruby #{RUBY_VERSION} / webrick",
      "base" => cfg.base_path,
    }
    boot_json = CGI.escapeHTML(JSON.generate(boot))
    title = "Rack Taskboard"
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>#{title}</title>
      <link rel="stylesheet" href="#{cfg.base_path}/style.css">
      </head>
      <body>
      <script>window.TB_BOOT = #{boot_json};</script>
      <header class="topbar">
        <h1>#{title}</h1>
        <div class="meta"><span class="release">release #{CGI.escapeHTML(cfg.build_marker)}</span></div>
      </header>
      <main id="app"></main>
      <footer class="statusbar"><span id="status-text">loading…</span></footer>
      <script src="#{cfg.base_path}/app.js"></script>
      </body>
      </html>
    HTML
  end

  def parse_query(qs)
    result = {}
    qs.split("&").each do |part|
      next if part.empty?

      key, _, value = part.partition("=")
      key = Rack::Utils.unescape(key)
      value = Rack::Utils.unescape(value)
      result[key] = value unless key.empty? || result.key?(key)
    end
    result
  end

  def log(env, method, path, status)
    remote = env["REMOTE_ADDR"] || "-"
    puts "#{remote} #{method} #{path} #{status}"
    STDOUT.flush
  end
end