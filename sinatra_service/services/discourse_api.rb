require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'time'

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

  # The privileged identity used ONLY for bridge-internal lookups (resolving a
  # token's uid to a username, checking admin status). Never used for tools.
  def self.api_user
    ENV.fetch('DISCOURSE_API_USER', 'system')
  end

  ACTING_USER_KEY = :ai_connect_discourse_api_username

  # SEC-00 permission ceiling: every tool call is made AS the token owner, so
  # Discourse's Guardian enforces that user's real permissions. Calls made
  # outside an as_user / as_system block fail closed (no implicit system).
  def self.as_user(username)
    raise ArgumentError, 'username required' if username.to_s.strip.empty?

    with_acting_user(username.to_s) { yield }
  end

  def self.as_system
    with_acting_user(api_user) { yield }
  end

  def self.acting_username
    Thread.current[ACTING_USER_KEY]
  end

  def self.with_acting_user(username)
    previous = Thread.current[ACTING_USER_KEY]
    Thread.current[ACTING_USER_KEY] = username
    yield
  ensure
    Thread.current[ACTING_USER_KEY] = previous
  end
  private_class_method :with_acting_user

  # Last request seen in stub mode — lets specs assert which Api-Username a
  # tool call would have used, without a live Discourse.
  class << self
    attr_accessor :last_stub_request
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
    username = acting_username
    if username.nil? || username.empty?
      LOGGER.error("Refusing Discourse API #{method.upcase} #{path}: no acting user (fail closed)")
      return { 'error' => 'no_acting_user', 'error_type' => 'forbidden',
               'message' => 'Discourse API call made without an acting user' }
    end

    if stub_mode?
      self.last_stub_request = { method: method, path: path, username: username }
      return stub_response(method, path, body, username)
    end

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
    req['Api-Username'] = username
    req['Content-Type'] = 'application/json'
    req.body = body.to_json if body && !body.empty?
    response = http.request(req)
    code = response.code.to_i
    parsed = JSON.parse(response.body)
    if parsed.is_a?(Hash) && !(200..299).cover?(code)
      parsed['error_type'] ||= "http_#{code}"
      parsed['http_status'] = code
    end
    note_upstream_failure("HTTP #{code}") if code >= 500
    parsed
  rescue JSON::ParserError => e
    LOGGER.error("Discourse API returned invalid JSON for #{method.upcase} #{path}: #{e.message}")
    # A non-JSON 4xx page is still Discourse's answer (not found / forbidden).
    return { 'error' => 'invalid_response', 'error_type' => "http_#{code}", 'http_status' => code } if code.to_i.between?(400, 499)

    note_upstream_failure('non-JSON response')
    { 'error' => 'invalid_response', 'error_type' => 'json_parse', 'message' => 'Discourse API returned non-JSON' }
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    LOGGER.error("Discourse API timeout for #{method.upcase} #{path}: #{e.message}")
    note_upstream_failure('timeout')
    { 'error' => 'timeout', 'error_type' => 'timeout', 'message' => e.message }
  rescue StandardError => e
    LOGGER.error("Discourse API error for #{method.upcase} #{path}: #{e.class}: #{e.message}")
    note_upstream_failure(e.class.name)
    { 'error' => e.message, 'error_type' => 'api_error' }
  end

  # Upstream failure tracking (1.2.6): list tools used to turn a Discourse
  # outage into an empty list with success=true. A tool call now records the
  # first server-side failure (5xx / timeout / non-JSON / connection error) and
  # ModuleBase turns the call into upstream_error (HTTP 502). 4xx answers are
  # NOT failures — they are Discourse's permission / not-found decisions.
  UPSTREAM_FAILURE_KEY = :ai_connect_upstream_failure

  def self.reset_upstream_failure!
    Thread.current[UPSTREAM_FAILURE_KEY] = nil
  end

  def self.upstream_failure
    Thread.current[UPSTREAM_FAILURE_KEY]
  end

  def self.note_upstream_failure(reason)
    Thread.current[UPSTREAM_FAILURE_KEY] ||= reason.to_s
  end

  # Used when DISCOURSE_STUB_MODE=1 (development / smoke tests without a real Discourse running)
  def self.stub_response(method, path, _body, username = nil)
    require_relative '../fixtures/stub_data'
    StubData.lookup(method, path, username)
  end
end

# Resolves a token's Discourse uid to the user the bridge must act as.
# The lookup itself runs as the privileged API user (admin endpoint); the
# result is cached briefly so tool calls don't add a round-trip each time.
module DiscourseUsers
  CACHE_TTL = Integer(ENV.fetch('AI_CONNECT_USER_CACHE_TTL', '60'))
  CACHE_MAX = 10_000
  @cache = {}
  @mutex = Mutex.new

  # Returns { id:, username:, admin:, moderator: } or nil (unknown, suspended,
  # inactive, staged, or lookup failure). Callers MUST fail closed on nil.
  def self.resolve(uid)
    uid = uid.to_i
    return nil unless uid.positive?

    now = Time.now.to_i
    cached = @mutex.synchronize { @cache[uid] }
    return cached[:user] if cached && cached[:expires_at] > now

    user = fetch(uid)
    if user
      @mutex.synchronize do
        @cache.clear if @cache.size >= CACHE_MAX
        @cache[uid] = { user: user, expires_at: now + CACHE_TTL }
      end
    end
    user
  end

  def self.admin?(uid)
    resolve(uid)&.dig(:admin) == true
  end

  def self.clear_cache!
    @mutex.synchronize { @cache.clear }
  end

  def self.fetch(uid)
    data = DiscourseApi.as_system { DiscourseApi.get("/admin/users/#{uid}.json") }
    return nil unless data.is_a?(Hash) && !data['error_type'] && !data['errors']

    username = data['username'].to_s
    return nil if username.empty? || data['id'].to_i != uid
    return nil if data['active'] == false || data['staged'] == true
    return nil if suspended?(data['suspended_till'])

    { id: uid, username: username, admin: data['admin'] == true, moderator: data['moderator'] == true }
  rescue StandardError => e
    DiscourseApi::LOGGER.error("User lookup failed for uid=#{uid}: #{e.class}")
    nil
  end
  private_class_method :fetch

  def self.suspended?(till)
    return false if till.nil? || till.to_s.empty?

    Time.parse(till.to_s) > Time.now
  rescue ArgumentError
    true
  end
  private_class_method :suspended?
end
