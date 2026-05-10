require_relative 'spec_helper'

RSpec.describe InputValidator do
  let(:schema) do
    { required: { title: :string, count: :integer }, optional: { flag: :boolean, note: :string } }
  end

  it 'returns coerced values when all required present' do
    out, err = InputValidator.validate({ 'title' => 'hi', 'count' => '5' }, schema)
    expect(err).to be_nil
    expect(out[:title]).to eq('hi')
    expect(out[:count]).to eq(5)
  end

  it 'errors when required is missing' do
    _, err = InputValidator.validate({ 'title' => 'hi' }, schema)
    expect(err).to include('count')
  end

  it 'errors when integer cannot be coerced' do
    _, err = InputValidator.validate({ 'title' => 'hi', 'count' => 'abc' }, schema)
    expect(err).to include('integer')
  end

  it 'enforces max length on regular strings' do
    _, err = InputValidator.validate({ 'title' => 'a' * 16_001, 'count' => '1' }, schema)
    expect(err).to include('exceeds max length')
  end

  it 'enforces tighter max length on :title key' do
    _, err = InputValidator.validate({ 'title' => 't' * 300, 'count' => '1' }, schema)
    expect(err).to include('exceeds max length')
  end

  it 'accepts boolean true/false strings' do
    out, = InputValidator.validate({ 'title' => 'x', 'count' => '1', 'flag' => 'true' }, schema)
    expect(out[:flag]).to be true
  end

  it 'allows missing optional fields' do
    out, err = InputValidator.validate({ 'title' => 'x', 'count' => '1' }, schema)
    expect(err).to be_nil
    expect(out).not_to have_key(:flag)
  end

  it 'rejects empty strings as missing for required' do
    _, err = InputValidator.validate({ 'title' => '   ', 'count' => '1' }, schema)
    expect(err).to include('Missing required')
  end
end
