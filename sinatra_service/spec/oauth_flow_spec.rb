require_relative 'spec_helper'
require 'digest'
require 'base64'

RSpec.describe 'OAuth PKCE flow' do
  let(:verifier)  { 'a' * 64 }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }

  describe 'GET /oauth/authorize' do
    it 'requires client_id and code_challenge' do
      get '/oauth/authorize'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('invalid_request')
    end

    it 'rejects unknown client' do
      get '/oauth/authorize', { client_id: 'nonexistent', code_challenge: challenge, uid: '1' }
      expect(last_response.body).to include('invalid_client')
    end

    it 'shows consent form for valid client with uid' do
      get '/oauth/authorize', { client_id: 'claude', code_challenge: challenge, uid: '1', scope: 'read write' }
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('AI Connect Authorization')
      expect(last_response.body).to include('user ID 1')
    end

    it 'prefixes the consent form action with the Discourse base path (subfolder install)' do
      header 'X-Discourse-Uid', '1'
      header 'X-AI-Connect-Base-Path', '/forum'
      get '/oauth/authorize', { client_id: 'claude', code_challenge: challenge }
      expect(last_response.body).to include('action="/forum/ai-connect-plugin/authorize"')
    end

    it 'ignores a malformed base path header' do
      header 'X-Discourse-Uid', '1'
      header 'X-AI-Connect-Base-Path', 'https://evil.example/x"'
      get '/oauth/authorize', { client_id: 'claude', code_challenge: challenge }
      expect(last_response.body).to include('action="/ai-connect-plugin/authorize"')
    end

    it 'shows sign-in prompt when no uid resolved' do
      ENV['DEV_ALLOW_UID_PARAM'] = '0'
      get '/oauth/authorize', { client_id: 'claude', code_challenge: challenge }
      expect(last_response.body).to include('Sign in required')
      ENV['DEV_ALLOW_UID_PARAM'] = '1'
    end
  end

  describe 'POST /oauth/authorize → /api/ai-connect/token' do
    it 'rejects denied consent' do
      post '/oauth/authorize', {
        client_id: 'claude', code_challenge: challenge,
        redirect_uri: 'http://app.local/cb', scope: 'read', uid: '1', approved: 'false'
      }
      expect(last_response.headers['Location']).to include('error=access_denied')
    end

    it 'accepts the consent as a JSON body (what the Discourse proxy sends)' do
      header 'X-Discourse-Uid', '1'
      post '/oauth/authorize',
           { client_id: 'claude', code_challenge: challenge, redirect_uri: 'http://app.local/cb',
             scope: 'read write', state: 'js1', approved: 'true' }.to_json,
           { 'CONTENT_TYPE' => 'application/json' }
      expect(last_response.status).to be_between(300, 399)
      loc = last_response.headers['Location']
      expect(loc).to match(/code=[0-9a-f]+/)
      expect(loc).to include('state=js1')
    end

    it 'redirects with code on approval' do
      post '/oauth/authorize', {
        client_id: 'claude', code_challenge: challenge,
        redirect_uri: 'http://app.local/cb', scope: 'read write',
        state: 'xyz', uid: '1', approved: 'true'
      }
      expect(last_response.status).to be_between(300, 399)
      loc = last_response.headers['Location']
      expect(loc).to match(/code=[0-9a-f]+/)
      expect(loc).to include('state=xyz')
    end

    it 'completes full PKCE round-trip' do
      post '/oauth/authorize', {
        client_id: 'claude', code_challenge: challenge,
        redirect_uri: 'http://app.local/cb', scope: 'read write',
        uid: '1', approved: 'true'
      }
      code = last_response.headers['Location'][/code=([0-9a-f]+)/, 1]
      expect(code).not_to be_nil

      post '/api/ai-connect/token', {
        grant_type: 'authorization_code',
        code: code,
        code_verifier: verifier,
        redirect_uri: 'http://app.local/cb'
      }
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body['access_token']).to start_with('xfa_')
      expect(body['refresh_token']).to start_with('xfr_')
      expect(body['token_type']).to eq('Bearer')
      expect(body['expires_in']).to eq(3600)
    end

    it 'rejects mismatched PKCE verifier' do
      post '/oauth/authorize', {
        client_id: 'claude', code_challenge: challenge,
        redirect_uri: 'http://app.local/cb', scope: 'read',
        uid: '1', approved: 'true'
      }
      code = last_response.headers['Location'][/code=([0-9a-f]+)/, 1]

      post '/api/ai-connect/token', {
        grant_type: 'authorization_code',
        code: code, code_verifier: 'wrong_verifier_value_here_must_be_long_enough_to_pass'
      }
      expect(JSON.parse(last_response.body)['error']).to eq('invalid_grant')
    end

    it 'prevents code replay' do
      post '/oauth/authorize', {
        client_id: 'claude', code_challenge: challenge, scope: 'read',
        uid: '1', approved: 'true', redirect_uri: 'http://app.local/cb'
      }
      code = last_response.headers['Location'][/code=([0-9a-f]+)/, 1]

      post '/api/ai-connect/token', { grant_type: 'authorization_code', code: code, code_verifier: verifier }
      expect(JSON.parse(last_response.body)['access_token']).not_to be_nil

      post '/api/ai-connect/token', { grant_type: 'authorization_code', code: code, code_verifier: verifier }
      expect(JSON.parse(last_response.body)['error']).to eq('invalid_grant')
    end
  end

  describe 'refresh token' do
    it 'exchanges refresh_token for new access token' do
      post '/oauth/authorize', {
        client_id: 'claude', code_challenge: challenge, scope: 'read write',
        uid: '1', approved: 'true', redirect_uri: 'http://app.local/cb'
      }
      code = last_response.headers['Location'][/code=([0-9a-f]+)/, 1]
      post '/api/ai-connect/token', { grant_type: 'authorization_code', code: code, code_verifier: verifier }
      first = JSON.parse(last_response.body)

      post '/api/ai-connect/token', { grant_type: 'refresh_token', refresh_token: first['refresh_token'] }
      expect(last_response.status).to eq(200)
      second = JSON.parse(last_response.body)
      expect(second['access_token']).to start_with('xfa_')
      expect(second['access_token']).not_to eq(first['access_token'])
    end
  end

  describe 'unsupported grant' do
    it 'returns unsupported_grant_type' do
      post '/api/ai-connect/token', { grant_type: 'client_credentials' }
      expect(JSON.parse(last_response.body)['error']).to eq('unsupported_grant_type')
    end
  end
end
