require 'sinatra/base'
require 'json'
require 'securerandom'
require 'digest'
require 'base64'
require 'pg'
require 'net/http'
require 'uri'
require 'logger'

require_relative 'services/db'
require_relative 'services/discourse_api'
require_relative 'lib/input_validator'
require_relative 'lib/module_base'
require_relative 'lib/module_registry'
require_relative 'lib/modules/core_module'
require_relative 'lib/modules/content_module'
require_relative 'lib/modules/community_module'
require_relative 'lib/pro_loader'
require_relative 'lib/confirmation'
require_relative 'controllers/manifest'
require_relative 'controllers/oauth'
require_relative 'controllers/tools'
require_relative 'controllers/info'
require_relative 'controllers/confirmations'
require_relative 'middleware/auth'
require_relative 'middleware/rate_limit'

class DiscourseAiConnect < Sinatra::Base
  PLUGIN_VERSION = '1.2.9'

  LOGGER = Logger.new($stdout)
  LOGGER.progname = 'DiscourseAiConnect'

  set :port, ENV.fetch('PORT', 3086).to_i
  # Loopback by default: the only legitimate caller of the X-Discourse-Uid
  # routes is the Discourse proxy on the same host. Override with BIND only
  # behind a reverse proxy you control.
  set :bind, ENV.fetch('BIND', '127.0.0.1')
  set :show_exceptions, false
  set :raise_errors, false
  set :dump_errors, false
  set :host_authorization, permitted_hosts: []

  def self.allowed_origins
    raw = ENV.fetch('ALLOWED_ORIGINS', '')
    return [] if raw.empty?
    raw.split(',').map(&:strip).reject(&:empty?)
  end

  def self.allow_any_origin?
    ENV['RACK_ENV'] != 'production' && allowed_origins.empty?
  end

  PROXY_SECRET_HEADER = 'HTTP_X_AI_CONNECT_PROXY_SECRET'

  def self.proxy_secret
    ENV.fetch('AI_CONNECT_PROXY_SECRET', '').to_s
  end

  configure do
    if proxy_secret.empty?
      LOGGER.warn('SECURITY: AI_CONNECT_PROXY_SECRET is not set — OAuth consent, token generation and ' \
                  'user/admin token routes that rely on X-Discourse-Uid will refuse every request (fail closed). ' \
                  'Set the same value in the sidecar env and the Discourse site setting ai_connect_proxy_secret.')
    elsif proxy_secret.bytesize < 32
      LOGGER.warn('SECURITY: AI_CONNECT_PROXY_SECRET is shorter than 32 bytes — use a long random value.')
    end
    unless %w[127.0.0.1 localhost ::1].include?(settings.bind.to_s)
      LOGGER.warn("SECURITY: sidecar bound to #{settings.bind} — keep it reachable only by the Discourse host.")
    end

    registry = AiConnect::ModuleRegistry.new
    registry.register(AiConnect::Modules::CoreModule.new, key: 'core')
    registry.register(AiConnect::Modules::ContentModule.new, key: 'content')
    registry.register(AiConnect::Modules::CommunityModule.new, key: 'community')
    AiConnect::ProLoader.load(registry)
    AiConnect::ModuleRegistry.run_init_callbacks(registry)
    set :module_registry, registry
  end

  configure :production, :development do
    DB.init_schema
    ConfirmationStore.init_schema

    # Daily cleanup scheduler — background thread, fires once per process lifetime
    # whenever CLEANUP_INTERVAL elapses.  Errors are swallowed so the process
    # never crashes due to a cleanup failure.
    Thread.new do
      loop do
        sleep 3600 # wake every hour; DB.should_run_cleanup? guards the 24 h window
        DB.run_cleanup rescue nil if DB.should_run_cleanup?
      end
    end
  end

  before do
    request.env['ai_connect.trusted_proxy'] = trusted_proxy?
    origin = request.env['HTTP_ORIGIN']
    allowed = self.class.allowed_origins
    if origin
      if allowed.include?(origin)
        response.headers['Access-Control-Allow-Origin'] = origin
        response.headers['Vary'] = 'Origin'
      elsif self.class.allow_any_origin?
        response.headers['Access-Control-Allow-Origin'] = origin
        response.headers['Vary'] = 'Origin'
      end
    elsif self.class.allow_any_origin?
      response.headers['Access-Control-Allow-Origin'] = '*'
    end
    response.headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type, X-Discourse-Uid'
    response.headers['Access-Control-Allow-Credentials'] = 'true' if origin && allowed.include?(origin)
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Referrer-Policy'] = 'no-referrer'
    content_type :json
  end

  options '*' do
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, DELETE, OPTIONS'
    halt 204
  end

  get '/' do
    base = ENV.fetch('DISCOURSE_AI_CONNECT_URL', '').sub(%r{/+\z}, '')
    redirect "#{base}/ai-connect"
  end

  get '/health' do
    { status: 'ok', service: 'discourse-ai-connect', version: PLUGIN_VERSION }.to_json
  end

  get '/api/ai-connect/manifest' do
    ManifestController.get(registry: settings.module_registry).to_json
  end

  get '/api/aiconnect-manifest' do
    ManifestController.get(registry: settings.module_registry).to_json
  end

  post '/api/aiconnect-oauth' do
    alias_redirect('/api/ai-connect/token', 307)
  end

  get '/api/aiconnect-tools' do
    tool_name = params['name'] || params['tool']
    halt 400, json_error('missing_tool_name') unless tool_name
    alias_redirect("/api/ai-connect/v1/tools/#{tool_name}?#{request.query_string}", 307)
  end

  post '/api/aiconnect-tools' do
    tool_name = params['name'] || params['tool'] || (JSON.parse(request.body.read)['name'] rescue nil)
    request.body.rewind
    halt 400, json_error('missing_tool_name') unless tool_name
    alias_redirect("/api/ai-connect/v1/tools/#{tool_name}?#{request.query_string}", 307)
  end

  get '/ai-connect' do
    content_type :html
    InfoController.page(request.env)
  end

  get '/oauth/authorize' do
    rate_check = RateLimitMiddleware.check_oauth(client_ip)
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]
    halt 503, json_error('proxy_secret_not_configured') if self.class.proxy_secret.empty?
    content_type :html
    page = OAuthController.authorize(params, request.env)
    # 1.2.9: a refused request is an error page with HTTP 400 (was 200).
    status 400 if page.is_a?(OAuthController::ErrorPage)
    page
  end

  post '/oauth/authorize' do
    rate_check = RateLimitMiddleware.check_oauth(client_ip)
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]
    require_trusted_proxy!
    # The Discourse proxy forwards the consent as a JSON body; Sinatra params
    # only carry form-encoded fields, so merge both (form values win).
    json_body = parse_json(request.body.read)
    request.body.rewind
    consent = json_body.is_a?(Hash) ? json_body.merge(params) : params
    result = OAuthController.handle_consent(consent, request.env)
    if result[:redirect]
      redirect result[:redirect]
    else
      status 400
      result.to_json
    end
  end

  post '/api/ai-connect/token' do
    rate_check = RateLimitMiddleware.check_token_endpoint(client_ip)
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]
    # Sinatra params omit JSON bodies (only form-encoded); agents POST JSON here.
    json_body = parse_json(request.body.read)
    request.body.rewind
    input = json_body.is_a?(Hash) ? json_body.merge(params) : params
    result = OAuthController.token(input, ip: client_ip)
    # RFC 6749 §5.1/§5.2 (1.2.9): token responses are never cached; an error is
    # HTTP 400 (401 + WWW-Authenticate for invalid_client), never 200.
    headers 'Cache-Control' => 'no-store', 'Pragma' => 'no-cache'
    if result[:error]
      code = OAuthController.token_error_status(result[:error])
      headers 'WWW-Authenticate' => 'Basic realm="ai-connect"' if code == 401
      status code
    end
    result.to_json
  end

  # RFC 7009 token revocation (Servio SPEC §5.2). Deliberately unauthenticated:
  # possession of the token is the authorisation (public PKCE clients). Accepts
  # form-urlencoded and JSON. 200 for any well-formed request, including unknown
  # or already-revoked tokens, so the endpoint cannot be used to probe tokens.
  post '/api/ai-connect/revoke' do
    json_body = request.media_type == 'application/json' ? parse_json(request.body.read) : {}
    request.body.rewind
    input = json_body.is_a?(Hash) ? json_body.merge(params) : params
    token = input['token'].to_s.strip
    halt 400, json_error('invalid_request', error_description: 'token is required') if token.empty?

    hint = input['token_type_hint'].is_a?(String) ? input['token_type_hint'] : nil
    found = DB.revoke_pair(token, hint: hint)
    # Audit trail: never log the token value — only an 8-char prefix.
    LOGGER.info("oauth.revoke prefix=#{token[0, 8]}... found=#{found} hint=#{hint || '-'}")
    { revoked: true }.to_json
  end

  post '/api/ai-connect/generate-token' do
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('not_authenticated') unless uid

    request.body.rewind
    body = JSON.parse(request.body.read) rescue {}
    body = {} unless body.is_a?(Hash)
    scope = requested_scope(body['scope'], uid)
    # Only a pre-registered client id is recorded on the token; anything else
    # (typo, made-up name) falls back to the generic generator client.
    requested_client = DB.get_client(body['client_id'].to_s.strip) unless body['client_id'].to_s.strip.empty?
    client_id = requested_client ? requested_client['client_id'] : 'ai-agent-default'

    tokens = DB.save_tokens(client_id, uid, scope,
                            source: 'generator', ip_address: client_ip)
    {
      access_token: tokens[:access],
      refresh_token: tokens[:refresh],
      token_type: 'Bearer',
      expires_in: 3600,
      scope: scope
    }.to_json
  end

  post '/api/ai-connect/generate-prompt' do
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('not_authenticated') unless uid

    request.body.rewind
    body = JSON.parse(request.body.read) rescue {}
    body = {} unless body.is_a?(Hash)
    scope = requested_scope(body['scope'], uid)

    tokens = DB.save_tokens('ai-agent-default', uid, scope,
                            source: 'generator', ip_address: client_ip)
    site_name = ENV.fetch('DISCOURSE_SITE_NAME', 'Discourse Forum')
    prompt = InfoController.build_prompt(tokens[:access], tokens[:refresh], site_name, settings.module_registry)
    {
      access_token: tokens[:access],
      refresh_token: tokens[:refresh],
      expires_in: 3600,
      refresh_token_expires_in: 2592000,
      prompt: prompt
    }.to_json
  end

  # ---------------------------------------------------------------------------
  # Admin — token management. Requires a Discourse ADMIN, checked via the
  # Discourse API (cached <= AI_CONNECT_USER_CACHE_TTL s), not just a scope: either a Bearer token with `delete` scope
  # whose owner is an admin, or the trusted Discourse proxy acting for an admin.
  # ---------------------------------------------------------------------------

  # GET /api/ai-connect/admin/tokens[?filter=active|unused|inactive|expired|revoked]
  get '/api/ai-connect/admin/tokens' do
    auth = require_admin!

    filter = params['filter']
    { tokens: DB.list_tokens(filter: filter) }.to_json
  end

  # DELETE /api/ai-connect/admin/tokens/:prefix — revoke single token by prefix
  delete '/api/ai-connect/admin/tokens/:prefix' do |prefix|
    auth = require_admin!

    ok = DB.revoke_token_by_prefix(prefix, revoked_by: auth[:uid])
    halt 404, json_error('not_found') unless ok
    { success: true }.to_json
  end

  # POST /api/ai-connect/admin/tokens/bulk-revoke
  # body: { "filter": "unused|inactive|all", "days": N (optional) }
  post '/api/ai-connect/admin/tokens/bulk-revoke' do
    auth = require_admin!

    body = parse_json(request.body.read)
    filter = body['filter'].to_s
    days   = body['days']&.to_i

    count = case filter
    when 'unused'
      DB.revoke_unused(days: (days && days > 0 ? days : nil), revoked_by: auth[:uid])
    when 'inactive'
      DB.revoke_inactive(days: (days && days > 0 ? days : DB::INACTIVE_DAYS), revoked_by: auth[:uid])
    when 'all'
      DB.list_tokens(filter: 'active').reduce(0) do |n, row|
        n + (DB.revoke_token_by_prefix(row['token_prefix'], revoked_by: auth[:uid]) ? 1 : 0)
      end
    else
      halt 422, json_error('invalid_filter', message: "filter must be unused, inactive, or all")
    end

    { success: true, revoked: count }.to_json
  end

  # GET /api/ai-connect/admin/users/:uid/tokens[?filter=...]
  get '/api/ai-connect/admin/users/:uid/tokens' do |uid|
    auth = require_admin!

    filter = params['filter']
    { tokens: DB.list_tokens_for_user(uid.to_i, filter: filter) }.to_json
  end

  post '/api/ai-connect/admin/users/:uid/block' do |uid|
    auth = require_admin!

    DB.block_user(uid.to_i, auth[:uid])
    { success: true, user_id: uid.to_i, blocked: true }.to_json
  end

  delete '/api/ai-connect/admin/users/:uid/block' do |uid|
    auth = require_admin!

    DB.unblock_user(uid.to_i)
    { success: true, user_id: uid.to_i, blocked: false }.to_json
  end

  post '/api/ai-connect/admin/users/:uid/unblock' do |uid|
    auth = require_admin!

    DB.unblock_user(uid.to_i)
    { success: true, user_id: uid.to_i, blocked: false }.to_json
  end

  get '/api/ai-connect/admin/users/:uid/blocked' do |uid|
    auth = require_admin!

    { user_id: uid.to_i, blocked: DB.user_blocked?(uid.to_i) }.to_json
  end

  post '/api/ai-connect/admin/emergency-revoke-all' do
    auth = require_admin!

    count = DB.revoke_all_tokens(revoked_by: auth[:uid])
    { success: true, revoked: count }.to_json
  end

  # ---------------------------------------------------------------------------
  # User — own-token management (identified by X-Discourse-Uid header,
  # set by the Discourse proxy on behalf of the logged-in user)
  # ---------------------------------------------------------------------------

  # GET /api/ai-connect/tokens[?filter=...]
  get '/api/ai-connect/tokens' do
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('not_authenticated') unless uid

    filter = params['filter']
    { tokens: DB.list_tokens_for_user(uid, filter: filter) }.to_json
  end

  # DELETE /api/ai-connect/tokens/:prefix — user revokes one of their own tokens
  delete '/api/ai-connect/tokens/:prefix' do |prefix|
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('not_authenticated') unless uid

    reg = DB.list_tokens_for_user(uid).find { |r| r['token_prefix'] == prefix }
    halt 404, json_error('not_found') unless reg

    ok = DB.revoke_token_by_prefix(prefix, revoked_by: uid)
    halt 404, json_error('not_found') unless ok
    { success: true }.to_json
  end

  # POST /api/ai-connect/tokens/bulk-revoke
  # body: { "filter": "unused|inactive|all" }
  post '/api/ai-connect/tokens/bulk-revoke' do
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('not_authenticated') unless uid

    body   = parse_json(request.body.read)
    filter = body['filter'].to_s
    days   = body['days']&.to_i

    unless %w[unused inactive all].include?(filter)
      halt 422, json_error('invalid_filter', message: "filter must be unused, inactive, or all")
    end

    tokens = DB.list_tokens_for_user(uid, filter: filter == 'all' ? 'active' : filter)
    count  = tokens.reduce(0) do |n, row|
      n + (DB.revoke_token_by_prefix(row['token_prefix'], revoked_by: uid) ? 1 : 0)
    end

    { success: true, revoked: count }.to_json
  end

  # ---------------------------------------------------------------------------
  # Tools proxy
  # ---------------------------------------------------------------------------

  get '/api/ai-connect/v1/tools/:tool_name' do |tool_name|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]

    halt 403, json_error('user_blocked', message: 'User is blocked from API access') if DB.user_blocked?(auth[:uid])

    required_scope = settings.module_registry.tool_required_scope(tool_name)
    halt 404, json_error('tool_not_found') if required_scope.nil?
    halt 405, json_error('method_not_allowed', message: 'This tool requires POST') unless required_scope == 'read'
    require_tool_scope!(auth, required_scope)

    rate_check = RateLimitMiddleware.check_tool(auth[:token])
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]

    excluded = %w[tool_name splat captures]
    args = if params['arguments']
      begin; JSON.parse(params['arguments']); rescue JSON::ParserError; {}; end
    else
      params.to_h.reject { |k, _| excluded.include?(k.to_s) }
    end

    result = execute_as_owner(tool_name, args, auth)
    has_error = result.is_a?(Hash) && result.key?(:error)
    status tool_error_status(result[:error]) if has_error
    { success: !has_error, data: result }.to_json
  end

  post '/api/ai-connect/v1/tools/:tool_name' do |tool_name|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]

    halt 403, json_error('user_blocked', message: 'User is blocked from API access') if DB.user_blocked?(auth[:uid])

    required_scope = settings.module_registry.tool_required_scope(tool_name)
    halt 404, { success: false, data: { error: 'tool_not_found' } }.to_json if required_scope.nil?
    require_tool_scope!(auth, required_scope)

    rate_check = RateLimitMiddleware.check_tool(auth[:token])
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]

    body_str = request.body.read
    params_json = parse_json(body_str)
    params_json = {} unless params_json.is_a?(Hash)
    result = execute_as_owner(tool_name, params_json, auth)
    if result.is_a?(Hash) && result[:error] == 'confirmation_required' && result[:confirmation_envelope]
      status 202
      return result[:confirmation_envelope].to_json
    end
    has_error = result.is_a?(Hash) && result.key?(:error)
    status tool_error_status(result[:error]) if has_error
    { success: !has_error, data: result }.to_json
  end

  # ---------------------------------------------------------------------------
  # user-confirm-v1 (1.2.7)
  # ---------------------------------------------------------------------------

  # Agent: status of a confirmation it asked for (same user only). Reading it never executes anything.
  get '/api/ai-connect/v1/confirmations/:id' do |id|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]

    action = ConfirmationStore.find(id)
    halt 404, { success: false, data: { error: 'confirmation_not_found' } }.to_json if action.nil? || action['uid'] != auth[:uid]

    ConfirmationStore.sweep!
    action = ConfirmationStore.find(id)
    ConfirmationStore.mark_delivered(id) if %w[executed failed].include?(action['status'])
    { success: true, data: AiConnect::Confirmation.status_payload(action) }.to_json
  end

  # Human step — reached ONLY through the Discourse proxy (shared secret + the signed-in user's id).
  # The Discourse controller refuses API-key / user-API-key / Authorization requests and checks CSRF.
  get '/api/ai-connect/confirmations/page' do
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('login_required') unless uid

    content_type :html
    ConfirmationsController.page(uid, confirmation_page_opts.merge(focus: params['confirmation_id']))
  end

  post '/api/ai-connect/confirmations/decide' do
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('login_required') unless uid

    content_type :html
    body = parse_json(request.body.read)
    body = {} unless body.is_a?(Hash)
    status_code, html = ConfirmationsController.decide(uid, body, settings.module_registry, confirmation_page_opts)
    status status_code
    html
  end

  post '/api/ai-connect/confirmations/autonomy/revoke' do
    require_trusted_proxy!
    uid = discourse_uid
    halt 401, json_error('login_required') unless uid

    content_type :html
    body = parse_json(request.body.read)
    body = {} unless body.is_a?(Hash)
    ConfirmationsController.revoke_autonomy(uid, body['grant_id'], confirmation_page_opts)
  end

  # ---------------------------------------------------------------------------
  # Error handlers
  # ---------------------------------------------------------------------------

  error JSON::ParserError do
    status 400
    json_error('invalid_json', message: env['sinatra.error']&.message)
  end

  error do |e|
    LOGGER.error("Unhandled error #{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
    status 500
    json_error('internal_error', message: ENV['RACK_ENV'] == 'production' ? 'Internal server error' : e.message)
  end

  helpers do
    def client_ip
      request.env['HTTP_X_FORWARDED_FOR']&.split(',')&.first&.strip || request.ip || 'unknown'
    end

    # True only when the request carries the shared secret the Discourse proxy
    # sends (constant-time compare). Without it X-Discourse-Uid is ignored.
    def trusted_proxy?
      secret = self.class.proxy_secret
      return false if secret.empty?

      given = request.env[DiscourseAiConnect::PROXY_SECRET_HEADER].to_s
      return false if given.empty?

      Rack::Utils.secure_compare(Digest::SHA256.hexdigest(secret), Digest::SHA256.hexdigest(given))
    end

    def require_trusted_proxy!
      halt 503, json_error('proxy_secret_not_configured') if self.class.proxy_secret.empty?
      halt 403, json_error('untrusted_proxy') unless request.env['ai_connect.trusted_proxy'] == true
    end

    def discourse_uid
      return nil unless request.env['ai_connect.trusted_proxy'] == true

      uid = request.env['HTTP_X_DISCOURSE_UID']&.to_i
      uid && uid.positive? ? uid : nil
    end

    # Default "read write"; unknown scopes dropped; delete/admin only for admins.
    def requested_scope(raw, uid)
      raw = raw.to_s.strip.empty? ? 'read write' : raw.to_s
      OAuthController.clamp_scope(OAuthController.sanitize_scope(raw), uid)
    end

    def require_tool_scope!(auth, required_scope)
      return if AiConnect::ModuleBase.scope_grants?(auth[:scope], required_scope)

      halt 403, { success: false,
                  data: { error: 'insufficient_scope', message: "This tool requires #{required_scope} scope" } }.to_json
    end

    # SEC-00: run the tool AS the token owner. Unresolvable owner = 403; there
    # is no fallback to the system user.
    def execute_as_owner(tool_name, args, auth)
      owner = DiscourseUsers.resolve(auth[:uid])
      unless owner
        LOGGER.warn("tool #{tool_name} refused: token owner uid=#{auth[:uid]} could not be resolved")
        halt 403, { success: false, data: { error: 'user_not_permitted',
                                            message: 'Token owner could not be resolved to an active Discourse user' } }.to_json
      end
      extra = { client_id: auth[:client_id], token_prefix: auth[:token] ? DB.token_prefix(auth[:token]) : nil, ip: client_ip }
      DiscourseApi.as_user(owner[:username]) do
        ToolsController.execute(tool_name, args, auth[:uid], auth[:scope], extra: extra)
      end
    end

    # Headers the Discourse proxy adds for the confirmation page (CSRF token of the session, base path, locale).
    def confirmation_page_opts
      { csrf: request.env['HTTP_X_AI_CONNECT_CSRF'].to_s, base_path: request.env['HTTP_X_AI_CONNECT_BASE_PATH'].to_s,
        locale: request.env['HTTP_X_AI_CONNECT_LOCALE'].to_s, ip: client_ip }
    end

    # Admin routes: Discourse admin status is checked live (as system) for the
    # acting identity. Returns { uid: } for audit fields.
    def require_admin!
      header = request.env['HTTP_AUTHORIZATION'].to_s
      if header.start_with?('Bearer ')
        auth = AuthMiddleware.require_bearer(request)
        halt 401, auth.to_json if auth[:error]
        halt 403, json_error('insufficient_scope') unless AiConnect::ModuleBase.scope_grants?(auth[:scope], 'delete')
        halt 403, json_error('admin_required') unless DiscourseUsers.admin?(auth[:uid])
        return auth
      end

      if request.env['ai_connect.trusted_proxy'] == true && (uid = discourse_uid)
        halt 403, json_error('admin_required') unless DiscourseUsers.admin?(uid)
        return { uid: uid }
      end

      halt 401, { error: 'unauthorized', error_description: 'Bearer token required' }.to_json
    end

    # Tool error code -> HTTP status. A tool error must never travel as 200
    # (agents read 200 as success). Unknown codes = 400 (bad request).
    TOOL_ERROR_STATUS = {
      'tool_not_found' => 404, 'not_found' => 404, 'insufficient_scope' => 403,
      'forbidden' => 403, 'invalid_params' => 400, 'not_implemented' => 501,
      'upstream_error' => 502,
      # user-confirm-v1 (1.2.7)
      'confirmation_rejected' => 410, 'confirmation_expired' => 410, 'confirmation_mismatch' => 409,
      'confirmation_not_found' => 404, 'confirmation_unavailable' => 403, 'bridge_update_required' => 501,
      'user_blocked' => 403, 'token_revoked' => 403, 'user_not_permitted' => 403
    }.freeze

    def tool_error_status(code)
      TOOL_ERROR_STATUS.fetch(code.to_s, 400)
    end

    def json_error(code, **extra)
      { error: code, **extra }.to_json
    end

    def parse_json(body_str)
      return {} if body_str.nil? || body_str.strip.empty?
      JSON.parse(body_str)
    rescue JSON::ParserError => e
      LOGGER.warn("Invalid JSON body: #{e.message}")
      {}
    end

    # Redirect Location must carry the public base (e.g. .../discourse); Sinatra's
    # to() builds an app-root path that drops the reverse-proxy prefix -> 404.
    def alias_redirect(path, code)
      base = ENV.fetch('DISCOURSE_AI_CONNECT_URL', '').sub(%r{/+\z}, '')
      redirect(base.empty? ? to(path) : "#{base}#{path}", code)
    end
  end

  run! if app_file == $PROGRAM_NAME
end

DiscourseAiConnect.run! if __FILE__ == $PROGRAM_NAME
