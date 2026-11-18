# frozen_string_literal: true

module Solana::Ruby::Watchtower
  # Reads what the cluster says about a validator. Each method takes an RPC
  # client (anything with #call(method, params)) and returns plain data.
  module Observe
    extend self

    # found: false when the vote account is in neither list.
    VoteAccount = Data.define(:slot, :found, :delinquent, :last_vote, :node_pubkey)

    GossipEntry = Data.define(:pubkey, :ip)

    def vote_account(rpc, vote_pubkey)
      # Both at processed: lastVote is reported at the commitment asked for, so
      # comparing it to a confirmed slot would add a steady false lag.
      slot     = Integer(rpc.call('getSlot', [{ 'commitment' => 'processed' }]))
      accounts = rpc.call('getVoteAccounts', [{ 'commitment' => 'processed', 'votePubkey' => vote_pubkey }])

      current    = Array(accounts['current']).find    { |a| a['votePubkey'] == vote_pubkey }
      delinquent = Array(accounts['delinquent']).find { |a| a['votePubkey'] == vote_pubkey }
      account    = current || delinquent

      VoteAccount.new(slot: slot, found: !account.nil?, delinquent: !delinquent.nil?,
                      last_vote: account && Integer(account['lastVote']), node_pubkey: account&.fetch('nodePubkey'))
    end

    # The gossip table narrowed to the given identities and anything advertised
    # from the given IPs; the full table is thousands of entries.
    def gossip(rpc, pubkeys:, ips:)
      rpc.call('getClusterNodes', []).filter_map do |node|
        entry = GossipEntry.new(pubkey: node['pubkey'], ip: host(node['gossip']))
        entry if pubkeys.include?(entry.pubkey) || ips.include?(entry.ip)
      end
    end

    private

    # "1.2.3.4:8000" or "[2001:db8::1]:8000" -> the address alone.
    def host(addr)
      return nil if addr.nil? || addr.empty?

      addr.rpartition(':').first.delete_prefix('[').delete_suffix(']')
    end
  end
end
