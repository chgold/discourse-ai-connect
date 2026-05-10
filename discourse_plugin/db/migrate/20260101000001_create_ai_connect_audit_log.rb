class CreateAiConnectAuditLog < ActiveRecord::Migration[7.0]
  def change
    create_table :ai_connect_audit_logs do |t|
      t.integer :user_id, null: false
      t.string  :client_id, null: false
      t.string  :action, null: false
      t.string  :scope
      t.string  :ip_address
      t.text    :details
      t.timestamps
    end
    add_index :ai_connect_audit_logs, :user_id
    add_index :ai_connect_audit_logs, :client_id
    add_index :ai_connect_audit_logs, [:user_id, :created_at]
  end
end
