import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "ai-connect-init",
  initialize() {
    withPluginApi("0.8.31", (api) => {
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
    });
  }
};
