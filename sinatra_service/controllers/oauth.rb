require 'digest'
require 'base64'
require 'securerandom'
require 'cgi'

module OAuthController
  def self.base_url
    ENV.fetch('DISCOURSE_AI_CONNECT_URL', 'http://localhost:8086')
  end

  def self.verify_pkce(verifier, challenge)
    return false unless verifier && challenge
    computed = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    # Constant-time comparison to prevent timing attacks
    secure_compare(computed, challenge)
  end

  def self.secure_compare(a, b)
    return false unless a.bytesize == b.bytesize
    res = 0
    a.bytes.zip(b.bytes) { |x, y| res |= x ^ y }
    res.zero?
  end

  # Resolve the Discourse user who is approving the consent.
  # Priority:
  #   1. X-Discourse-Uid header (set by the Discourse plugin when proxying authorized session)
  #   2. uid form param (only allowed when DEV_ALLOW_UID_PARAM=1)
  #   3. nil → caller must redirect to Discourse SSO / login
  def self.resolve_uid(params, env)
    header_uid = env['HTTP_X_DISCOURSE_UID']&.to_i
    return header_uid if header_uid && header_uid.positive?

    if ENV['DEV_ALLOW_UID_PARAM'] == '1' && params['uid']
      params['uid'].to_i
    else
      nil
    end
  end

  def self.authorize(params, env)
    client_id = params['client_id']
    challenge = params['code_challenge']
    return error_html('invalid_request', 'Missing client_id or code_challenge') unless client_id && challenge

    client = DB.get_client(client_id)
    return error_html('invalid_client', 'Unknown client_id') unless client

    scope    = sanitize_scope(params['scope'])
    redirect = params['redirect_uri'].to_s
    state    = params['state'].to_s
    name     = client['client_name']

    # If we can resolve the user from the Discourse session header, show consent.
    # Otherwise prompt them to login at Discourse first.
    uid = resolve_uid(params, env)

    if uid.nil?
      return <<~HTML
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>AI Connect — Sign in required</title>
        <style>body{font-family:system-ui,sans-serif;max-width:480px;margin:80px auto;padding:20px}
        .btn{display:inline-block;padding:10px 20px;background:#4CAF50;color:#fff;border-radius:4px;text-decoration:none}</style></head><body>
        <h2>Sign in required</h2>
        <p>Please sign in to your Discourse forum, then come back to this page.</p>
        <a class="btn" href="/login?return_path=#{CGI.escape(env['REQUEST_URI'].to_s)}">Sign in</a>
        </body></html>
      HTML
    end

    <<~HTML
      <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>AI Connect — Discourse</title>
      <style>body{font-family:system-ui,sans-serif;max-width:480px;margin:80px auto;padding:20px}
      .btn{padding:10px 20px;border:none;border-radius:4px;cursor:pointer;font-size:15px}
      .approve{background:#4CAF50;color:#fff}.deny{background:#f44336;color:#fff;margin-left:8px}</style></head><body>
      <h2>AI Connect Authorization</h2>
      <p>Agent <strong>#{CGI.escapeHTML(name.to_s)}</strong> requests access to your Discourse account (user ID #{uid}).</p>
      <p>Scopes: <strong>#{CGI.escapeHTML(scope)}</strong></p>
      <form method="POST" action="/oauth/authorize">
        <input type="hidden" name="client_id" value="#{CGI.escapeHTML(client_id.to_s)}">
        <input type="hidden" name="code_challenge" value="#{CGI.escapeHTML(challenge.to_s)}">
        <input type="hidden" name="redirect_uri" value="#{CGI.escapeHTML(redirect)}">
        <input type="hidden" name="scope" value="#{CGI.escapeHTML(scope)}">
        <input type="hidden" name="state" value="#{CGI.escapeHTML(state)}">
        <input type="hidden" name="uid" value="#{uid}">
        <button type="submit" name="approved" value="true" class="btn approve">Approve</button>
        <button type="submit" name="approved" value="false" class="btn deny">Deny</button>
      </form></body></html>
    HTML
  end

  def self.handle_consent(params, env)
    if params['approved'] != 'true'
      return { redirect: "#{params['redirect_uri']}?error=access_denied" }
    end

    # Re-validate the UID came from a trusted source — never trust the raw form value alone.
    uid = resolve_uid(params, env)
    return { error: 'unauthorized', error_description: 'User must be authenticated' } if uid.nil?

    client = DB.get_client(params['client_id'])
    return { error: 'invalid_client' } unless client

    challenge = params['code_challenge'].to_s
    return { error: 'invalid_request', error_description: 'PKCE challenge required' } if challenge.empty?

    code = SecureRandom.hex(32)
    DB.save_code(code, params['client_id'], uid, sanitize_scope(params['scope']), challenge, params['redirect_uri'].to_s)

    redirect_uri = params['redirect_uri']
    state        = params['state'].to_s
    dest = if redirect_uri.nil? || redirect_uri.empty? || redirect_uri == 'urn:ietf:wg:oauth:2.0:oob'
             "#{base_url}/oauth/callback?code=#{code}&state=#{CGI.escape(state)}"
           else
             "#{redirect_uri}?code=#{code}&state=#{CGI.escape(state)}"
           end
    { redirect: dest }
  end

  def self.token(params)
    grant = params['grant_type']

    if grant == 'authorization_code'
      rec = DB.get_code(params['code'])
      return { error: 'invalid_grant' } unless rec
      return { error: 'invalid_grant', error_description: 'Code expired or already used' } unless rec['used'] == 'f' && Time.now.to_i < rec['expires_at'].to_i
      return { error: 'invalid_grant', error_description: 'PKCE failed' } unless verify_pkce(params['code_verifier'], rec['code_challenge'])
      DB.mark_code_used(params['code'])
      tokens = DB.save_tokens(rec['client_id'], rec['uid'].to_i, rec['scope'])
      return { access_token: tokens[:access], token_type: 'Bearer', expires_in: 3600, refresh_token: tokens[:refresh], scope: rec['scope'] }
    end

    if grant == 'refresh_token'
      rec = DB.get_token(params['refresh_token'])
      return { error: 'invalid_grant' } unless rec && rec['token_type'] == 'refresh' && Time.now.to_i < rec['expires_at'].to_i
      DB.revoke_token(params['refresh_token'])
      tokens = DB.save_tokens(rec['client_id'], rec['uid'].to_i, rec['scope'])
      return { access_token: tokens[:access], token_type: 'Bearer', expires_in: 3600, refresh_token: tokens[:refresh], scope: rec['scope'] }
    end

    { error: 'unsupported_grant_type' }
  end

  ALLOWED_SCOPES = %w[read write delete].freeze
  def self.sanitize_scope(raw)
    requested = raw.to_s.split(/\s+/).reject(&:empty?)
    filtered  = requested & ALLOWED_SCOPES
    filtered.empty? ? 'read' : filtered.join(' ')
  end

  def self.error_html(error, description)
    <<~HTML
      <!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>AI Connect — Error</title>
      <style>body{font-family:system-ui,sans-serif;max-width:480px;margin:80px auto;padding:20px}
      .err{background:#fee;border:1px solid #f44;padding:14px;border-radius:6px;color:#900}</style></head><body>
      <h2>OAuth Authorization Error</h2>
      <div class="err"><strong>#{CGI.escapeHTML(error)}</strong>: #{CGI.escapeHTML(description)}</div>
      </body></html>
    HTML
  end
end
