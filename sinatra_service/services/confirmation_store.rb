# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'db'

# ConfirmationStore — persistence for the user-confirm-v1 flow (1.2.7).
#
# Three tables, created idempotently next to the bridge's own tables:
#   ai_connect_pending_actions   one row per action an agent asked for (pending → executing → executed|failed,
#                                pending → rejected|expired). Bound to user + tool + args hash + client.
#   ai_connect_confirmation_events  append-only audit log (requested, reused, confirmed, executed, ...).
#   ai_connect_autonomy_grants   "let this client run this tool without asking me" (per user, tool, client).
module ConfirmationStore
  RESULT_KEEP_DAYS = 30
  SECRET_KEY_RE = /(password|secret|token)\z/i

  def self.conn
    DB.conn
  end

  def self.init_schema
    conn.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS ai_connect_pending_actions (
        id VARCHAR(40) PRIMARY KEY,
        uid INTEGER NOT NULL,
        tool VARCHAR(150) NOT NULL,
        args_hash VARCHAR(64) NOT NULL,
        args_json TEXT NOT NULL,
        client_key VARCHAR(120) NOT NULL,
        client_id VARCHAR(100),
        scope VARCHAR(100) NOT NULL,
        token_prefix VARCHAR(16),
        risk VARCHAR(20) NOT NULL DEFAULT 'destructive',
        summary VARCHAR(255) NOT NULL,
        details_json TEXT,
        preview_json TEXT,
        locale VARCHAR(20),
        status VARCHAR(12) NOT NULL DEFAULT 'pending',
        result_json TEXT,
        created_at BIGINT NOT NULL,
        expires_at BIGINT NOT NULL,
        decided_at BIGINT,
        executed_at BIGINT,
        delivered_at BIGINT
      );
      CREATE INDEX IF NOT EXISTS idx_aicpa_lookup ON ai_connect_pending_actions(uid, tool, args_hash, client_key, status);
      CREATE INDEX IF NOT EXISTS idx_aicpa_uid_status ON ai_connect_pending_actions(uid, status);
      CREATE TABLE IF NOT EXISTS ai_connect_confirmation_events (
        id SERIAL PRIMARY KEY,
        action_id VARCHAR(40),
        event VARCHAR(30) NOT NULL,
        uid INTEGER,
        actor_uid INTEGER,
        tool VARCHAR(150),
        client_id VARCHAR(100),
        ip VARCHAR(64),
        created_at BIGINT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS idx_aicce_uid ON ai_connect_confirmation_events(uid, created_at);
      CREATE TABLE IF NOT EXISTS ai_connect_autonomy_grants (
        id SERIAL PRIMARY KEY,
        uid INTEGER NOT NULL,
        tool VARCHAR(150) NOT NULL,
        client_id VARCHAR(100) NOT NULL,
        created_at BIGINT NOT NULL,
        revoked_at BIGINT
      );
      CREATE UNIQUE INDEX IF NOT EXISTS idx_aicag_active ON ai_connect_autonomy_grants(uid, tool, client_id) WHERE revoked_at IS NULL;
    SQL
  end

  def self.now
    Time.now.to_i
  end

  def self.new_id
    "conf_#{SecureRandom.hex(16)}"
  end

  def self.row(sql, params)
    r = conn.exec_params(sql, params).first
    r && decode(r)
  end

  def self.decode(r)
    r = r.dup
    %w[uid created_at expires_at decided_at executed_at delivered_at].each { |k| r[k] = r[k]&.to_i }
    r['args'] = JSON.parse(r['args_json'] || '{}')
    r['details'] = r['details_json'] ? JSON.parse(r['details_json']) : []
    r['preview'] = r['preview_json'] ? JSON.parse(r['preview_json']) : nil
    r['result'] = r['result_json'] ? JSON.parse(r['result_json']) : nil
    r
  end

  # Turns every pending action past its TTL into 'expired' and drops results older than 30 days.
  def self.sweep!
    t = now
    expired = conn.exec_params(
      "UPDATE ai_connect_pending_actions SET status='expired', decided_at=$1 WHERE status='pending' AND expires_at <= $1 RETURNING id, uid, tool, client_id",
      [t]
    ).to_a
    expired.each { |e| add_event(e['id'], 'expired', uid: e['uid'].to_i, tool: e['tool'], client_id: e['client_id']) }
    conn.exec_params('DELETE FROM ai_connect_pending_actions WHERE created_at < $1', [t - RESULT_KEEP_DAYS * 86_400])
  rescue StandardError
    nil
  end

  def self.create(uid:, tool:, args:, args_hash:, client_key:, client_id:, scope:, token_prefix:, risk:, summary:,
                  details:, preview:, locale:, ttl:)
    id = new_id
    t = now
    values = [id, uid, tool, args_hash, JSON.generate(args), client_key, client_id, scope, token_prefix, risk,
              summary, JSON.generate(details || []), preview.nil? ? nil : JSON.generate(preview), locale, t, t + ttl]
    conn.exec_params(<<~SQL, values)
      INSERT INTO ai_connect_pending_actions
        (id, uid, tool, args_hash, args_json, client_key, client_id, scope, token_prefix, risk, summary, details_json,
         preview_json, locale, status, created_at, expires_at)
      VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,'pending',$15,$16)
    SQL
    find(id)
  end

  def self.find(id)
    row('SELECT * FROM ai_connect_pending_actions WHERE id=$1', [id.to_s])
  end

  def self.find_pending(uid, tool, args_hash, client_key)
    row(<<~SQL, [uid, tool, args_hash, client_key, now])
      SELECT * FROM ai_connect_pending_actions
       WHERE uid=$1 AND tool=$2 AND args_hash=$3 AND client_key=$4 AND status='pending' AND expires_at > $5
       ORDER BY created_at DESC LIMIT 1
    SQL
  end

  # Executed (or failed) within `recent` seconds, or within `uncollected` seconds and never collected by the agent.
  def self.find_recent_executed(uid, tool, args_hash, client_key, recent:, uncollected:)
    t = now
    row(<<~SQL, [uid, tool, args_hash, client_key, t - recent, t - uncollected])
      SELECT * FROM ai_connect_pending_actions
       WHERE uid=$1 AND tool=$2 AND args_hash=$3 AND client_key=$4 AND status IN ('executed','failed')
         AND (executed_at >= $5 OR (executed_at >= $6 AND delivered_at IS NULL))
       ORDER BY executed_at DESC LIMIT 1
    SQL
  end

  # Single use: only one request can move a pending action to 'executing'.
  def self.claim(id, uid)
    t = now
    row(<<~SQL, [id.to_s, uid, t])
      UPDATE ai_connect_pending_actions SET status='executing', decided_at=$3
       WHERE id=$1 AND uid=$2 AND status='pending' AND expires_at > $3
       RETURNING *
    SQL
  end

  def self.reject(id, uid)
    t = now
    row(<<~SQL, [id.to_s, uid, t])
      UPDATE ai_connect_pending_actions SET status='rejected', decided_at=$3
       WHERE id=$1 AND uid=$2 AND status='pending' AND expires_at > $3
       RETURNING *
    SQL
  end

  def self.finish(id, ok, result)
    conn.exec_params(
      'UPDATE ai_connect_pending_actions SET status=$2, result_json=$3, executed_at=$4 WHERE id=$1',
      [id.to_s, ok ? 'executed' : 'failed', JSON.generate(redact(result)), now]
    )
    find(id)
  end

  def self.mark_delivered(id)
    conn.exec_params('UPDATE ai_connect_pending_actions SET delivered_at=$2 WHERE id=$1 AND delivered_at IS NULL', [id.to_s, now])
  end

  def self.pending_for_user(uid)
    sweep!
    conn.exec_params(
      "SELECT * FROM ai_connect_pending_actions WHERE uid=$1 AND status='pending' AND expires_at > $2 ORDER BY created_at DESC LIMIT 50",
      [uid, now]
    ).map { |r| decode(r) }
  end

  def self.recent_for_user(uid, limit = 20)
    conn.exec_params(
      "SELECT * FROM ai_connect_pending_actions WHERE uid=$1 AND status <> 'pending' ORDER BY COALESCE(decided_at, created_at) DESC LIMIT $2",
      [uid, limit]
    ).map { |r| decode(r) }
  end

  # ── audit (append-only) ──
  def self.add_event(action_id, event, uid: nil, actor_uid: nil, tool: nil, client_id: nil, ip: nil)
    conn.exec_params(
      'INSERT INTO ai_connect_confirmation_events (action_id, event, uid, actor_uid, tool, client_id, ip, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)',
      [action_id, event, uid, actor_uid, tool, client_id, ip, now]
    )
  rescue StandardError
    nil
  end

  def self.events_for_user(uid, limit = 30)
    conn.exec_params(
      'SELECT action_id, event, tool, client_id, created_at FROM ai_connect_confirmation_events WHERE uid=$1 ORDER BY id DESC LIMIT $2',
      [uid, limit]
    ).to_a
  end

  # ── autonomy grants ──
  def self.autonomy?(uid, tool, client_id)
    return false if client_id.to_s.empty?

    conn.exec_params(
      'SELECT 1 FROM ai_connect_autonomy_grants WHERE uid=$1 AND tool=$2 AND client_id=$3 AND revoked_at IS NULL',
      [uid, tool, client_id]
    ).any?
  end

  def self.grant_autonomy(uid, tool, client_id)
    return false if client_id.to_s.empty?

    conn.exec_params(
      'INSERT INTO ai_connect_autonomy_grants (uid, tool, client_id, created_at) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING',
      [uid, tool, client_id, now]
    )
    true
  end

  def self.revoke_autonomy(uid, grant_id)
    conn.exec_params(
      'UPDATE ai_connect_autonomy_grants SET revoked_at=$3 WHERE id=$1 AND uid=$2 AND revoked_at IS NULL RETURNING tool, client_id',
      [grant_id.to_i, uid, now]
    ).first
  end

  def self.autonomy_for_user(uid)
    conn.exec_params(
      'SELECT id, tool, client_id, created_at FROM ai_connect_autonomy_grants WHERE uid=$1 AND revoked_at IS NULL ORDER BY id DESC',
      [uid]
    ).to_a
  end

  def self.redact(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), h| h[k] = k.to_s.match?(SECRET_KEY_RE) ? '[redacted]' : redact(v) }
    when Array then value.map { |v| redact(v) }
    else value
    end
  end
end
