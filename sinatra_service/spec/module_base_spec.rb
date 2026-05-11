require_relative 'spec_helper'

RSpec.describe AiConnect::ModuleBase do
  let(:test_module_class) do
    Class.new(described_class) do
      def module_name
        'test'
      end

      def register_tools
        register_tool :hello, {
          description: 'Say hello',
          input_schema: { type: 'object', properties: { name: { type: 'string' } } },
          required_scope: 'read',
          validation_schema: { required: { name: :string }, optional: {} }
        }

        register_tool :restricted, {
          description: 'Pro only',
          input_schema: { type: 'object' },
          required_scope: 'write',
          pro_only: true,
          validation_schema: { required: {}, optional: {} }
        }
      end

      private

      def execute_hello(params, _context)
        { greeting: "Hello, #{params[:name]}" }
      end

      def execute_restricted(_params, _context)
        { ok: true }
      end
    end
  end

  subject(:mod) { test_module_class.new }

  describe '#tools' do
    it 'registers tools under short name' do
      expect(mod.tools.keys).to contain_exactly('hello', 'restricted')
    end

    it 'namespaces full name with module_name' do
      expect(mod.tools['hello'][:name]).to eq('test.hello')
    end
  end

  describe '#execute_tool' do
    it 'returns tool_not_found for unknown tool' do
      result = mod.execute_tool('missing', {}, {})
      expect(result[:error]).to eq('tool_not_found')
    end

    it 'rejects pro_only without write scope' do
      result = mod.execute_tool('restricted', {}, { scope: 'read' })
      expect(result[:error]).to eq('insufficient_scope')
    end

    it 'allows pro_only with write scope' do
      result = mod.execute_tool('restricted', {}, { scope: 'read write' })
      expect(result[:ok]).to be true
    end

    it 'validates required params' do
      result = mod.execute_tool('hello', {}, { scope: 'read' })
      expect(result[:error]).to eq('invalid_params')
    end

    it 'dispatches to execute_<name>' do
      result = mod.execute_tool('hello', { 'name' => 'world' }, { scope: 'read' })
      expect(result[:greeting]).to eq('Hello, world')
    end
  end

  describe '#manifest_tools' do
    it 'omits write tools for read scope' do
      names = mod.manifest_tools(scope: 'read').map { |t| t[:name] }
      expect(names).to contain_exactly('test.hello')
    end

    it 'includes write tools when write in scope' do
      names = mod.manifest_tools(scope: 'read write').map { |t| t[:name] }
      expect(names).to contain_exactly('test.hello', 'test.restricted')
    end
  end

  describe 'abstract enforcement' do
    it 'raises when register_tools not implemented' do
      bad = Class.new(described_class) { def module_name; 'x'; end }
      expect { bad.new }.to raise_error(NotImplementedError)
    end

    it 'raises when module_name not implemented' do
      bad = Class.new(described_class) { def register_tools; end }
      expect { bad.new.module_name }.to raise_error(NotImplementedError)
    end
  end
end
