# frozen_string_literal: true

module Solana::Ruby::Watchtower
  # Runs a Monitor's checks on their intervals until told to stop.
  #
  # Single-threaded on purpose: a check never overlaps the previous run of
  # itself, and a slow run delays the next one instead of piling up behind it.
  # A check that raises is logged and tried again on schedule; the vote check
  # then skips its heartbeat ping, which is how a crash loop gets noticed.
  class Runner
    def initialize(monitor, logger:, votes_every:, gossip_every:,
                   now: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(s) { sleep(s) })
      @monitor  = monitor
      @logger   = logger
      @schedule = { 'votes' => votes_every, 'gossip' => gossip_every }
      @now      = now
      @sleeper  = sleeper
      @stop     = false
    end

    def stop! = @stop = true

    def stopped? = @stop

    def run
      due = @schedule.keys.to_h { |check| [check, @now.call] }
      until @stop
        due.each do |check, at|
          break if @stop
          next if @now.call < at

          run_check(check)
          # From when it was due, so the cadence does not drift by each run's
          # duration; but never into the past after a long stall.
          due[check] = [at + @schedule[check], @now.call].max
        end
        # Short naps, so a stop is honoured within a second.
        wait = due.values.min - @now.call
        @sleeper.call([[wait, 1].min, 0.05].max) if wait.positive? && !@stop
      end
    end

    private

    def run_check(check)
      @monitor.run(check)
    rescue StandardError => e
      @logger.error("#{check} check crashed: #{e.class}: #{e.message}")
    end
  end
end
