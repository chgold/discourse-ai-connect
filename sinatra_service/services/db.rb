require 'pg'
require 'securerandom'
require 'logger'

module DB
  LOGGER = Logger.new($stdout)
  LOGGER.progname = 'DB'

  CLEANUP_INTERVAL   = 86_400  # 24 hours in seconds
  UNUSED_DAYS        = 30
  INACTIVE_DAYS      = 180
  EXPIRED_GRACE_DAYS = 90
  PURGE_DAYS         = 365

  @last_cleanup_at = nil

  def self.config
    {
      host:     ENV.fetch('DB_HOST', '127.0.0.1'),
      port:     ENV.fetch('DB_PORT', '5432').to_i,
      dbname:   ENV.fetch('DB_NAME', 'discourse_dev'),
      user:     ENV.fetch('DB_USER', 'discourse'),
      password: ENV.fetch('DB_PASSWORD') {
        if ENV['RACK_ENV'] == 'production'
          raise 'DB_PASSWORD environment variable is required in production'
        end
        ''
      }
    }
  end

  def self.conn
    # A libpq connection is not thread-safe; Puma serves on multiple threads, so
    # sharing one connection corrupts the protocol (SSL "bad record mac"). Keep
    # one connection per thread, reconnecting if it was closed/broken.
    c = Thread.current[:ai_connect_pg]
    if c.nil? || c.finished?
      LOGGER.info("Connecting to PostgreSQL #{config[:host]}:#{config[:port]}/#{config[:dbname]} as #{config[:user]}")
      c = PG.connect(config)
      c.exec("SET client_min_messages=WARNING") rescue nil
      Thread.current[:ai_connect_pg] = c
    end
    c
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

    # Idempotent v2 column migrations — last_used_ip, last_used_ua
    conn.exec(<<~SQL)
      ALTER TABLE ai_connect_token_registry
        ADD COLUMN IF NOT EXISTS last_used_ip VARCHAR(45) NULL,
        ADD COLUMN IF NOT EXISTS last_used_ua VARCHAR(255) NULL;
      CREATE INDEX IF NOT EXISTS idx_token_registry_last_used
        ON ai_connect_token_registry(last_used_at);
      CREATE INDEX IF NOT EXISTS idx_token_registry_revoked_expires
        ON ai_connect_token_registry(revoked_at, expires_at);
    SQL

    # Idempotent widen: legacy installs created ai_rate_limits.window_type as
    # VARCHAR(10), which cannot hold 'token_minute'/'oauth_minute' — every call
    # to the token endpoint (incl. refresh grants) failed with a 500.
    conn.exec(<<~SQL)
      DO $$
      BEGIN
        IF (SELECT character_maximum_length FROM information_schema.columns
             WHERE table_name = 'ai_rate_limits' AND column_name = 'window_type'
               AND table_schema = current_schema()) < 20 THEN
          ALTER TABLE ai_rate_limits ALTER COLUMN window_type TYPE VARCHAR(20);
        END IF;
      END $$;
    SQL

    conn.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS ai_blocked_users (
        user_id BIGINT PRIMARY KEY,
        blocked_at TIMESTAMP DEFAULT NOW(),
        blocked_by BIGINT
      );
    SQL

    conn.exec(<<~SQL)
      CREATE TABLE IF NOT EXISTS ai_connect_meta (
        key_name VARCHAR(100) PRIMARY KEY,
        value TEXT,
        updated_at BIGINT NOT NULL
      );
    SQL

    seeded_clients = [
      { id: 'webmcp-master',     name: 'WebMCP Master',     scopes: 'read write delete manage_users' },
      { id: 'claude',            name: 'claude',            scopes: 'read write delete' },
      { id: 'chatgpt',           name: 'chatgpt',           scopes: 'read write delete' },
      { id: 'gemini',            name: 'gemini',            scopes: 'read write delete' },
      { id: 'grok',              name: 'grok',              scopes: 'read write delete' },
      { id: 'copilot',           name: 'copilot',           scopes: 'read write delete' },
      { id: 'perplexity',        name: 'perplexity',        scopes: 'read write delete' },
      { id: 'meta-ai',           name: 'meta-ai',           scopes: 'read write delete' },
      { id: 'deepseek',          name: 'deepseek',          scopes: 'read write delete' },
      { id: 'ai-agent-default',  name: 'ai-agent-default',  scopes: 'read write delete' },
    ]
    seeded_clients.each do |c|
      conn.exec_params(
        "INSERT INTO ai_clients (client_id, client_name, redirect_uris, scopes) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING",
        [c[:id], c[:name], 'urn:ietf:wg:oauth:2.0:oob', c[:scopes]]
      )
    end
  end

  # Normalize client_id per protocol spec: claude / claude-ai / claude_ai are equivalent.
  def self.normalize_client_id(client_id)
    return nil if client_id.nil?
    client_id.to_s.downcase.gsub(/[-_]ai\z/, '').gsub(/[-_]/, '')
  end

  def self.get_client(client_id)
    result = conn.exec_params("SELECT * FROM ai_clients WHERE client_id=$1", [client_id])
    row = result.first
    return row if row

    normalized = normalize_client_id(client_id)
    return nil if normalized.nil? || normalized.empty?
    all = conn.exec("SELECT * FROM ai_clients").to_a
    all.find { |r| normalize_client_id(r['client_id']) == normalized }
  end

  def self.list_clients
    conn.exec("SELECT client_id, client_name FROM ai_clients ORDER BY id ASC").to_a
  end

  def self.registered_clients_map
    list_clients.each_with_object({}) { |row, h| h[row['client_id']] = row['client_name'] }
  rescue PG::Error => e
    LOGGER.warn("registered_clients_map failed: #{e.message}")
    {}
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
    at = "xfa_#{SecureRandom.hex(32)}"
    rt = "xfr_#{SecureRandom.hex(32)}"
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

  # RFC 7009 revocation (Servio SPEC §5.2). `token` may be the access OR the
  # refresh token of a pair; either one revokes the WHOLE pair plus its registry
  # row (admin list / "My tokens") in one transaction. `hint` only changes the
  # lookup order. Tokens are stored in plaintext (no hash column), so the lookup
  # is a plaintext match. Returns true if a pair was found (already-revoked
  # pairs count too), false for unknown tokens — callers must not leak this.
  def self.revoke_pair(token, hint: nil, revoked_by: nil)
    return false if token.nil? || token.to_s.empty?

    order = hint.to_s == 'refresh_token' ? %w[refresh access] : %w[access refresh]
    row = nil
    order.each do |type|
      row = conn.exec_params(
        'SELECT token, token_type, parent_token FROM ai_tokens WHERE token=$1 AND token_type=$2',
        [token, type]
      ).first
      break if row
    end
    return false unless row

    access = row['token_type'] == 'access' ? row['token'] : row['parent_token']
    conn.transaction do |c|
      c.exec_params('UPDATE ai_tokens SET revoked=TRUE WHERE token=$1', [row['token']])
      if access && !access.empty?
        c.exec_params('UPDATE ai_tokens SET revoked=TRUE WHERE token=$1 OR parent_token=$1', [access])
        c.exec_params(
          'UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 ' \
          'WHERE token_prefix=$1 AND revoked_at IS NULL',
          [token_prefix(access), revoked_by]
        )
      end
    end
    true
  end

  # ---------------------------------------------------------------------------
  # Token Registry — visibility + revocation for issued bearer tokens
  # ---------------------------------------------------------------------------

  TOKEN_PREFIX_LENGTH = 16

  # Token state filters — used by list_tokens and bulk-revoke
  FILTER_CLAUSES = {
    'active'   => "revoked_at IS NULL AND expires_at > NOW()",
    'used'     => "revoked_at IS NULL AND expires_at > NOW() AND last_used_at IS NOT NULL AND last_used_at > NOW() - 30 * INTERVAL '1 day'",
    'unused'   => "revoked_at IS NULL AND expires_at > NOW() AND last_used_at IS NULL",
    'inactive' => "revoked_at IS NULL AND expires_at > NOW() AND last_used_at IS NOT NULL AND last_used_at < NOW() - 30 * INTERVAL '1 day'",
    'expired'  => "revoked_at IS NULL AND expires_at <= NOW()",
    'revoked'  => "revoked_at IS NOT NULL"
  }.freeze

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

  # touch_last_used — best-effort: updates last_used_at, last_used_ip, last_used_ua.
  # Never raises; failure must never block the authenticated request.
  def self.touch_last_used(token, ip: nil, ua: nil)
    prefix = token_prefix(token)
    return nil unless prefix
    conn.exec_params(
      <<~SQL,
        UPDATE ai_connect_token_registry
        SET last_used_at = NOW(),
            last_used_ip = COALESCE($2, last_used_ip),
            last_used_ua = COALESCE(LEFT($3, 255), last_used_ua)
        WHERE token_prefix = $1 AND revoked_at IS NULL
      SQL
      [prefix, ip, ua]
    )
    nil
  rescue PG::Error => e
    LOGGER.warn("touch_last_used failed (best-effort): #{e.message}")
    nil
  end

  # Backward-compatible alias — kept so existing callers don't break
  def self.mark_token_used(token)
    touch_last_used(token)
  end

  # ---------------------------------------------------------------------------
  # List helpers
  # ---------------------------------------------------------------------------

  def self.list_tokens(include_revoked: true, filter: nil)
    conditions = []
    if filter && FILTER_CLAUSES.key?(filter.to_s)
      conditions << FILTER_CLAUSES[filter.to_s]
    elsif !include_revoked
      conditions << "revoked_at IS NULL"
    end
    sql = "SELECT * FROM ai_connect_token_registry"
    sql += " WHERE #{conditions.join(' AND ')}" unless conditions.empty?
    sql += " ORDER BY issued_at DESC"
    conn.exec(sql).to_a
  end

  def self.list_tokens_for_user(uid, filter: nil)
    conditions = ["user_id = $1"]
    conditions << FILTER_CLAUSES[filter.to_s] if filter && FILTER_CLAUSES.key?(filter.to_s)
    sql  = "SELECT * FROM ai_connect_token_registry"
    sql += " WHERE #{conditions.join(' AND ')}"
    sql += " ORDER BY issued_at DESC"
    conn.exec_params(sql, [uid]).to_a
  end

  def self.user_has_active_tokens?(uid)
    result = conn.exec_params(
      "SELECT 1 FROM ai_connect_token_registry WHERE user_id=$1 AND revoked_at IS NULL AND expires_at > NOW() LIMIT 1",
      [uid]
    )
    result.ntuples > 0
  end

  # ---------------------------------------------------------------------------
  # Revoke methods
  # ---------------------------------------------------------------------------

  def self.revoke_token_by_prefix(prefix, revoked_by: nil)
    return false if prefix.nil? || prefix.empty?
    reg = conn.exec_params(
      "SELECT id FROM ai_connect_token_registry WHERE token_prefix=$1 AND revoked_at IS NULL",
      [prefix]
    ).first
    return false unless reg
    conn.exec_params(
      "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 WHERE token_prefix=$1",
      [prefix, revoked_by]
    )
    cascade_ai_tokens_by_prefix(prefix)
    true
  end

  # Revoke a single registry row by its integer id
  def self.revoke_by_id(id, revoked_by: nil)
    result = conn.exec_params(
      "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 WHERE id=$1 AND revoked_at IS NULL RETURNING token_prefix",
      [id, revoked_by]
    )
    return false if result.ntuples == 0
    cascade_ai_tokens_by_prefix(result.first['token_prefix'])
    true
  end

  # Revoke every active token belonging to a user
  def self.revoke_all_for_user(uid, revoked_by: nil)
    result = conn.exec_params(
      "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 WHERE user_id=$1 AND revoked_at IS NULL RETURNING token_prefix",
      [uid, revoked_by]
    )
    result.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    result.ntuples
  end

  # Revoke an explicit list of registry ids
  def self.revoke_by_ids(ids, revoked_by: nil)
    return 0 if ids.nil? || ids.empty?
    safe_ids = ids.map(&:to_i).select(&:positive?)
    return 0 if safe_ids.empty?
    placeholders = safe_ids.each_index.map { |i| "$#{i + 2}" }.join(',')
    result = conn.exec_params(
      "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$1 WHERE id IN (#{placeholders}) AND revoked_at IS NULL RETURNING token_prefix",
      [revoked_by, *safe_ids]
    )
    result.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    result.ntuples
  end

  # Revoke tokens never used (last_used_at IS NULL) older than `days` days
  def self.revoke_unused(days: UNUSED_DAYS, revoked_by: nil)
    result = if days.nil? || days.to_i <= 0
      conn.exec_params(
        <<~SQL, [revoked_by]
          UPDATE ai_connect_token_registry
          SET revoked_at = NOW(), revoked_by = $1
          WHERE revoked_at IS NULL
            AND last_used_at IS NULL
          RETURNING token_prefix
        SQL
      )
    else
      conn.exec_params(
        <<~SQL, [revoked_by, days.to_i]
          UPDATE ai_connect_token_registry
          SET revoked_at = NOW(), revoked_by = $1
          WHERE revoked_at IS NULL
            AND last_used_at IS NULL
            AND issued_at < NOW() - $2 * INTERVAL '1 day'
          RETURNING token_prefix
        SQL
      )
    end
    result.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    result.ntuples
  end

  # Revoke tokens not used in more than `days` days
  def self.revoke_inactive(days: INACTIVE_DAYS, revoked_by: nil)
    result = conn.exec_params(
      <<~SQL,
        UPDATE ai_connect_token_registry
        SET revoked_at = NOW(), revoked_by = $1
        WHERE revoked_at IS NULL
          AND last_used_at IS NOT NULL
          AND last_used_at < NOW() - $2 * INTERVAL '1 day'
        RETURNING token_prefix
      SQL
      [revoked_by, days]
    )
    result.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    result.ntuples
  end

  # Revoke a list of token prefixes (by-prefix), optionally only those issued before
  # before_time (unix int).  Cascades the refresh-token chain in ai_tokens.
  # Used by upgrade/backfill path (see SPEC §9).
  def self.cascade_revoke_oauth(prefixes, before_time: nil, revoked_by: 0)
    return 0 if prefixes.nil? || prefixes.empty?
    count = 0
    prefixes.each do |prefix|
      next if prefix.nil? || prefix.empty?
      result = if before_time
        conn.exec_params(
          "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 WHERE token_prefix=$1 AND revoked_at IS NULL AND issued_at < to_timestamp($3) RETURNING token_prefix",
          [prefix, revoked_by, before_time.to_i]
        )
      else
        conn.exec_params(
          "UPDATE ai_connect_token_registry SET revoked_at=NOW(), revoked_by=$2 WHERE token_prefix=$1 AND revoked_at IS NULL RETURNING token_prefix",
          [prefix, revoked_by]
        )
      end
      next if result.ntuples == 0
      cascade_ai_tokens_by_prefix(prefix)
      count += 1
    end
    count
  end

  def self.revoke_all_tokens(revoked_by: nil)
    result = conn.exec_params(
      "UPDATE ai_connect_token_registry SET revoked_at = NOW(), revoked_by = $1 WHERE revoked_at IS NULL RETURNING token_prefix",
      [revoked_by]
    )
    result.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    result.ntuples
  end

  # ---------------------------------------------------------------------------
  # User blocking
  # ---------------------------------------------------------------------------

  def self.block_user(uid, admin_uid = nil)
    conn.exec_params(
      "INSERT INTO ai_blocked_users (user_id, blocked_at, blocked_by) VALUES ($1, NOW(), $2) ON CONFLICT (user_id) DO UPDATE SET blocked_at = NOW(), blocked_by = $2",
      [uid, admin_uid]
    )
  end

  def self.unblock_user(uid)
    conn.exec_params("DELETE FROM ai_blocked_users WHERE user_id = $1", [uid])
  end

  def self.user_blocked?(uid)
    result = conn.exec_params("SELECT 1 FROM ai_blocked_users WHERE user_id = $1", [uid])
    result.ntuples > 0
  end

  # ---------------------------------------------------------------------------
  # Auto-cleanup (lazy / scheduled)
  # ---------------------------------------------------------------------------

  def self.should_run_cleanup?
    return true if @last_cleanup_at.nil?
    Time.now.to_i - @last_cleanup_at >= CLEANUP_INTERVAL
  end

  # Runs all four cleanup rules from SPEC §5.1.
  # Returns a hash of counts for audit logging.
  # Never raises — caller should rescue.
  def self.run_cleanup(revoked_by: nil)
    @last_cleanup_at = Time.now.to_i
    counts = {}

    # Rule 1: never-used tokens older than 30 days
    r = conn.exec_params(
      <<~SQL, [revoked_by]
        UPDATE ai_connect_token_registry
        SET revoked_at = NOW(), revoked_by = $1
        WHERE revoked_at IS NULL
          AND last_used_at IS NULL
          AND issued_at < NOW() - #{UNUSED_DAYS} * INTERVAL '1 day'
        RETURNING token_prefix
      SQL
    )
    r.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    counts[:unused_revoked] = r.ntuples

    # Rule 2: inactive tokens (last used > 180 days ago)
    r = conn.exec_params(
      <<~SQL, [revoked_by]
        UPDATE ai_connect_token_registry
        SET revoked_at = NOW(), revoked_by = $1
        WHERE revoked_at IS NULL
          AND last_used_at IS NOT NULL
          AND last_used_at < NOW() - #{INACTIVE_DAYS} * INTERVAL '1 day'
        RETURNING token_prefix
      SQL
    )
    r.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    counts[:inactive_revoked] = r.ntuples

    # Rule 3: expired > 90 days ago but not yet revoked
    r = conn.exec_params(
      <<~SQL, [revoked_by]
        UPDATE ai_connect_token_registry
        SET revoked_at = NOW(), revoked_by = $1
        WHERE revoked_at IS NULL
          AND expires_at < NOW() - #{EXPIRED_GRACE_DAYS} * INTERVAL '1 day'
        RETURNING token_prefix
      SQL
    )
    r.each { |row| cascade_ai_tokens_by_prefix(row['token_prefix']) }
    counts[:expired_revoked] = r.ntuples

    # Rule 4: hard-delete rows revoked > 365 days ago (GDPR purge)
    purged = conn.exec(
      "DELETE FROM ai_connect_token_registry WHERE revoked_at IS NOT NULL AND revoked_at < NOW() - #{PURGE_DAYS} * INTERVAL '1 day' RETURNING id"
    )
    counts[:purged] = purged.ntuples

    total = counts.values.sum
    LOGGER.info("Token cleanup complete: #{counts.inspect} (total=#{total})")
    counts
  rescue PG::Error => e
    LOGGER.error("run_cleanup failed: #{e.message}")
    {}
  end

  # ---------------------------------------------------------------------------
  # Rate limiting
  # ---------------------------------------------------------------------------

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  def self.cascade_ai_tokens_by_prefix(prefix)
    return unless prefix
    conn.exec_params(
      "UPDATE ai_tokens SET revoked=TRUE WHERE token LIKE $1 OR parent_token LIKE $1",
      ["#{prefix}%"]
    )
  rescue PG::Error => e
    LOGGER.warn("cascade_ai_tokens_by_prefix failed for #{prefix}: #{e.message}")
  end
  private_class_method :cascade_ai_tokens_by_prefix
end
