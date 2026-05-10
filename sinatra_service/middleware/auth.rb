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
    { uid: rec['uid'].to_i, scope: rec['scope'], token: token }
  end
end
