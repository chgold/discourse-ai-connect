require_relative '../spec_helper'

RSpec.describe AiConnect::Modules::ProModule do
  subject(:mod) { described_class.new }

  let(:write_ctx) { { scope: 'read write', uid: 1 } }
  let(:read_ctx)  { { scope: 'read', uid: 1 } }

  describe 'registered tools' do
    it 'registers exactly the 5 pro tools' do
      expect(mod.tools.keys).to contain_exactly(
        'createTopic', 'replyToTopic', 'editPost', 'sendMessage', 'likePost'
      )
    end

    it 'marks all as pro_only with write scope' do
      mod.tools.each_value do |t|
        expect(t[:required_scope]).to eq('write')
        expect(t[:pro_only]).to be true
      end
    end
  end

  describe 'scope enforcement' do
    it 'rejects createTopic with read-only scope' do
      result = mod.execute_tool('createTopic', { 'title' => 'X', 'raw' => 'body', 'category_id' => 1 }, read_ctx)
      expect(result[:error]).to eq('insufficient_scope')
    end
  end

  describe '#execute_tool' do
    it 'createTopic returns id+title' do
      result = mod.execute_tool('createTopic', { 'title' => 'Hi', 'raw' => 'body', 'category_id' => 1 }, write_ctx)
      expect(result[:title]).to eq('Hi')
      expect(result).to have_key(:id)
    end

    it 'replyToTopic validates required raw' do
      result = mod.execute_tool('replyToTopic', { 'topic_id' => 1 }, write_ctx)
      expect(result[:error]).to eq('invalid_params')
    end

    it 'editPost validates required post_id' do
      result = mod.execute_tool('editPost', { 'raw' => 'new content' }, write_ctx)
      expect(result[:error]).to eq('invalid_params')
    end

    it 'sendMessage validates required params' do
      result = mod.execute_tool('sendMessage', { 'username' => 'admin' }, write_ctx)
      expect(result[:error]).to eq('invalid_params')
    end

    it 'likePost returns liked=true by default' do
      result = mod.execute_tool('likePost', { 'post_id' => 42 }, write_ctx)
      expect(result[:liked]).to be true
      expect(result[:post_id]).to eq(42)
    end

    it 'likePost respects unlike=true' do
      result = mod.execute_tool('likePost', { 'post_id' => 42, 'unlike' => 'true' }, write_ctx)
      expect(result[:liked]).to be false
    end
  end

  describe 'input validation limits' do
    it 'rejects oversized raw body' do
      result = mod.execute_tool('createTopic', { 'title' => 'X', 'raw' => 'a' * 20_000, 'category_id' => 1 }, write_ctx)
      expect(result[:error]).to eq('invalid_params')
    end

    it 'rejects oversized title' do
      result = mod.execute_tool('createTopic', { 'title' => 't' * 500, 'raw' => 'body', 'category_id' => 1 }, write_ctx)
      expect(result[:error]).to eq('invalid_params')
    end
  end
end
