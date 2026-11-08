# frozen_string_literal: true

module AiConnect
  class ModuleRegistry
    BRIEF_KEY_RE = /\A[a-z0-9]+(\.[a-z0-9_]+)+\z/.freeze

    def initialize
      @modules = []
      @brief_metrics = {}
      @brief_lists = []
    end

    def register(mod, key: nil)
      mod_key = key || mod.class.name
      @modules.reject! { |entry| entry[:key] == mod_key }
      @modules << { key: mod_key, mod: mod }

      if mod.respond_to?(:brief_metrics)
        Array(mod.brief_metrics).each { |metric| register_brief_metric(metric) }
      end
    end

    # Register a declarative brief metric.
    #
    # goldnat.ai reads these on a schedule (no LLM in the loop) by calling the
    # named tool and pulling the scalar at valuePath. Contract from
    # docs-site/site-owners/manifest-format.md (brief section):
    #   :key         required. `^[a-z0-9]+(\.[a-z0-9_]+)+$`, 1–120 chars.
    #   :tool        required. Manifest tool name w/o site prefix, 1–200 chars.
    #   :args        optional. Constant hash; may contain {{...}} placeholders.
    #   :valuePath   required. Dotted, keys & numeric indices only (no wildcards).
    #   :unit        optional. Free-form ≤ 24 chars. ILS/USD/EUR/GBP → currency
    #                formatting; anything else → plain suffix. Omit for pure counts.
    #   :granularity optional. hour|day|week|month (default day).
    #
    # Returns true if accepted; false if rejected (invalid or over 50-metric cap).
    def register_brief_metric(config)
      return false unless config.is_a?(Hash)
      key = (config[:key] || config['key']).to_s
      tool = (config[:tool] || config['tool']).to_s
      value_path = (config[:valuePath] || config['valuePath']).to_s
      return false if key.empty? || tool.empty? || value_path.empty?
      return false unless BRIEF_KEY_RE.match?(key)
      return false if @brief_metrics.size >= 50

      metric = { key: key, tool: tool, valuePath: value_path }
      args = config[:args] || config['args']
      metric[:args] = args if args.is_a?(Hash)
      unit = config[:unit] || config['unit']
      metric[:unit] = unit.to_s[0, 24] if unit.is_a?(String) && !unit.empty?
      granularity = (config[:granularity] || config['granularity']).to_s
      metric[:granularity] = granularity if %w[hour day week month].include?(granularity)

      @brief_metrics[key] = metric
      true
    end

    def brief_metrics
      @brief_metrics.values
    end

    def brief_lists
      @brief_lists.dup
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
