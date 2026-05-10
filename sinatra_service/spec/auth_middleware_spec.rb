require_relative 'spec_helper'

RSpec.describe AuthMiddleware do
  let(:fake_request) do
    Struct.new(:env).new({})
  end

  it 'rejects missing Authorization header' do
    result = AuthMiddleware.require_bearer(fake_request)
    expect(result[:error]).to eq('unauthorized')
  end

  it 'rejects non-Bearer scheme' do
    fake_request.env['HTTP_AUTHORIZATION'] = 'Basic abc'
    result = AuthMiddleware.require_bearer(fake_request)
    expect(result[:error]).to eq('unauthorized')
  end

  it 'rejects empty bearer' do
    fake_request.env['HTTP_AUTHORIZATION'] = 'Bearer '
    result = AuthMiddleware.require_bearer(fake_request)
    expect(result[:error]).to eq('unauthorized')
  end

  it 'rejects unknown token' do
    fake_request.env['HTTP_AUTHORIZATION'] = 'Bearer dsc_fake'
    result = AuthMiddleware.require_bearer(fake_request)
    expect(result[:error]).to eq('invalid_token')
  end

  it 'accepts a valid token' do
    tokens = DB.save_tokens('claude', 42, 'read write')
    fake_request.env['HTTP_AUTHORIZATION'] = "Bearer #{tokens[:access]}"
    result = AuthMiddleware.require_bearer(fake_request)
    expect(result[:uid]).to eq(42)
    expect(result[:scope]).to eq('read write')
  end

  it 'rejects revoked token' do
    tokens = DB.save_tokens('claude', 42, 'read')
    DB.revoke_token(tokens[:access])
    fake_request.env['HTTP_AUTHORIZATION'] = "Bearer #{tokens[:access]}"
    result = AuthMiddleware.require_bearer(fake_request)
    expect(result[:error]).to eq('invalid_token')
  end
end
