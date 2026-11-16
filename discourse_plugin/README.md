# discourse-ai-connect (Discourse plugin)

This is the **Discourse-side** half of AI Connect. It mounts under `/ai-connect-plugin/*`
and proxies requests to the **Sinatra bridge service** (`../sinatra_service/`), forwarding
the authenticated user's UID via `X-Discourse-Uid` so the bridge can issue scoped OAuth tokens.

## Routes

| Method | Path                                | Purpose                                        |
|--------|-------------------------------------|------------------------------------------------|
| GET    | `/ai-connect-plugin/`               | Info page                                      |
| GET    | `/ai-connect-plugin/manifest`       | Proxies to bridge `/api/ai-connect/manifest`   |
| GET    | `/ai-connect-plugin/authorize`      | OAuth consent screen (proxy)                   |
| POST   | `/ai-connect-plugin/authorize`      | Handle consent submission                      |
| POST   | `/ai-connect-plugin/generate-token` | Self-service token generation                  |

## Site settings

| Setting                    | Default                   | Description                                |
|----------------------------|---------------------------|--------------------------------------------|
| `ai_connect_enabled`       | `true`                    | Master on/off switch                       |
| `ai_connect_bridge_url`    | `http://localhost:3086`   | URL of the Sinatra bridge service          |
| `ai_connect_notify_login`  | `false`                   | Notify bridge on user login events         |

## Install

```bash
cd /var/discourse/containers/app.yml      # in standard Discourse install
# Append to hooks.after_code:
#   - exec:
#       cd: $home/plugins
#       cmd:
#         - git clone https://github.com/chgold/discourse-ai-connect.git
./launcher rebuild app
```

For development:

```bash
ln -s /path/to/discourse-ai-connect/discourse_plugin \
      /var/www/discourse/plugins/ai-connect
```
