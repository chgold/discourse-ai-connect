require_relative 'spec_helper'

RSpec.describe 'CORS' do
  it 'echoes whitelisted origin' do
    header 'Origin', 'http://test.local'
    get '/health'
    expect(last_response.headers['Access-Control-Allow-Origin']).to eq('http://test.local')
  end

  it 'does not echo non-whitelisted origin in production' do
    ENV['RACK_ENV'] = 'production'
    header 'Origin', 'http://evil.example.com'
    get '/health'
    expect(last_response.headers['Access-Control-Allow-Origin']).to be_nil
    ENV['RACK_ENV'] = 'test'
  end

  it 'sets security headers' do
    get '/health'
    expect(last_response.headers['X-Content-Type-Options']).to eq('nosniff')
    expect(last_response.headers['Referrer-Policy']).to eq('no-referrer')
  end
end
