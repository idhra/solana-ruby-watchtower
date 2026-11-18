# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module Solana::Ruby::Watchtower
  # Where alerts go. A notifier answers #deliver(text) with true when the text
  # was delivered and false when it was not, in which case the monitor offers
  # the alert again on the next run. Notifiers never raise.
  module Notifiers
    # Builds the notifiers named under `notify:` in the config. With none
    # configured, alerts are only logged.
    def self.build(settings, logger:)
      notifiers = settings.map do |kind, options|
        options ||= {}
        case kind.to_s
        when 'telegram' then Telegram.new(bot_token: options['bot_token'], chat_id: options['chat_id'], logger: logger)
        when 'webhook'  then Webhook.new(url: options['url'], logger: logger)
        else raise ConfigError, "notify.#{kind}: unknown notifier (telegram or webhook)"
        end
      end
      return Log.new(logger) if notifiers.empty?

      notifiers.size == 1 ? notifiers.first : Fanout.new(notifiers)
    end

    # Logs instead of sending. The fallback when nothing is configured.
    class Log
      def initialize(logger)
        @logger = logger
      end

      def deliver(text)
        @logger.warn("alert (no notifier configured): #{text}")
        true
      end
    end

    class Telegram
      def initialize(bot_token:, chat_id:, logger:)
        raise ConfigError, 'notify.telegram.bot_token is empty' if bot_token.to_s.strip.empty?
        raise ConfigError, 'notify.telegram.chat_id is empty' if chat_id.to_s.strip.empty?

        @uri     = URI("https://api.telegram.org/bot#{bot_token}/sendMessage")
        @chat_id = chat_id.to_s
        @logger  = logger
      end

      def deliver(text)
        response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) do |http|
          http.post(@uri.path, URI.encode_www_form(chat_id: @chat_id, text: text, disable_web_page_preview: true))
        end
        return true if response.is_a?(Net::HTTPSuccess)

        @logger.error("Telegram answered #{response.code}: #{response.body.to_s[0, 200]}")
        false
      rescue StandardError => e
        # The class only: a connection error can quote the URL, and the bot token is in it.
        @logger.error("Telegram send failed: #{e.class}")
        false
      end
    end

    # POSTs JSON to a webhook. The text is sent as both `text` (Slack) and
    # `content` (Discord); each ignores the other's field.
    class Webhook
      def initialize(url:, logger:)
        @uri = URI.parse(url.to_s)
        raise ConfigError, 'notify.webhook.url is not an http(s) URL' unless @uri.is_a?(URI::HTTP) && @uri.host

        @logger = logger
      end

      def deliver(text)
        response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == 'https', open_timeout: 5, read_timeout: 10) do |http|
          http.post(@uri.request_uri, JSON.generate(text: text, content: text), 'Content-Type' => 'application/json')
        end
        return true if response.is_a?(Net::HTTPSuccess)

        @logger.error("webhook #{@uri.host} answered #{response.code}")
        false
      rescue StandardError => e
        @logger.error("webhook #{@uri.host} send failed: #{e.class}")
        false
      end
    end

    # Sends to every notifier. Delivered only when all of them took it, so a
    # channel that failed gets the alert again, at the cost of a repeat on the
    # channels that did not fail: a duplicate is cheaper than a missed alert.
    class Fanout
      def initialize(notifiers)
        @notifiers = notifiers
      end

      def deliver(text) = @notifiers.map { |n| n.deliver(text) }.all?
    end
  end
end
