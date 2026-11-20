# frozen_string_literal: true

require 'cgi'
require 'json'

# ConfirmationsController — the human step of user-confirm-v1 (1.2.7).
#
# Rendered by the bridge, shown by Discourse at /ai-connect-plugin/ai-actions (ProxyController#ai_actions):
# the signed-in user sees the actions an AI agent asked to run in their name, with a plain summary,
# and confirms or rejects each one. The form posts back to Discourse (session cookie + CSRF token);
# Discourse refuses API-key / user-API-key / Authorization requests before proxying, so an agent
# holding a token can never confirm its own request.
module ConfirmationsController
  T = {
    'en' => {
      title: 'AI actions', heading: 'AI actions waiting for your confirmation',
      intro: 'An AI assistant you connected asked to do these things in your name. Nothing happens until you confirm.',
      none: 'Nothing is waiting for your confirmation.',
      what: 'What will happen', tech: 'Technical details', client: 'Asked by', requested: 'Asked at',
      expires: 'Expires', confirm: 'Confirm and run', reject: 'Reject',
      autonomy: 'From now on, let %<client>s run this action without asking me',
      grants: 'Actions you allowed without asking', remove: 'Remove', no_grants: 'None.',
      recent: 'Recent decisions', done_ok: 'Done. The action ran once, in your name.',
      done_fail: 'The action was confirmed but Discourse refused it: %<error>s',
      rejected: 'Rejected. Nothing was done.', running: 'Confirmed. The action is running now, once, in your name. Refresh this page in a moment to see the result.', gone: 'This request is no longer waiting (status: %<status>s).',
      not_found: 'This request was not found for your account.', revoked: 'Removed. The assistant will ask again next time.',
      st_pending: 'waiting', st_executed: 'done', st_failed: 'failed', st_rejected: 'rejected', st_expired: 'expired', st_executing: 'running'
    },
    'he' => {
      title: 'פעולות AI', heading: 'פעולות AI שמחכות לאישור שלך',
      intro: 'עוזר AI שחיברת ביקש לעשות את הדברים האלה בשמך. שום דבר לא קורה עד שתאשר.',
      none: 'אין כרגע פעולות שמחכות לאישור שלך.',
      what: 'מה יקרה', tech: 'פרטים טכניים', client: 'מי ביקש', requested: 'מתי ביקש',
      expires: 'בתוקף עד', confirm: 'לאשר ולבצע', reject: 'לדחות',
      autonomy: 'מעכשיו, %<client>s יכול לבצע את הפעולה הזאת בלי לשאול אותי',
      grants: 'פעולות שהרשית בלי לשאול', remove: 'להסיר', no_grants: 'אין.',
      recent: 'החלטות אחרונות', done_ok: 'בוצע. הפעולה רצה פעם אחת, בשמך.',
      done_fail: 'אישרת, אבל Discourse סירב לבצע: %<error>s',
      rejected: 'נדחה. שום דבר לא בוצע.', running: 'אושר. הפעולה רצה עכשיו, פעם אחת, בשמך. רעננו את הדף בעוד רגע כדי לראות את התוצאה.', gone: 'הבקשה הזאת כבר לא מחכה (מצב: %<status>s).',
      not_found: 'הבקשה לא נמצאה בחשבון שלך.', revoked: 'הוסר. העוזר יבקש אישור שוב בפעם הבאה.',
      st_pending: 'ממתין', st_executed: 'בוצע', st_failed: 'נכשל', st_rejected: 'נדחה', st_expired: 'פג תוקף', st_executing: 'בביצוע'
    }
  }.freeze

  module_function

  def lang(locale)
    AiConnect::Confirmation.lang(locale)
  end

  def tr(locale, key, **vars)
    str = T[lang(locale)][key] || T['en'][key]
    vars.empty? ? str : format(str, **vars)
  end

  def h(s)
    CGI.escapeHTML(s.to_s)
  end

  def client_name(client_id)
    return '—' if client_id.to_s.empty?

    DB.registered_clients_map[client_id] || client_id
  rescue StandardError
    client_id
  end

  def when_s(ts)
    ts ? Time.at(ts.to_i).utc.strftime('%Y-%m-%d %H:%M UTC') : '—'
  end

  def page(uid, opts, notice: nil, notice_kind: 'info')
    loc = opts[:locale]
    base = opts[:base_path].to_s.sub(%r{/+\z}, '')
    csrf = opts[:csrf].to_s
    pending = ConfirmationStore.pending_for_user(uid)
    focus = opts[:focus].to_s
    pending = pending.partition { |a| a['id'] == focus }.flatten unless focus.empty?
    grants = ConfirmationStore.autonomy_for_user(uid)
    recent = ConfirmationStore.recent_for_user(uid, 10)
    rtl = lang(loc) == 'he'

    cards = pending.map { |a| card(a, loc, base, csrf) }.join
    cards = "<p class=\"muted\">#{h tr(loc, :none)}</p>" if cards.empty?
    grant_rows = grants.map do |g|
      <<~HTML
        <li><code>#{h g['tool']}</code> — #{h client_name(g['client_id'])}
          <form method="post" action="#{h base}/ai-connect-plugin/ai-actions/autonomy/revoke" class="inline">
            <input type="hidden" name="authenticity_token" value="#{h csrf}">
            <input type="hidden" name="grant_id" value="#{h g['id']}">
            <button type="submit" class="link">#{h tr(loc, :remove)}</button>
          </form></li>
      HTML
    end.join
    grant_rows = "<li class=\"muted\">#{h tr(loc, :no_grants)}</li>" if grant_rows.empty?
    recent_rows = recent.map do |a|
      "<li>#{h a['summary']} — <strong>#{h tr(loc, :"st_#{a['status']}")}</strong> <span class=\"muted\">#{h when_s(a['decided_at'] || a['created_at'])}</span></li>"
    end.join

    <<~HTML
      <!DOCTYPE html><html lang="#{lang(loc)}" dir="#{rtl ? 'rtl' : 'ltr'}"><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1"><title>#{h tr(loc, :title)}</title>
      <style>
        body{font-family:system-ui,-apple-system,sans-serif;max-width:720px;margin:32px auto;padding:0 16px;color:#222;background:#fff}
        h1{font-size:1.4em} h2{font-size:1.15em;margin:0 0 8px} .muted{color:#666}
        .card{border:1px solid #ccc;border-radius:8px;padding:16px;margin:16px 0}
        .card ul{margin:6px 0 10px} .meta{font-size:.9em;color:#555}
        .notice{padding:12px;border-radius:6px;margin:16px 0;background:#eef6ff;border:1px solid #9cc3ef}
        .notice.error{background:#fdecec;border-color:#e99}
        .notice.ok{background:#ecf9ee;border-color:#8c8}
        button{padding:8px 16px;border-radius:6px;border:1px solid #888;cursor:pointer;font-size:1em}
        button.confirm{background:#b3261e;color:#fff;border-color:#b3261e} button.link{border:none;background:none;color:#06c;padding:0 4px}
        form.inline{display:inline} details{margin-top:8px;font-size:.85em} pre{white-space:pre-wrap;word-break:break-word;background:#f6f6f6;padding:8px}
      </style></head><body>
      <h1>#{h tr(loc, :heading)}</h1>
      <p class="muted">#{h tr(loc, :intro)}</p>
      #{notice ? "<div class=\"notice #{h notice_kind}\">#{h notice}</div>" : ''}
      #{cards}
      <h2>#{h tr(loc, :grants)}</h2><ul>#{grant_rows}</ul>
      #{recent_rows.empty? ? '' : "<h2>#{h tr(loc, :recent)}</h2><ul>#{recent_rows}</ul>"}
      </body></html>
    HTML
  end

  def card(a, loc, base, csrf)
    details = Array(a['details']).map { |d| "<li>#{h d}</li>" }.join
    autonomy = if AiConnect::Confirmation.autonomy_allowed? && !a['client_id'].to_s.empty?
                 "<p><label><input type=\"checkbox\" name=\"autonomy\" value=\"1\"> #{h tr(loc, :autonomy, client: client_name(a['client_id']))}</label></p>"
               else
                 ''
               end
    preview = a['preview'] ? JSON.pretty_generate(a['preview']) : '{}'
    <<~HTML
      <div class="card" id="#{h a['id']}">
        <h2>#{h a['summary']}</h2>
        #{details.empty? ? '' : "<strong>#{h tr(loc, :what)}</strong><ul>#{details}</ul>"}
        <div class="meta">#{h tr(loc, :client)}: #{h client_name(a['client_id'])} · #{h tr(loc, :requested)}: #{h when_s(a['created_at'])} · #{h tr(loc, :expires)}: #{h when_s(a['expires_at'])}</div>
        <form method="post" action="#{h base}/ai-connect-plugin/ai-actions/decide">
          <input type="hidden" name="authenticity_token" value="#{h csrf}">
          <input type="hidden" name="confirmation_id" value="#{h a['id']}">
          #{autonomy}
          <button type="submit" name="decision" value="confirm" class="confirm">#{h tr(loc, :confirm)}</button>
          <button type="submit" name="decision" value="reject">#{h tr(loc, :reject)}</button>
        </form>
        <details><summary>#{h tr(loc, :tech)}</summary><p><code>#{h a['tool']}</code> · #{h a['risk']} · <code>#{h a['id']}</code></p><pre>#{h preview}</pre></details>
      </div>
    HTML
  end

  # Returns [http_status, html].
  def decide(uid, body, registry, opts)
    loc = opts[:locale]
    id = body['confirmation_id'].to_s
    decision = body['decision'].to_s
    return [400, page(uid, opts, notice: tr(loc, :not_found), notice_kind: 'error')] if id.empty? || !%w[confirm reject].include?(decision)

    ConfirmationStore.sweep!
    if decision == 'reject'
      action = ConfirmationStore.reject(id, uid)
      return gone(uid, id, opts) unless action

      ConfirmationStore.add_event(id, 'rejected', uid: uid, actor_uid: uid, tool: action['tool'], client_id: action['client_id'], ip: opts[:ip])
      return [200, page(uid, opts, notice: tr(loc, :rejected), notice_kind: 'info')]
    end

    action = ConfirmationStore.claim(id, uid)
    return gone(uid, id, opts) unless action

    ConfirmationStore.add_event(id, 'confirmed', uid: uid, actor_uid: uid, tool: action['tool'], client_id: action['client_id'], ip: opts[:ip])
    if AiConnect::Confirmation.truthy?(body['autonomy']) && AiConnect::Confirmation.autonomy_allowed? &&
       ConfirmationStore.grant_autonomy(uid, action['tool'], action['client_id'])
      ConfirmationStore.add_event(id, 'autonomy_granted', uid: uid, actor_uid: uid, tool: action['tool'], client_id: action['client_id'], ip: opts[:ip])
    end
    # The tool calls Discourse back, and this request is itself being served by Discourse. On a
    # single-worker Discourse a synchronous run would wait for the worker that waits for us (seen on
    # DEV: 10 s proxy timeout, then the action ran). So the action runs in its own thread; we wait a
    # few seconds for it and otherwise tell the user it is running (status_url / a refresh shows it).
    worker = Thread.new do
      AiConnect::Confirmation.execute_confirmed(registry, action, ip: opts[:ip])
    rescue StandardError => e
      ConfirmationStore.add_event(action['id'], 'execution_failed', uid: uid, actor_uid: uid, tool: action['tool'],
                                  client_id: action['client_id'], ip: opts[:ip])
      ConfirmationStore.finish(action['id'], false, { error: 'execution_error', message: e.class.name })
    end
    stored = worker.join(sync_wait) ? worker.value : nil
    return [200, page(uid, opts, notice: tr(loc, :running), notice_kind: 'info')] if stored.nil?

    if stored['status'] == 'executed'
      [200, page(uid, opts, notice: tr(loc, :done_ok), notice_kind: 'ok')]
    else
      err = stored && stored['result'].is_a?(Hash) ? (stored['result']['message'] || stored['result']['error']) : 'error'
      [200, page(uid, opts, notice: tr(loc, :done_fail, error: err.to_s), notice_kind: 'error')]
    end
  end

  def sync_wait
    ENV['RACK_ENV'] == 'test' ? 30 : Float(ENV.fetch('AI_CONNECT_CONFIRM_WAIT', '3'))
  rescue ArgumentError
    3
  end

  def gone(uid, id, opts)
    loc = opts[:locale]
    a = ConfirmationStore.find(id)
    return [404, page(uid, opts, notice: tr(loc, :not_found), notice_kind: 'error')] if a.nil? || a['uid'] != uid

    [409, page(uid, opts, notice: tr(loc, :gone, status: tr(loc, :"st_#{a['status']}")), notice_kind: 'error')]
  end

  def revoke_autonomy(uid, grant_id, opts)
    row = ConfirmationStore.revoke_autonomy(uid, grant_id)
    if row
      ConfirmationStore.add_event(nil, 'autonomy_revoked', uid: uid, actor_uid: uid, tool: row['tool'], client_id: row['client_id'], ip: opts[:ip])
      return page(uid, opts, notice: tr(opts[:locale], :revoked), notice_kind: 'ok')
    end
    page(uid, opts)
  end
end
