---
title: Usage evidence files — the shared capacity substrate
description: Where per-silo usage data lives, how it is refreshed, staleness handling, and the two consumers (rota gateway + handoff planner).
status: reference
---

# Usage evidence files

Every routing decision in the farm — the `rota` virtual model and the `lib/handoff-plan.ts` planner — reads the same underlying data: per-silo usage evidence. This doc describes that data plane so both consumers stay consistent.

## Location

```
~/.claude-farm/usage/<silo>/claude.json
```

One file per silo/account. It records the consumed/remaining state that the three-bucket capacity model (session, weekly-all-model, weekly-model) is computed from.

## Refresh mechanism

The files are kept current by the desktop app's OAuth ping:

- **Manual**: Crew → **Refresh**.
- **Automatic**: a **90-second heartbeat** while the app is running.

If the app is not running, the files go stale — consumers must treat staleness explicitly (below).

## Consumers

### 1. Rota gateway (`docs/rota-gateway.md`)

Scores each silo:

```
score = min(session remaining, max(weekly remaining − 10% reserve, 0))
      + 0.12 sticky bonus if this silo served the previous request
```

- A silo with **no usage evidence** scores a conservative **0.5** — usable, but never preferred over a silo with proven headroom.
- The winning pick is persisted to `~/.claude-farm/rota.json`; handoffs are logged in `gateway.log`.

### 2. Handoff planner (`lib/handoff-plan.ts` v2)

Computes `usableNow = min(session, weeklyOverall, weeklyModel)` per lane and applies expiry pressure. See `docs/availability-scheduling.md` and `docs/capacity-scheduling-implementation.md`.

## Staleness & missing-data rules

- **Missing file / unreported silo** → conservative default (rota uses 0.5; the planner treats it as low-confidence).
- **Stale file** (app not running / heartbeat lapsed) → the numbers reflect the last ping, not now. Prefer refreshing before a large routing decision.
- Safety reserves (8–20% by account confidence) sit on top of whatever these files report — they are not a substitute for fresh data.

## Why one substrate

Both consumers reading the same files means a Crew Refresh improves routing everywhere at once, and there is a single format to reason about when debugging why a silo was or wasn't picked.
