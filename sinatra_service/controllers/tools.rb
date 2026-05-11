# frozen_string_literal: true

module ToolsController
  def self.execute(tool_name, params, uid, scope, registry: nil)
    registry ||= DiscourseAiConnect.settings.module_registry
    registry.execute(tool_name, params, { uid: uid, scope: scope })
  end
end
