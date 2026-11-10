require_relative '../spec_helper'

RSpec.describe AiConnect::Modules::CoreModule do
  # Module code calls Discourse as the acting user; outside the app this
  # context must be set explicitly (no implicit system fallback).
  around { |ex| DiscourseApi.as_user('admin') { ex.run } }

  subject(:mod) { described_class.new }

  let(:read_ctx) { { scope: 'read', uid: 1 } }

  describe '#module_name' do
    it 'is discourse' do
      expect(mod.module_name).to eq('discourse')
    end
  end

  describe 'registered tools' do
    it 'registers exactly the 6 free tools' do
      expect(mod.tools.keys).to contain_exactly(
        'searchTopics', 'getTopic', 'getPost',
        'getCategories', 'getUserProfile', 'getLatestTopics'
      )
    end

    it 'marks all as read scope' do
      mod.tools.each_value do |t|
        expect(t[:required_scope]).to eq('read')
        expect(t[:pro_only]).to be false
      end
    end
  end

  describe '#execute_tool' do
    it 'getCategories returns category list' do
      result = mod.execute_tool('getCategories', {}, read_ctx)
      expect(result.first[:name]).to eq('General')
    end

    it 'searchTopics validates query' do
      result = mod.execute_tool('searchTopics', {}, read_ctx)
      expect(result[:error]).to eq('invalid_params')
    end

    it 'searchTopics returns topics' do
      result = mod.execute_tool('searchTopics', { 'query' => 'install' }, read_ctx)
      expect(result.first[:title]).to include('install')
    end

    it 'getTopic returns posts' do
      result = mod.execute_tool('getTopic', { 'topic_id' => 101 }, read_ctx)
      expect(result[:posts]).to be_an(Array)
    end

    it 'getTopic 404 unknown' do
      result = mod.execute_tool('getTopic', { 'topic_id' => 99_999 }, read_ctx)
      expect(result[:error]).to eq('not_found')
    end

    it 'getUserProfile returns admin' do
      result = mod.execute_tool('getUserProfile', { 'username' => 'admin' }, read_ctx)
      expect(result[:username]).to eq('admin')
    end

    it 'getLatestTopics returns latest' do
      result = mod.execute_tool('getLatestTopics', {}, read_ctx)
      expect(result.size).to eq(5)
    end

    it 'getLatestTopics filters by category_id' do
      result = mod.execute_tool('getLatestTopics', { 'category_id' => 2 }, read_ctx)
      expect(result.size).to eq(2)
    end
  end
end
