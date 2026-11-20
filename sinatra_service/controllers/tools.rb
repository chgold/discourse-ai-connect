# frozen_string_literal: true

module ToolsController
  # extra (1.2.7): client_id / token_prefix / ip for the confirmation gate.
  def self.execute(tool_name, params, uid, scope, registry: nil, extra: {})
    registry ||= DiscourseAiConnect.settings.module_registry
    registry.execute(tool_name, params, { uid: uid, scope: scope }.merge(extra))
  end
end
