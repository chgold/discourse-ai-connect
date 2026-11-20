require 'digest'
require 'base64'
require 'securerandom'
require 'cgi'
require_relative '../lib/redirect_uri'

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
  # The X-Discourse-Uid header is trusted ONLY when the request carries the
  # shared proxy secret (env['ai_connect.trusted_proxy'], set by the app after a
  # constant-time compare). Anyone who can reach the sidecar directly could
  # otherwise mint a code for any uid. The uid form param is a test-only aid.
  def self.resolve_uid(params, env)
    return nil unless env['ai_connect.trusted_proxy'] == true

    header_uid = env['HTTP_X_DISCOURSE_UID']&.to_i
    return header_uid if header_uid && header_uid.positive?

    if ENV['RACK_ENV'] == 'test' && ENV['DEV_ALLOW_UID_PARAM'] == '1' && params['uid']
      uid = params['uid'].to_i
      uid.positive? ? uid : nil
    end
  end

  # Base path of a subfolder Discourse install (e.g. "/forum"), sent by the
  # Discourse proxy. Honoured only from the trusted proxy and only when it is a
  # plain absolute path; anything else means "installed at the domain root".
  def self.proxy_base_path(env)
    return '' unless env['ai_connect.trusted_proxy'] == true

    path = env['HTTP_X_AI_CONNECT_BASE_PATH'].to_s
    path.match?(%r{\A(/[A-Za-z0-9._~-]+)+\z}) ? path : ''
  end

  def self.authorize(params, env)
    client_id = params['client_id']
    challenge = params['code_challenge']
    return error_html('invalid_request', 'Missing client_id or code_challenge') unless client_id && challenge

    client = DB.get_client(client_id)
    return error_html('invalid_client', 'Unknown client_id') unless client

    redirect = params['redirect_uri'].to_s
    state    = params['state'].to_s
    name     = client['client_name']
    # 1.2.8 (OAuth 2.1 / RFC 9700): only a redirect_uri the client registered
    # (exact match). A refused request gets our error page — never a redirect.
    unless RedirectUri.registered?(redirect, RedirectUri.registered_list(client['redirect_uris']))
      return error_html('invalid_request', 'redirect_uri is not registered for this client')
    end
    method = params['code_challenge_method'].to_s
    return error_html('invalid_request', 'Only S256 code_challenge_method is supported') unless method.empty? || method == 'S256'

    # If we can resolve the user from the Discourse session header, show consent.
    # Otherwise prompt them to login at Discourse first.
    uid = resolve_uid(params, env)
    scope = clamp_scope(sanitize_scope(params['scope']), uid)
    # Consent rendered through the Discourse proxy posts back to the proxy
    # route (so the session + CSRF token are re-checked by Discourse).
    form_action = env['ai_connect.trusted_proxy'] && env['HTTP_X_DISCOURSE_UID'] ? "#{proxy_base_path(env)}/ai-connect-plugin/authorize" : '/oauth/authorize'
    csrf = env['HTTP_X_AI_CONNECT_CSRF'].to_s
    csrf_field = csrf.empty? ? '' : %(<input type="hidden" name="authenticity_token" value="#{CGI.escapeHTML(csrf)}">)

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
      <form method="POST" action="#{form_action}">
        #{csrf_field}
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
    # 1.2.8: client and registered redirect_uri are checked BEFORE Approve or
    # Deny redirects anywhere (Deny used to redirect to whatever was posted).
    client = DB.get_client(params['client_id'])
    return { error: 'invalid_client' } unless client

    redirect_uri = params['redirect_uri'].to_s
    unless RedirectUri.registered?(redirect_uri, RedirectUri.registered_list(client['redirect_uris']))
      return { error: 'invalid_request', error_description: 'redirect_uri is not registered for this client' }
    end
    oob = RedirectUri.normalise(redirect_uri) == RedirectUri::OOB
    sep = redirect_uri.include?('?') ? '&' : '?'
    state = params['state'].to_s

    if params['approved'] != 'true'
      return { error: 'access_denied', error_description: 'Authorization denied' } if oob

      return { redirect: "#{redirect_uri}#{sep}error=access_denied&state=#{CGI.escape(state)}" }
    end

    # Re-validate the UID came from a trusted source — never trust the raw form value alone.
    uid = resolve_uid(params, env)
    return { error: 'unauthorized', error_description: 'User must be authenticated' } if uid.nil?

    challenge = params['code_challenge'].to_s
    return { error: 'invalid_request', error_description: 'PKCE challenge required' } if challenge.empty?

    method = params['code_challenge_method'].to_s
    return { error: 'invalid_request', error_description: 'Only S256 code_challenge_method is supported' } unless method.empty? || method == 'S256'

    code = SecureRandom.hex(32)
    scope = clamp_scope(sanitize_scope(params['scope']), uid)
    DB.save_code(code, params['client_id'], uid, scope, challenge, redirect_uri)

    dest = if oob
             "#{base_url}/oauth/callback?code=#{code}&state=#{CGI.escape(state)}"
           else
             "#{redirect_uri}#{sep}code=#{code}&state=#{CGI.escape(state)}"
           end
    { redirect: dest }
  end

  def self.token(params, ip: nil)
    grant = params['grant_type']

    if grant == 'authorization_code'
      rec = DB.get_code(params['code'])
      return { error: 'invalid_grant' } unless rec
      return { error: 'invalid_grant', error_description: 'Code expired or already used' } unless rec['used'] == 'f' && Time.now.to_i < rec['expires_at'].to_i
      # 1.2.8: the code is bound to its client and redirect_uri.
      unless params['client_id'].to_s.empty?
        sent_client = DB.get_client(params['client_id'])
        code_client = DB.get_client(rec['client_id'])
        return { error: 'invalid_grant', error_description: 'client_id does not match the authorization code' } unless sent_client && code_client && sent_client['client_id'] == code_client['client_id']
      end
      sent_redirect = params.key?('redirect_uri') ? params['redirect_uri'] : nil
      return { error: 'invalid_grant', error_description: 'redirect_uri does not match the authorization request' } unless RedirectUri.token_matches?(rec['redirect_uri'], sent_redirect)
      return { error: 'invalid_grant', error_description: 'PKCE failed' } unless verify_pkce(params['code_verifier'], rec['code_challenge'])
      DB.mark_code_used(params['code'])
      tokens = DB.save_tokens(rec['client_id'], rec['uid'].to_i, rec['scope'], source: 'oauth', ip_address: ip)
      return { access_token: tokens[:access], token_type: 'Bearer', expires_in: 3600, refresh_token: tokens[:refresh], scope: rec['scope'] }
    end

    if grant == 'refresh_token'
      rec = DB.get_token(params['refresh_token'])
      return { error: 'invalid_grant' } unless rec && rec['token_type'] == 'refresh' && Time.now.to_i < rec['expires_at'].to_i
      DB.revoke_token(params['refresh_token'])
      tokens = DB.save_tokens(rec['client_id'], rec['uid'].to_i, rec['scope'], source: 'refresh', ip_address: ip)
      return { access_token: tokens[:access], token_type: 'Bearer', expires_in: 3600, refresh_token: tokens[:refresh], scope: rec['scope'] }
    end

    { error: 'unsupported_grant_type' }
  end

  ALLOWED_SCOPES = %w[read write delete].freeze
  PRIVILEGED_SCOPES = %w[delete admin].freeze
  def self.sanitize_scope(raw)
    requested = raw.to_s.split(/\s+/).reject(&:empty?)
    filtered  = requested & ALLOWED_SCOPES
    filtered.empty? ? 'read' : filtered.join(' ')
  end

  # Privileged scopes (delete/admin) are granted only to Discourse admins.
  # Everyone else gets at most "read write". Lookup failure = not admin.
  def self.clamp_scope(scope, uid)
    tokens = scope.to_s.split(/\s+/).reject(&:empty?)
    return scope if (tokens & PRIVILEGED_SCOPES).empty?
    return scope if uid && DiscourseUsers.admin?(uid)

    clamped = tokens - PRIVILEGED_SCOPES
    clamped.empty? ? 'read' : clamped.join(' ')
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
