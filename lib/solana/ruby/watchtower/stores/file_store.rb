# frozen_string_literal: true

require 'fileutils'
require 'json'

module Solana::Ruby::Watchtower
  module Stores
    # All states in one JSON file, rewritten atomically on every save, so a
    # restart neither repeats an alert already sent nor forgets one that is
    # firing. Meant for a single monitor process.
    class FileStore
      def initialize(path)
        @path = path
        @lock = Mutex.new
        @states = read
      end

      attr_reader :path

      def fetch(key)
        @lock.synchronize do
          hash = @states[key.to_s]
          hash ? CheckState.from_h(hash) : CheckState.new(key: key)
        end
      end

      def save(state)
        @lock.synchronize do
          @states[state.key] = JSON.parse(JSON.generate(state.to_h))
          write
        end
      end

      def all = @lock.synchronize { @states.values.map { |h| CheckState.from_h(h) } }

      private

      def read
        return {} unless File.exist?(@path)

        JSON.parse(File.read(@path))
      rescue JSON::ParserError => e
        # Starting over costs a repeated alert; refusing to start costs the monitor.
        warn "solana-watchtower: #{@path} is not valid JSON (#{e.message}); starting with empty state"
        {}
      end

      def write
        FileUtils.mkdir_p(File.dirname(@path))
        tmp = "#{@path}.tmp"
        File.write(tmp, JSON.pretty_generate(@states))
        File.rename(tmp, @path)
      end
    end
  end
end
