# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-07-03

### Changed
- **Servio Protocol:** Token prefixes aligned to unified standard (`dsc_` → `xfa_`, `dscr_` → `xfr_`).

## [1.0.0] - 2026-05-10

### Added

- **Discourse plugin** (`discourse_plugin/`) — was empty in 0.x; now ships a
  full manifest, locales, migration, proxy controller, bridge client, and a
  Glimmer initializer. Mounted at `/ai-connect-plugin/*`.
- **RSpec test suite** (`sinatra_service/spec/`) with 50 examples covering
  manifest, OAuth PKCE flow, tools, auth middleware, rate limiting, input
  validation, and CORS. Coverage > 80%.
- **`bin/test`** script for one-command test runs.
- **Input validation** library (`lib/input_validator.rb`) — type coercion
  and length limits on every tool param.
- **Health endpoint** `GET /health`.
- **`DISCOURSE_STUB_MODE`** for running without a live Discourse upstream.
- README, CHANGELOG, LICENSE, TEST_CREDENTIALS docs.

### Changed (security)

- **DB credentials** moved out of source into `DB_HOST/PORT/NAME/USER/PASSWORD`
  env vars; `DB_PASSWORD` is **required** in production.
- **OAuth UID resolution** no longer trusts a hardcoded `1` — reads from
  `X-Discourse-Uid` header (set by the Discourse plugin) or rejects the
  request. `DEV_ALLOW_UID_PARAM=1` opt-in for local development only.
- **CORS** is now whitelist-based via `ALLOWED_ORIGINS`; never `*` in
  production.
- **`DISCOURSE_URL`** is auto-upgraded to HTTPS in production (non-localhost).
- **PKCE comparison** is constant-time to prevent timing attacks.
- **Bare rescues** replaced with `rescue StandardError` + structured logging
  via `Logger`.
- **Rate limiting** added on `/oauth/authorize` (per IP) and
  `/api/ai-connect/token` (per IP), in addition to existing per-token limits
  on tool endpoints. All limits are env-tunable.
- **Bearer token check** in `AuthMiddleware` now rejects empty tokens.
- **HTML escaping** in OAuth consent form to prevent reflected XSS.

### Fixed

- Tool error responses with array payloads no longer raise
  `TypeError: no implicit conversion of Symbol into Integer`.
- Response from `discourse.editPost` now consistently shapes its return value.
- `client_ip` helper handles `X-Forwarded-For` correctly when behind a proxy.

## [0.1.0] - 2026-04-20

### Added

- Initial Sinatra bridge with manifest, OAuth, 11 tools.
- Empty `discourse_plugin/` scaffolding (no actual plugin code).
