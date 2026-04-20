require 'net/http'
require 'uri'
require 'json'

module DiscourseApi
  BASE_URL = ENV.fetch('DISCOURSE_URL', 'http://localhost:3086')
  API_KEY  = ENV.fetch('DISCOURSE_API_KEY', '')
  API_USER = ENV.fetch('DISCOURSE_API_USER', 'system')

  def self.get(path)
    call(:get, path)
  end

  def self.post(path, body = {})
    call(:post, path, body)
  end

  def self.put(path, body = {})
    call(:put, path, body)
  end

  private

  def self.call(method, path, body = nil)
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    req = case method
          when :get  then Net::HTTP::Get.new(uri)
          when :post then Net::HTTP::Post.new(uri)
          when :put  then Net::HTTP::Put.new(uri)
          end
    req['Api-Key']      = API_KEY
    req['Api-Username'] = API_USER
    req['Content-Type'] = 'application/json'
    req.body = body.to_json if body && !body.empty?
    response = http.request(req)
    JSON.parse(response.body)
  rescue => e
    { 'error' => e.message }
  end
end
