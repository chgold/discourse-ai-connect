module RateLimitMiddleware
  def self.check(token)
    result = DB.check_rate_limit(token, per_minute: 50, per_hour: 1000)
    if result[:limited]
      halt 429, { error: 'rate_limit_exceeded', window: result[:window] }.to_json
    end
  end
end
