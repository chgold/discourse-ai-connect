require_relative 'spec_helper'
require 'digest'
require 'base64'

RSpec.describe 'Tool execution' do
  let(:verifier)  { 'verifier_' * 8 }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }

  def issue_token(scope: 'read write')
    post '/oauth/authorize', {
      client_id: 'claude', code_challenge: challenge, scope: scope,
      uid: '1', approved: 'true'
    }
    code = last_response.headers['Location'][/code=([0-9a-f]+)/, 1]
    post '/api/ai-connect/token', { grant_type: 'authorization_code', code: code, code_verifier: verifier }
    JSON.parse(last_response.body)['access_token']
  end

  def tool_post(name, body, token: nil)
    header 'Authorization', "Bearer #{token || issue_token}"
    header 'Content-Type', 'application/json'
    post "/api/ai-connect/v1/tools/#{name}", body.to_json
  end

  describe 'authentication' do
    it 'requires Bearer token' do
      header 'Content-Type', 'application/json'
      post '/api/ai-connect/v1/tools/discourse.getCategories', {}.to_json
      expect(last_response.status).to eq(401)
    end

    it 'rejects bogus token' do
      header 'Authorization', 'Bearer dsc_doesnotexist'
      header 'Content-Type', 'application/json'
      post '/api/ai-connect/v1/tools/discourse.getCategories', {}.to_json
      expect(last_response.status).to eq(401)
    end
  end

  describe 'tool: getCategories' do
    it 'returns the category list (stubbed)' do
      tool_post('discourse.getCategories', {})
      expect(last_response.status).to eq(200)
      body = JSON.parse(last_response.body)
      expect(body['success']).to be true
      expect(body['data']).to be_an(Array)
      expect(body['data'].first['name']).to eq('General')
    end
  end

  describe 'tool: searchTopics' do
    it 'validates required query param' do
      tool_post('discourse.searchTopics', {})
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body)['data']['error']).to eq('invalid_params')
    end

    it 'returns matched topics' do
      tool_post('discourse.searchTopics', { query: 'install' })
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)['data']
      expect(data.first['title']).to include('install')
    end
  end

  describe 'tool: getLatestTopics' do
    it 'returns latest topics' do
      tool_post('discourse.getLatestTopics', {})
      expect(last_response.status).to eq(200)
      data = JSON.parse(last_response.body)['data']
      expect(data.size).to eq(5)
    end

    it 'filters by category_id' do
      tool_post('discourse.getLatestTopics', { category_id: 2 })
      data = JSON.parse(last_response.body)['data']
      expect(data.size).to eq(2)
    end
  end

  describe 'tool: getTopic' do
    it 'returns topic with posts' do
      tool_post('discourse.getTopic', { topic_id: 101 })
      data = JSON.parse(last_response.body)['data']
      expect(data['posts']).to be_an(Array)
      expect(data['posts'].size).to be >= 1
    end

    it '404s unknown topic' do
      tool_post('discourse.getTopic', { topic_id: 99999 })
      expect(last_response.status).to eq(404) # 1.2.6: was 200 with success=false
      expect(JSON.parse(last_response.body)['data']['error']).to eq('not_found')
    end

    it 'rejects non-integer topic_id' do
      tool_post('discourse.getTopic', { topic_id: 'abc' })
      expect(last_response.status).to eq(400)
    end
  end

  describe 'tool: getUserProfile' do
    it 'returns admin profile' do
      tool_post('discourse.getUserProfile', { username: 'admin' })
      data = JSON.parse(last_response.body)['data']
      expect(data['username']).to eq('admin')
      expect(data['trust_level']).to eq(4)
    end
  end

  describe 'unknown tool' do
    it 'returns 404' do
      tool_post('discourse.nonexistent', {})
      expect(last_response.status).to eq(404)
    end
  end

  describe 'Pro tools require write scope' do
    it 'rejects createTopic with read-only token' do
      tool_post('discourse.createTopic',
                { title: 'New', raw: 'Body', category_id: 1 },
                token: issue_token(scope: 'read'))
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body)['data']['error']).to eq('insufficient_scope')
    end

    it 'accepts createTopic with write scope' do
      tool_post('discourse.createTopic',
                { title: 'New', raw: 'Body', category_id: 1 },
                token: issue_token(scope: 'read write'))
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)['success']).to be true
    end
  end

  describe 'input validation' do
    it 'rejects oversized raw body' do
      tool_post('discourse.createTopic',
                { title: 'X', raw: 'a' * 20_000, category_id: 1 },
                token: issue_token(scope: 'read write'))
      expect(last_response.status).to eq(400)
    end

    it 'rejects oversized title' do
      tool_post('discourse.createTopic',
                { title: 't' * 500, raw: 'body', category_id: 1 },
                token: issue_token(scope: 'read write'))
      expect(last_response.status).to eq(400)
    end
  end
end
