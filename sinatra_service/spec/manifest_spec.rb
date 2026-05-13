require_relative 'spec_helper'

RSpec.describe 'Manifest endpoint' do
  it 'returns valid JSON manifest with required keys' do
    get '/api/ai-connect/manifest'
    expect(last_response.status).to eq(200)
    expect(last_response.headers['Content-Type']).to include('application/json')

    body = JSON.parse(last_response.body)
    %w[schema_version name version description api_version capabilities server auth tools].each do |k|
      expect(body).to have_key(k)
    end
    expect(body['auth']['type']).to eq('oauth2')
    expect(body['auth']['pkce_required']).to be true
    expect(body['auth']['code_challenge_method']).to eq('S256')
    expect(body['tools']).to be_an(Array)
    expect(body['tools'].size).to be >= 11
  end

  it 'each tool has name + input_schema' do
    get '/api/ai-connect/manifest'
    tools = JSON.parse(last_response.body)['tools']
    tools.each do |t|
      expect(t).to have_key('name')
      expect(t).to have_key('input_schema')
    end
  end

  it 'exposes registered_clients map under auth with seeded clients' do
    get '/api/ai-connect/manifest'
    body = JSON.parse(last_response.body)
    expect(body['auth']).to have_key('registered_clients')
    clients = body['auth']['registered_clients']
    expect(clients).to be_a(Hash)
    expect(clients['claude']).to eq('claude')
    expect(clients['webmcp-master']).to eq('WebMCP Master')
  end

  it 'health endpoint returns ok' do
    get '/health'
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)['status']).to eq('ok')
  end
end
