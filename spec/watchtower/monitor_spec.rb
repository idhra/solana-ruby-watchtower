# frozen_string_literal: true

# The cluster is a fake RPC client serving canned answers; what is tested is what
# the monitor makes of them and what it sends.
RSpec.describe Watchtower::Monitor do
  class FakeCluster
    attr_accessor :slot, :last_vote, :delinquent, :node_pubkey, :found, :gossip, :error

    def initialize
      @slot, @last_vote, @delinquent, @node_pubkey, @found = 1000, 997, false, STAKED, true
      @gossip = [[STAKED, IP_1], [STANDBY_2, IP_2]]
    end

    def label = 'fake-rpc'

    def call(method, _params = [])
      raise error if error

      case method
      when 'getSlot' then slot
      when 'getVoteAccounts'
        account = { 'votePubkey' => VOTE, 'nodePubkey' => node_pubkey, 'lastVote' => last_vote }
        list = found ? [account] : []
        delinquent ? { 'current' => [], 'delinquent' => list } : { 'current' => list, 'delinquent' => [] }
      when 'getClusterNodes' then gossip.map { |pubkey, ip| { 'pubkey' => pubkey, 'gossip' => "#{ip}:8000" } }
      end
    end
  end

  class Outbox
    attr_reader :sent
    attr_accessor :working

    def initialize
      @sent = []
      @working = true
    end

    def deliver(text)
      @sent << text
      working
    end
  end

  let(:cluster)   { FakeCluster.new }
  let(:outbox)    { Outbox.new }
  let(:store)     { Watchtower::Stores::MemoryStore.new }
  let(:heartbeat) { instance_double(Watchtower::Heartbeat, ping: true) }
  let(:now)       { [Time.utc(2026, 11, 18, 12, 0, 0)] }
  let(:monitor) do
    described_class.new(Watchtower::Config.new(base_settings), store: store, notifier: outbox, heartbeat: heartbeat,
                                                               rpc: Watchtower::RpcPool.new([cluster]), logger: null_logger,
                                                               clock: -> { now[0] })
  end

  def advance(seconds) = now[0] += seconds
  def sent = outbox.sent
  def state(key) = store.fetch(key)

  it 'posts nothing while all is well' do
    3.times do
      monitor.check_votes
      monitor.check_gossip
    end
    expect(sent).to be_empty
    expect(state('voting').last_message).to eq('voting, 3 slots behind the tip')
    expect(state('node:node-2').last_message).to eq('node-2 is in gossip as standby')
  end

  it 'tags every message with the validator name' do
    cluster.last_vote = 1
    2.times { monitor.check_votes }
    expect(sent.last).to start_with('[test] 🚨 voting:')
  end

  describe 'votes' do
    it 'alerts on the second lagging check and reports recovery' do
      cluster.last_vote = 800
      monitor.check_votes
      expect(sent).to be_empty
      monitor.check_votes
      expect(sent.last).to include('voting: last vote 200 slots behind the tip (limit 100)')

      cluster.last_vote = 999
      monitor.check_votes
      expect(sent.last).to include('RESOLVED voting')
    end

    it 'names delinquency' do
      cluster.delinquent = true
      cluster.last_vote = 500
      2.times { monitor.check_votes }
      expect(sent.last).to include('DELINQUENT')
    end

    it 'alerts when the vote account is missing' do
      cluster.found = false
      2.times { monitor.check_votes }
      expect(sent.last).to include('is in neither the current nor the delinquent list')
    end

    it 'alerts when the vote account points at another identity' do
      cluster.node_pubkey = STANDBY_1
      2.times { monitor.check_votes }
      expect(sent).to include(a_string_including("vote_identity: vote account identity is #{STANDBY_1}"))
    end

    it 'treats RPC blindness as its own alert and leaves the voting state alone' do
      cluster.last_vote = 800
      2.times { monitor.check_votes }
      sent.clear

      cluster.error = RuntimeError.new('HTTP 429')
      4.times { monitor.check_votes }
      expect(sent).to eq(['[test] 🚨 rpc:votes: every RPC endpoint failed: fake-rpc: HTTP 429'])
      expect(state('voting')).to be_alerting
    end

    it 'pings the heartbeat after every completed run, even a blind one' do
      monitor.check_votes
      cluster.error = RuntimeError.new('down')
      monitor.check_votes
      expect(heartbeat).to have_received(:ping).twice
    end

    it 'does not ping when the run crashes' do
      allow(store).to receive(:save).and_raise(IOError, 'disk full')
      expect { monitor.check_votes }.to raise_error(IOError)
      expect(heartbeat).not_to have_received(:ping)
    end

    it 'sends an undelivered alert again on the next run' do
      outbox.working = false
      cluster.last_vote = 1
      3.times { monitor.check_votes }
      expect(sent.size).to eq(2)
      expect(state('voting')).not_to be_alerting
    end
  end

  describe 'gossip' do
    it 'alerts at once when a node is missing' do
      cluster.gossip = [[STAKED, IP_1]]
      monitor.check_gossip
      expect(sent).to eq(["[test] 🚨 node:node-2: node-2 (#{IP_2}) is not in gossip: the node is down or cut off"])
    end

    it 'alerts when a node runs an identity that is neither of its keys' do
      cluster.gossip = [[STAKED, IP_1], [STANDBY_1, IP_2]]
      monitor.check_gossip
      expect(sent.last).to include('node:node-2: node-2 is in gossip as Standby1…, neither the staked identity nor its own standby key')
    end

    it 'alerts when the staked identity gossips from an unknown host' do
      cluster.gossip = [[STAKED, '203.0.113.99'], [STANDBY_1, IP_1], [STANDBY_2, IP_2]]
      monitor.check_gossip
      expect(sent).to include(a_string_including('staked:gossip: staked identity in gossip on UNKNOWN HOST 203.0.113.99'))
    end

    it 'alerts when the staked identity is not in gossip' do
      cluster.gossip = [[STANDBY_1, IP_1], [STANDBY_2, IP_2]]
      monitor.check_gossip
      expect(sent).to include(a_string_including('staked:gossip: staked identity Stake111… is not in gossip'))
    end

    it 'reports a single role switch without a double-active alert' do
      monitor.check_gossip
      advance(120)
      cluster.gossip = [[STAKED, IP_2], [STANDBY_1, IP_1]]
      monitor.check_gossip
      expect(sent).to eq(["[test] ℹ️ staked identity moved from node-1 (#{IP_1}) to node-2 (#{IP_2})"])
      expect(state('staked:location')).not_to be_alerting
    end

    it 'calls a flip-flopping address double-active, and clears it after the window' do
      on1 = [[STAKED, IP_1], [STANDBY_2, IP_2]]
      on2 = [[STAKED, IP_2], [STANDBY_1, IP_1]]
      [on1, on2, on1].each do |table|
        cluster.gossip = table
        monitor.check_gossip
        advance(120)
      end
      expect(sent.last).to include('staked:location: ', 'changed 2 times in 15 min', 'BOTH NODES MAY BE RUNNING THE STAKED IDENTITY')

      advance(16 * 60)
      monitor.check_gossip
      expect(sent.last).to include('RESOLVED staked:location')
    end

    it 'handles a single node with no standby key' do
      settings = base_settings('nodes' => { 'solo' => { 'ip' => IP_1 } })
      solo = described_class.new(Watchtower::Config.new(settings), store: store, notifier: outbox, heartbeat: nil,
                                                                    rpc: Watchtower::RpcPool.new([cluster]), logger: null_logger)
      cluster.gossip = [[STAKED, IP_1]]
      solo.check_gossip
      expect(sent).to be_empty
    end
  end

  it 'rejects an unknown check name' do
    expect { monitor.run('everything') }.to raise_error(ArgumentError, /votes or gossip/)
  end
end
