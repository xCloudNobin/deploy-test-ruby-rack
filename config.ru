# Rack entry point. Serve with the production launcher (scripts/build.sh
# validates it, server.rb runs it) or with any Rack server:
#
#   bundle exec rackup -s webrick -o "$BIND_HOST" -p "$PORT" config.ru
require "json"
require_relative "src/app"

run App.new