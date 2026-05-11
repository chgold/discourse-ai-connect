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

  describe 'DB.mark_token_used' do
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

  describe 'AuthMiddleware integration' do
    let(:fake_request) { Struct.new(:env).new({}) }

    it 'marks last_used_at when a valid bearer is presented' do
      tokens = DB.save_tokens('claude', 21, 'read write')
      fake_request.env['HTTP_AUTHORIZATION'] = "Bearer #{tokens[:access]}"
      AuthMiddleware.require_bearer(fake_request)
      reg = DB.registry_for(tokens[:access])
      expect(reg['last_used_at']).not_to be_nil
    end

    it 'rejects tokens whose registry entry is revoked' do
      tokens = DB.save_tokens('claude', 21, 'read')
      DB.revoke_token_by_prefix(DB.token_prefix(tokens[:access]), revoked_by: 1)
      fake_request.env['HTTP_AUTHORIZATION'] = "Bearer #{tokens[:access]}"
      result = AuthMiddleware.require_bearer(fake_request)
      expect(result[:error]).to eq('invalid_token')
    end
  end

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
  end

  describe 'Admin endpoints' do
    include Rack::Test::Methods

    def app
      DiscourseAiConnect
    end

    let(:admin_tokens) { DB.save_tokens('claude', 1, 'read write delete') }
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
  end
end
