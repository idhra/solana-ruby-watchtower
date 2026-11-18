# frozen_string_literal: true

require 'erb'
require 'yaml'

module Solana::Ruby::Watchtower
  class ConfigError < Error; end

  # The settings for one validator, from a hash or a YAML file.
  #
  # A file is passed through ERB first, so secrets can stay in the environment:
  #
  #   bot_token: <%= ENV['TELEGRAM_BOT_TOKEN'] %>
  #
  # Everything is checked when the config is built, so a typo stops the monitor
  # at startup rather than leaving it running blind.
  class Config
    Node = Data.define(:name, :ip, :unstaked_identity)

    DEFAULTS = {
      'rpc_urls'                     => ['https://api.mainnet-beta.solana.com'],
      'rpc_timeout_seconds'          => 10,
      # Last vote this many slots behind the tip counts as not voting. Healthy
      # lag is a handful of slots; the cluster's delinquency mark is 128.
      'max_vote_lag_slots'           => 100,
      # Consecutive bad vote checks before an alert fires.
      'failures_to_alert'            => 2,
      # All RPC endpoints failing, held back longer: public RPC rate-limits in bursts.
      'rpc_failures_to_alert'        => 4,
      'realert_minutes'              => 30,
      # The staked identity's gossip address changing this many times within the
      # window means two nodes are advertising it.
      'double_active_moves'          => 2,
      'double_active_window_minutes' => 15,
      'votes_interval_seconds'       => 30,
      # getClusterNodes returns the whole cluster (well over a megabyte), so the
      # gossip checks run less often than the vote check.
      'gossip_interval_seconds'      => 120,
      'state_file'                   => 'watchtower-state.json',
      'notify'                       => {}
    }.freeze

    POSITIVE_INTEGERS = %w[
      rpc_timeout_seconds max_vote_lag_slots failures_to_alert rpc_failures_to_alert realert_minutes
      double_active_moves double_active_window_minutes votes_interval_seconds gossip_interval_seconds
    ].freeze

    PUBKEY = /\A[1-9A-HJ-NP-Za-km-z]{32,44}\z/

    attr_reader :name, :vote_account, :identity, :nodes, :rpc_urls, :notify, :heartbeat_url, :state_file,
                *POSITIVE_INTEGERS.map(&:to_sym)

    # base_dir resolves a relative state_file; for a file, its directory.
    def self.load(path)
      text = ERB.new(File.read(path)).result
      new(YAML.safe_load(text, aliases: true) || {}, base_dir: File.dirname(File.expand_path(path)))
    rescue Psych::SyntaxError => e
      raise ConfigError, "#{path}: #{e.message}"
    end

    def initialize(hash, base_dir: Dir.pwd)
      settings = DEFAULTS.merge(stringify(hash))

      @vote_account = pubkey!(settings, 'vote_account')
      @identity     = pubkey!(settings, 'identity')
      @name         = (settings['name'] || "#{@identity[0, 8]}…").to_s
      @nodes        = nodes!(settings['nodes'])
      @rpc_urls     = Array(settings['rpc_urls']).map { |u| u.to_s.strip }.reject(&:empty?)
      raise ConfigError, 'rpc_urls is empty' if @rpc_urls.empty?

      @rpc_urls.each { |u| url!(u, 'rpc_urls') }
      POSITIVE_INTEGERS.each { |k| instance_variable_set(:"@#{k}", positive_integer!(settings, k)) }

      @notify        = settings['notify'] || {}
      raise ConfigError, 'notify must be a mapping' unless @notify.is_a?(Hash)

      @heartbeat_url = blank?(settings['heartbeat_url']) ? nil : url!(settings['heartbeat_url'], 'heartbeat_url')
      @state_file    = File.expand_path(settings['state_file'].to_s, base_dir)
    end

    private

    def stringify(value)
      case value
      when Hash  then value.to_h { |k, v| [k.to_s, stringify(v)] }
      when Array then value.map { |v| stringify(v) }
      else value
      end
    end

    def nodes!(raw)
      raise ConfigError, 'nodes must map each node name to its ip (and unstaked_identity for a standby)' unless raw.is_a?(Hash) && raw.any?

      nodes = raw.map do |name, node|
        raise ConfigError, "nodes.#{name} must be a mapping" unless node.is_a?(Hash)
        raise ConfigError, "nodes.#{name}.ip is missing" if blank?(node['ip'])

        unstaked = node['unstaked_identity']
        unstaked = blank?(unstaked) ? nil : pubkey!(node, 'unstaked_identity', "nodes.#{name}.")
        Node.new(name: name.to_s, ip: node['ip'].to_s, unstaked_identity: unstaked)
      end
      duplicate = nodes.group_by(&:ip).find { |_, same| same.size > 1 }
      raise ConfigError, "nodes #{duplicate[1].map(&:name).join(' and ')} share ip #{duplicate[0]}" if duplicate

      nodes
    end

    def pubkey!(settings, key, prefix = '')
      value = settings[key].to_s
      raise ConfigError, "#{prefix}#{key} is missing" if value.empty?
      raise ConfigError, "#{prefix}#{key} is not a base58 public key: #{value.inspect}" unless value.match?(PUBKEY)

      value
    end

    def positive_integer!(settings, key)
      value = settings[key]
      raise ConfigError, "#{key} must be a positive integer, got #{value.inspect}" unless value.is_a?(Integer) && value.positive?

      value
    end

    def url!(value, key)
      uri = URI.parse(value.to_s)
      raise ConfigError, "#{key}: #{value.to_s.inspect} is not an http(s) URL" unless uri.is_a?(URI::HTTP) && uri.host

      value.to_s
    rescue URI::InvalidURIError
      raise ConfigError, "#{key}: #{value.to_s.inspect} is not an http(s) URL"
    end

    def blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
