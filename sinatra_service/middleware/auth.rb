module AuthMiddleware
  def self.require_bearer(request)
    header = request.env['HTTP_AUTHORIZATION'] || ''
    unless header.start_with?('Bearer ')
      return { error: 'unauthorized', error_description: 'Bearer token required' }
    end
    token = header.sub('Bearer ', '').strip
    return { error: 'unauthorized', error_description: 'Empty token' } if token.empty?

    rec = DB.get_token(token)
    unless rec && rec['token_type'] == 'access' && Time.now.to_i < rec['expires_at'].to_i
      return { error: 'invalid_token', error_description: 'Token expired or revoked' }
    end

    # Pass IP + UA on every successful auth (best-effort, never blocks the request)
    ip = extract_ip(request)
    ua = request.env['HTTP_USER_AGENT']
    DB.touch_last_used(token, ip: ip, ua: ua)

    if DB.should_run_cleanup? && ENV['RACK_ENV'] != 'test'
      Thread.new { DB.run_cleanup rescue nil }
    end

    { uid: rec['uid'].to_i, scope: rec['scope'], token: token, client_id: rec['client_id'] }
  end

  def self.extract_ip(request)
    forwarded = request.env['HTTP_X_FORWARDED_FOR']
    return forwarded.split(',').first.strip if forwarded && !forwarded.empty?
    request.env['REMOTE_ADDR'] || 'unknown'
  end
  private_class_method :extract_ip
end
