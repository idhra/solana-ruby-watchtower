# frozen_string_literal: true

RSpec.describe Watchtower::CLI do
  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:rpc_url) { 'https://rpc.example/' }
  let(:config_path) do
    File.join(@dir, 'watchtower.yml').tap do |path|
      File.write(path, base_settings('rpc_urls' => [rpc_url]).to_yaml)
    end
  end

  def cli(*args) = described_class.new(args, out: out, err: err).run

  def rpc_reply(method, result)
    stub_request(:post, rpc_url).with(body: hash_including('method' => method))
                                .to_return(body: JSON.generate(jsonrpc: '2.0', id: 1, result: result))
  end

  it 'runs one vote check and prints what it found' do
    rpc_reply('getSlot', 1000)
    rpc_reply('getVoteAccounts', 'current' => [{ 'votePubkey' => VOTE, 'nodePubkey' => STAKED, 'lastVote' => 998 }],
                                 'delinquent' => [])
    expect(cli('check', 'votes', '--config', config_path)).to eq(0)
    expect(out.string).to include('voting, 2 slots behind the tip', 'answering via rpc.example')
    expect(File).to exist(File.join(@dir, 'watchtower-state.json'))

    out.truncate(0)
    expect(cli('status', '-c', config_path)).to eq(0)
    expect(out.string).to match(/ok\s+voting\s+voting, 2 slots/)
  end

  it 'explains a bad config and exits 2' do
    File.write(config_path, base_settings('identity' => 'nope').to_yaml)
    expect(cli('check', 'votes', '-c', config_path)).to eq(2)
    expect(err.string).to include('identity is not a base58 public key')
  end

  it 'says when the config file is missing' do
    expect(cli('status', '-c', File.join(@dir, 'missing.yml'))).to eq(2)
    expect(err.string).to include('not found')
  end

  it 'rejects an unknown check' do
    expect(cli('check', 'everything', '-c', config_path)).to eq(2)
  end

  it 'sends a test notification' do
    expect(cli('notify-test', '-c', config_path)).to eq(0)
    expect(out.string).to include('test message', 'delivered')
  end

  it 'prints usage without a command' do
    expect(cli).to eq(2)
    expect(err.string).to include('Usage: solana-watchtower')
  end
end
