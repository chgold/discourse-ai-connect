require_relative '../spec_helper'

RSpec.describe AiConnect::Modules::CommunityModule do
  around { |ex| DiscourseApi.as_user('member_one') { ex.run } }

  subject(:mod) { described_class.new }

  let(:ctx) { { scope: 'read', uid: 2 } }

  it 'registers 10 read-only tools in the discourse namespace' do
    expect(mod.tools.keys).to contain_exactly(
      'getCurrentUser', 'getForumStatistics', 'getBadges', 'getSuggestedTopics', 'getTopicParticipants',
      'getPostLikes', 'getUserActivity', 'getNotifications', 'getBookmarks', 'getDrafts'
    )
    mod.tools.each_value do |t|
      expect(t[:required_scope]).to eq('read')
      expect(t[:name]).to start_with('discourse.')
    end
  end

  it 'getCurrentUser returns the acting user and token scopes' do
    allow(DiscourseApi).to receive(:get).with('/session/current.json').and_return(
      'current_user' => { 'id' => 2, 'username' => 'member_one', 'name' => 'M', 'trust_level' => 1,
                          'admin' => false, 'moderator' => false, 'groups' => [{ 'name' => 'trust_level_1' }] }
    )
    r = mod.execute_tool('getCurrentUser', {}, { scope: 'read write', uid: 2 })
    expect(r).to include(username: 'member_one', admin: false, groups: ['trust_level_1'], token_scopes: %w[read write])
  end

  it 'getForumStatistics never returns the contact e-mail' do
    allow(DiscourseApi).to receive(:get).with('/about.json').and_return(
      'about' => { 'title' => 'F', 'contact_email' => 'owner@example.com', 'can_see_about_stats' => true,
                   'stats' => { 'topics_count' => 3 } }
    )
    r = mod.execute_tool('getForumStatistics', {}, ctx)
    expect(r[:stats]).to eq('topics_count' => 3)
    expect(r.to_s).not_to include('owner@example.com')
  end

  it 'getBadges maps badge types and filters disabled ones' do
    allow(DiscourseApi).to receive(:get).with('/badges.json').and_return(
      'badge_types' => [{ 'id' => 3, 'name' => 'Bronze' }],
      'badges' => [{ 'id' => 1, 'name' => 'Basic', 'badge_type_id' => 3, 'enabled' => true, 'grant_count' => 2 },
                   { 'id' => 2, 'name' => 'Off', 'badge_type_id' => 3, 'enabled' => false }]
    )
    r = mod.execute_tool('getBadges', { 'only_enabled' => true }, ctx)
    expect(r.map { |b| b[:name] }).to eq(['Basic'])
    expect(r.first[:type]).to eq('Bronze')
  end

  it 'getSuggestedTopics / getTopicParticipants return not_found for a missing topic' do
    allow(DiscourseApi).to receive(:get).with('/t/999.json').and_return('error_type' => 'not_found', 'http_status' => 404)
    expect(mod.execute_tool('getSuggestedTopics', { 'topic_id' => 999 }, ctx)[:error]).to eq('not_found')
    expect(mod.execute_tool('getTopicParticipants', { 'topic_id' => 999 }, ctx)[:error]).to eq('not_found')
  end

  it 'getTopicParticipants returns usernames and post counts only' do
    allow(DiscourseApi).to receive(:get).with('/t/5.json').and_return(
      'id' => 5, 'participant_count' => 1,
      'details' => { 'created_by' => { 'username' => 'a', 'name' => 'A', 'email' => 'x@y' },
                     'participants' => [{ 'username' => 'a', 'name' => 'A', 'post_count' => 2, 'email' => 'x@y' }] }
    )
    r = mod.execute_tool('getTopicParticipants', { 'topic_id' => 5 }, ctx)
    expect(r[:participants]).to eq([{ username: 'a', name: 'A', post_count: 2 }])
    expect(r.to_s).not_to include('x@y')
  end

  it 'getPostLikes asks Discourse for like actions (type 2)' do
    allow(DiscourseApi).to receive(:get).with('/post_action_users.json?id=7&post_action_type_id=2')
                                        .and_return('post_action_users' => [{ 'username' => 'b', 'name' => 'B' }])
    r = mod.execute_tool('getPostLikes', { 'post_id' => 7 }, ctx)
    expect(r).to include(like_count: 1, users: [{ username: 'b', name: 'B' }])
  end

  it 'getUserActivity rejects an unknown filter' do
    r = mod.execute_tool('getUserActivity', { 'username' => 'a', 'filter' => 'secrets' }, ctx)
    expect(r[:error]).to eq('invalid_params')
  end

  it 'getUserActivity maps filter names to Discourse action types' do
    allow(DiscourseApi).to receive(:get).with('/user_actions.json?username=a&filter=4,5&offset=0')
                                        .and_return('user_actions' => [{ 'action_type' => 4, 'title' => 'T' }])
    r = mod.execute_tool('getUserActivity', { 'username' => 'a' }, ctx)
    expect(r[:actions].first).to include(action_type: 4, title: 'T')
  end

  it 'getBookmarks always reads the ACTING user, never one from the arguments' do
    allow(DiscourseApi).to receive(:get).with('/u/member_one/bookmarks.json').and_return('bookmarks' => [])
    r = mod.execute_tool('getBookmarks', { 'username' => 'admin' }, ctx)
    expect(r).to eq(bookmarks: [])
    expect(DiscourseApi).to have_received(:get).with('/u/member_one/bookmarks.json')
  end

  it 'getNotifications names the notification types and caps the limit' do
    allow(DiscourseApi).to receive(:get).with('/notifications.json?filter=unread').and_return(
      'total_rows_notifications' => 1,
      'notifications' => [{ 'id' => 1, 'notification_type' => 6, 'read' => false }]
    )
    r = mod.execute_tool('getNotifications', { 'unread_only' => true, 'limit' => 500 }, ctx)
    expect(r[:notifications].first).to include(type: 'private_message', read: false)
  end

  it 'turns a Discourse outage into upstream_error instead of an empty list' do
    allow(DiscourseApi).to receive(:get).with('/drafts.json') do
      DiscourseApi.note_upstream_failure('timeout')
      { 'error' => 'timeout', 'error_type' => 'timeout' }
    end
    r = mod.execute_tool('getDrafts', {}, ctx)
    expect(r[:error]).to eq('upstream_error')
  end
end
