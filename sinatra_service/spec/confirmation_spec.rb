require_relative 'spec_helper'

# user-confirm-v1 (1.2.7): a tool that declares `confirmation:` never runs on the agent's call.
# Contract: .specs/CONFIRMATION-FLOW-SPEC.md. Stub users: 1 admin · 2 alice · 3 bob (moderator).
module ConfirmSpecSupport
  class DangerModule < AiConnect::ModuleBase
    class << self
      attr_accessor :runs
    end
    self.runs = []

    def module_name
      'qa'
    end

    def register_tools
      register_tool :wipeThing, {
        description: 'Delete a thing',
        input_schema: { type: 'object', required: ['thing_id'], properties: { thing_id: { type: 'integer' } } },
        required_scope: 'write',
        validation_schema: { required: { thing_id: :integer }, optional: {} },
        confirmation: { required: true, risk: 'destructive', summary: 'Delete thing #{thing_id}', preview: :preview_wipe }
      }
      register_tool :maybeWipe, {
        description: 'Delete only when hard=true',
        input_schema: { type: 'object', required: ['thing_id'], properties: { thing_id: { type: 'integer' }, hard: { type: 'boolean' } } },
        required_scope: 'write',
        validation_schema: { required: { thing_id: :integer }, optional: { hard: :boolean } },
        confirmation: { required: ->(args) { args[:hard] == true || args['hard'] == true }, risk: 'destructive' }
      }
    end

    def preview_wipe(args, _ctx)
      return { error: 'not_found', message: 'No such thing' } if args[:thing_id].to_i == 404 || args['thing_id'].to_i == 404

      { thing_id: args[:thing_id] || args['thing_id'], what: 'remove it' }
    end

    def confirmation_text(short, args, _preview, locale)
      id = args[:thing_id] || args['thing_id']
      return { summary: "מחיקת דבר מספר #{id}", details: ['הדבר יימחק'] } if locale.to_s.start_with?('he')

      { summary: "Delete thing number #{id}", details: ["Thing #{id} is removed"] } if short == 'wipeThing'
    end

    def execute_wipeThing(params, ctx)
      self.class.runs << [params[:thing_id], ctx[:confirmation]]
      { wiped: params[:thing_id] }
    end

    def execute_maybeWipe(params, _ctx)
      self.class.runs << [params[:thing_id], :maybe]
      { wiped: params[:thing_id], hard: params[:hard] == true }
    end
  end
end

RSpec.describe 'user-confirm-v1 confirmation flow' do
  before(:all) do
    DiscourseAiConnect.settings.module_registry.register(ConfirmSpecSupport::DangerModule.new, key: 'qa-danger')
  end

  after(:all) do
    DiscourseAiConnect.settings.module_registry.instance_variable_get(:@modules).reject! { |e| e[:key] == 'qa-danger' }
  end

  before(:each) do
    ConfirmationStore.init_schema
    DB.conn.exec('TRUNCATE ai_connect_pending_actions, ai_connect_confirmation_events, ai_connect_autonomy_grants RESTART IDENTITY')
    DB.conn.exec('TRUNCATE ai_blocked_users') rescue nil
    ConfirmSpecSupport::DangerModule.runs = []
  end

  let(:runs) { ConfirmSpecSupport::DangerModule.runs }
  let(:token) { DB.save_tokens('claude', 2, 'read write')[:access] }

  def call(name, body, tok = token)
    header 'Authorization', "Bearer #{tok}"
    header 'Content-Type', 'application/json'
    post "/api/ai-connect/v1/tools/#{name}", body.to_json
    JSON.parse(last_response.body)
  end

  def decide(id, decision, uid: 2, autonomy: nil)
    header 'Authorization', nil
    header 'X-Discourse-Uid', uid.to_s
    header 'Content-Type', 'application/json'
    post '/api/ai-connect/confirmations/decide', { confirmation_id: id, decision: decision, autonomy: autonomy }.compact.to_json
    header 'X-Discourse-Uid', nil
    last_response
  end

  it 'answers 202 with a user summary and runs nothing' do
    j = call('qa.wipeThing', { thing_id: 7 })
    expect(last_response.status).to eq(202)
    expect(j['status']).to eq('pending_confirmation')
    expect(j['code']).to eq('confirmation_required')
    expect(j['confirmation_id']).to match(/\Aconf_[0-9a-f]{32}\z/)
    expect(j['confirm_url']).to include('/ai-connect-plugin/ai-actions?confirmation_id=')
    expect(j['status_url']).to include("/api/ai-connect/v1/confirmations/#{j['confirmation_id']}")
    expect(j['summary']).to eq('Delete thing number 7')
    expect(j['summary']).not_to match(/Not executed|confirmation_id/)
    expect(j['user_message']).to start_with('Delete thing number 7')
    expect(j['preview']['details']).to eq(['Thing 7 is removed'])
    expect(j['flow']).to eq('user-confirm-v1')
    expect(j['data']['confirmation_id']).to eq(j['confirmation_id'])
    expect(runs).to be_empty
  end

  it 'reuses the same pending action for the same call (no duplicates)' do
    a = call('qa.wipeThing', { thing_id: 7 })
    b = call('qa.wipeThing', { thing_id: 7 })
    expect(b['confirmation_id']).to eq(a['confirmation_id'])
    expect(b['reused']).to be true
    c = call('qa.wipeThing', { thing_id: 8 })
    expect(c['confirmation_id']).not_to eq(a['confirmation_id'])
  end

  it 'refuses an invalid call at the preview step and queues nothing' do
    j = call('qa.wipeThing', { thing_id: 404 })
    expect(last_response.status).to eq(404)
    expect(j['data']['error']).to eq('not_found')
    expect(ConfirmationStore.pending_for_user(2)).to be_empty
  end

  it 're-submitting with confirmation_id while pending only reports' do
    a = call('qa.wipeThing', { thing_id: 7 })
    b = call('qa.wipeThing', { thing_id: 7, confirmation_id: a['confirmation_id'] })
    expect(last_response.status).to eq(202)
    expect(b['confirmation_id']).to eq(a['confirmation_id'])
    expect(runs).to be_empty
  end

  it 'the user confirms once; replay with confirmation_id returns the stored result, never runs again' do
    a = call('qa.wipeThing', { thing_id: 7 })
    res = decide(a['confirmation_id'], 'confirm')
    expect(res.status).to eq(200)
    expect(res.body).to include('Done. The action ran once')
    expect(runs.size).to eq(1)
    expect(runs.first[1]).to eq(mode: 'confirmed', id: a['confirmation_id'])

    again = decide(a['confirmation_id'], 'confirm')
    expect(again.status).to eq(409)
    expect(runs.size).to eq(1)

    r = call('qa.wipeThing', { thing_id: 7, confirmation_id: a['confirmation_id'] })
    expect(last_response.status).to eq(200)
    expect(r['data']['wiped']).to eq(7)
    expect(r['data']['confirmation']['status']).to eq('executed')
    expect(runs.size).to eq(1)
  end

  it 'a repeat of a just-confirmed call returns the stored result (already_executed), confirmation_new asks again' do
    a = call('qa.wipeThing', { thing_id: 7 })
    decide(a['confirmation_id'], 'confirm')
    dup = call('qa.wipeThing', { thing_id: 7 })
    expect(last_response.status).to eq(200)
    expect(dup['data']['confirmation']['already_executed']).to be true
    expect(dup['data']['message']).to start_with('Already executed')
    expect(runs.size).to eq(1)

    fresh = call('qa.wipeThing', { thing_id: 7, confirmation_new: true })
    expect(last_response.status).to eq(202)
    expect(fresh['confirmation_id']).not_to eq(a['confirmation_id'])
  end

  it 'rejected → 410, expired → 410, other arguments → 409, other user → 404' do
    a = call('qa.wipeThing', { thing_id: 7 })
    expect(decide(a['confirmation_id'], 'reject').body).to include('Rejected')
    call('qa.wipeThing', { thing_id: 7, confirmation_id: a['confirmation_id'] })
    expect(last_response.status).to eq(410)

    b = call('qa.wipeThing', { thing_id: 9 })
    call('qa.wipeThing', { thing_id: 10, confirmation_id: b['confirmation_id'] })
    expect(last_response.status).to eq(409)

    other = DB.save_tokens('claude', 3, 'read write')[:access]
    call('qa.wipeThing', { thing_id: 9, confirmation_id: b['confirmation_id'] }, other)
    expect(last_response.status).to eq(404)
    expect(decide(b['confirmation_id'], 'confirm', uid: 3).status).to eq(404)

    DB.conn.exec_params('UPDATE ai_connect_pending_actions SET expires_at=1 WHERE id=$1', [b['confirmation_id']])
    call('qa.wipeThing', { thing_id: 9, confirmation_id: b['confirmation_id'] })
    expect(last_response.status).to eq(410)
    expect(JSON.parse(last_response.body)['data']['error']).to eq('confirmation_expired')
    expect(runs).to be_empty
  end

  it 'the decide route refuses a request that did not come through the Discourse proxy' do
    a = call('qa.wipeThing', { thing_id: 7 })
    header PROXY_SECRET_HEADER_NAME, nil
    decide(a['confirmation_id'], 'confirm')
    expect(last_response.status).to eq(403)
    expect(runs).to be_empty
  end

  it 'a Bearer token cannot reach the decide route as the user' do
    a = call('qa.wipeThing', { thing_id: 7 })
    header PROXY_SECRET_HEADER_NAME, nil
    header 'Authorization', "Bearer #{token}"
    header 'Content-Type', 'application/json'
    post '/api/ai-connect/confirmations/decide', { confirmation_id: a['confirmation_id'], decision: 'confirm' }.to_json
    expect(last_response.status).to eq(403)
    expect(runs).to be_empty
  end

  it 'autonomy grant: per user + tool + client, revocable' do
    a = call('qa.wipeThing', { thing_id: 7 })
    decide(a['confirmation_id'], 'confirm', autonomy: '1')
    grants = ConfirmationStore.autonomy_for_user(2)
    expect(grants.map { |g| [g['tool'], g['client_id']] }).to eq([['qa.wipeThing', 'claude']])

    call('qa.wipeThing', { thing_id: 11 })
    expect(last_response.status).to eq(200)
    expect(runs.last).to eq([11, { mode: 'autonomous' }])

    gpt = DB.save_tokens('chatgpt', 2, 'read write')[:access]
    call('qa.wipeThing', { thing_id: 12 }, gpt)
    expect(last_response.status).to eq(202)

    header 'X-Discourse-Uid', '2'
    header 'Content-Type', 'application/json'
    post '/api/ai-connect/confirmations/autonomy/revoke', { grant_id: grants.first['id'] }.to_json
    expect(last_response.body).to include('Removed')
    header 'X-Discourse-Uid', nil
    call('qa.wipeThing', { thing_id: 13 })
    expect(last_response.status).to eq(202)
  end

  it 'site kill switch turns autonomy off' do
    a = call('qa.wipeThing', { thing_id: 7 })
    decide(a['confirmation_id'], 'confirm', autonomy: '1')
    ENV['AI_CONNECT_CONFIRMATION_AUTONOMY'] = '0'
    call('qa.wipeThing', { thing_id: 21 })
    expect(last_response.status).to eq(202)
  ensure
    ENV.delete('AI_CONNECT_CONFIRMATION_AUTONOMY')
  end

  it 'conditional confirmation: only the risky variant is gated' do
    call('qa.maybeWipe', { thing_id: 1 })
    expect(last_response.status).to eq(200)
    call('qa.maybeWipe', { thing_id: 2, hard: true })
    expect(last_response.status).to eq(202)
    expect(runs.size).to eq(1)
  end

  it 'a read-only token never reaches the gate' do
    ro = DB.save_tokens('claude', 2, 'read')[:access]
    call('qa.wipeThing', { thing_id: 7 }, ro)
    expect(last_response.status).to eq(403)
    expect(ConfirmationStore.pending_for_user(2)).to be_empty
  end

  it 'a user blocked after asking cannot have the action run' do
    a = call('qa.wipeThing', { thing_id: 7 })
    DB.block_user(2, 1)
    decide(a['confirmation_id'], 'confirm')
    expect(last_response.body).to include('Discourse refused it')
    expect(runs).to be_empty
    expect(ConfirmationStore.find(a['confirmation_id'])['status']).to eq('failed')
  end

  it 'status_url reports to the same user only' do
    a = call('qa.wipeThing', { thing_id: 7 })
    header 'Authorization', "Bearer #{token}"
    get "/api/ai-connect/v1/confirmations/#{a['confirmation_id']}"
    j = JSON.parse(last_response.body)
    expect(j['data']['status']).to eq('pending')
    expect(j['data']['summary']).to eq('Delete thing number 7')
    other = DB.save_tokens('claude', 3, 'read write')[:access]
    header 'Authorization', "Bearer #{other}"
    get "/api/ai-connect/v1/confirmations/#{a['confirmation_id']}"
    expect(last_response.status).to eq(404)
  end

  it 'the page lists the waiting action with its summary, in Hebrew when the user locale is he' do
    call('qa.wipeThing', { thing_id: 7 })
    header 'Authorization', nil
    header 'X-Discourse-Uid', '2'
    header 'X-AI-Connect-Locale', 'he'
    header 'X-AI-Connect-CSRF', 'csrf-token-x'
    get '/api/ai-connect/confirmations/page'
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('Delete thing number 7')
    expect(last_response.body).to include('פעולות AI שמחכות לאישור שלך')
    expect(last_response.body).to include('value="csrf-token-x"')
    expect(last_response.body).to include('dir="rtl"')
  end

  it 'the manifest advertises the flow and marks the tools' do
    get '/api/ai-connect/manifest'
    m = JSON.parse(last_response.body)
    expect(m['capabilities']['confirmation']).to be true
    expect(m['confirmation']['flow']).to eq('user-confirm-v1')
    expect(m['confirmation']['tools']).to include('qa.wipeThing', 'qa.maybeWipe')
    tool = m['tools'].find { |t| t['name'] == 'qa.wipeThing' }
    expect(tool['confirmation']).to eq('required')
    expect(tool['risk']).to eq('destructive')
    expect(m['tools'].find { |t| t['name'] == 'qa.maybeWipe' }['confirmation']).to eq('conditional')
    expect(m['instructions']).to include('pending_confirmation')
  end
end
