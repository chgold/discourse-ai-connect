# frozen_string_literal: true

module ManifestController
  BASE_URL = ENV.fetch('DISCOURSE_AI_CONNECT_URL', 'http://localhost:8086')

  def self.get(registry: nil, scope: 'read write')
    registry ||= DiscourseAiConnect.settings.module_registry
    {
      schema_version:  '1.0',
      name:            'discourse-plugin',
      version:         '1.1.0',
      description:     'AI Connect for Discourse — search, read and participate in community discussions via AI agents',
      api_version:     'v1',
      capabilities:    { tools: true, resources: false, prompts: false },
      server:          { url: "#{BASE_URL}/api/ai-connect/v1", description: 'Tool endpoint base' },
      auth: {
        type:                   'oauth2',
        flow:                   'authorization_code',
        pkce_required:          true,
        code_challenge_method:  'S256',
        authorization_url:      "#{BASE_URL}/oauth/authorize",
        token_url:              "#{BASE_URL}/api/ai-connect/token",
        revocation_url:         "#{BASE_URL}/api/ai-connect/revoke",
        scopes: { read: 'Read topics and posts', write: 'Create topics and replies (Pro)', delete: 'Delete content (Pro)' },
      },
      tools: registry.all_tools(scope: scope),
    }
  end
end
