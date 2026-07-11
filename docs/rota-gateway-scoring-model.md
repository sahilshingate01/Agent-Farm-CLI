---
title: Rota gateway routing and scoring model
description: The scoring formula, evidence sources, and stickiness behavior that decide which silo the virtual `rota` model burns for each request.
---

# Rota gateway routing and scoring model

The local gateway's virtual model `rota` (alias `auto`) scores every Claude silo per request and routes to the winner. The portable `farmd` service owns the separate heterogeneous `crew` model. This is the runtime companion to the three-bucket availability doctrine: the doctrine decides *usable capacity*, the rota turns that into a *per-request pick*.

## The score

```
score = min(session remaining, max(weekly remaining − 10% reserve, 0))
      + 0.12 sticky bonus if this silo served the previous request
```

- **`min(session remaining, weekly remaining − reserve)`** — the healthiest lane by remaining headroom, protecting a 10% weekly reserve so a silo is never drained to zero.
- **`+0.12 sticky bonus`** — keeps consecutive requests on the silo that served the previous one, preserving warm context and prompt cache until another lane is meaningfully healthier.

## Evidence sources

- Usage numbers come from `~/.claude-farm/usage/<silo>/claude.json` — the same files the app's OAuth ping refreshes (Crew → Refresh, or the 90s heartbeat while the app runs).
- A silo with **no usage report** scores a conservative **0.5**: usable, but never preferred over a silo with proven headroom.

## State and observability

- **Current pick**: persisted at `~/.claude-farm/rota.json`.
- **Handoffs**: logged in `gateway.log`. To understand why a request landed where it did, correlate the log entry against the silo's `claude.json` at that time.

## Tuning notes

- Raising the 10% weekly reserve makes the rota more conservative near weekly limits; lowering it burns weekly capacity more aggressively.
- Raising the 0.12 sticky bonus increases lane stability (fewer switches, better cache hit rate) at the cost of slower rebalancing toward a healthier lane.
