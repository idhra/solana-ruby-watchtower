# frozen_string_literal: true

module Solana::Ruby::Watchtower
  # Where CheckStates live between runs. A store answers #fetch(key), returning a
  # CheckState (a fresh one for a key it has never seen), and #save(state).
  module Stores
    # Lost on restart, so a restart forgets an alert that is firing and fires it
    # again. For tests and one-off runs; the daemon uses FileStore.
    class MemoryStore
      def initialize
        @states = {}
        @lock = Mutex.new
      end

      def fetch(key)
        @lock.synchronize do
          hash = @states[key.to_s]
          hash ? CheckState.from_h(hash) : CheckState.new(key: key)
        end
      end

      def save(state)
        @lock.synchronize { @states[state.key] = Marshal.load(Marshal.dump(state.to_h)) }
      end

      def all = @lock.synchronize { @states.values.map { |h| CheckState.from_h(h) } }
    end
  end
end
