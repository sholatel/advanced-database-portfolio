# Portfolio 3: Transactions and Concurrency

> **Status:** planned (milestones M7–M8). This README is a placeholder and will be completed with "how it was implemented" and "how it was tested" sections.

## Purpose
Show that OwoRail's money movement is **ACID**. A wallet transfer function commits, rolls back, uses savepoints, handles duplicate requests through an idempotency key, and reverses transactions atomically. Then reproduce concurrency problems (non-repeatable read, lost update, deadlock) and the mechanisms that control them (row locks, isolation levels, ordered locking).

## Required evidence
- [ ] Transaction examples showing commit
- [ ] Rollback
- [ ] Isolation
- [ ] Concurrency issue or control mechanism
- [ ] Screenshots / output evidence

## Planned contents
| Path | Contents | Milestone |
|---|---|---|
| `sql/` | `transfer_funds()` function; commit, rollback, savepoint and reversal demos | M7 |
| `scripts/` | Two-connection Python concurrency demos with timestamped logs | M8 |
| `manual-two-terminal-guides/` | Step-by-step scripts to replay each scenario in two terminals | M8 |
| `evidence/` | Captured outputs and screenshots | M7–M8 |
