# frozen_string_literal: true

require 'webmock/rspec'
require 'tmpdir'
require 'stringio'
require_relative '../lib/solana/ruby/watchtower'

Watchtower = Solana::Ruby::Watchtower

# Fixture keys: valid base58, obviously not real accounts.
VOTE      = 'Vote111111111111111111111111111111111111111'
STAKED    = 'Stake11111111111111111111111111111111111111'
STANDBY_1 = 'Standby1111111111111111111111111111111111111'
STANDBY_2 = 'StandbyTwo11111111111111111111111111111111'
IP_1      = '198.51.100.1'
IP_2      = '198.51.100.2'

module WatchtowerSpecHelpers
  def base_settings(overrides = {})
    {
      'name' => 'test',
      'vote_account' => VOTE,
      'identity' => STAKED,
      'nodes' => {
        'node-1' => { 'ip' => IP_1, 'unstaked_identity' => STANDBY_1 },
        'node-2' => { 'ip' => IP_2, 'unstaked_identity' => STANDBY_2 }
      },
      'rpc_urls' => ['https://rpc.example/?api-key=SECRET']
    }.merge(overrides)
  end

  def null_logger = Logger.new(File::NULL)
end

RSpec.configure do |config|
  config.include WatchtowerSpecHelpers
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end
