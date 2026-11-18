# frozen_string_literal: true

require_relative 'lib/solana/ruby/watchtower/version'

Gem::Specification.new do |spec|
  spec.name                  = 'solana-ruby-watchtower'
  spec.version               = Solana::Ruby::Watchtower::VERSION
  spec.authors               = ['Paul Zupan, Idhra Inc.']
  spec.summary               = 'Off-box monitor for Solana validators, including active/standby HA pairs'
  spec.description           = <<~DESC
    Watches a Solana validator from the cluster's side, the way agave-watchtower
    does, and adds the checks an active/standby pair needs: each node present in
    gossip, the staked identity on a known host, and the staked identity
    advertised by two nodes at once. Alerts go to Telegram or a webhook (Slack or
    Discord) once, again while a problem lasts, and when it clears.
  DESC
  spec.homepage              = 'https://github.com/idhra/solana-ruby-watchtower'
  spec.license               = 'MIT'
  spec.required_ruby_version = '>= 3.2.0'
  spec.require_paths         = ['lib']
  spec.bindir                = 'exe'
  spec.executables           = ['solana-watchtower']

  spec.metadata = {
    'source_code_uri'       => "#{spec.homepage}/tree/main",
    'bug_tracker_uri'       => "#{spec.homepage}/issues",
    'changelog_uri'         => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'examples/*'] +
               ['LICENSE', 'README.md', 'CHANGELOG.md', 'solana-ruby-watchtower.gemspec']
  spec.extra_rdoc_files = ['LICENSE', 'README.md']

  # Runtime is the standard library only (net/http, json, yaml), so an operator
  # can run it on a small box without libsodium or a Solana SDK. logger leaves
  # the default gems in Ruby 3.5, hence the explicit dependency.
  spec.add_dependency 'logger', '~> 1.6'

  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'webmock', '~> 3.26'
end
