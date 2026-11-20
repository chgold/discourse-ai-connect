# frozen_string_literal: true

require 'json'
require 'uri'

# OAuth 2.1 redirect_uri rules (RFC 9700 4.1, RFC 8252 7.3) — 1.2.8.
#
# - an authorization request's redirect_uri must be one of the client's
#   registered URIs, compared as exact strings;
# - only exception: a registered loopback URI (http://127.0.0.1, http://[::1],
#   http://localhost) for a native app matches the same URI on any port;
# - an empty redirect_uri means the out-of-band flow and is accepted only when
#   the client registered urn:ietf:wg:oauth:2.0:oob;
# - at the token endpoint the redirect_uri must equal the one stored with the
#   code (an out-of-band code may omit it — no redirect happened).
#
# Pure functions, no database.
module RedirectUri
  OOB = 'urn:ietf:wg:oauth:2.0:oob'
  LOOPBACK_HOSTS = %w[127.0.0.1 [::1] localhost].freeze

  module_function

  # Parse the stored redirect_uris column: JSON array / string, or a list
  # separated by whitespace or commas.
  def registered_list(raw)
    text = raw.to_s.strip
    return [] if text.empty?

    list = begin
      decoded = JSON.parse(text)
      if decoded.is_a?(Array) then decoded
      elsif decoded.is_a?(String) then [decoded]
      end
    rescue JSON::ParserError
      nil
    end
    list ||= text.split(/[\s,]+/)
    list.select { |u| u.is_a?(String) && !u.strip.empty? }.map(&:strip)
  end

  # Empty and the OOB constant are the same thing.
  def normalise(uri)
    s = uri.to_s
    s.empty? ? OOB : s
  end

  def registered?(requested, registered)
    want = normalise(requested)
    registered.any? { |c| c == want || loopback_match?(c, want) }
  end

  # sent = nil means "absent".
  def token_matches?(stored, sent)
    s = normalise(stored)
    return s == OOB if sent.nil? || sent.to_s.empty?

    s == normalise(sent)
  end

  def loopback_match?(registered, requested)
    r = URI.parse(registered)
    q = URI.parse(requested)
    return false unless r.scheme == 'http' && q.scheme == 'http'
    return false unless r.userinfo.nil? && q.userinfo.nil?
    return false unless r.fragment.nil? && q.fragment.nil?

    rh = r.host.to_s.downcase
    rh = "[#{rh}]" if rh.include?(':') && !rh.start_with?('[')
    qh = q.host.to_s.downcase
    qh = "[#{qh}]" if qh.include?(':') && !qh.start_with?('[')
    return false unless LOOPBACK_HOSTS.include?(rh) && rh == qh

    r.path == q.path && r.query == q.query
  rescue URI::InvalidURIError
    false
  end
end
