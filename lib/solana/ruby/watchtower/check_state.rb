# frozen_string_literal: true

require 'time'

module Solana::Ruby::Watchtower
  # The alert state of one check.
  #
  # #observe records a result and says whether it calls for a message;
  # #acknowledge records that the message went out. They are separate so that an
  # alert the notifier failed to deliver is offered again on the next run
  # instead of being marked as sent.
  class CheckState
    Alert = Data.define(:kind, :key, :text) # kind: :firing, :reminder or :resolved

    ATTRIBUTES = %i[key alerting consecutive_failures failing_since last_alerted_at last_checked_at last_message data].freeze
    TIMES      = %i[failing_since last_alerted_at last_checked_at].freeze

    attr_accessor(*ATTRIBUTES)

    def initialize(key:, alerting: false, consecutive_failures: 0, failing_since: nil, last_alerted_at: nil,
                   last_checked_at: nil, last_message: nil, data: {})
      @key                  = key.to_s
      @alerting             = alerting ? true : false
      @consecutive_failures = consecutive_failures.to_i
      @failing_since        = time(failing_since)
      @last_alerted_at      = time(last_alerted_at)
      @last_checked_at      = time(last_checked_at)
      @last_message         = last_message
      @data                 = data || {}
    end

    def self.from_h(hash)
      new(**hash.transform_keys(&:to_sym).slice(*ATTRIBUTES))
    end

    # Times as ISO 8601 strings, ready for JSON.
    def to_h
      ATTRIBUTES.to_h do |attr|
        value = public_send(attr)
        [attr, TIMES.include?(attr) && value ? value.utc.iso8601 : value]
      end
    end

    def alerting? = @alerting

    def observe(ok:, message:, now:, failures_to_alert:, realert_after:)
      self.last_message    = message
      self.last_checked_at = now

      if ok
        self.consecutive_failures = 0
        # Kept until the recovery message is sent: it is what that message reports.
        self.failing_since = nil unless alerting?
        return unless alerting?

        return Alert.new(kind: :resolved, key: key, text: "✅ RESOLVED #{key}: #{message} (failing #{since(now)})")
      end

      self.consecutive_failures += 1
      self.failing_since ||= now
      return if consecutive_failures < failures_to_alert

      if !alerting?
        Alert.new(kind: :firing, key: key, text: "🚨 #{key}: #{message}")
      elsif last_alerted_at.nil? || now - last_alerted_at >= realert_after
        Alert.new(kind: :reminder, key: key, text: "🚨 STILL FAILING #{key} (#{since(now)}): #{message}")
      end
    end

    def acknowledge(alert, now)
      if alert.kind == :resolved
        self.alerting        = false
        self.failing_since   = nil
        self.last_alerted_at = nil
      else
        self.alerting        = true
        self.last_alerted_at = now
      end
    end

    private

    def since(now)
      return 'briefly' if failing_since.nil?

      minutes = ((now - failing_since) / 60).round
      "since #{failing_since.utc.strftime('%H:%M')} UTC, #{minutes} min"
    end

    def time(value)
      case value
      when nil    then nil
      when String then Time.iso8601(value)
      else value.to_time
      end
    end
  end
end
