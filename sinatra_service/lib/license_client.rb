# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'
require_relative '../services/db'

# LicenseClient — resolves the Pro edition from a verified license key.
#
# Validates a key against the Servio license server and caches the verdict in
# ai_connect_meta. Mirrors the XenForo/Ghost/Moodle/PrestaShop model: a valid
# key unlocks Pro, an unreachable server degrades to the last cached verdict
# (fail-open so a paying customer is never hard-blocked by a network blip), and
# no key = free.
module AiConnect
  class LicenseClient
    API_URL       = 'https://goldnat.ai/api/licenses/public/validate'
    EXPECTED_SLUG = 'discourse-plugin'
    CACHE_KEY     = 'license_status'
    CACHE_TTL_MS  = 7 * 24 * 60 * 60 * 1000
    VALID_STATUSES = %w[valid valid_no_updates].freeze

    # Require matching plugin_slug so another plugin's license can't unlock this one.
    # error_cached is the fail-open network-blip verdict (no slug present) -> honored.
    def self.grants_pro(data)
      return false unless data
      return true if data['status'] == 'error_cached'

      VALID_STATUSES.include?(data['status']) && data['plugin_slug'] == EXPECTED_SLUG
    end

    def self.resolve_edition
      key = (ENV['AICONNECT_LICENSE_KEY'] || '').strip
      return 'free' if key.empty?

      cached = read_cache
      if cached && cached['checked_at'] && (now_ms - cached['checked_at'].to_i) < CACHE_TTL_MS
        return grants_pro(cached) ? 'pro' : 'free'
      end

      resp = call_server(key)
      if resp.nil?
        return grants_pro(cached) ? 'pro' : 'free' if cached

        write_cache('valid' => true, 'status' => 'error_cached')
        return 'pro'
      end

      write_cache(resp)
      grants_pro(resp) ? 'pro' : 'free'
    end

    def self.read_cache
      row = DB.conn.exec_params('SELECT value FROM ai_connect_meta WHERE key_name=$1', [CACHE_KEY]).first
      row && row['value'] ? JSON.parse(row['value']) : nil
    rescue StandardError
      nil
    end

    def self.write_cache(status)
      payload = JSON.generate(status.merge('checked_at' => now_ms))
      DB.conn.exec_params(
        'INSERT INTO ai_connect_meta (key_name, value, updated_at) VALUES ($1,$2,$3) ' \
        'ON CONFLICT (key_name) DO UPDATE SET value=EXCLUDED.value, updated_at=EXCLUDED.updated_at',
        [CACHE_KEY, payload, now_ms]
      )
    rescue StandardError
      nil
    end

    def self.call_server(key)
      url = ENV.fetch('AICONNECT_LICENSE_URL', API_URL)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = 10
      http.read_timeout = 10

      req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
      req.body = JSON.generate(
        license_key: key,
        domain: current_domain,
        addon_version: '1.0.0'
      )

      res = http.request(req)
      return nil unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    rescue StandardError
      nil
    end

    def self.current_domain
      base = ENV.fetch('DISCOURSE_AI_CONNECT_URL', '')
      URI.parse(base).host&.downcase || 'localhost'
    rescue StandardError
      'localhost'
    end

    def self.now_ms
      (Time.now.to_f * 1000).to_i
    end
  end
end
