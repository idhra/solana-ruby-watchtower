# frozen_string_literal: true

require 'json'
require 'net/http'
require 'openssl'
require 'uri'

module Solana::Ruby::Watchtower
  # A minimal JSON-RPC client for one endpoint.
  #
  # Short timeouts and a single retry: a check runs every 30 seconds, so a slow
  # endpoint is better skipped in favour of the next one than waited on.
  class Rpc
    class Error < Solana::Ruby::Watchtower::Error; end

    TRANSIENT = [Timeout::Error, IOError, EOFError, SystemCallError, SocketError, OpenSSL::SSL::SSLError].freeze

    attr_reader :label

    def initialize(url, timeout: 10, open_timeout: 5, attempts: 2, sleeper: ->(s) { sleep(s) })
      @uri          = URI.parse(url)
      @timeout      = timeout
      @open_timeout = open_timeout
      @attempts     = attempts
      @sleeper      = sleeper
      @id           = 0
      # Host only: providers put API keys in the path or query string, and the
      # label ends up in alerts and logs.
      @label = @uri.host || 'rpc'
    end

    def call(method, params = [])
      attempt = 0
      begin
        attempt += 1
        post(method, params)
      rescue *TRANSIENT, RetryableHttp => e
        if attempt < @attempts
          @sleeper.call(1)
          retry
        end
        raise Error, describe(e)
      end
    end

    private

    # 429 and 5xx are worth a second try; any other HTTP status is not.
    class RetryableHttp < StandardError; end

    def post(method, params)
      @id += 1
      body = JSON.generate(jsonrpc: '2.0', id: @id, method: method, params: params)
      response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == 'https',
                                                       open_timeout: @open_timeout, read_timeout: @timeout) do |http|
        http.post(@uri.request_uri, body, 'Content-Type' => 'application/json')
      end

      code = response.code.to_i
      raise RetryableHttp, "HTTP #{code}" if code == 429 || code >= 500
      raise Error, "HTTP #{code}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body.to_s)
      if parsed['error']
        raise Error, "RPC error #{parsed['error']['code']}: #{parsed['error']['message']}"
      end

      parsed.fetch('result') { raise Error, 'response has no result' }
    rescue JSON::ParserError
      raise Error, 'response is not JSON'
    end

    # The class and message, never a URL: some exceptions quote the request
    # line, and the API key may be in it.
    def describe(error)
      return error.message if error.is_a?(RetryableHttp)

      "#{error.class.name.split('::').last}: #{error.message.gsub(@uri.to_s, @label)}"
    end
  end

  # Endpoints tried in order; the first to answer wins.
  class RpcPool
    class AllFailed < Solana::Ruby::Watchtower::Error; end

    Answer = Data.define(:value, :label)

    def self.from_urls(urls, timeout: 10)
      new(urls.map { |url| Rpc.new(url, timeout: timeout) })
    end

    # clients respond to #label and #call(method, params).
    def initialize(clients)
      raise ArgumentError, 'no RPC endpoints' if clients.empty?

      @clients = clients
    end

    # Yields each client until one gets through the block without raising, and
    # returns its result. Raises AllFailed naming every endpoint's error.
    def first_answer
      errors = []
      @clients.each do |client|
        return Answer.new(value: yield(client), label: client.label)
      rescue StandardError => e
        errors << "#{client.label}: #{e.message}"
      end
      raise AllFailed, errors.join('; ')
    end
  end
end
