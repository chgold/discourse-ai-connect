require 'sinatra/base'
require 'json'
require 'securerandom'
require 'digest'
require 'base64'
require 'pg'
require 'net/http'
require 'uri'

require_relative 'services/db'
require_relative 'services/discourse_api'
require_relative 'controllers/manifest'
require_relative 'controllers/oauth'
require_relative 'controllers/tools'
require_relative 'controllers/info'
require_relative 'middleware/auth'
require_relative 'middleware/rate_limit'

DB.init_schema

class DiscourseAiConnect < Sinatra::Base
  set :port, ENV.fetch('PORT', 3086).to_i
  set :bind, '0.0.0.0'
  set :show_exceptions, false

  before do
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type'
    content_type :json
  end

  options '*' do
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    halt 204
  end

  get '/api/ai-connect/manifest' do
    ManifestController.get.to_json
  end

  get '/ai-connect' do
    content_type :html
    InfoController.page(request.env)
  end

  get '/oauth/authorize' do
    content_type :html
    OAuthController.authorize(params, request.env)
  end

  post '/oauth/authorize' do
    OAuthController.handle_consent(params, request.env)
  end

  post '/api/ai-connect/token' do
    OAuthController.token(params).to_json
  end

  post '/api/ai-connect/revoke' do
    token = request.env['HTTP_AUTHORIZATION']&.sub(/^Bearer /, '')
    DB.revoke_token(token) if token
    { success: true }.to_json
  end

  post '/api/ai-connect/generate-token' do
    uid = request.env['HTTP_X_DISCOURSE_UID']&.to_i
    halt 401, { error: 'not_authenticated' }.to_json unless uid && uid > 0
    tokens = DB.save_tokens('ai-agent-default', uid, 'read write')
    { access_token: tokens[:access], token_type: 'Bearer', expires_in: 3600 }.to_json
  end

  post '/api/ai-connect/v1/tools/:tool_name' do |tool_name|
    auth = AuthMiddleware.require_bearer(request)
    halt 401, auth.to_json if auth[:error]
    RateLimitMiddleware.check(auth[:token])
    body_str = request.body.read
    params_json = begin; JSON.parse(body_str); rescue; {}; end
    result = ToolsController.execute(tool_name, params_json, auth[:uid], auth[:scope])
    status 404 if result[:error] == 'tool_not_found'
    status 403 if result[:error] == 'insufficient_scope'
    { success: !result.key?(:error), data: result }.to_json
  end

  error do |e|
    status 500
    { error: 'internal_error', message: e.message }.to_json
  end
end

DiscourseAiConnect.run!
