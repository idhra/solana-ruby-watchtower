# frozen_string_literal: true

require 'logger'
require 'optparse'

module Solana::Ruby::Watchtower
  # solana-watchtower COMMAND [options]
  #
  #   run                  run the checks on their intervals until SIGINT/SIGTERM
  #   check votes|gossip   run one check once and exit (for cron or a systemd timer)
  #   status               print each check's stored state
  #   notify-test          send a test message through the configured notifiers
  class CLI
    USAGE = <<~TEXT
      Usage: solana-watchtower COMMAND [options]

      Commands:
        run                  run the checks on their intervals until SIGINT/SIGTERM
        check votes|gossip   run one check once and exit
        status               print each check's stored state
        notify-test          send a test message through the configured notifiers

      Options:
    TEXT

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out  = out
      @err  = err
      @config_path = ENV.fetch('WATCHTOWER_CONFIG', 'watchtower.yml')
      @log_level   = Logger::INFO
    end

    # Returns the process exit status.
    def run
      parser.parse!(@argv)
      command = @argv.shift
      case command
      when 'run'         then run_forever
      when 'check'       then check_once(@argv.shift)
      when 'status'      then status
      when 'notify-test' then notify_test
      when nil           then @err.puts(parser.help) || 2
      else
        @err.puts "unknown command #{command.inspect}\n\n#{parser.help}"
        2
      end
    rescue ConfigError, OptionParser::ParseError => e
      @err.puts "solana-watchtower: #{e.message}"
      2
    end

    private

    def parser
      @parser ||= OptionParser.new do |o|
        o.banner = USAGE
        o.on('-c', '--config FILE', "config file (default: $WATCHTOWER_CONFIG or #{@config_path})") { |v| @config_path = v }
        o.on('-v', '--verbose', 'log every check result, not just alerts') { @log_level = Logger::DEBUG }
        o.on('--version', 'print the version') do
          @out.puts VERSION
          exit 0
        end
      end
    end

    def config
      raise ConfigError, "config file #{@config_path} not found (pass --config)" unless File.exist?(@config_path)

      @config ||= Config.load(@config_path)
    end

    def logger
      @logger ||= Logger.new(@out, progname: 'solana-watchtower', level: @log_level).tap do |l|
        l.formatter = proc { |sev, time, _, msg| "#{time.utc.strftime('%FT%TZ')} #{sev} #{msg}\n" }
      end
    end

    def monitor = @monitor ||= Monitor.new(config, logger: logger)

    def run_forever
      runner = Runner.new(monitor, logger: logger,
                                   votes_every: config.votes_interval_seconds,
                                   gossip_every: config.gossip_interval_seconds)
      %w[INT TERM].each { |signal| trap(signal) { runner.stop! } }
      logger.info("watching #{config.name}: vote account #{config.vote_account}, " \
                  "nodes #{config.nodes.map(&:name).join(', ')}, via #{config.rpc_urls.map { |u| URI(u).host }.join(', ')}")
      runner.run
      logger.info('stopped')
      0
    end

    def check_once(check)
      raise ConfigError, "check needs one of: #{Monitor::CHECKS.join(', ')}" unless Monitor::CHECKS.include?(check)

      monitor.run(check)
      print_states(monitor.store.all.select { |s| belongs_to?(s.key, check) })
      0
    end

    def status
      print_states(Stores::FileStore.new(config.state_file).all)
      0
    end

    def notify_test
      notifier = Notifiers.build(config.notify, logger: logger)
      if notifier.deliver("[#{config.name}] ✅ solana-watchtower test message")
        @out.puts 'delivered'
        0
      else
        @err.puts 'delivery failed, see the log above'
        1
      end
    end

    def belongs_to?(key, check)
      check == 'votes' ? %w[rpc:votes voting vote_identity].include?(key) : !%w[rpc:votes voting vote_identity].include?(key)
    end

    def print_states(states)
      if states.empty?
        @out.puts "no state yet in #{config.state_file}"
        return
      end
      width = states.map { |s| s.key.size }.max
      states.sort_by(&:key).each do |s|
        flag = s.alerting? ? 'ALERT' : (s.consecutive_failures.positive? ? 'fail ' : 'ok   ')
        @out.puts "#{flag}  #{s.key.ljust(width)}  #{s.last_message}"
      end
    end
  end
end
