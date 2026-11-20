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
        validation_schema: config[:validation_schema] || { required: {}, optional: {} },
        # user-confirm-v1 (1.2.7): { required: true | ->(args) { bool }, risk:, summary:, preview: :method }
        confirmation: config[:confirmation]
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

      DiscourseApi.reset_upstream_failure! if defined?(DiscourseApi)
      # Confirmation gate (1.2.7): order = scope -> validation -> confirmation -> the tool's own checks.
      gated = tool[:confirmation] && defined?(AiConnect::Confirmation) ? AiConnect::Confirmation.gate(self, tool, validated, params, context) : nil
      result = gated || send(method_name, validated, context)
      failure = defined?(DiscourseApi) ? DiscourseApi.upstream_failure : nil
      if failure
        return { error: 'upstream_error', message: "Discourse did not answer correctly (#{failure}); try again later" }
      end

      result
    end

    def manifest_tools(scope: 'read')
      @tools.values.select do |tool|
        ModuleBase.scope_grants?(scope, tool[:required_scope])
      end.map do |tool|
        entry = { name: tool[:name], description: tool[:description], input_schema: tool[:input_schema] }
        if tool[:confirmation] && defined?(AiConnect::Confirmation)
          entry[:confirmation] = AiConnect::Confirmation.mode(tool)
          entry[:risk] = AiConnect::Confirmation.risk(tool)
          lead = entry[:confirmation] == 'conditional' ? 'Some of its actions need' : 'Needs'
          entry[:description] = "#{tool[:description]} #{lead} the user's confirmation: the call returns 202 with a " \
                                'link for the user; nothing happens until the user confirms.'
        end
        entry
      end
    end

    # Optional hook: return an array of brief-metric definitions this module
    # publishes to goldnat.ai. The registry calls this on register() and forwards
    # each entry to register_brief_metric. Default is [] — most modules override
    # only when they have declarative metrics to publish.
    def brief_metrics
      []
    end
  end
end
