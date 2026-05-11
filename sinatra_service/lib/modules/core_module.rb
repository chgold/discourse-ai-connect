# frozen_string_literal: true

module AiConnect
  module Modules
    class CoreModule < AiConnect::ModuleBase
      def module_name
        'discourse'
      end

      def register_tools
        register_tool :searchTopics, {
          description: 'Search forum topics by keyword',
          input_schema: { type: 'object', required: ['query'], properties: { query: { type: 'string' }, page: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { query: :string }, optional: { page: :integer } }
        }

        register_tool :getTopic, {
          description: 'Get a topic with all its posts',
          input_schema: { type: 'object', required: ['topic_id'], properties: { topic_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { topic_id: :integer }, optional: {} }
        }

        register_tool :getPost, {
          description: 'Get a single post by ID',
          input_schema: { type: 'object', required: ['post_id'], properties: { post_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { post_id: :integer }, optional: {} }
        }

        register_tool :getCategories, {
          description: 'List all forum categories',
          input_schema: { type: 'object', properties: {} },
          required_scope: 'read',
          validation_schema: { required: {}, optional: {} }
        }

        register_tool :getUserProfile, {
          description: 'Get a user profile by username',
          input_schema: { type: 'object', required: ['username'], properties: { username: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { username: :string }, optional: {} }
        }

        register_tool :getLatestTopics, {
          description: 'Get latest topics with optional category',
          input_schema: { type: 'object', properties: { category_id: { type: 'integer' }, page: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: {}, optional: { category_id: :integer, page: :integer } }
        }
      end

      private

      def execute_searchTopics(params, _context)
        result = DiscourseApi.get("/search.json?q=#{URI.encode_www_form_component(params[:query])}&page=#{params[:page] || 1}")
        (result['topics'] || []).map { |t| { id: t['id'], title: t['title'], slug: t['slug'], posts_count: t['posts_count'] } }
      end

      def execute_getTopic(params, _context)
        result = DiscourseApi.get("/t/#{params[:topic_id]}.json")
        return { error: 'not_found' } if result['error_type']

        {
          id: result['id'],
          title: result['title'],
          posts_count: result['posts_count'],
          posts: (result.dig('post_stream', 'posts') || []).map { |p| { id: p['id'], cooked: p['cooked'], username: p['username'] } }
        }
      end

      def execute_getPost(params, _context)
        result = DiscourseApi.get("/posts/#{params[:post_id]}.json")
        return { error: 'not_found' } if result['error_type']

        { id: result['id'], topic_id: result['topic_id'], raw: result['raw'], username: result['username'] }
      end

      def execute_getCategories(_params, _context)
        result = DiscourseApi.get('/categories.json')
        (result.dig('category_list', 'categories') || []).map do |c|
          { id: c['id'], name: c['name'], description: c['description'], topic_count: c['topic_count'] }
        end
      end

      def execute_getUserProfile(params, _context)
        result = DiscourseApi.get("/users/#{URI.encode_www_form_component(params[:username])}.json")
        return { error: 'not_found' } if result['error_type']

        u = result['user']
        { id: u['id'], username: u['username'], name: u['name'], trust_level: u['trust_level'], post_count: u['post_count'] }
      end

      def execute_getLatestTopics(params, _context)
        path = params[:category_id] ? "/c/#{params[:category_id]}.json" : '/latest.json'
        result = DiscourseApi.get("#{path}?page=#{params[:page] || 0}")
        (result.dig('topic_list', 'topics') || []).map do |t|
          { id: t['id'], title: t['title'], slug: t['slug'], posts_count: t['posts_count'], last_posted_at: t['last_posted_at'] }
        end
      end
    end
  end
end
