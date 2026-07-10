ENV['RACK_ENV'] = 'test'
ENV['DB_HOST']     ||= '127.0.0.1'
ENV['DB_PORT']     ||= '5432'
ENV['DB_USER']     ||= 'discourse'
ENV['DB_NAME']     ||= ENV.fetch('TEST_DB_NAME', 'discourse_dev_test')
ENV['DB_PASSWORD'] ||= ''
ENV['DISCOURSE_STUB_MODE'] = '1'
ENV['DEV_ALLOW_UID_PARAM'] = '1'
ENV['ALLOWED_ORIGINS'] = 'http://test.local,http://localhost:8086'
ENV['AICONNECT_EDITION'] = 'pro'

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  add_group 'Controllers', 'controllers'
  add_group 'Services',    'services'
  add_group 'Middleware',  'middleware'
  add_group 'Lib',         'lib'
end

require 'rspec'
require 'rack/test'
require 'json'

$LOAD_PATH.unshift File.expand_path('..', __dir__)

def ensure_test_db!
  require 'pg'
  admin = PG.connect(
    host:     ENV['DB_HOST'],
    port:     ENV['DB_PORT'].to_i,
    dbname:   'postgres',
    user:     ENV['DB_USER'],
    password: ENV['DB_PASSWORD']
  )
  exists = admin.exec_params('SELECT 1 FROM pg_database WHERE datname=$1', [ENV['DB_NAME']]).any?
  admin.exec("CREATE DATABASE #{ENV['DB_NAME']}") unless exists
  admin.close
rescue PG::Error => e
  warn "Could not create test DB: #{e.message}"
end

ensure_test_db!

require_relative '../app'

module DBTestHelpers
  def reset_db!
    DB.init_schema
    DB.conn.exec('TRUNCATE ai_clients, ai_codes, ai_tokens, ai_rate_limits, ai_connect_token_registry RESTART IDENTITY')
    DB.init_schema
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.include Rack::Test::Methods
  config.include DBTestHelpers

  config.before(:each) { reset_db! }

  def app
    DiscourseAiConnect
  end
end
