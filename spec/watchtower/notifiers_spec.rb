# frozen_string_literal: true

RSpec.describe Watchtower::Notifiers do
  let(:log) { StringIO.new }
  let(:logger) { Logger.new(log) }
  let(:telegram_url) { 'https://api.telegram.org/bot123:TOKEN/sendMessage' }

  describe 'Telegram' do
    let(:telegram) { described_class::Telegram.new(bot_token: '123:TOKEN', chat_id: '-100', logger: logger) }

    it 'sends the text to the chat' do
      stub = stub_request(:post, telegram_url).with(body: hash_including('chat_id' => '-100', 'text' => 'hello'))
      expect(telegram.deliver('hello')).to be(true)
      expect(stub).to have_been_requested
    end

    it 'reports a rejected message as undelivered' do
      stub_request(:post, telegram_url).to_return(status: 400, body: 'chat not found')
      expect(telegram.deliver('hello')).to be(false)
      expect(log.string).to include('400', 'chat not found')
    end

    it 'never logs the token when the connection fails' do
      stub_request(:post, telegram_url).to_raise(SocketError.new("Failed to open TCP connection to #{telegram_url}"))
      expect(telegram.deliver('hello')).to be(false)
      expect(log.string).not_to include('TOKEN')
    end

    it 'refuses an empty token at startup' do
      expect { described_class::Telegram.new(bot_token: '', chat_id: '1', logger: logger) }
        .to raise_error(Watchtower::ConfigError, /bot_token is empty/)
    end
  end

  describe 'Webhook' do
    it 'posts the text as both Slack and Discord fields' do
      stub = stub_request(:post, 'https://hooks.example/x').with(body: { text: 'hi', content: 'hi' }.to_json)
      expect(described_class::Webhook.new(url: 'https://hooks.example/x', logger: logger).deliver('hi')).to be(true)
      expect(stub).to have_been_requested
    end
  end

  describe '.build' do
    it 'falls back to logging when nothing is configured' do
      notifier = described_class.build({}, logger: logger)
      expect(notifier.deliver('alert!')).to be(true)
      expect(log.string).to include('alert!')
    end

    it 'fans out to several, delivered only when all took it' do
      stub_request(:post, telegram_url)
      stub_request(:post, 'https://hooks.example/x').to_return(status: 500)
      notifier = described_class.build({ 'telegram' => { 'bot_token' => '123:TOKEN', 'chat_id' => '-100' },
                                         'webhook' => { 'url' => 'https://hooks.example/x' } }, logger: logger)
      expect(notifier.deliver('x')).to be(false)
      expect(a_request(:post, telegram_url)).to have_been_made
    end

    it 'rejects an unknown notifier' do
      expect { described_class.build({ 'pager' => {} }, logger: logger) }.to raise_error(Watchtower::ConfigError, /unknown notifier/)
    end
  end
end

RSpec.describe Watchtower::Heartbeat do
  it 'pings the URL, and a failure is logged but harmless' do
    stub_request(:get, 'https://hc.example/ping/abc').to_return({ status: 200 }, { status: 503 }).then.to_raise(SocketError)
    heartbeat = described_class.new('https://hc.example/ping/abc', logger: Logger.new(File::NULL))
    expect(heartbeat.ping).to be(true)
    expect(heartbeat.ping).to be(true) # a non-2xx still reached the service
    expect(heartbeat.ping).to be(false)
  end
end
