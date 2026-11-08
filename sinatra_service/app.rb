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
require_relative 'lib/pro_loader'
require_relative 'controllers/manifest'
require_relative 'controllers/oauth'
require_relative 'controllers/tools'
require_relative 'controllers/info'
require_relative 'middleware/auth'
require_relative 'middleware/rate_limit'

class DiscourseAiConnect < Sinatra::Base
  PLUGIN_VERSION = '1.2.1'

  LOGGER = Logger.new($stdout)
  LOGGER.progname = 'DiscourseAiConnect'

  set :port, ENV.fetch('PORT', 3086).to_i
  set :bind, ENV.fetch('BIND', '0.0.0.0')
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

  configure do
    registry = AiConnect::ModuleRegistry.new
    registry.register(AiConnect::Modules::CoreModule.new, key: 'core')
    registry.register(AiConnect::Modules::ContentModule.new, key: 'content')
    AiConnect::ProLoader.load(registry)
    AiConnect::ModuleRegistry.run_init_callbacks(registry)
    set :module_registry, registry
  end

  configure :production, :development do
    DB.init_schema

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
    content_type :html
    OAuthController.authorize(params, request.env)
  end

  post '/oauth/authorize' do
    rate_check = RateLimitMiddleware.check_oauth(client_ip)
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]
    result = OAuthController.handle_consent(params, request.env)
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
    OAuthController.token(json_body.merge(params), ip: client_ip).to_json
  end

  post '/api/ai-connect/revoke' do
    token = request.env['HTTP_AUTHORIZATION']&.sub(/^Bearer /, '')
    revoker = request.env['HTTP_X_DISCOURSE_UID']&.to_i
    DB.revoke_token(token, revoked_by: revoker) if token
    { success: true }.to_json
  end

  post '/api/ai-connect/generate-token' do
    uid = request.env['HTTP_X_DISCOURSE_UID']&.to_i
    halt 401, json_error('not_authenticated') unless uid && uid.positive?

    body = JSON.parse(request.body.read) rescue {}
    scope = body['scope'].to_s.strip.empty? ? 'read write' : body['scope'].to_s
    client_id = body['client_id'].to_s.strip.empty? ? 'ai-agent-default' : body['client_id'].to_s

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
    uid = request.env['HTTP_X_DISCOURSE_UID']&.to_i
    halt 401, json_error('not_authenticated') unless uid && uid.positive?

    body = JSON.parse(request.body.read) rescue {}
    scope = body['scope'].to_s.strip.empty? ? 'read write' : body['scope'].to_s

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
  # Admin — token management (requires Bearer + delete scope)
  # ---------------------------------------------------------------------------

  # GET /api/ai-connect/admin/tokens[?filter=active|unused|inactive|expired|revoked]
  get '/api/ai-connect/admin/tokens' do
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    filter = params['filter']
    { tokens: DB.list_tokens(filter: filter) }.to_json
  end

  # DELETE /api/ai-connect/admin/tokens/:prefix — revoke single token by prefix
  delete '/api/ai-connect/admin/tokens/:prefix' do |prefix|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    ok = DB.revoke_token_by_prefix(prefix, revoked_by: auth[:uid])
    halt 404, json_error('not_found') unless ok
    { success: true }.to_json
  end

  # POST /api/ai-connect/admin/tokens/bulk-revoke
  # body: { "filter": "unused|inactive|all", "days": N (optional) }
  post '/api/ai-connect/admin/tokens/bulk-revoke' do
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

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
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    filter = params['filter']
    { tokens: DB.list_tokens_for_user(uid.to_i, filter: filter) }.to_json
  end

  post '/api/ai-connect/admin/users/:uid/block' do |uid|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    DB.block_user(uid.to_i, auth[:uid])
    { success: true, user_id: uid.to_i, blocked: true }.to_json
  end

  delete '/api/ai-connect/admin/users/:uid/block' do |uid|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    DB.unblock_user(uid.to_i)
    { success: true, user_id: uid.to_i, blocked: false }.to_json
  end

  post '/api/ai-connect/admin/users/:uid/unblock' do |uid|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    DB.unblock_user(uid.to_i)
    { success: true, user_id: uid.to_i, blocked: false }.to_json
  end

  get '/api/ai-connect/admin/users/:uid/blocked' do |uid|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    { user_id: uid.to_i, blocked: DB.user_blocked?(uid.to_i) }.to_json
  end

  post '/api/ai-connect/admin/emergency-revoke-all' do
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')

    count = DB.revoke_all_tokens(revoked_by: auth[:uid])
    { success: true, revoked: count }.to_json
  end

  # ---------------------------------------------------------------------------
  # User — own-token management (identified by X-Discourse-Uid header,
  # set by the Discourse proxy on behalf of the logged-in user)
  # ---------------------------------------------------------------------------

  # GET /api/ai-connect/tokens[?filter=...]
  get '/api/ai-connect/tokens' do
    uid = discourse_uid
    halt 401, json_error('not_authenticated') unless uid

    filter = params['filter']
    { tokens: DB.list_tokens_for_user(uid, filter: filter) }.to_json
  end

  # DELETE /api/ai-connect/tokens/:prefix — user revokes one of their own tokens
  delete '/api/ai-connect/tokens/:prefix' do |prefix|
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

    rate_check = RateLimitMiddleware.check_tool(auth[:token])
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]

    excluded = %w[tool_name splat captures]
    args = if params['arguments']
      begin; JSON.parse(params['arguments']); rescue JSON::ParserError; {}; end
    else
      params.to_h.reject { |k, _| excluded.include?(k.to_s) }
    end

    result = ToolsController.execute(tool_name, args, auth[:uid], auth[:scope])
    has_error = result.is_a?(Hash) && result.key?(:error)
    if has_error
      status 404 if result[:error] == 'tool_not_found'
      status 403 if result[:error] == 'insufficient_scope'
      status 400 if result[:error] == 'invalid_params'
    end
    { success: !has_error, data: result }.to_json
  end

  post '/api/ai-connect/v1/tools/:tool_name' do |tool_name|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]

    halt 403, json_error('user_blocked', message: 'User is blocked from API access') if DB.user_blocked?(auth[:uid])

    rate_check = RateLimitMiddleware.check_tool(auth[:token])
    halt 429, json_error('rate_limit_exceeded', window: rate_check[:window]) if rate_check[:limited]

    body_str = request.body.read
    params_json = parse_json(body_str)
    result = ToolsController.execute(tool_name, params_json, auth[:uid], auth[:scope])
    has_error = result.is_a?(Hash) && result.key?(:error)
    if has_error
      status 404 if result[:error] == 'tool_not_found'
      status 403 if result[:error] == 'insufficient_scope'
      status 400 if result[:error] == 'invalid_params'
    end
    { success: !has_error, data: result }.to_json
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

    def discourse_uid
      uid = request.env['HTTP_X_DISCOURSE_UID']&.to_i
      uid && uid.positive? ? uid : nil
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
