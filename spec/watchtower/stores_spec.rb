# frozen_string_literal: true

RSpec.describe Watchtower::Stores::FileStore do
  around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

  let(:path) { File.join(@dir, 'nested', 'state.json') }

  it 'hands out a fresh state for an unknown key' do
    state = described_class.new(path).fetch('voting')
    expect([state.key, state.alerting?, state.consecutive_failures]).to eq(['voting', false, 0])
  end

  it 'survives a restart' do
    state = Watchtower::CheckState.new(key: 'voting', alerting: true, consecutive_failures: 3,
                                       failing_since: Time.utc(2026, 11, 18, 12), data: { 'ip' => '1.2.3.4' })
    described_class.new(path).save(state)

    reloaded = described_class.new(path).fetch('voting')
    expect(reloaded.to_h).to eq(state.to_h)
    expect(described_class.new(path).all.map(&:key)).to eq(['voting'])
  end

  it 'starts empty, with a warning, from a corrupt file' do
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, '{not json')
    store = nil
    expect { store = described_class.new(path) }.to output(/not valid JSON/).to_stderr
    expect(store.all).to be_empty
  end
end

RSpec.describe Watchtower::Stores::MemoryStore do
  it 'returns copies, so changes count only once saved' do
    store = described_class.new
    state = store.fetch('voting')
    state.consecutive_failures = 5
    expect(store.fetch('voting').consecutive_failures).to eq(0)
    store.save(state)
    expect(store.fetch('voting').consecutive_failures).to eq(5)
  end
end

RSpec.describe Watchtower::Stores::ActiveRecordStore do
  # A stand-in for an ActiveRecord model: just the calls the store makes.
  let(:model) do
    Class.new do
      attr_accessor(*Watchtower::CheckState::ATTRIBUTES)

      @rows = {}
      class << self
        attr_reader :rows

        def find_by(key:) = rows[key]
        def find_or_initialize_by(key:) = rows[key] || new.tap { |r| r.key = key }
        def order(_) = rows.values
      end

      def assign_attributes(attrs) = attrs.each { |k, v| public_send(:"#{k}=", v) }
      def save! = self.class.rows[key] = self
    end
  end

  it 'maps a state onto the columns and back' do
    store = described_class.new(model)
    state = Watchtower::CheckState.new(key: 'node:a', alerting: true, consecutive_failures: 1,
                                       last_alerted_at: Time.utc(2026, 11, 18), last_message: 'down', data: { 'x' => 1 })
    store.save(state)
    expect(store.fetch('node:a').to_h).to eq(state.to_h)
    expect(store.all.map(&:key)).to eq(['node:a'])
  end
end
