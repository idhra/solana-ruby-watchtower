# frozen_string_literal: true

require 'net/http'
require 'uri'

module Solana::Ruby::Watchtower
  # A dead-man's switch: GETs a URL (healthchecks.io, Uptime Kuma, Better Stack
  # and the like) after every completed vote check. When the monitor dies, hangs
  # or loses its network, the pings stop and that service raises the alarm,
  # which nothing inside the monitor can do for itself.
  class Heartbeat
    def initialize(url, logger:)
      @uri    = URI.parse(url)
      @logger = logger
    end

    def ping
      Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == 'https', open_timeout: 5, read_timeout: 5) do |http|
        http.get(@uri.request_uri)
      end
      true
    rescue StandardError => e
      @logger.error("heartbeat ping to #{@uri.host} failed: #{e.class}")
      false
    end
  end
end
