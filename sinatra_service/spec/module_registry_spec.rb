require_relative 'spec_helper'

RSpec.describe AiConnect::ModuleRegistry do
  # Module code calls Discourse as the acting user; outside the app this
  # context must be set explicitly (no implicit system fallback).
  around { |ex| DiscourseApi.as_user('admin') { ex.run } }

  let(:core) { AiConnect::Modules::CoreModule.new }
  let(:pro)  { AiConnect::Modules::ProModule.new }

  subject(:registry) do
    r = described_class.new
    r.register(core, key: 'core')
    r.register(pro,  key: 'pro')
    r
  end

  describe '#all_modules' do
    it 'returns both modules' do
      expect(registry.all_modules).to contain_exactly(core, pro)
    end
  end

  describe '#all_tools' do
    it 'returns only read tools for read scope' do
      names = registry.all_tools(scope: 'read').map { |t| t[:name] }
      expect(names).to include('discourse.searchTopics', 'discourse.getCategories')
      expect(names).not_to include('discourse.createTopic')
    end

    it 'returns the core read tools plus every Pro tool for write scope' do
      tools = registry.all_tools(scope: 'read write')
      pro = AiConnect::Modules::ProModule.new.tools.size
      expect(tools.size).to eq(registry.all_tools(scope: 'read').size + pro - 2) # 2 Pro tools are read-scope
      expect(tools.map { |t| t[:name] }).to include('discourse.createTopic', 'discourse.deletePost', 'discourse.getReviewQueue')
    end
  end

  describe '#execute' do
    it 'returns tool_not_found for unqualified name' do
      result = registry.execute('searchTopics', {}, {})
      expect(result[:error]).to eq('tool_not_found')
    end

    it 'returns tool_not_found for unknown namespace' do
      result = registry.execute('other.searchTopics', {}, {})
      expect(result[:error]).to eq('tool_not_found')
    end

    it 'routes to core module for read tools' do
      result = registry.execute('discourse.getCategories', {}, { scope: 'read' })
      expect(result).to be_an(Array)
      expect(result.first[:name]).to eq('General')
    end

    it 'routes to pro module for write tools' do
      result = registry.execute(
        'discourse.createTopic',
        { 'title' => 'X', 'raw' => 'body', 'category_id' => 1 },
        { scope: 'read write' }
      )
      expect(result[:title]).to eq('X')
    end

    it 'enforces pro_only across registry' do
      result = registry.execute(
        'discourse.createTopic',
        { 'title' => 'X', 'raw' => 'body', 'category_id' => 1 },
        { scope: 'read' }
      )
      expect(result[:error]).to eq('insufficient_scope')
    end
  end

  describe 'on_init callbacks' do
    after { described_class.reset_init_callbacks! }

    it 'allows third-party modules to register on init' do
      external_module_class = Class.new(AiConnect::ModuleBase) do
        def module_name; 'addon'; end
        def register_tools
          register_tool :ping, {
            description: 'Ping',
            input_schema: { type: 'object' },
            validation_schema: { required: {}, optional: {} }
          }
        end

        private

        def execute_ping(_p, _c); { pong: true }; end
      end

      described_class.on_init do |reg|
        reg.register(external_module_class.new, key: 'addon')
      end

      r = described_class.new
      described_class.run_init_callbacks(r)

      result = r.execute('addon.ping', {}, { scope: 'read' })
      expect(result[:pong]).to be true
    end
  end

  describe 'register replaces same key' do
    it 'replaces a module registered under the same key' do
      r = described_class.new
      r.register(core, key: 'core')
      r.register(AiConnect::Modules::CoreModule.new, key: 'core')
      expect(r.all_modules.size).to eq(1)
    end
  end
end
