require_relative 'spec_helper'
require 'digest'
require 'base64'

RSpec.describe 'Rate limiting' do
  let(:verifier)  { 'rl_verifier_' * 8 }
  let(:challenge) { Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false) }

  it 'OAuth /authorize is rate limited per IP' do
    ENV['RATE_LIMIT_OAUTH_PER_MINUTE'] = '3'
    4.times { get '/oauth/authorize', { client_id: 'claude', code_challenge: challenge, uid: '1' } }
    expect(last_response.status).to eq(429)
    ENV['RATE_LIMIT_OAUTH_PER_MINUTE'] = '10'
  end

  it 'Token endpoint is rate limited per IP' do
    ENV['RATE_LIMIT_TOKEN_PER_MINUTE'] = '2'
    3.times { post '/api/ai-connect/token', { grant_type: 'authorization_code', code: 'bad' } }
    expect(last_response.status).to eq(429)
    ENV['RATE_LIMIT_TOKEN_PER_MINUTE'] = '20'
  end

  it 'Tool endpoint is rate limited per token' do
    ENV['RATE_LIMIT_TOOL_PER_MINUTE'] = '3'
    tokens = DB.save_tokens('claude', 1, 'read')
    header 'Authorization', "Bearer #{tokens[:access]}"
    4.times { post '/api/ai-connect/v1/tools/discourse.getCategories', {}.to_json }
    expect(last_response.status).to eq(429)
    body = JSON.parse(last_response.body)
    expect(body['error']).to eq('rate_limit_exceeded')
    ENV['RATE_LIMIT_TOOL_PER_MINUTE'] = '50'
  end
end
