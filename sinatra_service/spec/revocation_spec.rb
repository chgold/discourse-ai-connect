require_relative 'spec_helper'

# RFC 7009 / Servio SPEC §5.2 conformance for POST /api/ai-connect/revoke.
RSpec.describe 'Token revocation (RFC 7009)' do
  let(:pair) { DB.save_tokens('claude', 7, 'read write') }

  def tool_call(access)
    header 'Authorization', "Bearer #{access}"
    get '/api/ai-connect/v1/tools/discourse.getCategories'
    header 'Authorization', nil
    last_response.status
  end

  def refresh_with(refresh)
    post '/api/ai-connect/token', { grant_type: 'refresh_token', refresh_token: refresh }
    JSON.parse(last_response.body)
  end

  it 'advertises revocation_url next to token_url in the manifest' do
    get '/api/ai-connect/manifest'
    auth = JSON.parse(last_response.body)['auth']
    expect(auth['revocation_url']).to end_with('/api/ai-connect/revoke')
    expect(auth['token_url']).to end_with('/api/ai-connect/token')
  end

  it 'revoking the REFRESH token (with hint) kills the access token too' do
    expect(tool_call(pair[:access])).to eq(200)

    post '/api/ai-connect/revoke', { token: pair[:refresh], token_type_hint: 'refresh_token', client_id: 'claude' }
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq('revoked' => true)

    expect(tool_call(pair[:access])).to eq(401)
    expect(refresh_with(pair[:refresh])['error']).to eq('invalid_grant')
  end

  it 'revoking the ACCESS token without a hint kills the refresh token too' do
    post '/api/ai-connect/revoke', { token: pair[:access] }
    expect(last_response.status).to eq(200)

    expect(tool_call(pair[:access])).to eq(401)
    expect(refresh_with(pair[:refresh])['error']).to eq('invalid_grant')
  end

  it 'syncs the token registry (admin list / My Tokens) in the same request' do
    post '/api/ai-connect/revoke', { token: pair[:refresh] }
    expect(DB.registry_for(pair[:access])['revoked_at']).not_to be_nil
  end

  it 'accepts a JSON body' do
    header 'Content-Type', 'application/json'
    post '/api/ai-connect/revoke', { token: pair[:access] }.to_json
    expect(last_response.status).to eq(200)
    expect(tool_call(pair[:access])).to eq(401)
  end

  it 'needs no authentication (no Bearer / uid header)' do
    post '/api/ai-connect/revoke', { token: pair[:access] }
    expect(last_response.status).to eq(200)
  end

  it 'returns 200 for unknown and already-revoked tokens (no probing)' do
    post '/api/ai-connect/revoke', { token: 'nope' }
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq('revoked' => true)

    post '/api/ai-connect/revoke', { token: pair[:access] }
    post '/api/ai-connect/revoke', { token: pair[:access] }
    expect(last_response.status).to eq(200)
  end

  it 'returns 400 invalid_request when token is missing' do
    post '/api/ai-connect/revoke', {}
    expect(last_response.status).to eq(400)
    expect(JSON.parse(last_response.body)['error']).to eq('invalid_request')
  end

  it 'does not touch other pairs' do
    other = DB.save_tokens('claude', 7, 'read write')
    post '/api/ai-connect/revoke', { token: pair[:access] }
    expect(tool_call(other[:access])).to eq(200)
  end
end
