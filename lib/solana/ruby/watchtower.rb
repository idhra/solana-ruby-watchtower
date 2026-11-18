# frozen_string_literal: true

module Solana
  module Ruby
    # Off-box monitoring for a Solana validator or an active/standby pair.
    #
    # The pieces, from the bottom up:
    #
    #   Rpc / RpcPool   JSON-RPC over net/http, tried endpoint by endpoint
    #   Observe         reads the vote account and the gossip table
    #   CheckState      alert state of one check: fire, remind, resolve
    #   Stores::*       where CheckStates live between runs
    #   Notifiers::*    where alerts go
    #   Monitor         runs the checks and turns results into alerts
    #   Runner / CLI    the long-running daemon around a Monitor
    module Watchtower
      class Error < StandardError; end
    end
  end
end

require_relative 'watchtower/version'
require_relative 'watchtower/config'
require_relative 'watchtower/rpc'
require_relative 'watchtower/observe'
require_relative 'watchtower/check_state'
require_relative 'watchtower/stores/memory_store'
require_relative 'watchtower/stores/file_store'
require_relative 'watchtower/stores/active_record_store'
require_relative 'watchtower/notifiers'
require_relative 'watchtower/heartbeat'
require_relative 'watchtower/monitor'
require_relative 'watchtower/runner'
require_relative 'watchtower/cli'
