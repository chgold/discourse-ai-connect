# frozen_string_literal: true

module AiConnect
  class ProxyController < ::ApplicationController
    requires_plugin AiConnect::PLUGIN_NAME

    skip_before_action :check_xhr, only: [:info, :manifest, :authorize, :handle_consent]
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
        headers: { 'X-AI-Connect-CSRF' => form_authenticity_token }
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

    def generate_token
      raise Discourse::NotLoggedIn unless current_user

      result = BridgeClient.proxy(:post, '/api/ai-connect/generate-token', user: current_user)
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

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.ai_connect_enabled
    end
  end
end
