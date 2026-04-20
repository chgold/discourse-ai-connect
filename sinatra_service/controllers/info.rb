module InfoController
  BASE_URL = ENV.fetch('DISCOURSE_AI_CONNECT_URL', 'http://localhost:8086')

  def self.page(env)
    <<~HTML
      <!DOCTYPE html><html><head><meta charset="utf-8"><title>AI Connect — Discourse</title>
      <style>body{font-family:sans-serif;max-width:700px;margin:40px auto;padding:20px;line-height:1.6}
      code{background:#f4f4f4;padding:2px 6px;border-radius:3px}pre{background:#f4f4f4;padding:15px;border-radius:6px;overflow-x:auto}
      .badge{background:#4CAF50;color:#fff;padding:4px 10px;border-radius:3px;font-size:14px}</style></head><body>
      <h1>🤖 AI Connect for Discourse <span class="badge">GACP v1.0</span></h1>
      <p>Connect AI agents to this Discourse forum via the WebMCP Protocol.</p>
      <h2>Manifest URL</h2>
      <pre><code>#{BASE_URL}/api/ai-connect/manifest</code></pre>
      <h2>OAuth Authorization</h2>
      <pre><code>#{BASE_URL}/oauth/authorize</code></pre>
      <h2>Available Tools</h2>
      <p><strong>Free (6):</strong> searchTopics, getTopic, getPost, getCategories, getUserProfile, getLatestTopics</p>
      <p><strong>Pro (5):</strong> createTopic, replyToTopic, editPost, sendMessage, likePost</p>
      <h2>Quick Start</h2>
      <pre><code>curl -X POST #{BASE_URL}/api/ai-connect/v1/tools/discourse.getCategories \\
        -H "Authorization: Bearer YOUR_TOKEN" \\
        -H "Content-Type: application/json" \\
        -d '{}'</code></pre>
      </body></html>
    HTML
  end
end
