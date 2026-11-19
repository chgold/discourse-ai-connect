# frozen_string_literal: true

require 'cgi'

module AiConnect
  module Modules
    # Read-only community tools added in 1.2.6 (Deep Research round 2):
    # who am I, site facts, badges, related topics, participants, likes,
    # a user's public activity, and the connected user's OWN notifications,
    # bookmarks and drafts.
    #
    # Every call goes through DiscourseApi AS the token owner, so Discourse's
    # Guardian decides what comes back. Personal tools always use the acting
    # username — never a username taken from the arguments — so one user can
    # never read another user's notifications, bookmarks or drafts.
    class CommunityModule < AiConnect::ModuleBase
      ACTIVITY_FILTERS = {
        'topics' => '4',
        'replies' => '5',
        'likes_given' => '1',
        'all' => '4,5'
      }.freeze

      def module_name
        'discourse'
      end

      def register_tools
        register_tool :getCurrentUser, {
          description: 'Who am I? The connected Discourse user (username, name, trust level, staff flags, groups) ' \
                       'and the scopes this token grants. Use it to check the connection.',
          input_schema: { type: 'object', properties: {} },
          required_scope: 'read',
          validation_schema: { required: {}, optional: {} }
        }

        register_tool :getForumStatistics, {
          description: 'Public facts about the forum from its About page: title, description, version, ' \
                       'and counts (topics, posts, users, active users, likes) for last day / 7 days / 30 days / all time.',
          input_schema: { type: 'object', properties: {} },
          required_scope: 'read',
          validation_schema: { required: {}, optional: {} }
        }

        register_tool :getBadges, {
          description: 'List the badges this forum offers (name, description, type gold/silver/bronze, how many users hold it).',
          input_schema: { type: 'object', properties: { only_enabled: { type: 'boolean' } } },
          required_scope: 'read',
          validation_schema: { required: {}, optional: { only_enabled: :boolean } }
        }

        register_tool :getSuggestedTopics, {
          description: 'Topics Discourse suggests next to a given topic (related / unread / new).',
          input_schema: { type: 'object', required: ['topic_id'], properties: { topic_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { topic_id: :integer }, optional: {} }
        }

        register_tool :getTopicParticipants, {
          description: 'Who took part in a topic: creator, last poster and participants with their post counts.',
          input_schema: { type: 'object', required: ['topic_id'], properties: { topic_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { topic_id: :integer }, optional: {} }
        }

        register_tool :getPostLikes, {
          description: 'Users who liked a post (username and display name only).',
          input_schema: { type: 'object', required: ['post_id'], properties: { post_id: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { post_id: :integer }, optional: {} }
        }

        register_tool :getUserActivity, {
          description: "A user's public activity stream: topics they started, replies, or likes given. " \
                       'filter: topics | replies | likes_given | all (default all = topics + replies).',
          input_schema: { type: 'object', required: ['username'],
                          properties: { username: { type: 'string' },
                                        filter: { type: 'string', enum: ACTIVITY_FILTERS.keys },
                                        offset: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: { username: :string }, optional: { filter: :string, offset: :integer } }
        }

        register_tool :getNotifications, {
          description: "The connected user's OWN notifications (newest first). unread_only=true returns only unread ones.",
          input_schema: { type: 'object', properties: { unread_only: { type: 'boolean' }, limit: { type: 'integer' } } },
          required_scope: 'read',
          validation_schema: { required: {}, optional: { unread_only: :boolean, limit: :integer } }
        }

        register_tool :getBookmarks, {
          description: "The connected user's OWN bookmarks (topic, post excerpt, name, reminder time).",
          input_schema: { type: 'object', properties: {} },
          required_scope: 'read',
          validation_schema: { required: {}, optional: {} }
        }

        register_tool :getDrafts, {
          description: "The connected user's OWN saved drafts (new topics and replies not yet posted).",
          input_schema: { type: 'object', properties: {} },
          required_scope: 'read',
          validation_schema: { required: {}, optional: {} }
        }
      end

      private

      def execute_getCurrentUser(_params, context)
        result = DiscourseApi.get('/session/current.json')
        u = result['current_user']
        return { error: 'not_found', message: 'Current user not found' } unless u.is_a?(Hash)

        {
          id: u['id'],
          username: u['username'],
          name: u['name'],
          trust_level: u['trust_level'],
          admin: u['admin'] == true,
          moderator: u['moderator'] == true,
          groups: Array(u['groups']).map { |g| g['name'] }.compact,
          unread_notifications: u['unread_notifications'],
          token_scopes: AiConnect::ModuleBase.scope_tokens(context[:scope])
        }
      end

      def execute_getForumStatistics(_params, _context)
        result = DiscourseApi.get('/about.json')
        about = result['about']
        return { error: 'not_found', message: 'About page not available' } unless about.is_a?(Hash)

        {
          title: about['title'],
          description: about['description'],
          locale: about['locale'],
          version: about['version'],
          site_creation_date: about['site_creation_date'],
          # contact_email is left out on purpose: an agent does not need it.
          stats: about['can_see_about_stats'] == false ? nil : about['stats']
        }
      end

      def execute_getBadges(params, _context)
        result = DiscourseApi.get('/badges.json')
        types = (result['badge_types'] || []).to_h { |t| [t['id'], t['name']] }
        badges = result['badges'] || []
        badges = badges.select { |b| b['enabled'] } if params[:only_enabled]
        badges.map do |b|
          {
            id: b['id'],
            name: b['name'],
            description: b['description'],
            type: types[b['badge_type_id']],
            grant_count: b['grant_count'],
            enabled: b['enabled']
          }
        end
      end

      def execute_getSuggestedTopics(params, _context)
        result = DiscourseApi.get("/t/#{params[:topic_id]}.json")
        return { error: 'not_found', message: 'Topic not found' } if result['error_type']

        {
          topic_id: result['id'],
          suggested: (result['suggested_topics'] || []).map do |t|
            { id: t['id'], title: t['title'], slug: t['slug'], posts_count: t['posts_count'],
              category_id: t['category_id'], last_posted_at: t['last_posted_at'] }
          end
        }
      end

      def execute_getTopicParticipants(params, _context)
        result = DiscourseApi.get("/t/#{params[:topic_id]}.json")
        return { error: 'not_found', message: 'Topic not found' } if result['error_type']

        details = result['details'] || {}
        person = ->(u) { u.is_a?(Hash) ? { username: u['username'], name: u['name'] } : nil }
        {
          topic_id: result['id'],
          participant_count: result['participant_count'],
          created_by: person.call(details['created_by']),
          last_poster: person.call(details['last_poster']),
          participants: (details['participants'] || []).map do |u|
            { username: u['username'], name: u['name'], post_count: u['post_count'] }
          end
        }
      end

      def execute_getPostLikes(params, _context)
        result = DiscourseApi.get("/post_action_users.json?id=#{params[:post_id]}&post_action_type_id=2")
        return { error: 'not_found', message: 'Post not found' } if result['error_type']

        users = (result['post_action_users'] || []).map { |u| { username: u['username'], name: u['name'] } }
        { post_id: params[:post_id], like_count: users.size, users: users }
      end

      def execute_getUserActivity(params, _context)
        filter_key = params[:filter].to_s.empty? ? 'all' : params[:filter].to_s
        filter = ACTIVITY_FILTERS[filter_key]
        return { error: 'invalid_params', message: "filter must be one of #{ACTIVITY_FILTERS.keys.join(', ')}" } unless filter

        offset = [params[:offset].to_i, 0].max
        path = "/user_actions.json?username=#{CGI.escape(params[:username].to_s)}&filter=#{filter}&offset=#{offset}"
        result = DiscourseApi.get(path)
        return { error: 'not_found', message: 'User not found or activity hidden' } if result['error_type']

        {
          username: params[:username],
          filter: filter_key,
          offset: offset,
          actions: (result['user_actions'] || []).map do |a|
            { action_type: a['action_type'], created_at: a['created_at'], topic_id: a['topic_id'],
              post_number: a['post_number'], title: a['title'], excerpt: a['excerpt'],
              category_id: a['category_id'], acting_username: a['acting_username'] }
          end
        }
      end

      def execute_getNotifications(params, _context)
        limit = params[:limit].to_i
        limit = 30 if limit <= 0
        limit = 60 if limit > 60
        path = '/notifications.json'
        path += '?filter=unread' if params[:unread_only]
        result = DiscourseApi.get(path)
        return { error: 'not_found', message: 'Notifications not available' } if result['error_type']

        list = (result['notifications'] || []).first(limit).map do |n|
          { id: n['id'], type: notification_type_name(n['notification_type']), read: n['read'],
            created_at: n['created_at'], topic_id: n['topic_id'], post_number: n['post_number'],
            fancy_title: n['fancy_title'], from: n.dig('data', 'display_username') }
        end
        { total: result['total_rows_notifications'], notifications: list }
      end

      def execute_getBookmarks(_params, _context)
        me = DiscourseApi.acting_username.to_s
        result = DiscourseApi.get("/u/#{CGI.escape(me)}/bookmarks.json")
        return { error: 'not_found', message: 'Bookmarks not available' } if result['error_type']

        list = result.dig('user_bookmark_list', 'bookmarks') || result['bookmarks'] || []
        {
          bookmarks: list.map do |b|
            { id: b['id'], name: b['name'], title: b['title'] || b['fancy_title'], excerpt: b['excerpt'],
              topic_id: b['topic_id'], linked_post_number: b['linked_post_number'],
              bookmarkable_type: b['bookmarkable_type'], reminder_at: b['reminder_at'], created_at: b['created_at'] }
          end
        }
      end

      def execute_getDrafts(_params, _context)
        result = DiscourseApi.get('/drafts.json')
        return { error: 'not_found', message: 'Drafts not available' } if result['error_type']

        {
          drafts: (result['drafts'] || []).map do |d|
            { draft_key: d['draft_key'], title: d['title'], excerpt: d['excerpt'], topic_id: d['topic_id'],
              category_id: d['category_id'], created_at: d['created_at'] }
          end
        }
      end

      # Discourse numeric notification types → readable names (Notification.types,
      # Discourse 2026.7 /site.json). Unknown (newer) types come back as type_<id>.
      NOTIFICATION_TYPES = {
        1 => 'mentioned', 2 => 'replied', 3 => 'quoted', 4 => 'edited', 5 => 'liked',
        6 => 'private_message', 7 => 'invited_to_private_message', 8 => 'invitee_accepted',
        9 => 'posted', 10 => 'moved_post', 11 => 'linked', 12 => 'granted_badge',
        13 => 'invited_to_topic', 14 => 'custom', 15 => 'group_mentioned',
        16 => 'group_message_summary', 17 => 'watching_first_post', 18 => 'topic_reminder',
        19 => 'liked_consolidated', 20 => 'post_approved', 21 => 'code_review_commit_approved',
        22 => 'membership_request_accepted', 23 => 'membership_request_consolidated',
        24 => 'bookmark_reminder', 25 => 'reaction', 26 => 'votes_released', 27 => 'event_reminder',
        28 => 'event_invitation', 29 => 'chat_mention', 30 => 'chat_message', 31 => 'chat_invitation',
        32 => 'chat_group_mention', 33 => 'chat_quoted', 34 => 'assigned',
        35 => 'question_answer_user_commented', 36 => 'watching_category_or_tag', 37 => 'new_features',
        38 => 'admin_problems', 39 => 'linked_consolidated', 40 => 'chat_watched_thread'
      }.freeze

      def notification_type_name(id)
        NOTIFICATION_TYPES[id.to_i] || "type_#{id}"
      end
    end
  end
end
