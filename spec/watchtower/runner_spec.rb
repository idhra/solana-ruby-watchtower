# frozen_string_literal: true

RSpec.describe Watchtower::Runner do
  # A clock that only moves when the runner sleeps.
  let(:clock) { [0.0] }
  let(:log) { StringIO.new }
  let(:runs) { [] }
  let(:monitor) { instance_double(Watchtower::Monitor) }
  let(:runner) do
    described_class.new(monitor, logger: Logger.new(log), votes_every: 30, gossip_every: 120,
                                 now: -> { clock[0] }, sleeper: ->(s) { clock[0] += s; runner.stop! if clock[0] >= 300 })
  end

  before do
    allow(monitor).to receive(:run) { |check| runs << [check, clock[0].round] }
  end

  it 'runs each check on its own interval' do
    runner.run
    expect(runs.select { |c, _| c == 'votes' }.map(&:last)).to eq([0, 30, 60, 90, 120, 150, 180, 210, 240, 270])
    expect(runs.select { |c, _| c == 'gossip' }.map(&:last)).to eq([0, 120, 240])
  end

  it 'logs a crashing check and keeps going' do
    allow(monitor).to receive(:run).with('gossip').and_raise(RuntimeError, 'boom')
    runner.run
    expect(log.string).to include('gossip check crashed: RuntimeError: boom')
    expect(runs.count { |c, _| c == 'votes' }).to eq(10)
  end
end
