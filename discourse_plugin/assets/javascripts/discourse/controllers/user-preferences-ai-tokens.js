import Controller from "@ember/controller";
import { action } from "@ember/object";
import { tracked } from "@glimmer/tracking";
import { inject as service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import I18n from "I18n";

const FILTERS = ["all", "active", "unused", "inactive", "expired", "revoked"];

function tokenState(tok) {
  const now = Date.now() / 1000;
  if (tok.revoked_at) return "revoked";
  const expiresAt = tok.expires_at
    ? new Date(tok.expires_at).getTime() / 1000
    : null;
  if (expiresAt && expiresAt <= now) return "expired";
  if (!tok.last_used_at) return "unused";
  const lastUsed = new Date(tok.last_used_at).getTime() / 1000;
  if (now - lastUsed > 30 * 86400) return "inactive";
  return "active";
}

function relativeTime(isoStr) {
  if (!isoStr) return I18n.t("ai_connect.never");
  const diff = (Date.now() - new Date(isoStr).getTime()) / 1000;
  if (diff < 60) return I18n.t("ai_connect.just_now");
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

function uaShort(ua) {
  if (!ua) return "—";
  // Shorten known AI agents
  if (/chatgpt/i.test(ua)) return "ChatGPT";
  if (/claude/i.test(ua)) return "Claude";
  if (/gemini/i.test(ua)) return "Gemini";
  if (/copilot/i.test(ua)) return "Copilot";
  if (/perplexity/i.test(ua)) return "Perplexity";
  // Fall back to first 40 chars
  return ua.slice(0, 40);
}

function enrichToken(tok) {
  const state = tokenState(tok);
  return {
    ...tok,
    state,
    state_label: I18n.t(`ai_connect.state_${state}`),
    issued_relative: relativeTime(tok.issued_at),
    last_used_relative: relativeTime(tok.last_used_at),
    ua_short: uaShort(tok.last_used_ua),
  };
}

export default class UserPreferencesAiTokensController extends Controller {
  @service dialog;
  @service router;

  @tracked tokens = [];
  @tracked isLoading = false;
  @tracked loadError = false;
  @tracked activeFilter = "all";

  get filters() {
    return FILTERS.map((key) => ({
      key,
      label: I18n.t(`ai_connect.filter_${key}`),
    }));
  }

  // ── lifecycle ────────────────────────────────────────────────────────────

  async loadTokens() {
    this.isLoading = true;
    this.loadError = false;
    try {
      const qs = this.activeFilter !== "all" ? `?filter=${this.activeFilter}` : "";
      const data = await ajax(`/ai-connect-plugin/tokens${qs}`);
      this.tokens = (data.tokens || []).map(enrichToken);
    } catch {
      this.loadError = true;
    } finally {
      this.isLoading = false;
    }
  }

  // ── actions ──────────────────────────────────────────────────────────────

  @action
  setFilter(key) {
    this.activeFilter = key;
    this.loadTokens();
  }

  @action
  async revokeToken(tok) {
    const confirmed = await this.dialog.confirm({
      message: I18n.t("ai_connect.revoke_confirm"),
    });
    if (!confirmed) return;

    try {
      await ajax(`/ai-connect-plugin/tokens/${tok.token_prefix}`, {
        type: "DELETE",
      });
      this.tokens = this.tokens.map((t) =>
        t.token_prefix === tok.token_prefix
          ? { ...t, state: "revoked", state_label: I18n.t("ai_connect.state_revoked") }
          : t
      );
    } catch {
      this.dialog.alert(I18n.t("ai_connect.revoke_error"));
    }
  }

  @action
  async revokeAllUnused() {
    const confirmed = await this.dialog.confirm({
      message: I18n.t("ai_connect.revoke_all_unused_confirm"),
    });
    if (!confirmed) return;
    await this._bulkRevoke("unused");
  }

  @action
  async revokeAllInactive() {
    const confirmed = await this.dialog.confirm({
      message: I18n.t("ai_connect.revoke_all_inactive_confirm"),
    });
    if (!confirmed) return;
    await this._bulkRevoke("inactive");
  }

  @action
  async revokeAllDanger() {
    const confirmed = await this.dialog.confirm({
      message: I18n.t("ai_connect.revoke_all_danger_confirm"),
    });
    if (!confirmed) return;
    await this._bulkRevoke("all");
  }

  async _bulkRevoke(filter) {
    try {
      const data = await ajax("/ai-connect-plugin/tokens/bulk-revoke", {
        type: "POST",
        data: JSON.stringify({ filter }),
        contentType: "application/json",
      });
      const count = data.revoked || 0;
      this.dialog.alert(I18n.t("ai_connect.bulk_revoke_success", { count }));
      await this.loadTokens();
    } catch {
      this.dialog.alert(I18n.t("ai_connect.revoke_error"));
    }
  }
}
