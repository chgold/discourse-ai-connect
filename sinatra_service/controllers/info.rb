module InfoController
  BASE_URL = ENV.fetch('DISCOURSE_AI_CONNECT_URL', 'http://localhost:8086')

  READ_TOOLS = [
    { name: 'discourse.searchTopics',    params: 'query=KEYWORD&limit=20',     hint: 'Search forum topics by keyword' },
    { name: 'discourse.getTopic',        params: 'topic_id=TOPIC_ID',          hint: 'Get a topic with all its posts' },
    { name: 'discourse.getPost',         params: 'post_id=POST_ID',            hint: 'Get a single post by ID' },
    { name: 'discourse.getCategories',   params: '',                           hint: 'List all forum categories' },
    { name: 'discourse.getUserProfile',  params: 'username=USERNAME',          hint: 'Get a user profile' },
    { name: 'discourse.getLatestTopics', params: 'category_id=CATEGORY_ID',    hint: 'Get latest topics' }
  ]

  WRITE_TOOLS = [
    { name: 'discourse.createTopic',  body: '{"category_id":CAT,"title":"TITLE","raw":"BODY"}',  hint: 'Create a new topic (Pro)' },
    { name: 'discourse.replyToTopic', body: '{"topic_id":TID,"raw":"REPLY"}',                    hint: 'Reply to topic (Pro)' },
    { name: 'discourse.editPost',     body: '{"post_id":PID,"raw":"NEW_BODY"}',                  hint: 'Edit a post (Pro)' },
    { name: 'discourse.sendMessage',  body: '{"username":"USER","title":"T","raw":"BODY"}',      hint: 'Send PM (Pro)' },
    { name: 'discourse.likePost',     body: '{"post_id":PID}',                                   hint: 'Like a post (Pro)' }
  ]

  # Summarises a tool's parameters from its input schema, for the agent prompt.
  def self.build_schema_hint(tool, max_optional = 3)
    schema = tool[:input_schema] || tool['input_schema'] || {}
    properties = schema[:properties] || schema['properties'] || {}
    return 'no arguments' if properties.nil? || properties.empty?

    required = (schema[:required] || schema['required'] || []).map(&:to_s)
    req = []
    opt = []

    properties.each do |name, spec|
      spec = spec.is_a?(Hash) ? spec : {}
      type = spec[:type] || spec['type'] || 'string'
      part = "#{name}=#{type}"

      if required.include?(name.to_s)
        req << part
        next
      end

      default = spec.key?(:default) ? spec[:default] : spec['default']
      part += " (default #{default})" unless default.nil?
      opt << part
    end

    req[-1] += ' [required]' unless req.empty?

    shown = opt.first(max_optional)
    hint = (req + shown).join(', ')
    hint += ", +#{opt.length - shown.length} more" if opt.length > shown.length
    hint
  end

  def self.build_prompt(access_token, refresh_token, site_name = 'Discourse Forum', registry = nil)
    base = BASE_URL
    uri  = URI.parse(base) rescue nil
    host_part = uri&.host || 'discourse'
    path_part = (uri&.path || '').chomp('/')
    # MCP site name: host + path-prefix (e.g. "dev.gold-t.co.il/discourse")
    site_name_mcp = path_part.empty? ? host_part : "#{host_part}#{path_part}"
    site_key  = site_name_mcp.gsub(/[^a-zA-Z0-9_-]/, '_')
    manifest  = "#{base}/api/aiconnect-manifest"
    tool_root = "#{base}/api/ai-connect/v1/tools"
    token_url = "#{base}/api/ai-connect/token"
    lines = []
    lines << "You have access to #{site_name} via AI Connect."
    lines << ""
     lines << "## Add site (goldnat.ai recommended)"
     lines << "Call servio_addSite (or webmcp_addSite for backward compat) with these parameters:"
    lines << "  name:          \"#{site_name_mcp}\""
    lines << "  manifest_url:  \"#{manifest}\""
    lines << "  token_url:     \"#{token_url}\""
    lines << "  token:         \"Bearer #{access_token}\""
    lines << "  refresh_token: \"#{refresh_token}\""
    lines << ""
    lines << "IMPORTANT: Paste BOTH token and refresh_token — otherwise the connection will stop working after 1 hour."
    lines << ""
    lines << "After adding the site, call these tools by EXACT name (do not search — use directly):"
    curated = (READ_TOOLS + WRITE_TOOLS).each_with_object({}) { |t, h| h[t[:name]] = t[:hint] }

    listed =
      begin
        registry.all_tools(scope: 'read write delete admin').map do |tool|
          name = tool[:name] || tool['name']
          { name: name, hint: curated[name] || build_schema_hint(tool) }
        end
      rescue StandardError
        (READ_TOOLS + WRITE_TOOLS).map { |t| { name: t[:name], hint: t[:hint] } }
      end

    listed.each do |t|
      mcp = "#{site_key}_#{t[:name].sub('.', '_')}"
      lines << "  #{mcp.ljust(50)}<- #{t[:hint]}"
    end
    lines << ""
    lines << "## Direct URL Access (Fallback — read-only tools)"
    lines << "If MCP is not available, read-only tools can be called via GET:"
    lines << ""
    READ_TOOLS.each do |t|
      url = "#{tool_root}/#{t[:name]}?token=#{access_token}"
      url += "&#{t[:params]}" unless t[:params].empty?
      lines << "  #{url}"
    end
    lines << ""
    lines << "Replace placeholders: KEYWORD=any word, TOPIC_ID/POST_ID/CATEGORY_ID=numbers, USERNAME=exact username"
    lines << ""
    lines << "## Write Tools (POST only — use MCP when possible)"
    lines << "  POST #{tool_root}/{tool_name}"
    lines << "  Authorization: Bearer #{access_token}"
    lines << "  Content-Type: application/json"
    lines << ""
    WRITE_TOOLS.each do |t|
      lines << "  // #{t[:name]} — #{t[:hint]}"
      lines << "  POST #{tool_root}/#{t[:name]}  body: #{t[:body]}"
      lines << ""
    end
    lines << "## Token Refresh (valid 30 days)"
    lines << "When access_token expires (after 1 hour), refresh it:"
    lines << "  POST #{token_url}"
    lines << "  Content-Type: application/json"
    lines << "  {\"grant_type\":\"refresh_token\",\"refresh_token\":\"#{refresh_token}\",\"client_id\":\"claude-ai\"}"
    lines << "Response contains a new access_token + new refresh_token (old pair is revoked)."
    lines << ""
    lines << "## Revoke a token (when you no longer need access)"
    lines << "To immediately revoke a token — for example when the task is done or a token may be exposed:"
    lines << "  POST #{base}/api/ai-connect/revoke"
    lines << "  Content-Type: application/json"
    lines << "  {\"token\":\"#{access_token}\"}"
    lines << "You (the user) can also review and revoke tokens anytime — including bulk-cleanup of unused/inactive"
    lines << "tokens — on your My Tokens page (Preferences → AI Tokens in Discourse)."
    lines << ""
    lines << "IMPORTANT: Do NOT use webmcp tool search — it may return tools from other sites."
    lines << "Call the tools listed above by their EXACT full name."
    lines << "Security note: This token acts on behalf of the user who generated it. Handle it with care."
    lines << "Documentation: https://plugins.goldnat.ai/discourse/guide"
    lines.join("\n")
  end

  def self.page(env)
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <title>Discourse AI Connect</title>
      <style>
      *{box-sizing:border-box;margin:0;padding:0}
      body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1014;color:#e5e7eb;line-height:1.6}
      .container{max-width:760px;margin:0 auto;padding:40px 20px}
      h1{font-size:28px;color:#fff;margin-bottom:6px;display:flex;align-items:center;gap:10px}
      .badge{background:#10b981;color:#022c22;padding:3px 10px;border-radius:999px;font-size:11px;font-weight:700;letter-spacing:0.5px;text-transform:uppercase}
      .subtitle{color:#9ca3af;margin-bottom:32px;font-size:15px}
      .section{background:#1a1d23;border-radius:12px;padding:24px;margin-bottom:20px;border:1px solid #1f2329}
      .section h2{font-size:16px;color:#6366f1;margin-bottom:14px;font-weight:600}
      .section p{font-size:14px;color:#cbd5e1;margin-bottom:10px}
      .url-box{background:#111318;border:1px solid #374151;border-radius:6px;padding:10px 14px;font-family:'SF Mono','Monaco',monospace;font-size:13px;color:#10b981;word-break:break-all;margin-bottom:8px}
      .btn{display:inline-block;padding:12px 24px;background:#6366f1;color:#fff;border:none;border-radius:6px;font-size:14px;font-weight:600;cursor:pointer;text-decoration:none;margin-top:12px}
      .btn:hover{background:#4f46e5}
      .btn.copy{background:#10b981;color:#022c22}
      .btn.copy:hover{background:#34d399}
      .connected-as{background:#0a1a14;border:1px solid #10b981;border-radius:8px;padding:14px 16px;margin-bottom:16px}
      .connected-as .badge-success{color:#10b981;font-size:18px}
      .connected-as strong{color:#fff;font-weight:600}
      .connected-as .note{font-size:12px;color:#9ca3af;margin-top:6px}
      #prompt-result{display:none;margin-top:18px}
      .prompt-box{background:#111318;border:1px solid #374151;border-radius:8px;padding:18px;font-family:'SF Mono','Monaco',monospace;font-size:12px;color:#cbd5e1;white-space:pre-wrap;word-break:break-all;max-height:520px;overflow-y:auto;margin-top:14px}
      .warn{background:#1a0a0a;border:1px solid #ef4444;color:#fca5a5;padding:12px 16px;border-radius:6px;margin:14px 0;font-size:13px}
      .tool{background:#111318;border:1px solid #1f2329;border-radius:6px;padding:8px 12px;font-size:13px;margin-bottom:6px;display:flex;justify-content:space-between}
      .tool-name{color:#a5b4fc;font-family:monospace}
      .tool-type{font-size:10px;padding:2px 6px;border-radius:3px;font-weight:700}
      .free{background:#065f46;color:#6ee7b7}
      .pro{background:#7c2d12;color:#fdba74}
      </style>
      </head>
      <body><div class="container">
      <h1>🤖 Discourse AI Connect <span class="badge">GACP v1.0</span></h1>
      <p class="subtitle">Connect AI agents to this Discourse forum via the WebMCP Protocol</p>

      <div class="section">
      <h2>What is Discourse AI Connect?</h2>
      <p>A bridge that exposes your Discourse forum to AI agents (Claude, ChatGPT, Gemini, etc.) using the standardized GoldT AI Connect Protocol (GACP) over OAuth 2.0 + WebMCP.</p>
      </div>

      <div class="section">
      <h2>Manifest URL (public)</h2>
      <div class="url-box">#{BASE_URL}/api/ai-connect/manifest</div>
      </div>

      <div class="section">
      <h2>🔑 Get Your Connection Prompt</h2>
      <div class="connected-as">
        <span class="badge-success">●</span> Connected as: <strong>Admin (UID 1)</strong>
        <div class="note">ℹ️ This Discourse bridge is a standalone Sinatra service. In dev/testing it auto-uses Admin (UID=1). In production it plugs into Discourse SSO via OAuth.</div>
      </div>
      <p>Click below to generate a complete copy-paste prompt for your AI agent. The prompt includes access token, refresh token, all tools, and instructions.</p>
      <button class="btn" id="generate-btn" type="button">⚡ Generate AI Connect Prompt</button>

      <div id="prompt-result">
        <div class="warn"><strong>⚠️ Save this prompt now.</strong> The tokens above will not be shown again. Access valid 1 hour, refresh valid 30 days. The AI will automatically use the refresh_token tool when access expires.</div>
        <button class="btn copy" id="copy-btn" type="button">📋 Copy Full Prompt</button>
        <div class="prompt-box" id="prompt-text"></div>
      </div>
      </div>

      <div class="section">
      <h2>🛠️ Available Tools</h2>
      <div class="tool"><span class="tool-name">discourse.searchTopics</span><span class="tool-type free">FREE</span></div>
      <div class="tool"><span class="tool-name">discourse.getTopic</span><span class="tool-type free">FREE</span></div>
      <div class="tool"><span class="tool-name">discourse.getPost</span><span class="tool-type free">FREE</span></div>
      <div class="tool"><span class="tool-name">discourse.getCategories</span><span class="tool-type free">FREE</span></div>
      <div class="tool"><span class="tool-name">discourse.getUserProfile</span><span class="tool-type free">FREE</span></div>
      <div class="tool"><span class="tool-name">discourse.getLatestTopics</span><span class="tool-type free">FREE</span></div>
      <div class="tool"><span class="tool-name">discourse.createTopic</span><span class="tool-type pro">PRO</span></div>
      <div class="tool"><span class="tool-name">discourse.replyToTopic</span><span class="tool-type pro">PRO</span></div>
      <div class="tool"><span class="tool-name">discourse.editPost</span><span class="tool-type pro">PRO</span></div>
      <div class="tool"><span class="tool-name">discourse.sendMessage</span><span class="tool-type pro">PRO</span></div>
      <div class="tool"><span class="tool-name">discourse.likePost</span><span class="tool-type pro">PRO</span></div>
      </div>

      </div>
      <script>
      (function(){
        var btn = document.getElementById('generate-btn');
        var box = document.getElementById('prompt-result');
        var txt = document.getElementById('prompt-text');
        var copy = document.getElementById('copy-btn');

        btn.addEventListener('click', async function(){
          btn.disabled = true; btn.textContent = 'Generating...';
          try {
            var r = await fetch('#{BASE_URL}/api/ai-connect/generate-prompt', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-Discourse-Uid': '1' },
              body: JSON.stringify({ scope: 'read write' })
            });
            var d = await r.json();
            if (r.ok && d.prompt) {
              txt.textContent = d.prompt;
              box.style.display = 'block';
              box.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            } else {
              alert('Error: ' + JSON.stringify(d));
            }
          } catch(e) {
            alert('Network error: ' + e.message);
          } finally {
            btn.disabled = false;
            btn.textContent = '⚡ Generate AI Connect Prompt';
          }
        });

        copy.addEventListener('click', function(){
          navigator.clipboard.writeText(txt.textContent).then(function(){
            var orig = copy.textContent;
            copy.textContent = '✓ Copied!';
            setTimeout(function(){ copy.textContent = orig; }, 1500);
          });
        });
      })();
      </script>
      </body></html>
    HTML
  end
end
