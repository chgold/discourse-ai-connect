import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "ai-connect-init",
  initialize() {
    withPluginApi("0.8.31", (api) => {
      // ── Legacy: generate-token button in account preferences ──────────────
      api.modifyClass("controller:preferences/account", {
        pluginId: "ai-connect",
        actions: {
          generateAiToken() {
            return fetch("/ai-connect-plugin/generate-token", {
              method: "POST",
              headers: { "X-Requested-With": "XMLHttpRequest" }
            })
              .then((r) => r.json())
              .then((data) => {
                if (data.access_token) {
                  navigator.clipboard.writeText(data.access_token);
                  this.dialog.alert(I18n.t("ai_connect.token_copied"));
                }
              });
          }
        }
      });

      // ── Token management tab in user preferences ──────────────────────────
      // Registers a new preferences route: /u/:username/preferences/ai-tokens
      api.addUserMenuTab?.({
        id: "ai-tokens",
        name: "ai_connect.tokens_page_title",
        icon: "key",
        route: "preferences.ai-tokens"
      });

      // Extend preferences routes with the ai-tokens section
      api.modifyClass?.("route:preferences", {
        pluginId: "ai-connect",
        actions: {
          // noop — handled by child route
        }
      });
    });
  }
};
