require 'net/http'
require 'uri'
require 'json'
require 'logger'

module DiscourseApi
  LOGGER = Logger.new($stdout)
  LOGGER.progname = 'DiscourseApi'

  class ApiError < StandardError
    attr_reader :code
    def initialize(message, code = nil)
      super(message)
      @code = code
    end
  end

  def self.base_url
    raw = ENV.fetch('DISCOURSE_URL', 'http://localhost:3086')
    # In production, force HTTPS to prevent token leak / MITM
    if ENV['RACK_ENV'] == 'production' && raw.start_with?('http://') &&
       !raw.match?(/\Ahttp:\/\/(localhost|127\.0\.0\.1|0\.0\.0\.0)/)
      raw = raw.sub('http://', 'https://')
      LOGGER.warn("Upgrading DISCOURSE_URL to HTTPS for production")
    end
    raw
  end

  def self.api_key
    ENV.fetch('DISCOURSE_API_KEY', '')
  end

  def self.api_user
    ENV.fetch('DISCOURSE_API_USER', 'system')
  end

  def self.stub_mode?
    ENV['DISCOURSE_STUB_MODE'] == '1'
  end

  def self.get(path)
    call(:get, path)
  end

  def self.post(path, body = {})
    call(:post, path, body)
  end

  def self.put(path, body = {})
    call(:put, path, body)
  end

  def self.call(method, path, body = nil)
    return stub_response(method, path, body) if stub_mode?

    uri = URI("#{base_url}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.open_timeout = 5
    http.read_timeout = 15
    req = case method
          when :get  then Net::HTTP::Get.new(uri)
          when :post then Net::HTTP::Post.new(uri)
          when :put  then Net::HTTP::Put.new(uri)
          end
    req['Api-Key']      = api_key unless api_key.empty?
    req['Api-Username'] = api_user
    req['Content-Type'] = 'application/json'
    req.body = body.to_json if body && !body.empty?
    response = http.request(req)
    JSON.parse(response.body)
  rescue JSON::ParserError => e
    LOGGER.error("Discourse API returned invalid JSON for #{method.upcase} #{path}: #{e.message}")
    { 'error' => 'invalid_response', 'error_type' => 'json_parse', 'message' => 'Discourse API returned non-JSON' }
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    LOGGER.error("Discourse API timeout for #{method.upcase} #{path}: #{e.message}")
    { 'error' => 'timeout', 'error_type' => 'timeout', 'message' => e.message }
  rescue StandardError => e
    LOGGER.error("Discourse API error for #{method.upcase} #{path}: #{e.class}: #{e.message}")
    { 'error' => e.message, 'error_type' => 'api_error' }
  end

  # Used when DISCOURSE_STUB_MODE=1 (development / smoke tests without a real Discourse running)
  def self.stub_response(method, path, _body)
    require_relative '../fixtures/stub_data'
    StubData.lookup(method, path)
  end
end
