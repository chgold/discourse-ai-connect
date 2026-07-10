# frozen_string_literal: true

# ProLoader — edition-gated loader for the separate Pro package.
#
# The Pro tools live in a separate package (discourse-moderator-ai-connect) and
# are registered into the core registry only when the site edition grants Pro
# AND that package is present. If either is false, no Pro tools are registered —
# they never appear in the manifest and cannot be executed. Mirrors the
# WordPress/XenForo/Ghost/Moodle/PrestaShop model.
module AiConnect
  class ProLoader
    PRO_MODULE_PATH = File.expand_path(
      '../../../discourse-moderator-ai-connect/lib/modules/pro_module.rb', __dir__
    )

    def self.load(registry)
      return false unless edition == 'pro'

      unless defined?(AiConnect::Modules::ProModule)
        return false unless File.file?(PRO_MODULE_PATH)

        require PRO_MODULE_PATH
      end

      return false unless defined?(AiConnect::Modules::ProModule)

      registry.register(AiConnect::Modules::ProModule.new, key: 'pro')
      true
    end

    def self.edition
      (ENV['AICONNECT_EDITION'] || 'free').downcase
    end
  end
end
