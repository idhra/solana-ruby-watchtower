# Changelog

## 0.1.0 (unreleased)

First release, extracted from the monitor built for Idhra's mainnet validator pair.

- Checks: vote lag and delinquency, vote-account identity, RPC reachability,
  each node in gossip, staked identity on a known host, staked identity
  advertised by two nodes (possible double-active).
- Alerts once, reminds while failing, reports recovery; an undelivered alert is
  retried on the next run.
- Notifiers: Telegram, webhook (Slack/Discord), log. Optional heartbeat URL.
- State stores: memory, JSON file, ActiveRecord.
- `solana-watchtower` CLI: `run`, `check`, `status`, `notify-test`.
