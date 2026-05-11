require 'pg'
require 'securerandom'
require 'logger'

module DB
  LOGGER = Logger.new($stdout)
  LOGGER.progname = 'DB'

  def self.config
    {
      host:     ENV.fetch('DB_HOST', '127.0.0.1'),
      port:     ENV.fetch('DB_PORT', '5432').to_i,
      dbname:   ENV.fetch('DB_NAME', 'discourse_dev'),
      user:     ENV.fetch('DB_USER', 'discourse'),
      password: ENV.fetch('DB_PASSWORD') {
        # In production, refuse to start without an explicit password
        if ENV['RACK_ENV'] == 'production'
          raise 'DB_PASSWORD environment variable is required in production'
        end
        ''
      }
    }
  end

  def self.conn
    @conn ||= begin
      LOGGER.info("Connecting to PostgreSQL #{config[:host]}:#{config[:port]}/#{config[:dbname]} as #{config[:user]}")
      c = PG.connect(config)
      c.exec("SET client_min_messages=WARNING") rescue nil
      c
    end
  rescue PG::Error => e
    LOGGER.error("DB connection failed: #{e.message}")
    raise
  end

  def self.init_schema
    conn.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS ai_clients (
        id SERIAL PRIMARY KEY,
        client_id VARCHAR(100) UNIQUE NOT NULL,
        client_name VARCHAR(200) NOT NULL,
        redirect_uris TEXT,
        scopes VARCHAR(500) DEFAULT 'read write',
        created_at TIMESTAMP DEFAULT NOW()
      );
      CREATE TABLE IF NOT EXISTS ai_codes (
        id SERIAL PRIMARY KEY,
        code VARCHAR(200) UNIQUE NOT NULL,
        client_id VARCHAR(100) NOT NULL,
        uid INTEGER NOT NULL,
        scope VARCHAR(500),
        code_challenge VARCHAR(200),
        redirect_uri VARCHAR(500),
        expires_at BIGINT NOT NULL,
        used BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP DEFAULT NOW()
      );
      CREATE TABLE IF NOT EXISTS ai_tokens (
        id SERIAL PRIMARY KEY,
        token VARCHAR(200) UNIQUE NOT NULL,
        token_type VARCHAR(10) NOT NULL,
        client_id VARCHAR(100),
        uid INTEGER NOT NULL,
        scope VARCHAR(500),
        parent_token VARCHAR(200),
        expires_at BIGINT NOT NULL,
        revoked BOOLEAN DEFAULT FALSE,
        created_at TIMESTAMP DEFAULT NOW()
      );
      CREATE TABLE IF NOT EXISTS ai_rate_limits (
        id SERIAL PRIMARY KEY,
        token VARCHAR(200) NOT NULL,
        window_type VARCHAR(20) NOT NULL,
        window_start BIGINT NOT NULL,
        request_count INTEGER DEFAULT 1,
        UNIQUE (token, window_type)
      );
      CREATE INDEX IF NOT EXISTS idx_ai_tokens_token ON ai_tokens(token);
      CREATE INDEX IF NOT EXISTS idx_ai_codes_code ON ai_codes(code);
      CREATE TABLE IF NOT EXISTS ai_connect_token_registry (
        id SERIAL PRIMARY KEY,
        token_prefix VARCHAR(16) UNIQUE NOT NULL,
        user_id INTEGER NOT NULL,
        client_id VARCHAR(80),
        scope VARCHAR(255),
        issued_at TIMESTAMP DEFAULT NOW(),
        expires_at TIMESTAMP,
        last_used_at TIMESTAMP NULL,
        revoked_at TIMESTAMP NULL,
        revoked_by INTEGER NULL,
        source VARCHAR(20),
        ip_address VARCHAR(45)
      );
      CREATE INDEX IF NOT EXISTS idx_token_registry_prefix ON ai_connect_token_registry(token_prefix);
      CREATE INDEX IF NOT EXISTS idx_token_registry_user ON ai_connect_token_registry(user_id);
    SQL
    agents = %w[claude chatgpt gemini grok copilot perplexity metaai deepseek ai-agent-default]
    agents.each do |agent|
      conn.exec_params(
        "INSERT INTO ai_clients (client_id, client_name, redirect_uris, scopes) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING",
        [agent, agent, 'urn:ietf:wg:oauth:2.0:oob', 'read write delete']
      )
    end
  end

  def self.get_client(client_id)
    result = conn.exec_params("SELECT * FROM ai_clients WHERE client_id=$1", [client_id])
    result.first
  end

  def self.save_code(code, client_id, uid, scope, challenge, redirect_uri)
    expires = Time.now.to_i + 600
    conn.exec_params(
      "INSERT INTO ai_codes (code,client_id,uid,scope,code_challenge,redirect_uri,expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7)",
      [code, client_id, uid, scope, challenge, redirect_uri, expires]
    )
  end

  def self.get_code(code)
    result = conn.exec_params("SELECT * FROM ai_codes WHERE code=$1", [code])
    result.first
  end

  def self.mark_code_used(code)
    conn.exec_params("UPDATE ai_codes SET used=TRUE WHERE code=$1", [code])
  end

  def self.save_tokens(client_id, uid, scope, source: 'oauth', ip_address: nil)
    at = "dsc_#{SecureRandom.hex(32)}"
    rt = "dscr_#{SecureRandom.hex(32)}"
    now = Time.now.to_i
    conn.exec_params(
      "INSERT INTO ai_tokens (token,token_type,client_id,uid,scope,expires_at) VALUES ($1,'access',$2,$3,$4,$5)",
      [at, client_id, uid, scope, now + 3600]
    )
    conn.exec_params(
      "INSERT INTO ai_tokens (token,token_type,client_id,uid,scope,parent_token,expires_at) VALUES ($1,'refresh',$2,$3,$4,$5,$6)",
      [rt, client_id, uid, scope, at, now + 2_592_000]
    )
    register_token(at, client_id: client_id, user_id: uid, scope: scope,
                       expires_at_unix: now + 3600, source: source, ip_address: ip_address)
    { access: at, refresh: rt }
  end

  def self.get_token(token)
    result = conn.exec_params("SELECT * FROM ai_tokens WHERE token=$1 AND revoked=FALSE", [token])
    row = result.first
    return nil unless row
    reg = registry_for(token)
    return nil if reg && reg['revoked_at']
    row
  end

  def self.revoke_token(token, revoked_by: nil)
    conn.exec_params("UPDATE ai_tokens SET revoked=TRUE WHERE token=$1 OR parent_token=$1", [token])
    prefix = token_prefix(token)
    conn.exec_params(
      "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 WHERE token_prefix=$1 AND revoked_at IS NULL",
      [prefix, revoked_by]
    )
  end

  # ---------------------------------------------------------------------------
  # Token Registry — visibility + revocation for issued bearer tokens
  # ---------------------------------------------------------------------------

  TOKEN_PREFIX_LENGTH = 16

  def self.token_prefix(token)
    return nil if token.nil?
    token.to_s[0, TOKEN_PREFIX_LENGTH]
  end

  def self.register_token(token, client_id:, user_id:, scope:, expires_at_unix:, source: 'oauth', ip_address: nil)
    prefix = token_prefix(token)
    return nil unless prefix
    conn.exec_params(<<~SQL, [prefix, user_id, client_id, scope, expires_at_unix, source, ip_address])
      INSERT INTO ai_connect_token_registry
        (token_prefix, user_id, client_id, scope, issued_at, expires_at, source, ip_address)
      VALUES ($1, $2, $3, $4, NOW(), to_timestamp($5), $6, $7)
      ON CONFLICT (token_prefix) DO NOTHING
    SQL
  end

  def self.registry_for(token)
    prefix = token_prefix(token)
    return nil unless prefix
    conn.exec_params(
      "SELECT * FROM ai_connect_token_registry WHERE token_prefix=$1",
      [prefix]
    ).first
  end

  def self.mark_token_used(token)
    prefix = token_prefix(token)
    return nil unless prefix
    conn.exec_params(
      "UPDATE ai_connect_token_registry SET last_used_at=NOW() WHERE token_prefix=$1 AND revoked_at IS NULL",
      [prefix]
    )
  end

  def self.list_tokens(include_revoked: true)
    sql = "SELECT * FROM ai_connect_token_registry"
    sql += " WHERE revoked_at IS NULL" unless include_revoked
    sql += " ORDER BY issued_at DESC"
    conn.exec(sql).to_a
  end

  def self.revoke_token_by_prefix(prefix, revoked_by: nil)
    return false if prefix.nil? || prefix.empty?
    reg = conn.exec_params(
      "SELECT * FROM ai_connect_token_registry WHERE token_prefix=$1 AND revoked_at IS NULL",
      [prefix]
    ).first
    return false unless reg
    conn.exec_params(
      "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 WHERE token_prefix=$1",
      [prefix, revoked_by]
    )
    # Also revoke the actual token + refresh chain in ai_tokens
    conn.exec_params(
      "UPDATE ai_tokens SET revoked=TRUE WHERE token LIKE $1 OR parent_token LIKE $1",
      ["#{prefix}%"]
    )
    true
  end

  # Generic rate limit check that supports any window key (e.g. token, IP, "oauth_authorize:<ip>")
  def self.check_rate_limit(key, per_minute: 50, per_hour: 1000, prefix: '')
    now = Time.now.to_i
    [[60, per_minute, "#{prefix}minute"], [3600, per_hour, "#{prefix}hour"]].each do |interval, limit, wtype|
      ws = now - (now % interval)
      result = conn.exec_params("SELECT * FROM ai_rate_limits WHERE token=$1 AND window_type=$2", [key, wtype])
      if (row = result.first)
        if row['window_start'].to_i == ws
          return { limited: true, window: wtype, limit: limit } if row['request_count'].to_i >= limit
          conn.exec_params("UPDATE ai_rate_limits SET request_count=request_count+1 WHERE id=$1", [row['id']])
        else
          conn.exec_params("UPDATE ai_rate_limits SET window_start=$1, request_count=1 WHERE id=$2", [ws, row['id']])
        end
      else
        conn.exec_params("INSERT INTO ai_rate_limits (token,window_type,window_start,request_count) VALUES ($1,$2,$3,1)", [key, wtype, ws])
      end
    end
    { limited: false }
  end
end
