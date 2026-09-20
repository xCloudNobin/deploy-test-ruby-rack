# Environment-driven configuration for the plain-Rack taskboard.

# No secrets: every knob is read from the process environment, which the
# supervisor exports. Defaults are safe for local development and for the
# verify/smoke harness. The VERSION file (git short SHA) is the default release
# marker unless BUILD_MARKER overrides it.
require "json"

ROOT = File.expand_path("..", __dir__).freeze

Config = Struct.new(
  :port, :bind_host, :data_dir, :database_path, :build_marker, :base_path, :root,
  keyword_init: true
) do
  def static_dir
    File.join(root, "static")
  end
end

module ConfigLoader
  module_function

  def default_marker
    path = File.join(ROOT, "VERSION")
    if File.readable?(path)
      marker = File.read(path).strip
      return marker unless marker.empty?
    end
    "dev"
  end

  def load(env = ENV, root: ROOT)
    data_dir = env["DATA_DIR"] || File.join(root, "data")
    Config.new(
      port: (env["PORT"] || "8080").to_i,
      bind_host: env["BIND_HOST"] || "0.0.0.0",
      data_dir: data_dir,
      database_path: env["DATABASE_PATH"] || File.join(data_dir, "taskboard.db"),
      build_marker: env["BUILD_MARKER"] || default_marker,
      base_path: (env["BASE_PATH"] || "").sub(%r{/+\z}, ""),
      root: root
    )
  end
end