# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/spec/v2.0.0.html).

## [1.2.8] - unreleased

### Security
- **OAuth `redirect_uri` must be registered (OAuth 2.1 / RFC 9700).** The consent screen and the consent POST accepted any `redirect_uri`, so a crafted link could deliver the authorization code to a third party, and Deny redirected to whatever address was posted (open redirect). Now the address must be one of the client's registered URIs (exact string match; a registered loopback `http://127.0.0.1/...` / `http://localhost/...` accepts any port, RFC 8252 §7.3). Refused requests get an error from the site itself — never a redirect. The client and its address are checked before Approve or Deny does anything; Deny keeps `state`.
- **Token exchange is bound to the authorization request.** `redirect_uri` must equal the one used at authorize (an out-of-band code may omit it) and a `client_id` that is sent must be the code's client.
- `code_challenge_method` other than `S256` is refused.
- The default clients are registered with `urn:ietf:wg:oauth:2.0:oob`, the address every current connection (goldnat and the AI clients) uses, so existing connections keep working.

## [1.2.7] - unreleased

### Added — user confirmation for risky actions (user-confirm-v1)
- A tool can declare `confirmation:`. Calling it does not run it: the bridge answers
  HTTP 202 `pending_confirmation` with a plain summary for the user and a
  `confirm_url`. The action runs once, as that user, only after the user confirms
  on the new page **/ai-connect-plugin/ai-actions** inside Discourse (signed-in
  session + CSRF; requests with an API key, a user API key or an Authorization
  header are refused, so the agent can never confirm itself).
- Pending actions are bound to user + tool + arguments + client, expire after 15
  minutes, are single-use, and a re-sent `confirmation_id` only reports the result.
  A repeat of a just-confirmed call returns the stored result ("already executed").
- Optional per-user, per-tool, per-client autonomy grant (revocable on the page;
  site switch `AI_CONNECT_CONFIRMATION_AUTONOMY=0`), and an append-only event log.
- Agent status route `GET /api/ai-connect/v1/confirmations/{id}`; the manifest
  advertises `capabilities.confirmation`, a `confirmation` block, per-tool
  `confirmation` / `risk`, and an `instructions` paragraph.
- Used by the Pro package (discourse-moderator-ai-connect 1.1.0) for deleting
  posts/topics, suspending/silencing users and deleting review decisions.

### Fixed
- Pro licence check expected the free core's slug, so a valid licence of the paid
  product (`discourse-moderator-ai-connect`) could never unlock Pro.
- Input validation read a boolean `false` as a missing parameter.

## [1.2.6] - 2026-11-20

### Added (Deep Research round 2 — all read-only, as the connected user)
- 10 tools: `getCurrentUser` (who am I + token scopes), `getForumStatistics`
  (About-page counts, no contact e-mail), `getBadges`, `getSuggestedTopics`,
  `getTopicParticipants`, `getPostLikes`, `getUserActivity`, and the connected
  user's OWN `getNotifications`, `getBookmarks`, `getDrafts` (always the token
  owner — a username in the arguments is ignored).
- `goldnat` pre-registered OAuth client.

### Fixed
- A tool error such as "not found" was returned with HTTP 200; tool errors now
  carry a real status (404 not found, 400 bad input, 403 scope, 502 upstream).
- When Discourse failed (timeout / 5xx / non-JSON), list tools answered an
  empty list with success=true; they now answer `upstream_error` (502).
- The token button in Discourse ignored the requested scope and always issued
  "read write"; the requested scope / client is now forwarded (still clamped
  to what the user may hold; unknown clients fall back to the generic one).
- `getForumStats` counted only the first 30 topics; it now scans up to 300
  and reports `scanned_topics` + `complete`.

## [1.2.5] - 2026-11-11

### Fixed (found on the first run inside a real Discourse — DEV, v2026.7.5, subfolder install)
- **Consent approval was always treated as "denied".** The Discourse proxy
  forwards the consent as a JSON body, but the bridge's `POST /oauth/authorize`
  read only form-encoded params, so `approved` was never seen and no
  authorization code was issued. The route now merges the JSON body (same as
  the token endpoint). Still requires the trusted proxy secret.
- **Subfolder installs (`relative_url_root`).** The consent form posted to
  `/ai-connect-plugin/authorize` at the domain root. The Discourse plugin now
  sends its base path (`X-AI-Connect-Base-Path`), and the bridge prefixes the
  form action with it (trusted proxy only, strict path validation).

## [1.2.4] - 2026-11-10

### Security (SEC-00 permission ceiling — a tool can never do more than the token owner)
- **Tools act as the token owner.** Every Discourse API call made by a tool now
  sends `Api-Username: <token owner>` (uid resolved via `/admin/users/:id.json`,
  cached 60 s) instead of `system`, so Discourse's Guardian enforces the user's
  real permissions (no more reading others' PMs / staff categories or editing
  any post). An owner that cannot be resolved (unknown, suspended, inactive,
  staged, lookup error) gets `403 user_not_permitted`; there is no fallback to
  `system`. Calls outside an explicit acting-user context are refused.
- **Exact scope matching.** Each tool's `required_scope` is enforced on both the
  GET and POST tool routes and inside `ModuleBase#execute_tool`, by whole
  whitespace-separated tokens (`rewrite` no longer satisfies `write`).
- **Token-admin routes require a Discourse admin** (checked via the API), not
  just the `delete` scope: Bearer token with `delete` whose owner is an admin,
  or the trusted Discourse proxy acting for an admin.
- **Sidecar trust.** `X-Discourse-Uid` is honoured only with the shared secret
  `X-AI-Connect-Proxy-Secret` (env `AI_CONNECT_PROXY_SECRET` = site setting
  `ai_connect_proxy_secret`, constant-time compare) on OAuth consent,
  generate-token/prompt, and user/admin token routes. Unset secret = those
  routes return `503` (fail closed) with a startup warning. Default bind is now
  `127.0.0.1`. `DEV_ALLOW_UID_PARAM` is honoured only under `RACK_ENV=test`.
- **Scope clamping.** Requested scopes at OAuth consent and generate-token are
  filtered to `read write delete`; `delete`/`admin` are granted only to
  Discourse admins, everyone else gets at most `read write`.

### Fixed
- Discourse plugin: bridge client supports `DELETE` (token revoke via the proxy
  failed); consent form posts back to `/ai-connect-plugin/authorize` with the
  session CSRF token; anonymous `/authorize` redirects to login.

## [1.2.3] - 2026-11-09

### Security
- **RFC 7009 token revocation** (`POST /api/ai-connect/revoke`, Servio SPEC §5.2):
  now reads `token` (+ optional `token_type_hint`) from a form-urlencoded or JSON
  body instead of the `Authorization` header, needs no authentication, and
  revokes the **whole pair** whether the access or the refresh token is sent
  (previously revoking a refresh token left its access token valid). Always
  returns `200 {"revoked":true}` (no token probing); `400 invalid_request` only
  when `token` is missing. The token registry (admin list / My Tokens) is
  updated in the same transaction. Advertised as `auth.revocation_url`.

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
