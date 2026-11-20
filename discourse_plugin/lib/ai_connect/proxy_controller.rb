# frozen_string_literal: true

module AiConnect
  class ProxyController < ::ApplicationController
    requires_plugin AiConnect::PLUGIN_NAME

    skip_before_action :check_xhr, only: [:info, :manifest, :authorize, :handle_consent,
                                         :ai_actions, :ai_actions_decide, :ai_actions_revoke_autonomy]
    before_action :ensure_enabled

    def info
      result = BridgeClient.proxy(:get, '/ai-connect')
      render html: result[:body].to_s.html_safe, status: result[:status]
    rescue BridgeClient::BridgeError => e
      render plain: "AI Connect bridge unavailable: #{e.message}", status: 502
    end

    def manifest
      result = BridgeClient.proxy(:get, '/api/ai-connect/manifest')
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    def authorize
      unless current_user
        cookies[:destination_url] = request.fullpath
        return redirect_to path('/login')
      end

      result = BridgeClient.proxy(
        :get,
        '/oauth/authorize',
        user:    current_user,
        params:  params.permit(:client_id, :code_challenge, :redirect_uri, :scope, :state).to_h,
        # The consent form posts back to this proxy; Discourse's CSRF check
        # must pass, so hand the bridge this session's token to embed.
        headers: { 'X-AI-Connect-CSRF' => form_authenticity_token,
                   # Subfolder installs (relative_url_root): the form must post to
                   # <base_path>/ai-connect-plugin/authorize, not the domain root.
                   'X-AI-Connect-Base-Path' => Discourse.base_path.to_s }
      )
      render html: result[:body].to_s.html_safe, status: result[:status]
    rescue BridgeClient::BridgeError => e
      render plain: "Bridge unavailable: #{e.message}", status: 502
    end

    def handle_consent
      raise Discourse::NotLoggedIn unless current_user

      result = BridgeClient.proxy(
        :post,
        '/oauth/authorize',
        user: current_user,
        body: params.permit(:client_id, :code_challenge, :redirect_uri, :scope, :state, :approved).to_h
      )
      if (location = result[:headers]['location'])
        redirect_to location, allow_other_host: true
      else
        render plain: result[:body], status: result[:status]
      end
    rescue BridgeClient::BridgeError => e
      render plain: "Bridge unavailable: #{e.message}", status: 502
    end

    # -------------------------------------------------------------------------
    # AI actions — the human step of user-confirm-v1 (1.2.7)
    # A pending destructive action runs only when the signed-in user confirms it
    # here. Requests authenticated by an API key, a user API key or an
    # Authorization header are refused: whoever holds a token (the agent) must
    # never be able to confirm. POSTs are CSRF-checked by Discourse.
    # -------------------------------------------------------------------------

    # GET /ai-connect-plugin/ai-actions[?confirmation_id=...]
    def ai_actions
      refuse_token_auth!
      unless current_user
        cookies[:destination_url] = request.fullpath
        return redirect_to path('/login')
      end

      result = BridgeClient.proxy(:get, '/api/ai-connect/confirmations/page', user: current_user,
                                  params: params.permit(:confirmation_id).to_h, headers: ai_actions_headers)
      render html: result[:body].to_s.html_safe, status: result[:status]
    rescue BridgeClient::BridgeError => e
      render plain: "Bridge unavailable: #{e.message}", status: 502
    end

    # POST /ai-connect-plugin/ai-actions/decide  (confirmation_id, decision=confirm|reject, autonomy=1)
    def ai_actions_decide
      refuse_token_auth!
      raise Discourse::NotLoggedIn unless current_user

      result = BridgeClient.proxy(:post, '/api/ai-connect/confirmations/decide', user: current_user,
                                  body: params.permit(:confirmation_id, :decision, :autonomy).to_h, headers: ai_actions_headers)
      render html: result[:body].to_s.html_safe, status: result[:status]
    rescue BridgeClient::BridgeError => e
      render plain: "Bridge unavailable: #{e.message}", status: 502
    end

    # POST /ai-connect-plugin/ai-actions/autonomy/revoke  (grant_id)
    def ai_actions_revoke_autonomy
      refuse_token_auth!
      raise Discourse::NotLoggedIn unless current_user

      result = BridgeClient.proxy(:post, '/api/ai-connect/confirmations/autonomy/revoke', user: current_user,
                                  body: params.permit(:grant_id).to_h, headers: ai_actions_headers)
      render html: result[:body].to_s.html_safe, status: result[:status]
    rescue BridgeClient::BridgeError => e
      render plain: "Bridge unavailable: #{e.message}", status: 502
    end

    def generate_token
      raise Discourse::NotLoggedIn unless current_user

      # Forward the requested scope / client (1.2.6): before this the bridge
      # never saw them and always issued "read write". The bridge still clamps
      # the scope to what this user may hold.
      body = params.permit(:scope, :client_id).to_h.compact
      result = BridgeClient.proxy(:post, '/api/ai-connect/generate-token', user: current_user, body: body)
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    # -------------------------------------------------------------------------
    # User token management — proxied to sinatra_service
    # -------------------------------------------------------------------------

    # GET  /ai-connect-plugin/tokens[?filter=...]
    def user_tokens
      raise Discourse::NotLoggedIn unless current_user

      filter = params[:filter].presence
      path   = filter ? "/api/ai-connect/tokens?filter=#{CGI.escape(filter)}" : '/api/ai-connect/tokens'
      result = BridgeClient.proxy(:get, path, user: current_user)
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    # DELETE /ai-connect-plugin/tokens/:prefix
    def revoke_user_token
      raise Discourse::NotLoggedIn unless current_user

      prefix = params[:prefix].to_s.strip
      return render json: { error: 'invalid_prefix' }, status: 422 if prefix.empty?

      result = BridgeClient.proxy(:delete, "/api/ai-connect/tokens/#{prefix}", user: current_user)
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    # POST /ai-connect-plugin/tokens/bulk-revoke
    # body: { filter: "unused|inactive|all" }
    def bulk_revoke_user_tokens
      raise Discourse::NotLoggedIn unless current_user

      filter = params.require(:filter)
      unless %w[unused inactive all].include?(filter)
        return render json: { error: 'invalid_filter' }, status: 422
      end

      result = BridgeClient.proxy(
        :post,
        '/api/ai-connect/tokens/bulk-revoke',
        user: current_user,
        body: { filter: filter }
      )
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    # -------------------------------------------------------------------------
    # Admin token management — proxied to sinatra_service (admin only)
    # -------------------------------------------------------------------------

    # GET  /ai-connect-plugin/admin/tokens[?filter=...]
    def admin_tokens
      raise Discourse::InvalidAccess unless current_user&.admin?

      filter = params[:filter].presence
      path   = filter ? "/api/ai-connect/admin/tokens?filter=#{CGI.escape(filter)}" : '/api/ai-connect/admin/tokens'
      result = BridgeClient.proxy(:get, path, user: current_user)
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    # DELETE /ai-connect-plugin/admin/tokens/:prefix
    def admin_revoke_token
      raise Discourse::InvalidAccess unless current_user&.admin?

      prefix = params[:prefix].to_s.strip
      return render json: { error: 'invalid_prefix' }, status: 422 if prefix.empty?

      result = BridgeClient.proxy(:delete, "/api/ai-connect/admin/tokens/#{prefix}", user: current_user)
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    # POST /ai-connect-plugin/admin/tokens/bulk-revoke
    # body: { filter: "unused|inactive|all", days: N (optional) }
    def admin_bulk_revoke_tokens
      raise Discourse::InvalidAccess unless current_user&.admin?

      filter = params.require(:filter)
      unless %w[unused inactive all].include?(filter)
        return render json: { error: 'invalid_filter' }, status: 422
      end

      body = { filter: filter }
      body[:days] = params[:days].to_i if params[:days].present?

      result = BridgeClient.proxy(
        :post,
        '/api/ai-connect/admin/tokens/bulk-revoke',
        user: current_user,
        body: body
      )
      render json: result[:body], status: result[:status]
    rescue BridgeClient::BridgeError => e
      render json: { error: 'bridge_unreachable', message: e.message }, status: 502
    end

    private

    def refuse_token_auth!
      token_auth = is_api? || is_user_api? || request.authorization.present? ||
                   request.headers['Api-Key'].present? || request.headers['User-Api-Key'].present?
      raise Discourse::InvalidAccess if token_auth
    end

    def ai_actions_headers
      { 'X-AI-Connect-CSRF' => form_authenticity_token,
        'X-AI-Connect-Base-Path' => Discourse.base_path.to_s,
        'X-AI-Connect-Locale' => current_user.effective_locale.to_s }
    end

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.ai_connect_enabled
    end
  end
end
