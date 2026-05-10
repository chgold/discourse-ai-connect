# Stub responses for Discourse API (used when DISCOURSE_STUB_MODE=1).
# Lets the bridge serve realistic data without a running Discourse instance — useful for tests,
# CI, and demo environments where bootstrapping full Discourse (Postgres + Redis + sidekiq) is
# impractical.
module StubData
  CATEGORIES = [
    { 'id' => 1, 'name' => 'General',         'description' => 'General discussions',                'topic_count' => 2 },
    { 'id' => 2, 'name' => 'Tech Support',    'description' => 'Get help with technical issues',     'topic_count' => 2 },
    { 'id' => 3, 'name' => 'Announcements',   'description' => 'Important community announcements',  'topic_count' => 1 }
  ].freeze

  TOPICS = [
    { 'id' => 101, 'title' => 'Welcome to the forum',          'slug' => 'welcome-to-the-forum',          'posts_count' => 3, 'category_id' => 1, 'last_posted_at' => '2026-05-01T10:00:00Z' },
    { 'id' => 102, 'title' => 'Forum rules and etiquette',     'slug' => 'forum-rules-and-etiquette',     'posts_count' => 2, 'category_id' => 1, 'last_posted_at' => '2026-05-02T10:00:00Z' },
    { 'id' => 201, 'title' => 'How to install AI Connect?',    'slug' => 'how-to-install-ai-connect',     'posts_count' => 4, 'category_id' => 2, 'last_posted_at' => '2026-05-03T10:00:00Z' },
    { 'id' => 202, 'title' => 'OAuth callback not working',    'slug' => 'oauth-callback-not-working',    'posts_count' => 5, 'category_id' => 2, 'last_posted_at' => '2026-05-04T10:00:00Z' },
    { 'id' => 301, 'title' => 'v1.0 released',                 'slug' => 'v10-released',                  'posts_count' => 1, 'category_id' => 3, 'last_posted_at' => '2026-05-05T10:00:00Z' }
  ].freeze

  POSTS = [
    { 'id' => 1001, 'topic_id' => 101, 'username' => 'admin',   'raw' => 'Welcome aboard everyone!',                          'cooked' => '<p>Welcome aboard everyone!</p>' },
    { 'id' => 1002, 'topic_id' => 101, 'username' => 'alice',   'raw' => 'Thanks for the warm welcome.',                      'cooked' => '<p>Thanks for the warm welcome.</p>' },
    { 'id' => 1003, 'topic_id' => 102, 'username' => 'admin',   'raw' => 'Please be respectful in all your interactions.',    'cooked' => '<p>Please be respectful in all your interactions.</p>' },
    { 'id' => 2001, 'topic_id' => 201, 'username' => 'bob',     'raw' => 'How do I install AI Connect on my forum?',          'cooked' => '<p>How do I install AI Connect on my forum?</p>' },
    { 'id' => 2002, 'topic_id' => 201, 'username' => 'admin',   'raw' => 'Just drop the plugin into ./plugins and restart.',   'cooked' => '<p>Just drop the plugin into ./plugins and restart.</p>' },
    { 'id' => 3001, 'topic_id' => 301, 'username' => 'admin',   'raw' => 'v1.0 is now available with OAuth + 11 tools.',      'cooked' => '<p>v1.0 is now available with OAuth + 11 tools.</p>' }
  ].freeze

  USERS = [
    { 'id' => 1, 'username' => 'admin', 'name' => 'Administrator', 'trust_level' => 4, 'post_count' => 12 },
    { 'id' => 2, 'username' => 'alice', 'name' => 'Alice Demo',    'trust_level' => 2, 'post_count' => 5  },
    { 'id' => 3, 'username' => 'bob',   'name' => 'Bob Demo',      'trust_level' => 1, 'post_count' => 3  }
  ].freeze

  def self.lookup(method, path)
    case
    when path.start_with?('/categories.json')
      { 'category_list' => { 'categories' => CATEGORIES } }
    when path.start_with?('/latest.json')
      { 'topic_list' => { 'topics' => TOPICS } }
    when path =~ %r{\A/c/(\d+)\.json}
      cat_id = ::Regexp.last_match(1).to_i
      { 'topic_list' => { 'topics' => TOPICS.select { |t| t['category_id'] == cat_id } } }
    when path.start_with?('/search.json')
      query = path[/q=([^&]+)/, 1].to_s
      decoded = URI.decode_www_form_component(query).downcase
      matches = TOPICS.select { |t| t['title'].downcase.include?(decoded) }
      matches = TOPICS if matches.empty? && decoded.empty?
      { 'topics' => matches }
    when path =~ %r{\A/t/(\d+)\.json}
      tid = ::Regexp.last_match(1).to_i
      topic = TOPICS.find { |t| t['id'] == tid }
      return { 'error_type' => 'not_found' } unless topic
      topic.merge('post_stream' => { 'posts' => POSTS.select { |p| p['topic_id'] == tid } })
    when path =~ %r{\A/posts/(\d+)\.json}
      pid = ::Regexp.last_match(1).to_i
      post = POSTS.find { |p| p['id'] == pid }
      return { 'error_type' => 'not_found' } unless post
      post
    when path =~ %r{\A/users/([^.]+)\.json}
      uname = ::Regexp.last_match(1)
      user = USERS.find { |u| u['username'] == uname }
      return { 'error_type' => 'not_found' } unless user
      { 'user' => user }
    when path == '/posts.json' && method == :post
      { 'id' => 9999, 'topic_id' => 999, 'username' => 'admin' }
    when path =~ %r{\A/posts/(\d+)\.json} && method == :put
      { 'id' => ::Regexp.last_match(1).to_i, 'edited' => true }
    when path == '/post_actions.json'
      { 'success' => 'OK' }
    else
      { 'error_type' => 'not_implemented', 'message' => "Stub does not implement #{method} #{path}" }
    end
  end
end
