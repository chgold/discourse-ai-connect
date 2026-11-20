# frozen_string_literal: true

require 'json'
require 'digest'
require 'cgi'
require 'time'
require_relative '../services/confirmation_store'

# Confirmation — the user-confirm-v1 flow for Discourse (1.2.7).
# Contract: /workspace/.specs/CONFIRMATION-FLOW-SPEC.md (Servio §6.5 202 pending_confirmation).
#
# A tool that declares `confirmation:` (destructive / risky moderation) is NOT executed when an
# agent calls it. The gate stores a pending action bound to user + tool + SHA-256 of the canonical
# arguments + client, and answers 202 with a summary for the user and a confirm_url. Only the user,
# on a page inside Discourse (logged-in session + CSRF; requests with an API key / token are
# refused), can confirm or reject. Confirming runs the tool ONCE, as that user, in confirmed mode.
# Re-submitting with confirmation_id never executes — it only reports.
module AiConnect
  module Confirmation
    FLOW = 'user-confirm-v1'
    CONTROL_KEYS = %w[confirmation_id confirmation_new].freeze

    TEXT = {
      'en' => {
        nothing_done: 'Nothing has been done yet. Open the link to confirm or reject it.',
        generic: 'Run the action "%<tool>s"',
        agent_message: 'Not executed. This action needs the confirmation of the user. Show the user the summary ' \
                       'and confirm_url, say that nothing has happened yet, and do not repeat the call on your own. ' \
                       'After the user says they confirmed, send the same call again with confirmation_id, or GET status_url.',
        already: 'Already executed - the user confirmed this a moment ago; it was not run again. ' \
                 'Send confirmation_new=true only if the user asked to do it again.'
      },
      'he' => {
        nothing_done: 'עדיין לא בוצע כלום. פתחו את הקישור כדי לאשר או לדחות.',
        generic: 'ביצוע הפעולה "%<tool>s"'
      }
    }.freeze

    module_function

    def t(locale, key, **vars)
      str = (TEXT[lang(locale)] || {})[key] || TEXT['en'][key]
      vars.empty? ? str : format(str, **vars)
    end

    def lang(locale)
      l = locale.to_s.downcase.tr('-', '_').split('_').first
      TEXT.key?(l) ? l : 'en'
    end

    def ttl
      Integer(ENV.fetch('AI_CONNECT_CONFIRMATION_TTL', '900')).clamp(60, 86_400)
    rescue ArgumentError
      900
    end

    def duplicate_window
      Integer(ENV.fetch('AI_CONNECT_CONFIRMATION_DUPLICATE_WINDOW', '120')).clamp(0, 3600)
    rescue ArgumentError
      120
    end

    # Site kill switch for autonomy grants (AI_CONNECT_CONFIRMATION_AUTONOMY=0 turns them off).
    def autonomy_allowed?
      ENV.fetch('AI_CONNECT_CONFIRMATION_AUTONOMY', '1') != '0'
    end

    def base_url
      ENV.fetch('DISCOURSE_AI_CONNECT_URL', 'http://localhost:8086').sub(%r{/+\z}, '')
    end

    def confirm_url(id)
      "#{base_url}/ai-connect-plugin/ai-actions?confirmation_id=#{CGI.escape(id)}"
    end

    def status_url(id)
      "#{base_url}/api/ai-connect/v1/confirmations/#{CGI.escape(id)}"
    end

    # ── declaration helpers ──
    def declared?(tool)
      !tool[:confirmation].nil? && tool[:confirmation] != false
    end

    def config(tool)
      c = tool[:confirmation]
      c.is_a?(Hash) ? c : { required: true }
    end

    def mode(tool)
      return nil unless declared?(tool)

      config(tool).fetch(:required, true).respond_to?(:call) ? 'conditional' : 'required'
    end

    def risk(tool)
      config(tool)[:risk] || 'destructive'
    end

    def required?(tool, args)
      return false unless declared?(tool)
      return false if tool[:required_scope].to_s == 'read'

      req = config(tool).fetch(:required, true)
      req.respond_to?(:call) ? (req.call(args) ? true : false) : (req ? true : false)
    end

    def canonical(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), h| h[k.to_s] = canonical(v) unless CONTROL_KEYS.include?(k.to_s) }
             .sort.to_h
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end

    def args_hash(tool_name, args)
      Digest::SHA256.hexdigest("#{tool_name}\n#{JSON.generate(canonical(args || {}))}")
    end

    def raw_value(raw, key)
      return nil unless raw.is_a?(Hash)

      raw.key?(key) ? raw[key] : raw[key.to_sym]
    end

    def truthy?(v)
      v == true || v.to_s == 'true' || v.to_s == '1'
    end

    def client_key(ctx)
      "rest:#{ctx[:client_id].to_s.empty? ? 'unknown' : ctx[:client_id]}"
    end

    # ── the gate (called by ModuleBase#execute_tool after scope + validation) ──
    # Returns nil when the tool may run now (no confirmation needed / confirmed / autonomous),
    # otherwise the result to send back (202 envelope, stored result, or an error).
    def gate(mod, tool, args, raw, ctx)
      return nil unless required?(tool, args)

      name = tool[:name]
      hash = args_hash(name, args)

      if (cx = ctx[:confirmed_execution])
        return nil if cx[:tool] == name && cx[:args_hash] == hash

        return { error: 'confirmation_mismatch', message: 'Confirmed mode admits only the confirmed tool and arguments' }
      end

      uid = ctx[:uid].to_i
      return { error: 'confirmation_unavailable', message: 'This action needs a signed-in user to confirm it' } unless uid.positive?

      ConfirmationStore.sweep!
      ckey = client_key(ctx)

      if (cid = raw_value(raw, 'confirmation_id')) && !cid.to_s.empty?
        return resubmission(cid.to_s, uid, name, hash, ctx)
      end

      if autonomy_allowed? && ConfirmationStore.autonomy?(uid, name, ctx[:client_id])
        ConfirmationStore.add_event(nil, 'autonomous_execute', uid: uid, tool: name, client_id: ctx[:client_id], ip: ctx[:ip])
        ctx[:confirmation] = { mode: 'autonomous' }
        return nil
      end

      unless truthy?(raw_value(raw, 'confirmation_new')) || duplicate_window.zero?
        done = ConfirmationStore.find_recent_executed(uid, name, hash, ckey, recent: duplicate_window, uncollected: ttl)
        if done
          ConfirmationStore.mark_delivered(done['id'])
          ConfirmationStore.add_event(done['id'], 'duplicate_blocked', uid: uid, tool: name, client_id: ctx[:client_id], ip: ctx[:ip])
          return stored_result(done, already_executed: true)
        end
      end

      if (pending = ConfirmationStore.find_pending(uid, name, hash, ckey))
        ConfirmationStore.add_event(pending['id'], 'reused', uid: uid, tool: name, client_id: ctx[:client_id], ip: ctx[:ip])
        return envelope(pending, reused: true)
      end

      preview = build_preview(mod, tool, args, ctx)
      return preview if preview.is_a?(Hash) && preview[:error]
      if defined?(DiscourseApi) && DiscourseApi.upstream_failure
        return { error: 'upstream_error', message: "Discourse did not answer correctly (#{DiscourseApi.upstream_failure}); try again later" }
      end

      locale = resolve_locale(ctx)
      text = build_text(mod, tool, args, preview, locale)
      action = ConfirmationStore.create(
        uid: uid, tool: name, args: canonical(args), args_hash: hash, client_key: ckey, client_id: ctx[:client_id],
        scope: ctx[:scope].to_s, token_prefix: ctx[:token_prefix], risk: risk(tool), summary: text[:summary],
        details: text[:details], preview: preview, locale: lang(locale), ttl: ttl
      )
      ConfirmationStore.add_event(action['id'], 'requested', uid: uid, tool: name, client_id: ctx[:client_id], ip: ctx[:ip])
      envelope(action, reused: false)
    end

    def resubmission(cid, uid, name, hash, ctx)
      action = ConfirmationStore.find(cid)
      return { error: 'confirmation_not_found', message: 'Unknown confirmation_id' } if action.nil? || action['uid'] != uid

      if action['tool'] != name || action['args_hash'] != hash
        ConfirmationStore.add_event(cid, 'mismatch', uid: uid, tool: name, client_id: ctx[:client_id], ip: ctx[:ip])
        return { error: 'confirmation_mismatch', message: 'confirmation_id belongs to another tool or other arguments' }
      end

      case action['status']
      when 'pending', 'executing' then envelope(action, reused: true)
      when 'executed', 'failed'
        ConfirmationStore.mark_delivered(cid)
        ConfirmationStore.add_event(cid, 'replay_blocked', uid: uid, tool: name, client_id: ctx[:client_id], ip: ctx[:ip])
        stored_result(action, already_executed: false)
      when 'rejected' then { error: 'confirmation_rejected', message: 'The user rejected this action. Do not retry it.', confirmation_id: cid }
      else { error: 'confirmation_expired', message: 'The confirmation request expired. Ask the user before starting it again.', confirmation_id: cid }
      end
    end

    def build_preview(mod, tool, args, ctx)
      p = config(tool)[:preview]
      out = case p
            when Symbol, String then mod.send(p, args, ctx)
            when Proc then p.call(args, ctx)
            else args
            end
      out.is_a?(Hash) ? out : { value: out }
    rescue StandardError => e
      { error: 'preview_failed', message: "Could not prepare the preview (#{e.class})" }
    end

    def build_text(mod, tool, args, preview, locale)
      short = tool[:short_name]
      text = mod.respond_to?(:confirmation_text) ? mod.confirmation_text(short, args, preview, locale) : nil
      text = nil unless text.is_a?(Hash)
      summary = text && text[:summary]
      summary = preview[:summary] if blank?(summary) && preview.is_a?(Hash)
      summary = fill_template(config(tool)[:summary], args, preview) if blank?(summary)
      summary = preview[:what] if blank?(summary) && preview.is_a?(Hash)
      summary = t(locale, :generic, tool: tool[:name]) if blank?(summary)
      details = Array((text && text[:details]) || (preview.is_a?(Hash) && preview[:details]) || []).map { |d| clean(d) }.reject(&:empty?)
      { summary: clean(summary)[0, 255], details: details.first(10) }
    end

    def fill_template(tpl, args, preview)
      return nil if blank?(tpl)

      vals = {}
      (preview.is_a?(Hash) ? preview : {}).each { |k, v| vals[k.to_s] = v if v.is_a?(String) || v.is_a?(Numeric) }
      (args || {}).each { |k, v| vals[k.to_s] = v }
      tpl.to_s.gsub(/\{(\w+)\}/) { vals.key?(Regexp.last_match(1)) ? vals[Regexp.last_match(1)].to_s : '' }
    end

    def clean(s)
      CGI.unescapeHTML(s.to_s.gsub(/<[^>]*>/, ' ')).gsub(/\s+/, ' ').strip
    end

    def blank?(s)
      s.nil? || s.to_s.strip.empty?
    end

    # The user's Discourse locale (their own preference, else the site default), looked up as the
    # acting user. A failed lookup never fails the call.
    def resolve_locale(ctx)
      return ctx[:locale].to_s unless blank?(ctx[:locale])
      return 'en' unless defined?(DiscourseApi) && DiscourseApi.acting_username

      before = DiscourseApi.upstream_failure
      loc = nil
      begin
        u = DiscourseApi.get("/u/#{CGI.escape(DiscourseApi.acting_username.to_s)}.json")
        loc = u.dig('user', 'locale') if u.is_a?(Hash)
        if blank?(loc)
          site = DiscourseApi.get('/site/basic-info.json')
          loc = site['locale'] if site.is_a?(Hash)
        end
      rescue StandardError
        loc = nil
      ensure
        DiscourseApi.reset_upstream_failure! if before.nil? && DiscourseApi.upstream_failure
      end
      blank?(loc) ? 'en' : loc.to_s
    end

    def iso(ts)
      ts ? Time.at(ts.to_i).utc.iso8601 : nil
    end

    def envelope(action, reused:)
      loc = action['locale']
      body = {
        success: false, status: 'pending_confirmation', code: 'confirmation_required',
        message: t('en', :agent_message),
        confirmation_id: action['id'], confirm_url: confirm_url(action['id']), status_url: status_url(action['id']),
        expires_at: iso(action['expires_at']), expires_in: [action['expires_at'].to_i - Time.now.to_i, 0].max,
        tool: action['tool'], risk: action['risk'], summary: action['summary'],
        user_message: "#{action['summary']}. #{t(loc, :nothing_done)}".sub('.. ', '. '),
        preview: (action['preview'] || {}).merge('details' => action['details']), flow: FLOW, reused: reused
      }
      { error: 'confirmation_required', confirmation_envelope: body.merge(data: body.dup) }
    end

    def stored_result(action, already_executed:)
      res = action['result'].is_a?(Hash) ? action['result'] : { 'value' => action['result'] }
      out = res.transform_keys(&:to_sym)
      out[:confirmation] = { id: action['id'], status: action['status'], executed_at: iso(action['executed_at']),
                             already_executed: already_executed }
      out[:message] = t('en', :already) if already_executed
      out
    end

    def status_payload(action)
      out = { confirmation_id: action['id'], status: action['status'], tool: action['tool'], risk: action['risk'],
              summary: action['summary'], created_at: iso(action['created_at']), expires_at: iso(action['expires_at']),
              decided_at: iso(action['decided_at']), executed_at: iso(action['executed_at']) }
      out[:result] = action['result'] if %w[executed failed].include?(action['status'])
      out
    end

    # Runs a confirmed action once, as its user. Blocked users, revoked tokens and lost Discourse
    # permissions are refused (the tool re-runs its own checks under the user's Guardian).
    def execute_confirmed(registry, action, ip: nil)
      uid = action['uid']
      failure = nil
      failure = { error: 'user_blocked', message: 'User is blocked from API access' } if DB.user_blocked?(uid)
      failure ||= { error: 'token_revoked', message: 'The connection that asked for this action was revoked' } if token_revoked?(action['token_prefix'])
      owner = failure ? nil : DiscourseUsers.resolve(uid)
      failure ||= { error: 'user_not_permitted', message: 'Token owner could not be resolved to an active Discourse user' } unless owner

      result = failure || DiscourseApi.as_user(owner[:username]) do
        ctx = { uid: uid, scope: action['scope'], client_id: action['client_id'], ip: ip,
                confirmed_execution: { tool: action['tool'], args_hash: action['args_hash'] },
                confirmation: { mode: 'confirmed', id: action['id'] } }
        registry.execute(action['tool'], action['args'], ctx)
      end
      ok = !(result.is_a?(Hash) && result[:error])
      stored = ConfirmationStore.finish(action['id'], ok, result)
      ConfirmationStore.add_event(action['id'], ok ? 'executed' : 'execution_failed', uid: uid, actor_uid: uid,
                                  tool: action['tool'], client_id: action['client_id'], ip: ip)
      stored
    end

    def token_revoked?(prefix)
      return false if blank?(prefix)

      row = DB.conn.exec_params('SELECT revoked_at FROM ai_connect_token_registry WHERE token_prefix=$1', [prefix]).first
      row && !row['revoked_at'].nil?
    rescue StandardError
      true
    end

    # Manifest: top-level block (only when at least one tool declares confirmation).
    def manifest_block(tools)
      names = tools.select { |t| t[:confirmation] }.map { |t| t[:name] }
      return nil if names.empty?

      {
        flow: FLOW, pending_status_code: 202, error_code: 'confirmation_required',
        status_url_template: "#{base_url}/api/ai-connect/v1/confirmations/{confirmation_id}",
        confirmed_by: 'user', autonomy: autonomy_allowed?, tools: names
      }
    end

    INSTRUCTIONS = 'Some tools change or remove content or punish a user. They are marked "confirmation" in this ' \
                   'manifest. Calling one does NOT execute it: you get HTTP 202 with status=pending_confirmation, a ' \
                   'summary and confirm_url. Show the user the summary and the link, say nothing has happened yet, and ' \
                   'never repeat the call on your own. Only the user can confirm, signed in to the forum. After they ' \
                   'confirm, send the same call with confirmation_id (or GET status_url) to read the result.'
  end
end
