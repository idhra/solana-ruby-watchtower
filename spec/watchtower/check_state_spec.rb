# frozen_string_literal: true

RSpec.describe Watchtower::CheckState do
  let(:t0) { Time.utc(2026, 11, 18, 12, 0, 0) }
  let(:state) { described_class.new(key: 'voting') }

  def observe(ok, at, failures_to_alert: 2)
    state.observe(ok: ok, message: ok ? 'fine' : 'bad', now: at, failures_to_alert: failures_to_alert, realert_after: 30 * 60)
  end

  def fire!
    observe(false, t0)
    state.acknowledge(observe(false, t0 + 30), t0 + 30)
  end

  it 'says nothing while healthy' do
    expect(observe(true, t0)).to be_nil
  end

  it 'fires only after enough consecutive failures' do
    expect(observe(false, t0)).to be_nil
    alert = observe(false, t0 + 30)
    expect(alert.kind).to eq(:firing)
    expect(alert.text).to include('voting: bad')
  end

  it 'starts the count again after a good result' do
    observe(false, t0)
    observe(true, t0 + 30)
    expect(observe(false, t0 + 60)).to be_nil
  end

  it 'reminds while still failing, but not on every run' do
    fire!
    expect(observe(false, t0 + 60)).to be_nil
    expect(observe(false, t0 + (29 * 60))).to be_nil
    alert = observe(false, t0 + (31 * 60))
    expect(alert.kind).to eq(:reminder)
    expect(alert.text).to include('since 12:00 UTC')
  end

  it 'reports recovery once, with how long it lasted' do
    fire!
    alert = observe(true, t0 + 600)
    expect(alert.kind).to eq(:resolved)
    expect(alert.text).to include('since 12:00 UTC, 10 min')
    state.acknowledge(alert, t0 + 600)

    expect(observe(true, t0 + 660)).to be_nil
    expect(state).not_to be_alerting
    expect(state.failing_since).to be_nil
  end

  it 'offers an undelivered alert again' do
    observe(false, t0)
    expect(observe(false, t0 + 30).kind).to eq(:firing)
    expect(observe(false, t0 + 60).kind).to eq(:firing)
  end

  it 'offers an undelivered recovery again' do
    fire!
    expect(observe(true, t0 + 60).kind).to eq(:resolved)
    expect(observe(true, t0 + 90).kind).to eq(:resolved)
  end

  it 'round-trips through a hash with ISO 8601 times' do
    fire!
    state.data = { 'ip' => '1.2.3.4' }
    copy = described_class.from_h(JSON.parse(JSON.generate(state.to_h)))
    expect(copy.to_h).to eq(state.to_h)
    expect(copy.failing_since).to eq(t0)
  end
end
