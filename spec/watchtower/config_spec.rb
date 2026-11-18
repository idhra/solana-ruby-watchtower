# frozen_string_literal: true

RSpec.describe Watchtower::Config do
  it 'fills in the defaults' do
    config = described_class.new(base_settings.except('rpc_urls', 'name'))
    expect(config.rpc_urls).to eq(['https://api.mainnet-beta.solana.com'])
    expect(config.max_vote_lag_slots).to eq(100)
    expect(config.votes_interval_seconds).to eq(30)
    expect(config.name).to eq('Stake111…')
  end

  it 'reads nodes, with an optional standby key' do
    settings = base_settings('nodes' => { 'solo' => { 'ip' => '198.51.100.9' } })
    node = described_class.new(settings).nodes.first
    expect([node.name, node.ip, node.unstaked_identity]).to eq(['solo', '198.51.100.9', nil])
  end

  it 'accepts symbol keys' do
    settings = base_settings.transform_keys(&:to_sym)
    expect(described_class.new(settings).vote_account).to eq(VOTE)
  end

  {
    'a missing vote account'    => [{ 'vote_account' => nil }, /vote_account is missing/],
    'a placeholder identity'    => [{ 'identity' => 'YOUR_STAKED_IDENTITY_PUBKEY' }, /identity is not a base58/],
    'no nodes'                  => [{ 'nodes' => {} }, /nodes must map/],
    'a node without an ip'      => [{ 'nodes' => { 'a' => { 'unstaked_identity' => STANDBY_1 } } }, /nodes.a.ip is missing/],
    'two nodes on one ip'       => [{ 'nodes' => { 'a' => { 'ip' => '1.1.1.1' }, 'b' => { 'ip' => '1.1.1.1' } } }, /share ip/],
    'a non-URL endpoint'        => [{ 'rpc_urls' => ['not a url'] }, /not an http/],
    'a zero threshold'          => [{ 'failures_to_alert' => 0 }, /positive integer/],
    'a string interval'         => [{ 'votes_interval_seconds' => '30' }, /positive integer/]
  }.each do |what, (overrides, error)|
    it "rejects #{what}" do
      expect { described_class.new(base_settings(overrides)) }.to raise_error(Watchtower::ConfigError, error)
    end
  end

  it 'loads a file through ERB and resolves state_file next to it' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'watchtower.yml')
      File.write(path, <<~YAML)
        vote_account: #{VOTE}
        identity: <%= ENV.fetch('SPEC_IDENTITY') %>
        nodes:
          a: { ip: 198.51.100.1 }
        state_file: state/watchtower.json
      YAML
      config = with_env('SPEC_IDENTITY' => STAKED) { described_class.load(path) }
      expect(config.identity).to eq(STAKED)
      expect(config.state_file).to eq(File.join(dir, 'state/watchtower.json'))
    end
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
