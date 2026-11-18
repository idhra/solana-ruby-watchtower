# frozen_string_literal: true

require 'logger'

module Solana::Ruby::Watchtower
  # Runs the checks for one validator and turns their results into alerts.
  #
  #   monitor.check_votes   # every 30s: is the staked identity voting?
  #   monitor.check_gossip  # every 2 min: are the nodes up, is only one staked?
  #
  # Each check key keeps a CheckState in the store, and posts when it goes bad,
  # every realert_minutes while it stays bad, and when it recovers:
  #
  #   rpc:votes, rpc:gossip   every RPC endpoint failed
  #   voting                  last vote too far behind the tip, or delinquent
  #   vote_identity           the vote account points at another identity
  #   staked:gossip           staked identity absent from gossip, or on an unknown host
  #   staked:location         staked identity's address flipping between hosts
  #   node:<name>             a node absent from gossip, or running a key it should not
  class Monitor
    CHECKS = %w[votes gossip].freeze

    attr_reader :config, :store, :notifier

    def initialize(config, store: nil, notifier: nil, rpc: nil, heartbeat: :from_config,
                   logger: Logger.new($stdout), clock: -> { Time.now.utc })
      @config   = config
      @logger   = logger
      @store    = store || Stores::FileStore.new(config.state_file)
      @notifier = notifier || Notifiers.build(config.notify, logger: logger)
      @rpc      = rpc || RpcPool.from_urls(config.rpc_urls, timeout: config.rpc_timeout_seconds)
      @heartbeat = heartbeat == :from_config ? (config.heartbeat_url && Heartbeat.new(config.heartbeat_url, logger: logger)) : heartbeat
      @clock = clock
    end

    def run(check)
      case check.to_s
      when 'votes'  then check_votes
      when 'gossip' then check_gossip
      else raise ArgumentError, "unknown check #{check.inspect} (#{CHECKS.join(' or ')})"
      end
    end

    def check_votes
      answer = rpc_answer('rpc:votes', config.rpc_failures_to_alert) { |rpc| Observe.vote_account(rpc, config.vote_account) }
      # Unknown is not bad: the other checks keep their state until RPC is back.
      if answer
        evaluate_voting(answer.value)
        evaluate_vote_identity(answer.value) if answer.value.found
      end
      # After every completed run, whatever it found: the heartbeat proves the
      # monitor is alive, the alerts above say what it saw.
      @heartbeat&.ping
    end

    def check_gossip
      pubkeys = [config.identity, *config.nodes.map(&:unstaked_identity).compact]
      answer = rpc_answer('rpc:gossip', config.failures_to_alert) do |rpc|
        Observe.gossip(rpc, pubkeys: pubkeys, ips: config.nodes.map(&:ip))
      end
      return unless answer

      entries = answer.value
      staked  = entries.find { |e| e.pubkey == config.identity }
      evaluate_staked_gossip(staked)
      evaluate_staked_location(staked.ip) if staked
      config.nodes.each { |node| evaluate_node(node, entries.select { |e| e.ip == node.ip }) }
    end

    private

    def rpc_answer(key, failures_to_alert)
      answer = @rpc.first_answer { |rpc| yield rpc }
      evaluate(key, ok: true, message: "answering via #{answer.label}", failures_to_alert: failures_to_alert)
      answer
    rescue RpcPool::AllFailed => e
      evaluate(key, ok: false, message: "every RPC endpoint failed: #{e.message}", failures_to_alert: failures_to_alert)
      nil
    end

    def evaluate_voting(vote)
      unless vote.found
        return evaluate('voting', ok: false,
                                  message: "vote account #{short(config.vote_account)} is in neither the current nor the delinquent list")
      end

      lag = [vote.slot - vote.last_vote, 0].max
      ok, message =
        if vote.delinquent
          [false, "DELINQUENT: last vote at slot #{vote.last_vote}, #{lag} slots behind"]
        elsif lag > config.max_vote_lag_slots
          [false, "last vote #{lag} slots behind the tip (limit #{config.max_vote_lag_slots})"]
        else
          [true, "voting, #{lag} slots behind the tip"]
        end
      evaluate('voting', ok: ok, message: message)
    end

    def evaluate_vote_identity(vote)
      ok = vote.node_pubkey == config.identity
      evaluate('vote_identity', ok: ok,
                                message: if ok
                                           "vote account identity is #{short(config.identity)}"
                                         else
                                           "vote account identity is #{vote.node_pubkey}, expected #{config.identity}"
                                         end)
    end

    # Gossip runs every couple of minutes, so a single miss is reported.
    def evaluate_staked_gossip(staked)
      # An address that is neither node means the staked key is running somewhere
      # else: a leaked key, or a node added without updating the config.
      ok = staked && config.nodes.any? { |n| n.ip == staked.ip }
      message = staked ? "staked identity in gossip on #{where(staked.ip)}" : "staked identity #{short(config.identity)} is not in gossip"
      evaluate('staked:gossip', ok: ok ? true : false, message: message, failures_to_alert: 1)
    end

    # Gossip keeps one address per identity, whichever node pushed last. One node
    # holding the staked identity gives a steady address; two nodes holding it make
    # the address flip between them. A single change is a role switch, reported
    # but not alarming.
    def evaluate_staked_location(ip)
      state  = store.fetch('staked:location')
      now    = @clock.call
      window = config.double_active_window_minutes * 60
      previous = state.data['ip']
      moves = Array(state.data['moves']).map { |t| Time.iso8601(t) }.select { |t| t > now - window }

      if previous && previous != ip
        moves << now
        @notifier.deliver(tag("ℹ️ staked identity moved from #{where(previous)} to #{where(ip)}")) if moves.size < config.double_active_moves
      end
      state.data = { 'ip' => ip, 'moves' => moves.map { |t| t.utc.iso8601 } }

      double = moves.size >= config.double_active_moves
      message = if double
                  "staked identity's gossip address changed #{moves.size} times in #{config.double_active_window_minutes} min, " \
                    "now #{where(ip)}: BOTH NODES MAY BE RUNNING THE STAKED IDENTITY"
                else
                  "staked identity steady on #{where(ip)}"
                end
      evaluate_state(state, ok: !double, message: message, failures_to_alert: 1)
    end

    def evaluate_node(node, here)
      expected = { config.identity => 'staked' }
      expected[node.unstaked_identity] = 'standby' if node.unstaked_identity
      known = here.filter_map { |e| expected[e.pubkey] }

      ok, message =
        if here.empty?
          [false, "#{node.name} (#{node.ip}) is not in gossip: the node is down or cut off"]
        elsif known.empty?
          [false, "#{node.name} is in gossip as #{here.map { |e| short(e.pubkey) }.join(', ')}, " \
                  'neither the staked identity nor its own standby key']
        else
          [true, "#{node.name} is in gossip as #{known.uniq.join(' + ')}"]
        end
      evaluate("node:#{node.name}", ok: ok, message: message, failures_to_alert: 1)
    end

    def evaluate(key, ok:, message:, failures_to_alert: config.failures_to_alert)
      evaluate_state(store.fetch(key), ok: ok, message: message, failures_to_alert: failures_to_alert)
    end

    def evaluate_state(state, ok:, message:, failures_to_alert:)
      now = @clock.call
      alert = state.observe(ok: ok, message: message, now: now, failures_to_alert: failures_to_alert,
                            realert_after: config.realert_minutes * 60)
      @logger.debug("#{state.key}: #{ok ? 'ok' : 'FAIL'}: #{message}")
      if alert
        @logger.warn(alert.text)
        state.acknowledge(alert, now) if @notifier.deliver(tag(alert.text))
      end
      store.save(state)
      state
    end

    # Names the validator, so one chat can take alerts for several.
    def tag(text) = "[#{config.name}] #{text}"

    def where(ip)
      node = config.nodes.find { |n| n.ip == ip }
      node ? "#{node.name} (#{ip})" : "UNKNOWN HOST #{ip}"
    end

    def short(pubkey) = "#{pubkey.to_s[0, 8]}…"
  end
end
