#!/usr/bin/env ruby
# Production launcher for the plain-Rack taskboard.
#
# Loads config.ru (the canonical Rack entry point) and serves it with the
# WEBrick production server through Rackup::Handler — the exact path the rackup
# CLI uses. WEBrick is multithreaded and this script runs in-process (blocking).
#
#   bundle exec ruby server.rb
#
# Configuration comes from the process environment (see src/config.rb):
#   PORT, BIND_HOST, DATA_DIR, DATABASE_PATH, BUILD_MARKER, BASE_PATH
require "rack"
require "rackup"
require "webrick"
$stdout.sync = true

require_relative "src/config"

cfg = ConfigLoader.load

# WEBrick may install its own INT/TERM handlers during start; this fallback
# guarantees the process still exits on SIGTERM if it does not.
trap("TERM") { exit(0) }
trap("INT") { exit(0) }

app, = Rack::Builder.parse_file(File.join(ConfigLoader::ROOT, "config.ru"))

Rackup::Handler::WEBrick.run(
  app,
  Host: cfg.bind_host,
  Port: cfg.port,
  Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO)
)