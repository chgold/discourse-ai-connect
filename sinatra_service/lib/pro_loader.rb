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
      return false if bundles.empty?

      unless defined?(AiConnect::Modules::ProModule)
        return false unless File.file?(PRO_MODULE_PATH)

        require PRO_MODULE_PATH
      end

      return false unless defined?(AiConnect::Modules::ProModule)

      registry.register(AiConnect::Modules::ProModule.new, key: 'pro')
      true
    end

    # Bundles granted by the current license (BUNDLES-LICENSE-SPEC v1.0).
    # ['*'] for legacy edition='pro' (grants everything), [] for free.
    def self.bundles
      edition == 'pro' ? ['*'] : []
    end

    def self.has_bundle?(bundle)
      b = bundles
      b.include?('*') || b.include?(bundle)
    end

    def self.edition
      env = (ENV['AICONNECT_EDITION'] || '').downcase
      return env unless env.empty?

      require_relative 'license_client'
      AiConnect::LicenseClient.resolve_edition
    rescue StandardError
      'free'
    end
  end
end
