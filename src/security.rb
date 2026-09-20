# Stateless cookie session + CSRF protection for the plain-Rack taskboard.
#
# A session is a single random token stored in an HttpOnly, SameSite=Lax
# cookie. Every mutating request must echo that token in the `X-CSRF-Token`
# header or the `_csrf` body field, so a cross-site form cannot forge a
# mutation even though the browser legitimately holds the cookie.
require "securerandom"
require "rack/utils"

module Security
  SESSION_COOKIE = "rack_tb_session".freeze

  module_function

  def new_token
    SecureRandom.hex(32)
  end

  def parse_cookies(header)
    return {} if header.nil? || header.empty?

    result = {}
    header.split(";").each do |part|
      name, _, value = part.strip.partition("=")
      next if name.empty?

      result[name] = Rack::Utils.unescape(value)
    end
    result
  end

  def set_cookie_header(value)
    "#{SESSION_COOKIE}=#{value}; path=/; HttpOnly; SameSite=Lax"
  end

  def csrf_matches?(candidate, session_token)
    return false if candidate.nil? || candidate.empty?
    return false if session_token.nil? || session_token.empty?

    Rack::Utils.secure_compare(candidate.to_s, session_token.to_s)
  end
end