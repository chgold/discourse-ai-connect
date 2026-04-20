module ToolsController
  PRO_TOOLS = %w[
    discourse.createTopic discourse.replyToTopic discourse.editPost
    discourse.sendMessage discourse.likePost
  ].freeze

  def self.execute(tool_name, params, uid, scope)
    if PRO_TOOLS.include?(tool_name) && !scope.to_s.include?('write')
      return { error: 'insufficient_scope', message: 'This tool requires write scope (Pro tier)' }
    end

    case tool_name
    when 'discourse.searchTopics'
      result = DiscourseApi.get("/search.json?q=#{URI.encode_www_form_component(params['query'] || '')}&page=#{params['page'] || 1}")
      topics = result['topics'] || []
      topics.map { |t| { id: t['id'], title: t['title'], slug: t['slug'], posts_count: t['posts_count'] } }

    when 'discourse.getTopic'
      result = DiscourseApi.get("/t/#{params['topic_id']}.json")
      return { error: 'not_found' } if result['error_type']
      { id: result['id'], title: result['title'], posts_count: result['posts_count'],
        posts: (result['post_stream']['posts'] || []).map { |p| { id: p['id'], cooked: p['cooked'], username: p['username'] } } }

    when 'discourse.getPost'
      result = DiscourseApi.get("/posts/#{params['post_id']}.json")
      return { error: 'not_found' } if result['error_type']
      { id: result['id'], topic_id: result['topic_id'], raw: result['raw'], username: result['username'] }

    when 'discourse.getCategories'
      result = DiscourseApi.get('/categories.json')
      (result.dig('category_list', 'categories') || []).map { |c| { id: c['id'], name: c['name'], description: c['description'], topic_count: c['topic_count'] } }

    when 'discourse.getUserProfile'
      result = DiscourseApi.get("/users/#{params['username']}.json")
      return { error: 'not_found' } if result['error_type']
      u = result['user']
      { id: u['id'], username: u['username'], name: u['name'], trust_level: u['trust_level'], post_count: u['post_count'] }

    when 'discourse.getLatestTopics'
      path = params['category_id'] ? "/c/#{params['category_id']}.json" : '/latest.json'
      result = DiscourseApi.get("#{path}?page=#{params['page'] || 0}")
      topics = result.dig('topic_list', 'topics') || []
      topics.map { |t| { id: t['id'], title: t['title'], slug: t['slug'], posts_count: t['posts_count'], last_posted_at: t['last_posted_at'] } }

    when 'discourse.createTopic'
      result = DiscourseApi.post('/posts.json', { title: params['title'], raw: params['raw'], category: params['category_id'] })
      return { error: result['errors']&.join(', ') || 'create_failed' } if result['error_type'] || result['errors']
      { id: result['topic_id'], post_id: result['id'], title: params['title'] }

    when 'discourse.replyToTopic'
      result = DiscourseApi.post('/posts.json', { topic_id: params['topic_id'], raw: params['raw'] })
      return { error: result['errors']&.join(', ') || 'reply_failed' } if result['error_type'] || result['errors']
      { post_id: result['id'], topic_id: params['topic_id'] }

    when 'discourse.editPost'
      result = DiscourseApi.put("/posts/#{params['post_id']}.json", { post: { raw: params['raw'] } })
      return { error: 'edit_failed' } if result['error_type']
      { post_id: params['post_id'], edited: true }

    when 'discourse.sendMessage'
      result = DiscourseApi.post('/posts.json', { title: params['title'], raw: params['raw'], archetype: 'private_message', target_recipients: params['username'] })
      return { error: result['errors']&.join(', ') || 'send_failed' } if result['error_type'] || result['errors']
      { sent: true, topic_id: result['topic_id'] }

    when 'discourse.likePost'
      action = params['unlike'] ? 'destroy' : 'create'
      result = DiscourseApi.post("/post_actions.json", { id: params['post_id'], post_action_type_id: 2, flag_topic: false })
      { liked: !params['unlike'], post_id: params['post_id'] }

    else
      { error: 'tool_not_found' }
    end
  end
end
