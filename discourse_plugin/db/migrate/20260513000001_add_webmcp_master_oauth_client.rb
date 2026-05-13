# frozen_string_literal: true

class AddWebmcpMasterOauthClient < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:ai_clients)

    execute(<<~SQL)
      INSERT INTO ai_clients (client_id, client_name, redirect_uris, scopes, created_at)
      VALUES ('webmcp-master', 'WebMCP Master', 'urn:ietf:wg:oauth:2.0:oob', 'read write delete manage_users', NOW())
      ON CONFLICT (client_id) DO NOTHING
    SQL
  end

  def down
    return unless table_exists?(:ai_clients)

    execute("DELETE FROM ai_clients WHERE client_id = 'webmcp-master'")
  end
end
