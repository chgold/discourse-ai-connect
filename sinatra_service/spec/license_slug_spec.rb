require_relative 'spec_helper'
require_relative '../lib/license_client'

# 1.2.7: the paid product is discourse-moderator-ai-connect (licence prefix DIS). Before 1.2.7 the
# client expected the free core's slug, so a real Pro licence could never unlock Pro.
RSpec.describe AiConnect::LicenseClient do
  it 'grants Pro only for a valid licence of the Pro product' do
    expect(described_class.grants_pro('status' => 'valid', 'plugin_slug' => 'discourse-moderator-ai-connect')).to be true
    expect(described_class.grants_pro('status' => 'valid_no_updates', 'plugin_slug' => 'discourse-moderator-ai-connect')).to be true
    expect(described_class.grants_pro('status' => 'valid', 'plugin_slug' => 'discourse-plugin')).to be false
    expect(described_class.grants_pro('status' => 'valid', 'plugin_slug' => 'xenforo-addon-pro')).to be false
    expect(described_class.grants_pro('status' => 'expired', 'plugin_slug' => 'discourse-moderator-ai-connect')).to be false
    expect(described_class.grants_pro(nil)).to be false
  end

  it 'keeps the fail-open verdict for a network blip' do
    expect(described_class.grants_pro('status' => 'error_cached')).to be true
  end
end

RSpec.describe InputValidator do
  it 'reads a boolean false as false, not as missing (1.2.7)' do
    out, err = described_class.validate({ 'pinned' => false }, { required: { pinned: :boolean }, optional: {} })
    expect(err).to be_nil
    expect(out[:pinned]).to be false
    out, = described_class.validate({ 'flag' => false }, { required: {}, optional: { flag: :boolean } })
    expect(out).to eq(flag: false)
  end
end
