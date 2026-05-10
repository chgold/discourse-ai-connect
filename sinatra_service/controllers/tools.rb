require_relative '../lib/input_validator'

module ToolsController
  PRO_TOOLS = %w[
    discourse.createTopic discourse.replyToTopic discourse.editPost
    discourse.sendMessage discourse.likePost
  ].freeze

  SCHEMAS = {
    'discourse.searchTopics'    => { required: { query: :string }, optional: { page: :integer } },
    'discourse.getTopic'        => { required: { topic_id: :integer }, optional: {} },
    'discourse.getPost'         => { required: { post_id: :integer }, optional: {} },
    'discourse.getCategories'   => { required: {}, optional: {} },
    'discourse.getUserProfile'  => { required: { username: :string }, optional: {} },
    'discourse.getLatestTopics' => { required: {}, optional: { category_id: :integer, page: :integer } },
    'discourse.createTopic'     => { required: { title: :string, raw: :string, category_id: :integer }, optional: {} },
    'discourse.replyToTopic'    => { required: { topic_id: :integer, raw: :string }, optional: {} },
    'discourse.editPost'        => { required: { post_id: :integer, raw: :string }, optional: {} },
    'discourse.sendMessage'     => { required: { username: :string, title: :string, raw: :string }, optional: {} },
    'discourse.likePost'        => { required: { post_id: :integer }, optional: { unlike: :boolean } }
  }.freeze

  def self.execute(tool_name, params, _uid, scope)
    schema = SCHEMAS[tool_name]
    return { error: 'tool_not_found' } unless schema

    if PRO_TOOLS.include?(tool_name) && !scope.to_s.include?('write')
      return { error: 'insufficient_scope', message: 'This tool requires write scope (Pro tier)' }
    end

    validated, err = InputValidator.validate(params, schema)
    return { error: 'invalid_params', message: err } if err

    case tool_name
    when 'discourse.searchTopics'
      result = DiscourseApi.get("/search.json?q=#{URI.encode_www_form_component(validated[:query])}&page=#{validated[:page] || 1}")
      (result['topics'] || []).map { |t| { id: t['id'], title: t['title'], slug: t['slug'], posts_count: t['posts_count'] } }

    when 'discourse.getTopic'
      result = DiscourseApi.get("/t/#{validated[:topic_id]}.json")
      return { error: 'not_found' } if result['error_type']
      { id: result['id'], title: result['title'], posts_count: result['posts_count'],
        posts: ((result.dig('post_stream', 'posts')) || []).map { |p| { id: p['id'], cooked: p['cooked'], username: p['username'] } } }

    when 'discourse.getPost'
      result = DiscourseApi.get("/posts/#{validated[:post_id]}.json")
      return { error: 'not_found' } if result['error_type']
      { id: result['id'], topic_id: result['topic_id'], raw: result['raw'], username: result['username'] }

    when 'discourse.getCategories'
      result = DiscourseApi.get('/categories.json')
      (result.dig('category_list', 'categories') || []).map { |c| { id: c['id'], name: c['name'], description: c['description'], topic_count: c['topic_count'] } }

    when 'discourse.getUserProfile'
      result = DiscourseApi.get("/users/#{URI.encode_www_form_component(validated[:username])}.json")
      return { error: 'not_found' } if result['error_type']
      u = result['user']
      { id: u['id'], username: u['username'], name: u['name'], trust_level: u['trust_level'], post_count: u['post_count'] }

    when 'discourse.getLatestTopics'
      path = validated[:category_id] ? "/c/#{validated[:category_id]}.json" : '/latest.json'
      result = DiscourseApi.get("#{path}?page=#{validated[:page] || 0}")
      (result.dig('topic_list', 'topics') || []).map do |t|
        { id: t['id'], title: t['title'], slug: t['slug'], posts_count: t['posts_count'], last_posted_at: t['last_posted_at'] }
      end

    when 'discourse.createTopic'
      result = DiscourseApi.post('/posts.json', { title: validated[:title], raw: validated[:raw], category: validated[:category_id] })
      return { error: result['errors']&.join(', ') || 'create_failed' } if result['error_type'] || result['errors']
      { id: result['topic_id'], post_id: result['id'], title: validated[:title] }

    when 'discourse.replyToTopic'
      result = DiscourseApi.post('/posts.json', { topic_id: validated[:topic_id], raw: validated[:raw] })
      return { error: result['errors']&.join(', ') || 'reply_failed' } if result['error_type'] || result['errors']
      { post_id: result['id'], topic_id: validated[:topic_id] }

    when 'discourse.editPost'
      result = DiscourseApi.put("/posts/#{validated[:post_id]}.json", { post: { raw: validated[:raw] } })
      return { error: 'edit_failed' } if result['error_type']
      { post_id: validated[:post_id], edited: true }

    when 'discourse.sendMessage'
      result = DiscourseApi.post('/posts.json',
                                 { title: validated[:title], raw: validated[:raw], archetype: 'private_message', target_recipients: validated[:username] })
      return { error: result['errors']&.join(', ') || 'send_failed' } if result['error_type'] || result['errors']
      { sent: true, topic_id: result['topic_id'] }

    when 'discourse.likePost'
      DiscourseApi.post('/post_actions.json', { id: validated[:post_id], post_action_type_id: 2, flag_topic: false })
      { liked: !validated[:unlike], post_id: validated[:post_id] }
    end
  end
end
