# frozen_string_literal: true

module AiConnect
  module Modules
    class ProModule < AiConnect::ModuleBase
      def module_name
        'discourse'
      end

      def register_tools
        register_tool :createTopic, {
          description: 'Create a new topic (Pro)',
          input_schema: { type: 'object', required: %w[title raw category_id], properties: { title: { type: 'string' }, raw: { type: 'string' }, category_id: { type: 'integer' } } },
          required_scope: 'write',
          pro_only: true,
          validation_schema: { required: { title: :string, raw: :string, category_id: :integer }, optional: {} }
        }

        register_tool :replyToTopic, {
          description: 'Post a reply to an existing topic (Pro)',
          input_schema: { type: 'object', required: %w[topic_id raw], properties: { topic_id: { type: 'integer' }, raw: { type: 'string' } } },
          required_scope: 'write',
          pro_only: true,
          validation_schema: { required: { topic_id: :integer, raw: :string }, optional: {} }
        }

        register_tool :editPost, {
          description: 'Edit an existing post (Pro)',
          input_schema: { type: 'object', required: %w[post_id raw], properties: { post_id: { type: 'integer' }, raw: { type: 'string' } } },
          required_scope: 'write',
          pro_only: true,
          validation_schema: { required: { post_id: :integer, raw: :string }, optional: {} }
        }

        register_tool :sendMessage, {
          description: 'Send a private message to a user (Pro)',
          input_schema: { type: 'object', required: %w[username title raw], properties: { username: { type: 'string' }, title: { type: 'string' }, raw: { type: 'string' } } },
          required_scope: 'write',
          pro_only: true,
          validation_schema: { required: { username: :string, title: :string, raw: :string }, optional: {} }
        }

        register_tool :likePost, {
          description: 'Like or unlike a post (Pro)',
          input_schema: { type: 'object', required: ['post_id'], properties: { post_id: { type: 'integer' }, unlike: { type: 'boolean' } } },
          required_scope: 'write',
          pro_only: true,
          validation_schema: { required: { post_id: :integer }, optional: { unlike: :boolean } }
        }
      end

      private

      def execute_createTopic(params, _context)
        result = DiscourseApi.post('/posts.json', { title: params[:title], raw: params[:raw], category: params[:category_id] })
        return { error: result['errors']&.join(', ') || 'create_failed' } if result['error_type'] || result['errors']

        { id: result['topic_id'], post_id: result['id'], title: params[:title] }
      end

      def execute_replyToTopic(params, _context)
        result = DiscourseApi.post('/posts.json', { topic_id: params[:topic_id], raw: params[:raw] })
        return { error: result['errors']&.join(', ') || 'reply_failed' } if result['error_type'] || result['errors']

        { post_id: result['id'], topic_id: params[:topic_id] }
      end

      def execute_editPost(params, _context)
        result = DiscourseApi.put("/posts/#{params[:post_id]}.json", { post: { raw: params[:raw] } })
        return { error: 'edit_failed' } if result['error_type']

        { post_id: params[:post_id], edited: true }
      end

      def execute_sendMessage(params, _context)
        result = DiscourseApi.post(
          '/posts.json',
          { title: params[:title], raw: params[:raw], archetype: 'private_message', target_recipients: params[:username] }
        )
        return { error: result['errors']&.join(', ') || 'send_failed' } if result['error_type'] || result['errors']

        { sent: true, topic_id: result['topic_id'] }
      end

      def execute_likePost(params, _context)
        DiscourseApi.post('/post_actions.json', { id: params[:post_id], post_action_type_id: 2, flag_topic: false })
        { liked: !params[:unlike], post_id: params[:post_id] }
      end
    end
  end
end
