# Discourse AI Connect — Agent Instructions

## Scope
Work exclusively within `/workspace/plugins/discourse/discourse-ai-connect/`.
Do NOT touch `/workspace/plugins-manager/` or any other platform directory.

Two parts:
- `discourse_plugin/` — runs inside Discourse (Ruby on Rails)
- `sinatra_service/` — separate Sinatra HTTP service (PostgreSQL)

## Token Management (mandatory)
This plugin complies with **Token Management UI & Lifecycle v1.0** (`/workspace/.specs/TOKEN-MANAGEMENT-SPEC.md`).

Minimum requirements:
- `ai_connect_token_registry` table with prefix-only storage (16 chars)
- `last_used_at`, `last_used_ip`, `last_used_ua` — updated on every request via `touch_last_used`
- User-facing page in Discourse user preferences (`/u/:username/preferences/ai-tokens`)
- 6 filters: Active / Renewable / Unused / Inactive / Revoked / All
- Cascade revoke to `ai_tokens` table (kills refresh_token too) — security mandatory
- Bulk revoke filter-aware
- Lazy cleanup via class-level timestamp + background scheduler

## Key source files
| File | Purpose |
|---|---|
| `sinatra_service/services/db.rb` | All registry operations + cascade |
| `sinatra_service/middleware/auth.rb` | Bearer auth — IP+UA + lazy cleanup |
| `sinatra_service/app.rb` | New endpoints (admin bulk + user-facing) |
| `discourse_plugin/lib/ai_connect/proxy_controller.rb` | Routes user/admin tokens |
| `discourse_plugin/assets/javascripts/discourse/` | UI (Ember controllers, routes, templates) |

## Tests
```bash
sudo -u discourse-dev bash -c 'cd /workspace/plugins/discourse/discourse-ai-connect/sinatra_service && bundle exec rspec'
```

## Git
All git commands prefixed with `GIT_MASTER=1`. Do NOT commit without explicit user approval.
