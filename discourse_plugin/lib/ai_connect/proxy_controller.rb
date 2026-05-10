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
      result = BridgeClient.proxy(
        :get,
        '/oauth/authorize',
        user:   current_user,
        params: params.permit(:client_id, :code_challenge, :redirect_uri, :scope, :state).to_h
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

    private

    def ensure_enabled
      raise Discourse::NotFound unless SiteSetting.ai_connect_enabled
    end
  end
end
