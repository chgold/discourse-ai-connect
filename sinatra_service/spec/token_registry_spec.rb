require_relative 'spec_helper'

RSpec.describe 'Token Registry' do
  describe 'DB.register_token + DB.registry_for' do
    it 'inserts a registry row when tokens are saved' do
      tokens = DB.save_tokens('claude', 100, 'read write', source: 'oauth', ip_address: '10.0.0.1')
      reg = DB.registry_for(tokens[:access])
      expect(reg).not_to be_nil
      expect(reg['user_id'].to_i).to eq(100)
      expect(reg['client_id']).to eq('claude')
      expect(reg['scope']).to eq('read write')
      expect(reg['source']).to eq('oauth')
      expect(reg['ip_address']).to eq('10.0.0.1')
      expect(reg['token_prefix']).to eq(tokens[:access][0, 16])
      expect(reg['revoked_at']).to be_nil
      expect(reg['last_used_at']).to be_nil
    end

    it 'records the source as generator for self-service tokens' do
      tokens = DB.save_tokens('ai-agent-default', 42, 'read write', source: 'generator', ip_address: '127.0.0.1')
      reg = DB.registry_for(tokens[:access])
      expect(reg['source']).to eq('generator')
    end
  end

  # ---------------------------------------------------------------------------
  # touch_last_used (v2) — replaces mark_token_used
  # ---------------------------------------------------------------------------

  describe 'DB.touch_last_used' do
    it 'updates last_used_at, last_used_ip, and last_used_ua together' do
      tokens = DB.save_tokens('claude', 7, 'read')
      DB.touch_last_used(tokens[:access], ip: '1.2.3.4', ua: 'ChatGPT/1.0')
      reg = DB.registry_for(tokens[:access])
      expect(reg['last_used_at']).not_to be_nil
      expect(reg['last_used_ip']).to eq('1.2.3.4')
      expect(reg['last_used_ua']).to eq('ChatGPT/1.0')
    end

    it 'accepts nil ip and ua without raising' do
      tokens = DB.save_tokens('claude', 7, 'read')
      expect { DB.touch_last_used(tokens[:access], ip: nil, ua: nil) }.not_to raise_error
    end

    it 'is a no-op when the token has no registry entry' do
      expect { DB.touch_last_used('dsc_unknown_token_xyz', ip: '1.2.3.4', ua: 'test') }.not_to raise_error
    end

    it 'does not update a revoked token' do
      tokens = DB.save_tokens('claude', 7, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(tokens[:access]), revoked_by: 1)
      DB.touch_last_used(tokens[:access], ip: '9.9.9.9', ua: 'evil-bot')
      reg = DB.registry_for(tokens[:access])
      expect(reg['last_used_ip']).to be_nil
    end
  end

  describe 'DB.mark_token_used (backward-compat alias)' do
    it 'updates last_used_at on the registry row' do
      tokens = DB.save_tokens('claude', 7, 'read')
      DB.mark_token_used(tokens[:access])
      reg = DB.registry_for(tokens[:access])
      expect(reg['last_used_at']).not_to be_nil
    end

    it 'is a no-op when the token has no registry entry' do
      expect { DB.mark_token_used('dsc_unknown_token_xyz') }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # AuthMiddleware integration (v2: passes IP + UA)
  # ---------------------------------------------------------------------------

  describe 'AuthMiddleware integration' do
    let(:fake_request) { Struct.new(:env, :ip).new({}, '127.0.0.1') }

    it 'marks last_used_at when a valid bearer is presented' do
      tokens = DB.save_tokens('claude', 21, 'read write')
      fake_request.env['HTTP_AUTHORIZATION'] = "Bearer #{tokens[:access]}"
      AuthMiddleware.require_bearer(fake_request)
      reg = DB.registry_for(tokens[:access])
      expect(reg['last_used_at']).not_to be_nil
    end

    it 'records last_used_ip from HTTP_X_FORWARDED_FOR' do
      tokens = DB.save_tokens('claude', 21, 'read write')
      fake_request.env['HTTP_AUTHORIZATION']      = "Bearer #{tokens[:access]}"
      fake_request.env['HTTP_X_FORWARDED_FOR']    = '5.6.7.8, 10.0.0.1'
      fake_request.env['HTTP_USER_AGENT']         = 'Claude/2.0'
      AuthMiddleware.require_bearer(fake_request)
      reg = DB.registry_for(tokens[:access])
      expect(reg['last_used_ip']).to eq('5.6.7.8')
      expect(reg['last_used_ua']).to eq('Claude/2.0')
    end

    it 'rejects tokens whose registry entry is revoked' do
      tokens = DB.save_tokens('claude', 21, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(tokens[:access]), revoked_by: 1)
      fake_request.env['HTTP_AUTHORIZATION'] = "Bearer #{tokens[:access]}"
      result = AuthMiddleware.require_bearer(fake_request)
      expect(result[:error]).to eq('invalid_token')
    end
  end

  # ---------------------------------------------------------------------------
  # Revoke methods
  # ---------------------------------------------------------------------------

  describe 'DB.revoke_token' do
    it 'sets revoked_at and revoked_by on the registry entry' do
      tokens = DB.save_tokens('claude', 9, 'read')
      DB.revoke_token(tokens[:access], revoked_by: 1)
      reg = DB.registry_for(tokens[:access])
      expect(reg['revoked_at']).not_to be_nil
      expect(reg['revoked_by'].to_i).to eq(1)
    end
  end

  describe 'DB.revoke_token_by_prefix' do
    it 'revokes by prefix and cascades to ai_tokens' do
      tokens = DB.save_tokens('claude', 11, 'read')
      prefix = DB.token_prefix(tokens[:access])
      expect(DB.revoke_token_by_prefix(prefix, revoked_by: 99)).to be true
      reg = DB.registry_for(tokens[:access])
      expect(reg['revoked_at']).not_to be_nil
      expect(reg['revoked_by'].to_i).to eq(99)
      expect(DB.get_token(tokens[:access])).to be_nil
    end

    it 'returns false for an unknown prefix' do
      expect(DB.revoke_token_by_prefix('dsc_nonexistent00', revoked_by: 1)).to be false
    end

    it 'returns false for empty input' do
      expect(DB.revoke_token_by_prefix(nil, revoked_by: 1)).to be false
      expect(DB.revoke_token_by_prefix('', revoked_by: 1)).to be false
    end
  end

  describe 'DB.revoke_by_id' do
    it 'revokes a token by registry row id' do
      tokens = DB.save_tokens('claude', 20, 'read')
      reg = DB.registry_for(tokens[:access])
      id  = reg['id'].to_i
      expect(DB.revoke_by_id(id, revoked_by: 5)).to be true
      updated = DB.registry_for(tokens[:access])
      expect(updated['revoked_at']).not_to be_nil
      expect(updated['revoked_by'].to_i).to eq(5)
    end

    it 'returns false for an unknown id' do
      expect(DB.revoke_by_id(999_999, revoked_by: 1)).to be false
    end
  end

  describe 'DB.revoke_all_for_user' do
    it 'revokes every token for the given user and returns the count' do
      DB.save_tokens('claude',  30, 'read')
      DB.save_tokens('chatgpt', 30, 'read write')
      DB.save_tokens('claude',  99, 'read') # different user — must not be revoked

      count = DB.revoke_all_for_user(30, revoked_by: 1)
      expect(count).to eq(2)

      remaining = DB.list_tokens_for_user(30, filter: 'active')
      expect(remaining).to be_empty

      other = DB.list_tokens_for_user(99, filter: 'active')
      expect(other).not_to be_empty
    end
  end

  describe 'DB.revoke_by_ids' do
    it 'revokes a list of registry ids' do
      t1 = DB.save_tokens('claude', 40, 'read')
      t2 = DB.save_tokens('chatgpt', 40, 'read')
      t3 = DB.save_tokens('gemini', 40, 'read')

      ids = [DB.registry_for(t1[:access])['id'].to_i,
             DB.registry_for(t2[:access])['id'].to_i]

      count = DB.revoke_by_ids(ids, revoked_by: 1)
      expect(count).to eq(2)

      expect(DB.registry_for(t1[:access])['revoked_at']).not_to be_nil
      expect(DB.registry_for(t2[:access])['revoked_at']).not_to be_nil
      expect(DB.registry_for(t3[:access])['revoked_at']).to be_nil
    end

    it 'returns 0 for empty input' do
      expect(DB.revoke_by_ids([], revoked_by: 1)).to eq(0)
      expect(DB.revoke_by_ids(nil, revoked_by: 1)).to eq(0)
    end
  end

  describe 'DB.revoke_unused' do
    it 'revokes tokens with last_used_at IS NULL older than the given days' do
      # Insert token directly so we can backdate issued_at
      old_token  = "dsc_#{SecureRandom.hex(32)}"
      new_token  = "dsc_#{SecureRandom.hex(32)}"
      now = Time.now.to_i
      DB.conn.exec_params(
        "INSERT INTO ai_connect_token_registry (token_prefix, user_id, client_id, scope, issued_at, expires_at, source) VALUES ($1,50,'x','read',NOW() - 40 * INTERVAL '1 day', NOW() + INTERVAL '1 hour','oauth')",
        [old_token[0, 16]]
      )
      DB.conn.exec_params(
        "INSERT INTO ai_connect_token_registry (token_prefix, user_id, client_id, scope, issued_at, expires_at, source) VALUES ($1,50,'x','read', NOW() - 5  * INTERVAL '1 day', NOW() + INTERVAL '1 hour','oauth')",
        [new_token[0, 16]]
      )

      count = DB.revoke_unused(days: 30, revoked_by: 0)
      expect(count).to be >= 1

      old_reg = DB.conn.exec_params("SELECT * FROM ai_connect_token_registry WHERE token_prefix=$1", [old_token[0, 16]]).first
      expect(old_reg['revoked_at']).not_to be_nil

      new_reg = DB.conn.exec_params("SELECT * FROM ai_connect_token_registry WHERE token_prefix=$1", [new_token[0, 16]]).first
      expect(new_reg['revoked_at']).to be_nil
    end
  end

  describe 'DB.revoke_inactive' do
    it 'revokes tokens last used more than days ago' do
      old_token = "dsc_#{SecureRandom.hex(32)}"
      new_token = "dsc_#{SecureRandom.hex(32)}"
      DB.conn.exec_params(
        "INSERT INTO ai_connect_token_registry (token_prefix, user_id, client_id, scope, issued_at, expires_at, last_used_at, source) VALUES ($1,60,'x','read',NOW() - 200 * INTERVAL '1 day', NOW() + INTERVAL '1 hour', NOW() - 200 * INTERVAL '1 day','oauth')",
        [old_token[0, 16]]
      )
      DB.conn.exec_params(
        "INSERT INTO ai_connect_token_registry (token_prefix, user_id, client_id, scope, issued_at, expires_at, last_used_at, source) VALUES ($1,60,'x','read',NOW() - 10 * INTERVAL '1 day', NOW() + INTERVAL '1 hour', NOW() - 10 * INTERVAL '1 day','oauth')",
        [new_token[0, 16]]
      )

      count = DB.revoke_inactive(days: 180, revoked_by: 0)
      expect(count).to be >= 1

      old_reg = DB.conn.exec_params("SELECT * FROM ai_connect_token_registry WHERE token_prefix=$1", [old_token[0, 16]]).first
      expect(old_reg['revoked_at']).not_to be_nil

      new_reg = DB.conn.exec_params("SELECT * FROM ai_connect_token_registry WHERE token_prefix=$1", [new_token[0, 16]]).first
      expect(new_reg['revoked_at']).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Cleanup
  # ---------------------------------------------------------------------------

  describe 'DB.should_run_cleanup? / DB.run_cleanup' do
    it 'should_run_cleanup? returns true when never run' do
      DB.instance_variable_set(:@last_cleanup_at, nil)
      expect(DB.should_run_cleanup?).to be true
    end

    it 'should_run_cleanup? returns false immediately after running' do
      DB.run_cleanup
      expect(DB.should_run_cleanup?).to be false
    end

    it 'run_cleanup returns a hash of counts' do
      result = DB.run_cleanup
      expect(result).to be_a(Hash)
      expect(result).to have_key(:unused_revoked)
      expect(result).to have_key(:inactive_revoked)
      expect(result).to have_key(:expired_revoked)
      expect(result).to have_key(:purged)
    end

    it 'run_cleanup hard-deletes rows revoked long ago (simulated)' do
      # Insert a token with revoked_at set > 365 days ago
      old_prefix = "dsc_#{SecureRandom.hex(7)}"[0, 16]
      DB.conn.exec_params(
        "INSERT INTO ai_connect_token_registry (token_prefix, user_id, client_id, scope, issued_at, expires_at, revoked_at, revoked_by, source) VALUES ($1,70,'x','read',NOW() - 400 * INTERVAL '1 day', NOW() - 400 * INTERVAL '1 day', NOW() - 400 * INTERVAL '1 day',0,'oauth')",
        [old_prefix]
      )
      DB.instance_variable_set(:@last_cleanup_at, nil)
      result = DB.run_cleanup
      expect(result[:purged]).to be >= 1
      expect(DB.conn.exec_params("SELECT id FROM ai_connect_token_registry WHERE token_prefix=$1", [old_prefix]).ntuples).to eq(0)
    end
  end

  # ---------------------------------------------------------------------------
  # cascade_revoke_oauth
  # ---------------------------------------------------------------------------

  describe 'DB.cascade_revoke_oauth' do
    it 'revokes given prefixes and cascades to ai_tokens' do
      t1 = DB.save_tokens('claude', 80, 'read')
      t2 = DB.save_tokens('chatgpt', 80, 'read')
      prefixes = [DB.token_prefix(t1[:access]), DB.token_prefix(t2[:access])]

      count = DB.cascade_revoke_oauth(prefixes, revoked_by: 0)
      expect(count).to eq(2)
      expect(DB.registry_for(t1[:access])['revoked_at']).not_to be_nil
      expect(DB.registry_for(t2[:access])['revoked_at']).not_to be_nil
    end

    it 'returns 0 for empty input' do
      expect(DB.cascade_revoke_oauth([], revoked_by: 0)).to eq(0)
      expect(DB.cascade_revoke_oauth(nil, revoked_by: 0)).to eq(0)
    end

    it 'respects before_time — only revokes tokens issued before the cutoff' do
      t1 = DB.save_tokens('claude', 81, 'read')
      # Set issued_at to 2 days ago via direct update
      DB.conn.exec_params(
        "UPDATE ai_connect_token_registry SET issued_at = NOW() - INTERVAL '2 days' WHERE token_prefix=$1",
        [DB.token_prefix(t1[:access])]
      )
      # Cutoff = 1 day ago → issued_at < cutoff, so should be revoked
      cutoff = Time.now.to_i - 86_400
      count = DB.cascade_revoke_oauth([DB.token_prefix(t1[:access])], before_time: cutoff, revoked_by: 0)
      expect(count).to eq(1)
    end

    it 'skips tokens issued after before_time' do
      t1 = DB.save_tokens('claude', 82, 'read')
      # Token issued NOW → issued_at > cutoff (1 day ago)
      cutoff = Time.now.to_i - 86_400
      count = DB.cascade_revoke_oauth([DB.token_prefix(t1[:access])], before_time: cutoff, revoked_by: 0)
      expect(count).to eq(0)
      expect(DB.registry_for(t1[:access])['revoked_at']).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # List helpers
  # ---------------------------------------------------------------------------

  describe 'DB.list_tokens' do
    it 'lists registered tokens with most recent first' do
      DB.save_tokens('claude', 1, 'read')
      DB.save_tokens('chatgpt', 2, 'read write')
      list = DB.list_tokens
      expect(list.size).to be >= 2
      expect(list.map { |r| r['client_id'] }).to include('claude', 'chatgpt')
    end

    it 'can exclude revoked tokens' do
      tokens = DB.save_tokens('claude', 1, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(tokens[:access]), revoked_by: 0)
      active = DB.list_tokens(include_revoked: false)
      expect(active.map { |r| r['token_prefix'] }).not_to include(DB.token_prefix(tokens[:access]))
    end

    it 'supports filter: unused' do
      used   = DB.save_tokens('claude', 1, 'read')
      unused = DB.save_tokens('chatgpt', 2, 'read')
      DB.touch_last_used(used[:access], ip: '1.2.3.4', ua: 'bot')

      list = DB.list_tokens(filter: 'unused')
      prefixes = list.map { |r| r['token_prefix'] }
      expect(prefixes).to     include(DB.token_prefix(unused[:access]))
      expect(prefixes).not_to include(DB.token_prefix(used[:access]))
    end

    it 'supports filter: revoked' do
      active  = DB.save_tokens('claude', 1, 'read')
      revoked = DB.save_tokens('chatgpt', 2, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(revoked[:access]), revoked_by: 1)

      list = DB.list_tokens(filter: 'revoked')
      prefixes = list.map { |r| r['token_prefix'] }
      expect(prefixes).to     include(DB.token_prefix(revoked[:access]))
      expect(prefixes).not_to include(DB.token_prefix(active[:access]))
    end

    it 'supports filter: active' do
      active  = DB.save_tokens('claude', 1, 'read')
      revoked = DB.save_tokens('chatgpt', 2, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(revoked[:access]), revoked_by: 1)

      list = DB.list_tokens(filter: 'active')
      prefixes = list.map { |r| r['token_prefix'] }
      expect(prefixes).to     include(DB.token_prefix(active[:access]))
      expect(prefixes).not_to include(DB.token_prefix(revoked[:access]))
    end
  end

  describe 'DB.list_tokens_for_user' do
    it 'returns only tokens belonging to the specified user' do
      DB.save_tokens('claude',  200, 'read')
      DB.save_tokens('chatgpt', 200, 'read write')
      DB.save_tokens('claude',  201, 'read') # different user

      list = DB.list_tokens_for_user(200)
      expect(list.size).to eq(2)
      expect(list.map { |r| r['user_id'].to_i }.uniq).to eq([200])
    end

    it 'supports filter: active' do
      active  = DB.save_tokens('claude',  202, 'read')
      revoked = DB.save_tokens('chatgpt', 202, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(revoked[:access]), revoked_by: 1)

      list = DB.list_tokens_for_user(202, filter: 'active')
      prefixes = list.map { |r| r['token_prefix'] }
      expect(prefixes).to     include(DB.token_prefix(active[:access]))
      expect(prefixes).not_to include(DB.token_prefix(revoked[:access]))
    end
  end

  describe 'DB.user_has_active_tokens?' do
    it 'returns true when the user has at least one active token' do
      DB.save_tokens('claude', 300, 'read')
      expect(DB.user_has_active_tokens?(300)).to be true
    end

    it 'returns false when all tokens are revoked' do
      tokens = DB.save_tokens('claude', 301, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(tokens[:access]), revoked_by: 1)
      expect(DB.user_has_active_tokens?(301)).to be false
    end

    it 'returns false for a user with no tokens at all' do
      expect(DB.user_has_active_tokens?(999_999)).to be false
    end
  end

  # ---------------------------------------------------------------------------
  # Admin endpoints
  # ---------------------------------------------------------------------------

  describe 'Admin endpoints' do
    include Rack::Test::Methods

    def app
      DiscourseAiConnect
    end

    let(:admin_tokens)   { DB.save_tokens('claude', 1, 'read write delete') }
    let(:regular_tokens) { DB.save_tokens('claude', 2, 'read write') }

    describe 'GET /api/ai-connect/admin/tokens' do
      it 'returns 401 without bearer' do
        get '/api/ai-connect/admin/tokens'
        expect(last_response.status).to eq(401)
      end

      it 'returns 403 without delete scope' do
        header 'Authorization', "Bearer #{regular_tokens[:access]}"
        get '/api/ai-connect/admin/tokens'
        expect(last_response.status).to eq(403)
      end

      it 'returns token list with delete scope' do
        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        get '/api/ai-connect/admin/tokens'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body['tokens']).to be_an(Array)
        expect(body['tokens']).not_to be_empty
      end

      it 'supports ?filter=active' do
        revoked = DB.save_tokens('chatgpt', 10, 'read')
        DB.revoke_token_by_prefix(DB.token_prefix(revoked[:access]), revoked_by: 1)

        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        get '/api/ai-connect/admin/tokens?filter=active'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        revoked_prefixes = body['tokens'].map { |t| t['token_prefix'] }
        expect(revoked_prefixes).not_to include(DB.token_prefix(revoked[:access]))
      end

      it 'supports ?filter=revoked' do
        revoked = DB.save_tokens('chatgpt', 10, 'read')
        DB.revoke_token_by_prefix(DB.token_prefix(revoked[:access]), revoked_by: 1)

        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        get '/api/ai-connect/admin/tokens?filter=revoked'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        prefixes = body['tokens'].map { |t| t['token_prefix'] }
        expect(prefixes).to include(DB.token_prefix(revoked[:access]))
      end
    end

    describe 'DELETE /api/ai-connect/admin/tokens/:prefix' do
      it 'requires bearer' do
        delete '/api/ai-connect/admin/tokens/abcdef0123456789'
        expect(last_response.status).to eq(401)
      end

      it 'requires delete scope' do
        header 'Authorization', "Bearer #{regular_tokens[:access]}"
        delete '/api/ai-connect/admin/tokens/abcdef0123456789'
        expect(last_response.status).to eq(403)
      end

      it 'returns 404 for unknown prefix' do
        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        delete '/api/ai-connect/admin/tokens/dsc_unknownprefix'
        expect(last_response.status).to eq(404)
      end

      it 'revokes the matching token' do
        victim = DB.save_tokens('chatgpt', 50, 'read')
        prefix = DB.token_prefix(victim[:access])
        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        delete "/api/ai-connect/admin/tokens/#{prefix}"
        expect(last_response.status).to eq(200)
        reg = DB.registry_for(victim[:access])
        expect(reg['revoked_at']).not_to be_nil
        expect(reg['revoked_by'].to_i).to eq(1)
      end
    end

    describe 'POST /api/ai-connect/admin/tokens/bulk-revoke' do
      it 'returns 401 without bearer' do
        post '/api/ai-connect/admin/tokens/bulk-revoke',
             { filter: 'unused' }.to_json,
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(401)
      end

      it 'returns 403 without delete scope' do
        header 'Authorization', "Bearer #{regular_tokens[:access]}"
        post '/api/ai-connect/admin/tokens/bulk-revoke',
             { filter: 'unused' }.to_json,
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(403)
      end

      it 'bulk-revokes unused tokens' do
        unused1 = DB.save_tokens('chatgpt', 60, 'read')
        unused2 = DB.save_tokens('gemini',  61, 'read')
        used    = DB.save_tokens('claude',  62, 'read')
        DB.touch_last_used(used[:access], ip: '1.2.3.4', ua: 'bot')

        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        post '/api/ai-connect/admin/tokens/bulk-revoke',
             { filter: 'unused' }.to_json,
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body['success']).to be true
        expect(body['revoked'].to_i).to be >= 2

        expect(DB.registry_for(unused1[:access])['revoked_at']).not_to be_nil
        expect(DB.registry_for(unused2[:access])['revoked_at']).not_to be_nil
        expect(DB.registry_for(used[:access])['revoked_at']).to     be_nil
      end

      it 'returns 422 for invalid filter' do
        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        post '/api/ai-connect/admin/tokens/bulk-revoke',
             { filter: 'bogus' }.to_json,
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(422)
      end
    end

    describe 'GET /api/ai-connect/admin/users/:uid/tokens' do
      it 'returns tokens for a specific user' do
        DB.save_tokens('claude',  70, 'read')
        DB.save_tokens('chatgpt', 70, 'read write')
        DB.save_tokens('gemini',  71, 'read') # different user

        header 'Authorization', "Bearer #{admin_tokens[:access]}"
        get '/api/ai-connect/admin/users/70/tokens'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body['tokens'].size).to eq(2)
        expect(body['tokens'].map { |t| t['user_id'].to_i }.uniq).to eq([70])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # User endpoints
  # ---------------------------------------------------------------------------

  describe 'User token endpoints' do
    include Rack::Test::Methods

    def app
      DiscourseAiConnect
    end

    describe 'GET /api/ai-connect/tokens' do
      it 'returns 401 without X-Discourse-Uid' do
        get '/api/ai-connect/tokens'
        expect(last_response.status).to eq(401)
      end

      it 'returns the user\'s tokens' do
        DB.save_tokens('claude',  400, 'read')
        DB.save_tokens('chatgpt', 400, 'read write')
        DB.save_tokens('gemini',  401, 'read') # different user

        header 'X-Discourse-Uid', '400'
        get '/api/ai-connect/tokens'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body['tokens'].size).to eq(2)
      end

      it 'supports ?filter=active' do
        active  = DB.save_tokens('claude',  402, 'read')
        revoked = DB.save_tokens('chatgpt', 402, 'read')
        DB.revoke_token_by_prefix(DB.token_prefix(revoked[:access]), revoked_by: 1)

        header 'X-Discourse-Uid', '402'
        get '/api/ai-connect/tokens?filter=active'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        prefixes = body['tokens'].map { |t| t['token_prefix'] }
        expect(prefixes).to     include(DB.token_prefix(active[:access]))
        expect(prefixes).not_to include(DB.token_prefix(revoked[:access]))
      end
    end

    describe 'DELETE /api/ai-connect/tokens/:prefix' do
      it 'returns 401 without X-Discourse-Uid' do
        delete '/api/ai-connect/tokens/someprefixhere'
        expect(last_response.status).to eq(401)
      end

      it 'returns 404 when the prefix does not belong to the user' do
        other = DB.save_tokens('claude', 500, 'read')
        header 'X-Discourse-Uid', '501' # different user
        delete "/api/ai-connect/tokens/#{DB.token_prefix(other[:access])}"
        expect(last_response.status).to eq(404)
      end

      it 'revokes the user\'s own token' do
        tokens = DB.save_tokens('claude', 510, 'read')
        prefix = DB.token_prefix(tokens[:access])
        header 'X-Discourse-Uid', '510'
        delete "/api/ai-connect/tokens/#{prefix}"
        expect(last_response.status).to eq(200)
        expect(DB.registry_for(tokens[:access])['revoked_at']).not_to be_nil
      end
    end

    describe 'POST /api/ai-connect/tokens/bulk-revoke' do
      it 'returns 401 without X-Discourse-Uid' do
        post '/api/ai-connect/tokens/bulk-revoke',
             { filter: 'unused' }.to_json,
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(401)
      end

      it 'bulk-revokes the user\'s own tokens' do
        t1 = DB.save_tokens('claude',  520, 'read')
        t2 = DB.save_tokens('chatgpt', 520, 'read write')

        header 'X-Discourse-Uid', '520'
        post '/api/ai-connect/tokens/bulk-revoke',
             { filter: 'all' }.to_json,
             'CONTENT_TYPE' => 'application/json'
        expect(last_response.status).to eq(200)
        body = JSON.parse(last_response.body)
        expect(body['success']).to be true
        expect(body['revoked'].to_i).to eq(2)

        expect(DB.registry_for(t1[:access])['revoked_at']).not_to be_nil
        expect(DB.registry_for(t2[:access])['revoked_at']).not_to be_nil
      end
    end
  end
end
