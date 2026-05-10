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

  def self.save_tokens(client_id, uid, scope)
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
    { access: at, refresh: rt }
  end

  def self.get_token(token)
    result = conn.exec_params("SELECT * FROM ai_tokens WHERE token=$1 AND revoked=FALSE", [token])
    result.first
  end

  def self.revoke_token(token)
    conn.exec_params("UPDATE ai_tokens SET revoked=TRUE WHERE token=$1 OR parent_token=$1", [token])
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
