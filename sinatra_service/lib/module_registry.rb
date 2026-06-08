# frozen_string_literal: true

module AiConnect
  class ModuleRegistry
    def initialize
      @modules = []
    end

    def register(mod, key: nil)
      mod_key = key || mod.class.name
      @modules.reject! { |entry| entry[:key] == mod_key }
      @modules << { key: mod_key, mod: mod }
    end

    def all_modules
      @modules.map { |e| e[:mod] }
    end

    def modules_for_namespace(namespace)
      all_modules.select { |m| m.module_name == namespace }
    end

    def all_tools(scope: 'read')
      all_modules.flat_map { |m| m.manifest_tools(scope: scope) }
    end

    def execute(tool_name, params, context = {})
      parts = tool_name.to_s.split('.', 2)
      return tool_not_found unless parts.length == 2

      namespace, short_name = parts
      candidates = modules_for_namespace(namespace)
      return tool_not_found if candidates.empty?

      target = candidates.find { |m| m.tools.key?(short_name) }
      return tool_not_found unless target

      target.execute_tool(short_name, params, context)
    end

    def tool_required_scope(tool_name)
      parts = tool_name.to_s.split('.', 2)
      return nil unless parts.length == 2

      namespace, short_name = parts
      candidates = modules_for_namespace(namespace)
      return nil if candidates.empty?

      target = candidates.find { |m| m.tools.key?(short_name) }
      target&.tools&.dig(short_name, :required_scope)
    end

    def self.on_init(&block)
      @init_callbacks ||= []
      @init_callbacks << block
    end

    def self.run_init_callbacks(registry)
      (@init_callbacks || []).each { |cb| cb.call(registry) }
    end

    def self.reset_init_callbacks!
      @init_callbacks = []
    end

    private

    def tool_not_found
      { error: 'tool_not_found' }
    end
  end
end
