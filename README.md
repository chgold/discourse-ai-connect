# Goldnat AI Connect for Discourse

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-1.2.5-green.svg)](CHANGELOG.md)

**Lets AI agents (Claude, ChatGPT, Gemini, Grok, Copilot, Perplexity, Meta AI, DeepSeek, …) search and read your Discourse forum through OAuth 2.0 + PKCE, acting as the user who approved them, with that user's permissions.**

Agents discover the available tools from a JSON manifest (the open [Servio](https://github.com/chgold/servio) protocol), so no per-agent setup is needed.

- **25 read-only tools.** This plugin does not create, edit or delete anything.
- **Runs as the token owner.** Tool calls reach the Discourse API with `Api-Username` set to the user who approved the agent, so Discourse's own Guardian decides what is visible: no private messages, staff categories or hidden topics the user could not see in the browser. A user who is suspended, staged, inactive or cannot be resolved is refused (`403`), with no fallback to the system user.
- **Exact scope checks** on every call, **rate limiting** per user and per endpoint, token list and revocation for users and admins, RFC 7009 revocation.
- **Subfolder installs** (`relative_url_root`) are supported.

---

## What it does

AI Connect has two cooperating pieces:

```
  AI Agent  ─►  Sinatra bridge service  ◄─►  Discourse REST API
                  (sinatra_service/)
                  ▲
                  │  /ai-connect-plugin/* proxy (+ shared secret)
                  │
              Discourse plugin
              (discourse_plugin/, mounted inside Discourse)
```

| Piece                 | Path                    | Role                                                                   |
|-----------------------|-------------------------|------------------------------------------------------------------------|
| **Sinatra bridge**    | `sinatra_service/`      | OAuth2 + PKCE, tool dispatch, rate limit, manifest, all REST calls (Ruby/Sinatra + its own PostgreSQL database) |
| **Discourse plugin**  | `discourse_plugin/`     | Consent screen; forwards `/ai-connect-plugin/*` to the bridge with the signed-in user's id |

The two parts trust each other only through a shared secret (`ai_connect_proxy_secret` / `AI_CONNECT_PROXY_SECRET`). If it is unset, the sensitive routes return `503`.

### 25 tools (all `read` scope)

| Group | Tools |
|-------|-------|
| Topics | `discourse.searchTopics`, `discourse.getTopic`, `discourse.getTopicSummary`, `discourse.getTopicPostsRange`, `discourse.getLatestTopics`, `discourse.getTopTopics` |
| Posts | `discourse.getPost`, `discourse.searchPosts`, `discourse.searchByAuthor`, `discourse.searchInCategory`, `discourse.getPostRevisions`, `discourse.getPostRevisionContent` |
| Categories | `discourse.getCategories`, `discourse.listCategories`, `discourse.getCategory`, `discourse.searchCategories`, `discourse.listTopicsByCategory` |
| Tags | `discourse.listTags`, `discourse.getTag`, `discourse.searchTags`, `discourse.listTopicsByTag`, `discourse.searchByTag` |
| Users | `discourse.getUserProfile`, `discourse.searchUsers` |
| Stats | `discourse.getForumStats` (unanswered topics count) |

A paid edition with write tools is planned but not released yet.

### External services

None by default. If an `AICONNECT_LICENSE_KEY` is set on the bridge (paid edition only), the key is validated against `https://goldnat.ai/api/licenses/public/validate`. Without a key, no request leaves your server.

---

## Installation

### 1. Install the Sinatra bridge service

```bash
cd sinatra_service
bundle install

# Configure environment
cp .env.example .env
$EDITOR .env

# Initialise DB (PostgreSQL must be reachable)
createdb -h "$DB_HOST" -U "$DB_USER" "$DB_NAME"

# Run
bundle exec puma -C config.ru -p 3086
# or: bundle exec rackup -p 3086
```

The bridge listens on `:3086` by default. In production, put Apache or Nginx in front of it for TLS, and expose it as `:8086`.

### 2. Install the Discourse plugin

In a normal Discourse install, edit `containers/app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/chgold/discourse-ai-connect.git
```

Then rebuild:

```bash
./launcher rebuild app
```

In **development**, symlink the plugin directory:

```bash
ln -s /path/to/discourse-ai-connect/discourse_plugin \
      /path/to/discourse/plugins/ai-connect
```

Then go to **Admin → Settings → Plugins** and configure:

| Setting | Description |
|---------|-------------|
| `ai_connect_enabled` | Turn the plugin on or off (default: on) |
| `ai_connect_bridge_url` | Where the bridge runs (default `http://localhost:3086`) |
| `ai_connect_proxy_secret` | Shared secret — the same value as `AI_CONNECT_PROXY_SECRET` on the bridge. Required. Generate with `openssl rand -hex 32` |
| `ai_connect_notify_login` | Tell the bridge when a user logs in (default: off) |

Open `/ai-connect-plugin/` while logged in to get a ready-made prompt for your AI agent.

---

## OAuth setup

AI Connect uses **OAuth2 Authorization Code Grant with PKCE** (RFC 7636). PKCE is **required** — clients without `code_challenge` / `code_verifier` are rejected.

### Endpoints

| Method | Path                         | Auth                      | Purpose                                              |
|--------|------------------------------|---------------------------|------------------------------------------------------|
| GET    | `/api/ai-connect/manifest`   | none                      | Servio manifest (`auth.token_url`, `auth.revocation_url`) |
| GET    | `/oauth/authorize`           | Discourse session         | PKCE consent screen                                  |
| POST   | `/api/ai-connect/token`      | none (PKCE / refresh)     | `authorization_code` and `refresh_token` grants      |
| POST   | `/api/ai-connect/revoke`     | none (token possession)   | RFC 7009 revocation: `token` (+ optional `token_type_hint`), form or JSON; revokes the whole pair; always `200` except `400 invalid_request` when `token` is missing |
| GET/POST | `/api/ai-connect/v1/tools/:name` | Bearer access token  | Tool execution                                       |
| GET    | `/health`                    | none                      | Health check                                         |

### Flow

```
┌──────────┐   1. GET /oauth/authorize?client_id=claude&code_challenge=…
│          │ ────────────────────────────────────────────────►
│  Agent   │
│ (Claude) │   2. consent page → user clicks "Approve"
│          │ ◄────────────────────────────────────────────────
│          │
│          │   3. redirect with ?code=…&state=…
│          │ ────────────────────────────────────────────────►
│          │
│          │   4. POST /api/ai-connect/token (code + code_verifier)
│          │ ────────────────────────────────────────────────►
│          │   5. { access_token, refresh_token, expires_in }
│          │ ◄────────────────────────────────────────────────
└──────────┘
```

Pre-registered clients: `claude`, `chatgpt`, `gemini`, `grok`, `copilot`, `perplexity`, `meta-ai`, `deepseek`, `ai-agent-default`, plus `webmcp-master` (the Goldnat test client).

### Manual smoke test

```bash
# 1. Manifest
curl -s http://localhost:8086/api/ai-connect/manifest | jq .name

# 2. Generate a quick test token. X-Discourse-Uid is trusted ONLY together with
#    the shared proxy secret (normally sent by the Discourse plugin).
curl -s -X POST http://localhost:8086/api/ai-connect/generate-token \
  -H "X-AI-Connect-Proxy-Secret: $AI_CONNECT_PROXY_SECRET" \
  -H "X-Discourse-Uid: 1"
# → { "access_token": "xfa_…", "expires_in": 3600 }

# 3. Call a tool
export TOKEN="dsc_…"
curl -s -X POST http://localhost:8086/api/ai-connect/v1/tools/discourse.getCategories \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}'
```

---

## Tool examples

```bash
TOKEN="dsc_yourtokenhere"

# searchTopics — read scope
curl -X POST http://localhost:8086/api/ai-connect/v1/tools/discourse.searchTopics \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"query":"install","page":1}'

# getCategories
curl -X POST http://localhost:8086/api/ai-connect/v1/tools/discourse.getCategories \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{}'

# getLatestTopics in category 2
curl -X POST http://localhost:8086/api/ai-connect/v1/tools/discourse.getLatestTopics \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"category_id":2}'

# getTopic
curl -X POST http://localhost:8086/api/ai-connect/v1/tools/discourse.getTopic \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"topic_id":101}'

# getUserProfile
curl -X POST http://localhost:8086/api/ai-connect/v1/tools/discourse.getUserProfile \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"username":"admin"}'
```

---

## Environment variables

| Variable                          | Default                  | Purpose                                          |
|-----------------------------------|--------------------------|--------------------------------------------------|
| `PORT`                            | `3086`                   | Bind port for the bridge                         |
| `BIND`                            | `127.0.0.1`              | Bind address (keep loopback; only Discourse should reach the bridge) |
| `AI_CONNECT_PROXY_SECRET`         | _(required)_             | Shared secret the Discourse plugin sends as `X-AI-Connect-Proxy-Secret` (same value as site setting `ai_connect_proxy_secret`). Unset = consent, token-generation and user/admin token routes fail closed |
| `RACK_ENV`                        | `development`            | `production` enables HTTPS upgrade + strict CORS |
| `DB_HOST`                         | `127.0.0.1`              | PostgreSQL host                                  |
| `DB_PORT`                         | `5432`                   | PostgreSQL port                                  |
| `DB_NAME`                         | `discourse_dev`          | DB name                                          |
| `DB_USER`                         | `discourse`              | DB user                                          |
| `DB_PASSWORD`                     | _(required in prod)_     | DB password                                      |
| `DISCOURSE_URL`                   | `http://localhost:3000`  | Upstream Discourse REST endpoint                 |
| `DISCOURSE_API_KEY`               | _(none)_                 | Discourse **All Users** API key — tool calls send `Api-Username: <token owner>` so Discourse enforces that user's permissions |
| `DISCOURSE_API_USER`              | `system`                 | Username used ONLY for bridge-internal lookups (uid → username, admin check); never for tool calls |
| `DISCOURSE_AI_CONNECT_URL`        | `http://localhost:8086`  | Public URL used in manifest                      |
| `ALLOWED_ORIGINS`                 | _(empty)_                | Comma-separated CORS whitelist                   |
| `RATE_LIMIT_TOOL_PER_MINUTE`      | `50`                     | Per-token tool calls / minute                    |
| `RATE_LIMIT_TOOL_PER_HOUR`        | `1000`                   | Per-token tool calls / hour                      |
| `RATE_LIMIT_OAUTH_PER_MINUTE`     | `10`                     | OAuth `/authorize` / min / IP                    |
| `RATE_LIMIT_OAUTH_PER_HOUR`       | `60`                     | OAuth `/authorize` / hour / IP                   |
| `RATE_LIMIT_TOKEN_PER_MINUTE`     | `20`                     | Token endpoint / min / IP                        |
| `RATE_LIMIT_TOKEN_PER_HOUR`       | `200`                    | Token endpoint / hour / IP                       |
| `DEV_ALLOW_UID_PARAM`             | `0`                      | Dev only: trust `uid` form param                 |
| `DISCOURSE_STUB_MODE`             | `0`                      | Serve stub data instead of real Discourse        |

---

## Development setup

```bash
git clone https://github.com/chgold/discourse-ai-connect
cd discourse-ai-connect/sinatra_service
bundle install
cp .env.example .env

# Create dev + test DBs
createdb -h 127.0.0.1 -U discourse discourse_dev
createdb -h 127.0.0.1 -U discourse discourse_dev_test

# Run tests
./bin/test

# Start dev server (stub Discourse, no upstream needed)
DISCOURSE_STUB_MODE=1 bundle exec rackup -p 3086

# Health check
curl http://localhost:3086/health
```

### Project layout

```
discourse-ai-connect/
├── sinatra_service/           # Bridge service
│   ├── app.rb                 # Sinatra app + routes
│   ├── config.ru              # Rack entrypoint
│   ├── Gemfile
│   ├── .env.example
│   ├── controllers/           # manifest, oauth, tools, info
│   ├── middleware/            # auth, rate_limit
│   ├── services/              # db, discourse_api
│   ├── lib/                   # input_validator
│   ├── fixtures/              # stub_data for tests/demo
│   ├── spec/                  # RSpec suite (60%+ coverage)
│   └── bin/test
├── discourse_plugin/          # Discourse-side plugin
│   ├── plugin.rb              # Manifest header (required by Discourse)
│   ├── config/
│   │   ├── settings.yml
│   │   └── locales/
│   ├── db/migrate/
│   ├── lib/ai_connect/        # bridge_client.rb, proxy_controller.rb
│   └── assets/
├── README.md
├── CHANGELOG.md
├── LICENSE                    # GPL-3.0
└── SECURITY.md
```

---

## Security

- **PKCE required** for all OAuth code grants (S256, RFC 7636)
- **Constant-time** PKCE verifier comparison (timing-safe)
- **HTTPS forced** when `RACK_ENV=production` (non-localhost upstream)
- **CORS whitelist** via `ALLOWED_ORIGINS` (never `*` in production)
- **DB password** must be set via env var; refused in production if absent
- **Rate limiting**: per-IP on OAuth endpoints, per-token on tool endpoints
- **Input validation** on every tool parameter (type + length limits)
- **Bearer tokens** are random 32-byte hex, scoped, time-limited (1h), revocable

---

## Support

- Bugs and questions: please use the contact form at <https://goldnat.ai/contact> (please name the plugin and its version). This is our main channel for bug reports.
- GitHub issues: <https://github.com/chgold/discourse-ai-connect/issues> are also read, but the contact form gets a faster answer.
- Security issues: see [SECURITY.md](SECURITY.md) — please do not open a public issue
- Documentation: <https://plugins.goldnat.ai/discourse>

---

## License

[GPL-3.0](LICENSE) © 2026 Chen Gold-Tovi
