# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module AiConnect
  class BridgeClient
    class BridgeError < StandardError; end

    DEFAULT_TIMEOUT = 10

    def self.bridge_url
      SiteSetting.ai_connect_bridge_url.to_s.sub(%r{/$}, '')
    end

    # Shared secret proving to the bridge that a request (and the
    # X-Discourse-Uid it carries) comes from this Discourse instance.
    def self.proxy_secret
      secret = SiteSetting.ai_connect_proxy_secret.to_s if SiteSetting.respond_to?(:ai_connect_proxy_secret)
      secret = ENV['AI_CONNECT_PROXY_SECRET'].to_s if secret.nil? || secret.empty?
      secret
    end

    def self.proxy(method, path, user: nil, params: nil, body: nil, headers: {})
      uri = URI("#{bridge_url}#{path}")
      uri.query = URI.encode_www_form(params) if params && !params.empty?

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl       = (uri.scheme == 'https')
      http.open_timeout  = DEFAULT_TIMEOUT
      http.read_timeout  = DEFAULT_TIMEOUT

      req = build_request(method, uri, body)
      secret = proxy_secret
      if secret.empty?
        Rails.logger.warn('[AiConnect] ai_connect_proxy_secret is not set — the bridge will refuse user-bound requests')
      else
        req['X-AI-Connect-Proxy-Secret'] = secret
      end
      req['X-Discourse-Uid'] = user.id.to_s if user
      req['X-Forwarded-For'] = 'discourse-plugin'
      headers.each { |k, v| req[k] = v.to_s }

      response = http.request(req)
      { status: response.code.to_i, body: response.body, headers: response.each_header.to_h }
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      raise BridgeError, "Bridge timeout: #{e.message}"
    rescue StandardError => e
      raise BridgeError, "Bridge error: #{e.message}"
    end

    def self.notify_login(user_id)
      proxy(:post, '/api/ai-connect/internal/login', body: { uid: user_id })
    rescue BridgeError => e
      Rails.logger.warn("[AiConnect] Bridge notify_login failed: #{e.message}")
      nil
    end

    def self.build_request(method, uri, body)
      req = case method
            when :get  then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            when :put  then Net::HTTP::Put.new(uri)
            when :delete then Net::HTTP::Delete.new(uri)
            else
              raise ArgumentError, "Unsupported method: #{method}"
            end
      if body
        req['Content-Type'] = 'application/json'
        req.body = body.is_a?(String) ? body : body.to_json
      end
      req
    end
  end
end
