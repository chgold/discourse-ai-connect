# frozen_string_literal: true

module AiConnect
  module Modules
    # Read-only discovery tools: categories, tags, search and topic history.
    #
    # Every call goes through DiscourseApi, which authenticates as the connected
    # user, so Discourse's own category and group permissions decide what comes
    # back. Nothing here bypasses them.
    class ContentModule < AiConnect::ModuleBase
      def module_name
        'discourse'
      end

      def register_tools
        register_categories_tools
        register_tag_tools
        register_search_tools
        register_topic_tools
      end

      private

      # ── registration ────────────────────────────────────────────────────

      def register_categories_tools
        register_tool :listCategories, {
          description: 'List forum categories with topic counts and descriptions',
          input_schema: { type: 'object', properties: {} },
          required_scope: 'read',
          validation_schema: { required: {}, optional: {} }
        }

        register_tool :getCategory, {
          description: 'Get a single category by ID',
          input_schema: { type: 'object', required: ['category_id'],
                          properties: { category_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { category_id: :integer }, optional: {} }
        }

        register_tool :searchCategories, {
          description: 'Find categories whose name matches a query',
          input_schema: { type: 'object', required: ['query'],
                          properties: { query: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { query: :string }, optional: {} }
        }

        register_tool :listTopicsByCategory, {
          description: 'List the topics inside a category',
          input_schema: { type: 'object', required: ['category_id'],
                          properties: { category_id: { type: 'integer' }, page: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { category_id: :integer }, optional: { page: :integer } }
        }
      end

      def register_tag_tools
        register_tool :listTags, {
          description: 'List the tags used on the forum, with usage counts',
          input_schema: { type: 'object', properties: {} },
          required_scope: 'read',
          validation_schema: { required: {}, optional: {} }
        }

        register_tool :getTag, {
          description: 'Get a tag and the topics using it',
          input_schema: { type: 'object', required: ['tag'],
                          properties: { tag: { type: 'string' }, page: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { tag: :string }, optional: { page: :integer } }
        }

        register_tool :searchTags, {
          description: 'Find tags matching a query',
          input_schema: { type: 'object', required: ['query'],
                          properties: { query: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { query: :string }, optional: {} }
        }

        register_tool :listTopicsByTag, {
          description: 'List the topics carrying a given tag',
          input_schema: { type: 'object', required: ['tag'],
                          properties: { tag: { type: 'string' }, page: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { tag: :string }, optional: { page: :integer } }
        }
      end

      def register_search_tools
        register_tool :searchPosts, {
          description: 'Search posts by keyword',
          input_schema: { type: 'object', required: ['query'],
                          properties: { query: { type: 'string' }, page: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { query: :string }, optional: { page: :integer } }
        }

        register_tool :searchByAuthor, {
          description: 'Search posts written by a specific user',
          input_schema: { type: 'object', required: ['username'],
                          properties: { username: { type: 'string' }, query: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { username: :string }, optional: { query: :string } }
        }

        register_tool :searchInCategory, {
          description: 'Search within one category',
          input_schema: { type: 'object', required: ['category', 'query'],
                          properties: { category: { type: 'string' }, query: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { category: :string, query: :string }, optional: {} }
        }

        register_tool :searchByTag, {
          description: 'Search topics carrying a given tag',
          input_schema: { type: 'object', required: ['tag'],
                          properties: { tag: { type: 'string' }, query: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { tag: :string }, optional: { query: :string } }
        }

        register_tool :searchUsers, {
          description: 'Find users by name or username',
          input_schema: { type: 'object', required: ['query'],
                          properties: { query: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { query: :string }, optional: {} }
        }

        register_tool :getTopTopics, {
          description: 'Get the top topics for a period (daily, weekly, monthly, yearly, all)',
          input_schema: { type: 'object',
                          properties: { period: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: {}, optional: { period: :string } }
        }
      end

      def register_topic_tools
        register_tool :getTopicSummary, {
          description: 'Get a topic without its full post stream — title, counts, tags and category',
          input_schema: { type: 'object', required: ['topic_id'],
                          properties: { topic_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { topic_id: :integer }, optional: {} }
        }

        register_tool :getTopicPostsRange, {
          description: 'Get a slice of a topic\'s posts, for reading long topics page by page',
          input_schema: { type: 'object', required: ['topic_id'],
                          properties: { topic_id: { type: 'integer' },
                                        offset: { type: 'integer' },
                                        limit: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { topic_id: :integer },
                               optional: { offset: :integer, limit: :integer } }
        }

        register_tool :getPostRevisions, {
          description: 'List the edit history of a post',
          input_schema: { type: 'object', required: ['post_id'],
                          properties: { post_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { post_id: :integer }, optional: {} }
        }

        register_tool :getPostRevisionContent, {
          description: 'Get the content of one specific post revision',
          input_schema: { type: 'object', required: %w[post_id revision],
                          properties: { post_id: { type: 'integer' },
                                        revision: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { post_id: :integer, revision: :integer }, optional: {} }
        }
      end

      # ── categories ──────────────────────────────────────────────────────

      def execute_listCategories(_params, _context)
        result = DiscourseApi.get('/categories.json')
        categories_from(result).map { |c| format_category(c) }
      end

      def execute_getCategory(params, _context)
        result = DiscourseApi.get("/c/#{params[:category_id]}/show.json")
        return { error: 'not_found', message: 'Category not found' } if result['error_type']

        format_category(result['category'] || result)
      end

      def execute_searchCategories(params, _context)
        needle = params[:query].to_s.downcase
        result = DiscourseApi.get('/categories.json')

        categories_from(result)
          .select { |c| "#{c['name']} #{c['description']}".to_s.downcase.include?(needle) }
          .map { |c| format_category(c) }
      end

      def execute_listTopicsByCategory(params, _context)
        page = params[:page] || 0
        result = DiscourseApi.get("/c/#{params[:category_id]}.json?page=#{page}")
        return { error: 'not_found', message: 'Category not found' } if result['error_type']

        topics_from(result).map { |t| format_topic(t) }
      end

      # ── tags ────────────────────────────────────────────────────────────

      def execute_listTags(_params, _context)
        result = DiscourseApi.get('/tags.json')
        tags_from(result).map { |t| format_tag(t) }
      end

      def execute_getTag(params, _context)
        tag = CGI.escape(params[:tag].to_s)
        page = params[:page] || 0
        result = DiscourseApi.get("/tag/#{tag}.json?page=#{page}")
        return { error: 'not_found', message: 'Tag not found' } if result['error_type']

        { tag: params[:tag], topics: topics_from(result).map { |t| format_topic(t) } }
      end

      def execute_searchTags(params, _context)
        needle = params[:query].to_s.downcase
        result = DiscourseApi.get('/tags.json')

        tags_from(result)
          .select { |t| t['id'].to_s.downcase.include?(needle) || t['text'].to_s.downcase.include?(needle) }
          .map { |t| format_tag(t) }
      end

      def execute_listTopicsByTag(params, _context)
        execute_getTag(params, nil)
      end

      # ── search ──────────────────────────────────────────────────────────

      def execute_searchPosts(params, _context)
        search(params[:query], page: params[:page])
      end

      def execute_searchByAuthor(params, _context)
        search("#{params[:query]} @#{params[:username]}".strip)
      end

      def execute_searchInCategory(params, _context)
        search("#{params[:query]} #category:#{params[:category]}".strip)
      end

      def execute_searchByTag(params, _context)
        search("#{params[:query]} #tag:#{params[:tag]}".strip)
      end

      def execute_searchUsers(params, _context)
        result = DiscourseApi.get("/u/search/users.json?term=#{CGI.escape(params[:query].to_s)}")
        (result['users'] || []).map do |u|
          { username: u['username'], name: u['name'], avatar_template: u['avatar_template'] }
        end
      end

      def execute_getTopTopics(params, _context)
        period = %w[daily weekly monthly quarterly yearly all].include?(params[:period].to_s) ? params[:period] : 'weekly'
        result = DiscourseApi.get("/top.json?period=#{period}")
        { period: period, topics: topics_from(result).map { |t| format_topic(t) } }
      end

      # ── topics and revisions ────────────────────────────────────────────

      def execute_getTopicSummary(params, _context)
        result = DiscourseApi.get("/t/#{params[:topic_id]}.json")
        return { error: 'not_found', message: 'Topic not found' } if result['error_type']

        {
          id: result['id'],
          title: result['title'],
          slug: result['slug'],
          posts_count: result['posts_count'],
          views: result['views'],
          like_count: result['like_count'],
          category_id: result['category_id'],
          tags: result['tags'] || [],
          created_at: result['created_at'],
          last_posted_at: result['last_posted_at'],
          closed: result['closed'],
          archived: result['archived']
        }
      end

      def execute_getTopicPostsRange(params, _context)
        result = DiscourseApi.get("/t/#{params[:topic_id]}.json")
        return { error: 'not_found', message: 'Topic not found' } if result['error_type']

        posts = result.dig('post_stream', 'posts') || []
        offset = [params[:offset].to_i, 0].max
        limit = params[:limit].to_i
        limit = 20 if limit <= 0
        limit = 100 if limit > 100

        {
          topic_id: result['id'],
          title: result['title'],
          total_posts: result['posts_count'],
          offset: offset,
          returned: posts.slice(offset, limit)&.length || 0,
          posts: (posts.slice(offset, limit) || []).map { |p| format_post(p) }
        }
      end

      def execute_getPostRevisions(params, _context)
        # Discourse exposes revisions one at a time. Walk backwards from the
        # post's current version so the caller gets the real history rather
        # than an assumed range.
        post = DiscourseApi.get("/posts/#{params[:post_id]}.json")
        return { error: 'not_found', message: 'Post not found' } if post['error_type']

        latest = post['version'].to_i
        revisions = []

        (2..latest).each do |number|
          rev = DiscourseApi.get("/posts/#{params[:post_id]}/revisions/#{number}.json")
          next if rev['error_type']

          revisions << {
            revision: number,
            created_at: rev['created_at'],
            username: rev['username'],
            edit_reason: rev['edit_reason']
          }
        end

        { post_id: params[:post_id], current_version: latest, revisions: revisions }
      end

      def execute_getPostRevisionContent(params, _context)
        rev = DiscourseApi.get("/posts/#{params[:post_id]}/revisions/#{params[:revision]}.json")
        return { error: 'not_found', message: 'Revision not found' } if rev['error_type']

        {
          post_id: params[:post_id],
          revision: params[:revision],
          created_at: rev['created_at'],
          username: rev['username'],
          edit_reason: rev['edit_reason'],
          body: rev.dig('body_changes', 'inline') || rev.dig('body_changes', 'side_by_side') || ''
        }
      end

      # ── helpers ─────────────────────────────────────────────────────────

      def search(query, page: nil)
        path = "/search.json?q=#{CGI.escape(query.to_s)}"
        path += "&page=#{page}" if page

        result = DiscourseApi.get(path)
        {
          topics: (result['topics'] || []).map { |t| format_topic(t) },
          posts: (result['posts'] || []).map { |p| format_post(p) }
        }
      end

      # Discourse returns categories under different keys depending on the
      # endpoint, so normalise rather than assuming one shape.
      def categories_from(result)
        result.dig('category_list', 'categories') || result['categories'] || []
      end

      def topics_from(result)
        result.dig('topic_list', 'topics') || result['topics'] || []
      end

      def tags_from(result)
        result['tags'] || result.dig('extras', 'tags') || []
      end

      def format_category(category)
        {
          id: category['id'],
          name: category['name'],
          slug: category['slug'],
          description: category['description_text'] || category['description'],
          topic_count: category['topic_count'],
          post_count: category['post_count'],
          parent_category_id: category['parent_category_id'],
          read_restricted: category['read_restricted']
        }
      end

      def format_topic(topic)
        {
          id: topic['id'],
          title: topic['title'],
          slug: topic['slug'],
          posts_count: topic['posts_count'],
          views: topic['views'],
          like_count: topic['like_count'],
          category_id: topic['category_id'],
          tags: topic['tags'] || [],
          created_at: topic['created_at'],
          last_posted_at: topic['last_posted_at']
        }
      end

      def format_post(post)
        {
          id: post['id'],
          topic_id: post['topic_id'],
          username: post['username'],
          created_at: post['created_at'],
          cooked: post['cooked'],
          blurb: post['blurb']
        }
      end

      def format_tag(tag)
        { id: tag['id'], text: tag['text'] || tag['id'], count: tag['count'] }
      end
    end
  end
end
