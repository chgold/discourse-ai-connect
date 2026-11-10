# frozen_string_literal: true

# name: discourse-ai-connect
# about: Connect AI agents (Claude, ChatGPT, Gemini, etc.) to your Discourse forum via the WebMCP / GACP protocol.
# version: 1.2.4
# authors: Chen Gold-Tovi (chgold)
# url: https://github.com/chgold/discourse-ai-connect
# required_version: 2.7.0

enabled_site_setting :ai_connect_enabled

register_asset 'stylesheets/ai-connect.scss'

after_initialize do
  module ::AiConnect
    PLUGIN_NAME = 'discourse-ai-connect'

    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace AiConnect
    end
  end

  require_relative 'lib/ai_connect/bridge_client'
  require_relative 'lib/ai_connect/proxy_controller'

  Discourse::Application.routes.append do
    mount ::AiConnect::Engine, at: '/ai-connect-plugin'
  end

  AiConnect::Engine.routes.draw do
    # Core
    get  '/'                  => 'proxy#info'
    get  '/manifest'          => 'proxy#manifest'
    get  '/authorize'         => 'proxy#authorize'
    post '/authorize'         => 'proxy#handle_consent'
    post '/generate-token'    => 'proxy#generate_token'

    # User token management (authenticated user sees/revokes their own tokens)
    get    '/tokens'                  => 'proxy#user_tokens'
    delete '/tokens/:prefix'          => 'proxy#revoke_user_token',       constraints: { prefix: /[^\/]+/ }
    post   '/tokens/bulk-revoke'      => 'proxy#bulk_revoke_user_tokens'

    # Admin token management (Discourse admin only)
    get    '/admin/tokens'            => 'proxy#admin_tokens'
    delete '/admin/tokens/:prefix'    => 'proxy#admin_revoke_token',      constraints: { prefix: /[^\/]+/ }
    post   '/admin/tokens/bulk-revoke' => 'proxy#admin_bulk_revoke_tokens'
  end

  on(:user_logged_in) do |user|
    AiConnect::BridgeClient.notify_login(user.id) if SiteSetting.ai_connect_notify_login
  end

  # Add a tab to user preferences: /u/:username/preferences/ai-tokens
  # This is rendered client-side via the Ember.js route defined in the plugin assets.
  add_to_serializer(:user, :ai_connect_tokens_url) do
    "/ai-connect-plugin/tokens"
  end
end
