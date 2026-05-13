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
require_relative 'lib/modules/pro_module'
require_relative 'controllers/manifest'
require_relative 'controllers/oauth'
require_relative 'controllers/tools'
require_relative 'controllers/info'
require_relative 'middleware/auth'
require_relative 'middleware/rate_limit'

class DiscourseAiConnect < Sinatra::Base
  PLUGIN_VERSION = '1.2.0'

  LOGGER = Logger.new($stdout)
  LOGGER.progname = 'DiscourseAiConnect'

  set :port, ENV.fetch('PORT', 3086).to_i
  set :bind, ENV.fetch('BIND', '0.0.0.0')
  set :show_exceptions, false
  set :raise_errors, false
  set :dump_errors, false

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
    registry.register(AiConnect::Modules::ProModule.new, key: 'pro')
    AiConnect::ModuleRegistry.run_init_callbacks(registry)
    set :module_registry, registry
  end

  configure :production, :development do
    DB.init_schema
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
    redirect '/ai-connect'
  end

  get '/health' do
    { status: 'ok', service: 'discourse-ai-connect', version: PLUGIN_VERSION }.to_json
  end

  get '/api/ai-connect/manifest' do
    ManifestController.get(registry: settings.module_registry).to_json
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
    OAuthController.token(params, ip: client_ip).to_json
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
    tokens = DB.save_tokens('ai-agent-default', uid, 'read write',
                            source: 'generator', ip_address: client_ip)
    { access_token: tokens[:access], token_type: 'Bearer', expires_in: 3600 }.to_json
  end

  get '/api/ai-connect/admin/tokens' do
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')
    { tokens: DB.list_tokens }.to_json
  end

  delete '/api/ai-connect/admin/tokens/:prefix' do |prefix|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    halt 403, json_error('insufficient_scope') unless auth[:scope].to_s.split.include?('delete')
    ok = DB.revoke_token_by_prefix(prefix, revoked_by: auth[:uid])
    halt 404, json_error('not_found') unless ok
    { success: true }.to_json
  end

  post '/api/ai-connect/v1/tools/:tool_name' do |tool_name|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]

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
  end

  run! if app_file == $PROGRAM_NAME
end

DiscourseAiConnect.run! if __FILE__ == $PROGRAM_NAME
