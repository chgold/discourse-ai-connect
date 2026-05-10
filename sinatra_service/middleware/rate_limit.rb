module RateLimitMiddleware
  def self.check_tool(token)
    per_min  = ENV.fetch('RATE_LIMIT_TOOL_PER_MINUTE', '50').to_i
    per_hour = ENV.fetch('RATE_LIMIT_TOOL_PER_HOUR', '1000').to_i
    DB.check_rate_limit(token, per_minute: per_min, per_hour: per_hour)
  end

  def self.check_oauth(ip)
    per_min  = ENV.fetch('RATE_LIMIT_OAUTH_PER_MINUTE', '10').to_i
    per_hour = ENV.fetch('RATE_LIMIT_OAUTH_PER_HOUR', '60').to_i
    DB.check_rate_limit("oauth:#{ip}", per_minute: per_min, per_hour: per_hour, prefix: 'oauth_')
  end

  def self.check_token_endpoint(ip)
    per_min  = ENV.fetch('RATE_LIMIT_TOKEN_PER_MINUTE', '20').to_i
    per_hour = ENV.fetch('RATE_LIMIT_TOKEN_PER_HOUR', '200').to_i
    DB.check_rate_limit("token:#{ip}", per_minute: per_min, per_hour: per_hour, prefix: 'token_')
  end
end
