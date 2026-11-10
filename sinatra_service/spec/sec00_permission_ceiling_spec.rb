require_relative 'spec_helper'
require 'digest'
require 'base64'

# SEC-00 permission ceiling: a tool may never do more than the token-owning
# user could do natively in Discourse. Stub users (fixtures/stub_data.rb):
#   1 admin (admin) · 2 alice (member) · 3 bob (moderator) · 4 mallory (suspended)
RSpec.describe 'SEC-00 permission ceiling' do
  let(:verifier)  { 'v' * 64 }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }

  def tool_post(name, body, token)
    header 'Authorization', "Bearer #{token}"
    header 'Content-Type', 'application/json'
    post "/api/ai-connect/v1/tools/#{name}", body.to_json
  end

  def json
    JSON.parse(last_response.body)
  end

  def without_proxy_secret
    header PROXY_SECRET_HEADER_NAME, nil
  end

  describe 'exact scope-token matching' do
    it 'matches whole whitespace-separated tokens only' do
      expect(AiConnect::ModuleBase.scope_grants?('read write', 'write')).to be true
      expect(AiConnect::ModuleBase.scope_grants?("read\twrite", 'write')).to be true
      expect(AiConnect::ModuleBase.scope_grants?('rewrite', 'write')).to be false
      expect(AiConnect::ModuleBase.scope_grants?('readwrite', 'write')).to be false
      expect(AiConnect::ModuleBase.scope_grants?('readonly', 'read')).to be false
      expect(AiConnect::ModuleBase.scope_grants?(nil, 'read')).to be false
    end

    it 'POST tools route rejects a write tool for a "rewrite" scope before executing it' do
      token = DB.save_tokens('claude', 2, 'read rewrite')[:access]
      tool_post('discourse.createTopic', { title: 'T', raw: 'body', category_id: 1 }, token)
      expect(last_response.status).to eq(403)
      expect(json['data']['error']).to eq('insufficient_scope')
      expect(DiscourseApi.last_stub_request).to be_nil
    end

    it 'POST tools route enforces required_scope for read tools too' do
      token = DB.save_tokens('claude', 2, 'write')[:access]
      tool_post('discourse.getCategories', {}, token)
      expect(last_response.status).to eq(403)
    end

    it 'ModuleBase#execute_tool enforces required_scope (defence in depth)' do
      mod = AiConnect::Modules::ProModule.new
      result = DiscourseApi.as_user('alice') do
        mod.execute_tool('createTopic', { 'title' => 'X', 'raw' => 'b', 'category_id' => 1 }, { scope: 'read rewrite' })
      end
      expect(result[:error]).to eq('insufficient_scope')
    end

    it 'manifest does not list write tools for a substring-only scope' do
      names = DiscourseAiConnect.settings.module_registry.all_tools(scope: 'read rewrite').map { |t| t[:name] }
      expect(names).to include('discourse.getCategories')
      expect(names).not_to include('discourse.createTopic')
    end
  end

  describe 'Discourse API calls are made as the token owner' do
    it 'sends Api-Username = token owner for a member' do
      token = DB.save_tokens('claude', 2, 'read')[:access]
      tool_post('discourse.getCategories', {}, token)
      expect(last_response.status).to eq(200)
      expect(DiscourseApi.last_stub_request[:username]).to eq('alice')
    end

    it 'sends Api-Username = token owner for a GET tool call' do
      token = DB.save_tokens('claude', 3, 'read')[:access]
      header 'Authorization', "Bearer #{token}"
      get '/api/ai-connect/v1/tools/discourse.getTopic', { topic_id: 101 }
      expect(last_response.status).to eq(200)
      expect(DiscourseApi.last_stub_request[:username]).to eq('bob')
    end

    it 'never acts as system for a tool call' do
      token = DB.save_tokens('claude', 1, 'read write')[:access]
      tool_post('discourse.getCategories', {}, token)
      expect(DiscourseApi.last_stub_request[:username]).to eq('admin')
      expect(DiscourseApi.last_stub_request[:username]).not_to eq('system')
    end

    it 'lets Discourse refuse a member editing someone else\'s post' do
      token = DB.save_tokens('claude', 2, 'read write')[:access]
      tool_post('discourse.editPost', { post_id: 1001, raw: 'hijacked' }, token) # post by admin
      expect(json['success']).to be false
      expect(json['data']['error_type']).to eq('invalid_access')
      expect(DiscourseApi.last_stub_request[:username]).to eq('alice')
    end

    it 'allows the member to edit their own post' do
      token = DB.save_tokens('claude', 2, 'read write')[:access]
      tool_post('discourse.editPost', { post_id: 1002, raw: 'fixed typo' }, token) # post by alice
      expect(json['success']).to be true
      expect(json['data']['edited']).to be true
    end

    it 'fails closed (403) when the token owner cannot be resolved' do
      token = DB.save_tokens('claude', 999, 'read write')[:access]
      tool_post('discourse.getCategories', {}, token)
      expect(last_response.status).to eq(403)
      expect(json['data']['error']).to eq('user_not_permitted')
      expect(DiscourseApi.last_stub_request[:path]).to start_with('/admin/users/') # only the lookup ran
    end

    it 'fails closed (403) for a suspended token owner' do
      token = DB.save_tokens('claude', 4, 'read')[:access]
      tool_post('discourse.getCategories', {}, token)
      expect(last_response.status).to eq(403)
    end

    it 'refuses Discourse API calls made without an acting user' do
      result = DiscourseApi.get('/categories.json')
      expect(result['error']).to eq('no_acting_user')
      expect(DiscourseApi.last_stub_request).to be_nil
    end
  end

  describe 'token-admin routes require a Discourse admin' do
    let!(:victim) { DB.save_tokens('chatgpt', 2, 'read write') }

    it 'rejects a non-admin Bearer token even with delete scope' do
      token = DB.save_tokens('claude', 2, 'read write delete')[:access]
      header 'Authorization', "Bearer #{token}"
      get '/api/ai-connect/admin/tokens'
      expect(last_response.status).to eq(403)
      expect(json['error']).to eq('admin_required')
    end

    it 'rejects emergency-revoke-all from a non-admin and leaves tokens active' do
      token = DB.save_tokens('claude', 3, 'read write delete')[:access] # moderator, not admin
      header 'Authorization', "Bearer #{token}"
      post '/api/ai-connect/admin/emergency-revoke-all'
      expect(last_response.status).to eq(403)
      expect(DB.get_token(victim[:access])).not_to be_nil
    end

    it 'rejects a non-admin blocking a user' do
      token = DB.save_tokens('claude', 2, 'read write delete')[:access]
      header 'Authorization', "Bearer #{token}"
      post '/api/ai-connect/admin/users/1/block'
      expect(last_response.status).to eq(403)
      expect(DB.user_blocked?(1)).to be false
    end

    it 'accepts an admin Bearer token with delete scope' do
      token = DB.save_tokens('claude', 1, 'read write delete')[:access]
      header 'Authorization', "Bearer #{token}"
      get '/api/ai-connect/admin/tokens'
      expect(last_response.status).to eq(200)
    end

    it 'accepts the trusted proxy acting for an admin, rejects it for a member' do
      header 'X-Discourse-Uid', '1'
      get '/api/ai-connect/admin/tokens'
      expect(last_response.status).to eq(200)

      header 'X-Discourse-Uid', '2'
      get '/api/ai-connect/admin/tokens'
      expect(last_response.status).to eq(403)
    end

    it 'ignores a forged admin X-Discourse-Uid without the proxy secret' do
      without_proxy_secret
      header 'X-Discourse-Uid', '1'
      get '/api/ai-connect/admin/tokens'
      expect(last_response.status).to eq(401)
    end
  end

  describe 'proxy shared secret' do
    it 'refuses user token routes without the secret' do
      without_proxy_secret
      header 'X-Discourse-Uid', '2'
      get '/api/ai-connect/tokens'
      expect(last_response.status).to eq(403)
      expect(json['error']).to eq('untrusted_proxy')
    end

    it 'refuses a wrong secret' do
      header PROXY_SECRET_HEADER_NAME, 'not-the-secret'
      header 'X-Discourse-Uid', '1'
      post '/api/ai-connect/generate-token', { scope: 'read write' }.to_json
      expect(last_response.status).to eq(403)
    end

    it 'refuses consent (code issuance) for a forged uid without the secret' do
      without_proxy_secret
      header 'X-Discourse-Uid', '1'
      post '/oauth/authorize', { client_id: 'claude', code_challenge: challenge, approved: 'true',
                                 redirect_uri: 'http://app.local/cb', scope: 'read write' }
      expect(last_response.status).to eq(403)
      expect(last_response.headers['Location']).to be_nil
    end

    it 'does not show a consent form for a forged uid without the secret' do
      without_proxy_secret
      header 'X-Discourse-Uid', '1'
      get '/oauth/authorize', { client_id: 'claude', code_challenge: challenge }
      expect(last_response.body).to include('Sign in required')
    end

    it 'fails closed (503) on trusted routes when the secret is not configured' do
      saved = ENV['AI_CONNECT_PROXY_SECRET']
      ENV['AI_CONNECT_PROXY_SECRET'] = ''
      begin
        header 'X-Discourse-Uid', '2'
        get '/api/ai-connect/tokens'
        expect(last_response.status).to eq(503)
        post '/api/ai-connect/generate-token', '{}'
        expect(last_response.status).to eq(503)
        post '/oauth/authorize', { client_id: 'claude', code_challenge: challenge, approved: 'true' }
        expect(last_response.status).to eq(503)
      ensure
        ENV['AI_CONNECT_PROXY_SECRET'] = saved
      end
    end

    it 'defaults the bind address to loopback' do
      expect(File.read(File.expand_path('../app.rb', __dir__))).to include("ENV.fetch('BIND', '127.0.0.1')")
    end
  end

  describe 'scope clamping' do
    it 'generate-token gives a member at most "read write"' do
      header 'X-Discourse-Uid', '2'
      post '/api/ai-connect/generate-token', { scope: 'read write delete admin' }.to_json
      expect(last_response.status).to eq(200)
      expect(json['scope']).to eq('read write')
      expect(DB.get_token(json['access_token'])['scope']).to eq('read write')
    end

    it 'generate-token drops unknown scopes from the raw body' do
      header 'X-Discourse-Uid', '2'
      post '/api/ai-connect/generate-token', { scope: 'superuser' }.to_json
      expect(json['scope']).to eq('read')
    end

    it 'generate-token keeps delete for a Discourse admin' do
      header 'X-Discourse-Uid', '1'
      post '/api/ai-connect/generate-token', { scope: 'read write delete' }.to_json
      expect(json['scope']).to eq('read write delete')
    end

    it 'OAuth consent clamps delete for a member' do
      header 'X-Discourse-Uid', '2'
      post '/oauth/authorize', { client_id: 'claude', code_challenge: challenge, approved: 'true',
                                 redirect_uri: 'http://app.local/cb', scope: 'read write delete' }
      code = last_response.headers['Location'][/code=([0-9a-f]+)/, 1]
      post '/api/ai-connect/token', { grant_type: 'authorization_code', code: code, code_verifier: verifier }
      expect(json['scope']).to eq('read write')
    end
  end
end
