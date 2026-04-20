module ManifestController
  BASE_URL = ENV.fetch('DISCOURSE_AI_CONNECT_URL', 'http://localhost:8086')

  TOOLS = [
    { name: 'discourse.searchTopics',    description: 'Search forum topics by keyword',            input_schema: { type: 'object', required: ['query'], properties: { query: { type: 'string' }, page: { type: 'integer' } } } },
    { name: 'discourse.getTopic',        description: 'Get a topic with all its posts',            input_schema: { type: 'object', required: ['topic_id'], properties: { topic_id: { type: 'integer' } } } },
    { name: 'discourse.getPost',         description: 'Get a single post by ID',                  input_schema: { type: 'object', required: ['post_id'], properties: { post_id: { type: 'integer' } } } },
    { name: 'discourse.getCategories',   description: 'List all forum categories',                 input_schema: { type: 'object', properties: {} } },
    { name: 'discourse.getUserProfile',  description: 'Get a user profile by username',            input_schema: { type: 'object', required: ['username'], properties: { username: { type: 'string' } } } },
    { name: 'discourse.getLatestTopics', description: 'Get latest topics with optional category',  input_schema: { type: 'object', properties: { category_id: { type: 'integer' }, page: { type: 'integer' } } } },
    { name: 'discourse.createTopic',     description: 'Create a new topic (Pro)',                  input_schema: { type: 'object', required: %w[title raw category_id], properties: { title: { type: 'string' }, raw: { type: 'string' }, category_id: { type: 'integer' } } } },
    { name: 'discourse.replyToTopic',    description: 'Post a reply to an existing topic (Pro)',   input_schema: { type: 'object', required: %w[topic_id raw], properties: { topic_id: { type: 'integer' }, raw: { type: 'string' } } } },
    { name: 'discourse.editPost',        description: 'Edit an existing post (Pro)',               input_schema: { type: 'object', required: %w[post_id raw], properties: { post_id: { type: 'integer' }, raw: { type: 'string' } } } },
    { name: 'discourse.sendMessage',     description: 'Send a private message to a user (Pro)',   input_schema: { type: 'object', required: %w[username title raw], properties: { username: { type: 'string' }, title: { type: 'string' }, raw: { type: 'string' } } } },
    { name: 'discourse.likePost',        description: 'Like or unlike a post (Pro)',              input_schema: { type: 'object', required: ['post_id'], properties: { post_id: { type: 'integer' }, unlike: { type: 'boolean' } } } },
  ].freeze

  def self.get
    {
      schema_version:  '1.0',
      name:            'discourse-plugin',
      version:         '1.0.0',
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
      tools: TOOLS.map { |t| { name: t[:name], description: t[:description], input_schema: t[:input_schema] } },
    }
  end
end
