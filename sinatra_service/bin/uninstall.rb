#!/usr/bin/env ruby
require_relative '../services/db'

puts "Removing AI Connect tables..."

DB.conn.exec(<<~SQL)
  DROP TABLE IF EXISTS ai_connect_token_registry CASCADE;
  DROP TABLE IF EXISTS ai_rate_limits CASCADE;
  DROP TABLE IF EXISTS ai_tokens CASCADE;
  DROP TABLE IF EXISTS ai_codes CASCADE;
  DROP TABLE IF EXISTS ai_clients CASCADE;
SQL

puts "Uninstall complete."
