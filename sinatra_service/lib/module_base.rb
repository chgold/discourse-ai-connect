# frozen_string_literal: true

module AiConnect
  class ModuleBase
    attr_reader :tools

    def initialize
      @tools = {}
      register_tools
    end

    def register_tools
      raise NotImplementedError, "#{self.class} must implement #register_tools"
    end

    def module_name
      raise NotImplementedError, "#{self.class} must implement #module_name"
    end

    def register_tool(name, config)
      full_name = "#{module_name}.#{name}"
      @tools[name.to_s] = {
        name: full_name,
        short_name: name.to_s,
        description: config[:description],
        input_schema: config[:input_schema],
        required_scope: config[:required_scope] || 'read',
        pro_only: config[:pro_only] || false,
        validation_schema: config[:validation_schema] || { required: {}, optional: {} }
      }
    end

    # Exact scope-token match: "read write" grants read and write; "rewrite"
    # or "readonly" grant nothing. Never use substring matching here.
    def self.scope_tokens(scope)
      scope.to_s.split(/\s+/).reject(&:empty?)
    end

    def self.scope_grants?(scope, required)
      scope_tokens(scope).include?(required.to_s)
    end

    def execute_tool(tool_name, params, context = {})
      tool = @tools[tool_name.to_s]
      return { error: 'tool_not_found' } unless tool

      unless ModuleBase.scope_grants?(context[:scope], tool[:required_scope])
        return { error: 'insufficient_scope', message: "This tool requires #{tool[:required_scope]} scope" }
      end

      if tool[:pro_only] && !ModuleBase.scope_grants?(context[:scope], 'write')
        return { error: 'insufficient_scope', message: 'This tool requires write scope (Pro tier)' }
      end

      validated, err = InputValidator.validate(params, tool[:validation_schema])
      return { error: 'invalid_params', message: err } if err

      method_name = "execute_#{tool[:short_name]}"
      unless respond_to?(method_name, true)
        return { error: 'not_implemented', message: "Tool #{tool_name} not implemented" }
      end

      send(method_name, validated, context)
    end

    def manifest_tools(scope: 'read')
      @tools.values.select do |tool|
        ModuleBase.scope_grants?(scope, tool[:required_scope])
      end.map do |tool|
        { name: tool[:name], description: tool[:description], input_schema: tool[:input_schema] }
      end
    end
  end
end
