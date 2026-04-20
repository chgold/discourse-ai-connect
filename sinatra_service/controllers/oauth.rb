require 'digest'
require 'base64'
require 'securerandom'

module OAuthController
  BASE_URL = ENV.fetch('DISCOURSE_AI_CONNECT_URL', 'http://localhost:8086')

  def self.verify_pkce(verifier, challenge)
    computed = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    computed == challenge
  end

  def self.authorize(params, env)
    client_id = params['client_id']
    challenge  = params['code_challenge']
    return '{"error":"invalid_request"}' unless client_id && challenge

    client = DB.get_client(client_id)
    return '{"error":"invalid_client"}' unless client

    scope      = params['scope'] || 'read write'
    redirect   = params['redirect_uri'] || ''
    state      = params['state'] || ''
    name       = client['client_name']

    <<~HTML
      <!DOCTYPE html><html><head><meta charset="utf-8"><title>AI Connect — Discourse</title>
      <style>body{font-family:sans-serif;max-width:480px;margin:80px auto;padding:20px}
      .btn{padding:10px 20px;border:none;border-radius:4px;cursor:pointer;font-size:15px}
      .approve{background:#4CAF50;color:#fff}.deny{background:#f44336;color:#fff;margin-left:8px}</style></head><body>
      <h2>AI Connect Authorization</h2>
      <p>Agent <strong>#{name}</strong> requests access to your Discourse account.</p>
      <p>Scopes: <strong>#{scope}</strong></p>
      <form method="POST" action="/oauth/authorize">
        <input type="hidden" name="client_id" value="#{client_id}">
        <input type="hidden" name="code_challenge" value="#{challenge}">
        <input type="hidden" name="redirect_uri" value="#{redirect}">
        <input type="hidden" name="scope" value="#{scope}">
        <input type="hidden" name="state" value="#{state}">
        <input type="hidden" name="uid" value="1">
        <button type="submit" name="approved" value="true" class="btn approve">Approve</button>
        <button type="submit" name="approved" value="false" class="btn deny">Deny</button>
      </form></body></html>
    HTML
  end

  def self.handle_consent(params, env)
    return { redirect: "#{params['redirect_uri']}?error=access_denied" } if params['approved'] != 'true'

    code = SecureRandom.hex(32)
    uid  = (params['uid'] || 1).to_i
    DB.save_code(code, params['client_id'], uid, params['scope'], params['code_challenge'], params['redirect_uri'])

    redirect_uri = params['redirect_uri']
    state        = params['state'] || ''
    dest = (redirect_uri.nil? || redirect_uri.empty? || redirect_uri == 'urn:ietf:wg:oauth:2.0:oob') \
      ? "#{BASE_URL}/oauth/callback?code=#{code}&state=#{state}" \
      : "#{redirect_uri}?code=#{code}&state=#{state}"
    { redirect: dest }
  end

  def self.token(params)
    grant = params['grant_type']

    if grant == 'authorization_code'
      rec = DB.get_code(params['code'])
      return { error: 'invalid_grant' } unless rec && rec['used'] == 'f' && Time.now.to_i < rec['expires_at'].to_i
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
end
