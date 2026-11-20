# frozen_string_literal: true

require_relative '../lib/redirect_uri'

RSpec.describe 'official redirect URIs (1.2.10)' do
  oob = RedirectUri::OOB
  claude = 'https://claude.ai/api/mcp/auth_callback'
  goldnat = 'https://goldnat.ai/oauth/callback'

  it 'adds the Claude callback to the plain OOB value of claude' do
    expect(JSON.parse(RedirectUri.with_official('claude', oob))).to eq([oob, claude])
  end

  it 'adds the goldnat callback to webmcp-master and goldnat' do
    expect(JSON.parse(RedirectUri.with_official('webmcp-master', JSON.generate([oob])))).to eq([oob, goldnat])
    expect(JSON.parse(RedirectUri.with_official('goldnat', oob))).to eq([oob, goldnat])
  end

  it 'keeps an admin-added URL and does not duplicate' do
    raw = JSON.generate([oob, 'https://admin.example/cb'])
    expect(JSON.parse(RedirectUri.with_official('claude', raw))).to eq([oob, 'https://admin.example/cb', claude])
    expect(RedirectUri.with_official('claude', JSON.generate([oob, claude]))).to be_nil
  end

  it 'never touches other clients' do
    %w[chatgpt gemini grok copilot perplexity meta-ai deepseek ai-agent-default].each do |id|
      expect(RedirectUri.with_official(id, oob)).to be_nil
    end
  end

  it 'the result is matched exactly' do
    list = RedirectUri.registered_list(RedirectUri.with_official('claude', oob))
    expect(RedirectUri.registered?(claude, list)).to be true
    expect(RedirectUri.registered?("#{claude}/x", list)).to be false
    expect(RedirectUri.registered?('https://claude.ai.evil.example/api/mcp/auth_callback', list)).to be false
    expect(RedirectUri.registered?('http://claude.ai/api/mcp/auth_callback', list)).to be false
    expect(RedirectUri.registered?(goldnat, list)).to be false
  end
end
