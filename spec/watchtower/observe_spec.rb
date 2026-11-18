# frozen_string_literal: true

RSpec.describe Watchtower::Observe do
  let(:rpc) { instance_double(Watchtower::Rpc) }

  describe '.vote_account' do
    def accounts(current: [], delinquent: [])
      allow(rpc).to receive(:call).with('getSlot', [{ 'commitment' => 'processed' }]).and_return(1000)
      allow(rpc).to receive(:call).with('getVoteAccounts', [{ 'commitment' => 'processed', 'votePubkey' => VOTE }])
                                  .and_return('current' => current, 'delinquent' => delinquent)
    end

    def account(last_vote) = { 'votePubkey' => VOTE, 'nodePubkey' => STAKED, 'lastVote' => last_vote }

    it 'reads a current account' do
      accounts(current: [account(997)])
      vote = described_class.vote_account(rpc, VOTE)
      expect(vote).to have_attributes(slot: 1000, found: true, delinquent: false, last_vote: 997, node_pubkey: STAKED)
    end

    it 'flags a delinquent account' do
      accounts(delinquent: [account(500)])
      expect(described_class.vote_account(rpc, VOTE)).to have_attributes(found: true, delinquent: true, last_vote: 500)
    end

    it 'reports an account in neither list as not found' do
      accounts
      expect(described_class.vote_account(rpc, VOTE)).to have_attributes(found: false, last_vote: nil)
    end
  end

  describe '.gossip' do
    it 'keeps only the watched identities and hosts, and strips ports' do
      allow(rpc).to receive(:call).with('getClusterNodes', []).and_return([
        { 'pubkey' => STAKED,     'gossip' => '203.0.113.5:8000' },
        { 'pubkey' => 'Other111', 'gossip' => "#{IP_2}:8000" },
        { 'pubkey' => 'Other222', 'gossip' => '[2001:db8::1]:8000' },
        { 'pubkey' => 'Other333', 'gossip' => nil }
      ])
      entries = described_class.gossip(rpc, pubkeys: [STAKED], ips: [IP_1, IP_2, '2001:db8::1'])
      expect(entries.map(&:to_h)).to eq([
        { pubkey: STAKED, ip: '203.0.113.5' },
        { pubkey: 'Other111', ip: IP_2 },
        { pubkey: 'Other222', ip: '2001:db8::1' }
      ])
    end
  end
end
