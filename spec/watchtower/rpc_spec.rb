# frozen_string_literal: true

RSpec.describe Watchtower::Rpc do
  let(:url) { 'https://rpc.example/?api-key=SECRET' }
  let(:rpc) { described_class.new(url, sleeper: ->(_) {}) }

  def reply(result) = { body: JSON.generate(jsonrpc: '2.0', id: 1, result: result), headers: { 'Content-Type' => 'application/json' } }

  it 'posts a JSON-RPC request and returns the result' do
    stub = stub_request(:post, url).with(body: hash_including('method' => 'getSlot', 'params' => [{ 'commitment' => 'processed' }]))
                                   .to_return(reply(42))
    expect(rpc.call('getSlot', [{ 'commitment' => 'processed' }])).to eq(42)
    expect(stub).to have_been_requested.once
  end

  it 'labels itself by host only' do
    expect(rpc.label).to eq('rpc.example')
  end

  it 'retries a 429 once, then succeeds' do
    stub_request(:post, url).to_return({ status: 429 }, reply(7))
    expect(rpc.call('getSlot')).to eq(7)
  end

  it 'gives up after the second 429' do
    stub_request(:post, url).to_return(status: 429)
    expect { rpc.call('getSlot') }.to raise_error(Watchtower::Rpc::Error, 'HTTP 429')
  end

  it 'retries a timeout once' do
    stub_request(:post, url).to_timeout.then.to_return(reply(9))
    expect(rpc.call('getSlot')).to eq(9)
  end

  it 'raises a JSON-RPC error without retrying' do
    stub = stub_request(:post, url).to_return(body: JSON.generate(error: { code: -32_601, message: 'Method not found' }))
    expect { rpc.call('nope') }.to raise_error(Watchtower::Rpc::Error, /-32601: Method not found/)
    expect(stub).to have_been_requested.once
  end

  it 'does not retry a 403' do
    stub = stub_request(:post, url).to_return(status: 403)
    expect { rpc.call('getSlot') }.to raise_error(Watchtower::Rpc::Error, 'HTTP 403')
    expect(stub).to have_been_requested.once
  end
end

RSpec.describe Watchtower::RpcPool do
  fake_client = Struct.new(:label, :error) do
    def call(*) = error ? raise(error) : 'answer'
  end

  it 'returns the first answer and says who gave it' do
    pool = described_class.new([fake_client.new('a', RuntimeError.new('down')), fake_client.new('b', nil)])
    answer = pool.first_answer { |c| c.call }
    expect([answer.value, answer.label]).to eq(%w[answer b])
  end

  it 'names every endpoint when all fail' do
    pool = described_class.new([fake_client.new('a', RuntimeError.new('HTTP 429')), fake_client.new('b', RuntimeError.new('timeout'))])
    expect { pool.first_answer { |c| c.call } }.to raise_error(described_class::AllFailed, 'a: HTTP 429; b: timeout')
  end

  it 'never puts an API key in the failure message' do
    url = 'https://rpc.example/?api-key=SECRET'
    stub_request(:post, url).to_return(status: 500)
    pool = described_class.new([Watchtower::Rpc.new(url, sleeper: ->(_) {})])
    expect { pool.first_answer { |c| c.call('getSlot') } }.to raise_error(described_class::AllFailed) { |e| expect(e.message).not_to include('SECRET') }
  end
end
