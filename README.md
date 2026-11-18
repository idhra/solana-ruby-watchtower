# solana-ruby-watchtower

An off-box monitor for a Solana validator, built for **active/standby HA pairs**.

`agave-watchtower` tells you when your vote account goes delinquent. With a
failover pair, that isn't enough. The failover daemon's own alerts fire on a
role change, so they stay silent in the cases that matter most:

- the active node dies and the standby can't take over,
- both nodes end up running the staked identity,
- the failover daemon has lost its RPC and is quietly doing nothing.

This gem watches the validator from the cluster's side, over RPC, from a machine
that is not one of your nodes. It checks the vote account and also the gossip
table, so it can see each node and which identity it's running.

It depends only on the Ruby standard library.

## What it checks

| Check | Every | Alerts when |
|---|---|---|
| `voting` | 30 s | Last vote more than `max_vote_lag_slots` (100) behind the tip, or delinquent, for 2 checks in a row |
| `vote_identity` | 30 s | The vote account points at an identity other than `identity` |
| `rpc:votes`, `rpc:gossip` | each run | Every RPC endpoint failed (4 in a row for votes). "Couldn't ask" is never reported as "down" |
| `node:<name>` | 2 min | A node is missing from gossip, or it's running a key that is neither the staked identity nor its own standby key |
| `staked:gossip` | 2 min | The staked identity is missing from gossip, or it's gossiping from an IP that isn't one of your nodes |
| `staked:location` | 2 min | The staked identity's gossip address flipped between hosts 2+ times in 15 min, which suggests **two nodes running the staked identity** |

A single change of the staked identity's address is a normal role switch. It
gets an informational message, not an alert.

Every alert is sent once when the check goes bad. It's repeated every
`realert_minutes` (30) while the check stays bad, and followed by ✅ RESOLVED
when it clears. Each message starts with `[name]`, so one chat can serve
several validators. If the notifier fails, the alert is offered again on the
next run.

## Install

```bash
gem install solana-ruby-watchtower
```

Requires Ruby 3.2 or newer.

## Configure

Copy [`examples/watchtower.yml`](examples/watchtower.yml) and fill it in:

```yaml
name: my-validator
vote_account: <vote account pubkey>
identity: <staked identity pubkey>
nodes:
  node-1: { ip: 203.0.113.10, unstaked_identity: <node-1 standby pubkey> }
  node-2: { ip: 203.0.113.20, unstaked_identity: <node-2 standby pubkey> }
rpc_urls:
  - https://api.mainnet-beta.solana.com
notify:
  telegram:
    bot_token: <%= ENV['TELEGRAM_BOT_TOKEN'] %>
    chat_id: <%= ENV['TELEGRAM_CHAT_ID'] %>
heartbeat_url: https://hc-ping.com/<uuid>
```

- **nodes**: every machine that may run the staked identity, keyed by the IP
  it gossips from. `unstaked_identity` is the key the node runs while it is the
  standby. Leave it out for a single node with no standby.
- **rpc_urls**: tried in order, first answer wins. **Use providers your
  failover tooling does not use.** If both rely on the same provider, one
  outage or rate limit blinds them together.
- **notify**: `telegram` and/or `webhook` (`url:`, works with Slack and
  Discord incoming webhooks). With neither, alerts are only logged.
- **heartbeat_url**: a dead-man's switch such as healthchecks.io, Uptime Kuma or
  Better Stack. It's pinged after every vote check. Without it, a monitor that
  dies takes its alerts down with it.

The file goes through ERB, so secrets can stay in the environment. Every value
is validated at startup; a bad config exits with status 2 and a message.

## Run

```bash
solana-watchtower notify-test -c watchtower.yml   # check the alert channel first
solana-watchtower check votes -c watchtower.yml   # one check, prints the results
solana-watchtower run -c watchtower.yml           # run until SIGINT/SIGTERM
solana-watchtower status -c watchtower.yml        # stored state of every check
```

The `run` command keeps each check's state in `state_file` (JSON, written
atomically), so after a restart it neither repeats alerts already sent nor
forgets one that is firing. `-v` logs every check result.

For systemd, see [`examples/solana-watchtower.service`](examples/solana-watchtower.service).

**Where to run it:** anywhere except your validator nodes, and ideally not with
the same hosting provider. A small VPS is plenty. Each gossip check downloads
the full cluster node list (about 1.5 MB), which comes to roughly 1 GB a day.

## Inside a Rails app

If you already run a Rails app with a job scheduler, you can run the checks as
jobs and keep their state in a table.

```ruby
# db/migrate/xxx_create_watchtower_checks.rb
create_table :watchtower_checks do |t|
  t.string   :key, null: false
  t.boolean  :alerting, null: false, default: false
  t.integer  :consecutive_failures, null: false, default: 0
  t.datetime :failing_since
  t.datetime :last_alerted_at
  t.datetime :last_checked_at
  t.text     :last_message
  t.jsonb    :data, null: false, default: {}
  t.timestamps
end
add_index :watchtower_checks, :key, unique: true
```

```ruby
# app/models/watchtower_check.rb
class WatchtowerCheck < ApplicationRecord; end

# app/jobs/watchtower_job.rb
class WatchtowerJob < ApplicationJob
  queue_as :watchtower
  # Solid Queue: drop a run that would overlap the previous one.
  limits_concurrency to: 1, key: ->(check) { "watchtower-#{check}" }, on_conflict: :discard

  def perform(check)
    Solana::Ruby::Watchtower::Monitor.new(
      Solana::Ruby::Watchtower::Config.load(Rails.root.join('config/watchtower.yml')),
      store:  Solana::Ruby::Watchtower::Stores::ActiveRecordStore.new(WatchtowerCheck),
      logger: Rails.logger
    ).run(check)
  end
end
```

```yaml
# config/recurring.yml (Solid Queue)
production:
  watchtower_votes:
    class: WatchtowerJob
    args: [ 'votes' ]
    schedule: every 30 seconds
  watchtower_gossip:
    class: WatchtowerJob
    args: [ 'gossip' ]
    schedule: every 2 minutes
```

A failing job never pings the heartbeat, so a crash loop is caught by the
heartbeat service the same way a dead process is.

## Limits

- **Double-active detection is a heuristic.** Gossip keeps one address per
  identity, the one pushed most recently. Two nodes holding the staked identity
  make that address flip, and the monitor sees it at its 2-minute sampling. A
  real failover followed by a failback within the window looks the same, and
  is worth hearing about anyway.
- **Gossip liveness is weak for the staked node.** The cluster keeps a staked
  identity's gossip entry for a long time after the node goes quiet. A dead
  active node is caught by the `voting` check, not by `node:<name>`. Standby
  (unstaked) entries expire quickly, so a dead standby is caught by gossip.
- **Public RPC rate-limits by IP.** On shared hosting egress you may see
  `rpc:*` alerts. Add a second endpoint to `rpc_urls`.

## Development

```bash
bundle install
bundle exec rspec
```

## License

MIT. See [LICENSE](LICENSE).
