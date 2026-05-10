module InputValidator
  MAX_STRING = 16_000
  MAX_TITLE  = 255

  def self.validate(raw_params, schema)
    raw_params = {} unless raw_params.is_a?(Hash)
    out = {}
    schema[:required].each do |key, type|
      val = raw_params[key.to_s] || raw_params[key]
      if val.nil? || (val.is_a?(String) && val.strip.empty?)
        return [nil, "Missing required parameter: #{key}"]
      end
      coerced, err = coerce(val, type, key)
      return [nil, err] if err
      out[key] = coerced
    end
    schema[:optional].each do |key, type|
      val = raw_params[key.to_s] || raw_params[key]
      next if val.nil?
      coerced, err = coerce(val, type, key)
      return [nil, err] if err
      out[key] = coerced
    end
    [out, nil]
  end

  def self.coerce(val, type, key)
    case type
    when :integer
      return [Integer(val), nil] if val.is_a?(Integer) || (val.is_a?(String) && val.match?(/\A-?\d+\z/))
      [nil, "Parameter #{key} must be an integer"]
    when :string
      str = val.to_s
      max = (key == :title) ? MAX_TITLE : MAX_STRING
      return [nil, "Parameter #{key} exceeds max length (#{max})"] if str.bytesize > max
      [str, nil]
    when :boolean
      return [true, nil]  if val == true || val == 'true'
      return [false, nil] if val == false || val == 'false' || val.nil?
      [nil, "Parameter #{key} must be boolean"]
    else
      [val, nil]
    end
  end
end
