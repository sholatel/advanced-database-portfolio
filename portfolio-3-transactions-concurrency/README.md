# Portfolio 3: Transactions and Concurrency (7 marks)

> **Status:** planned (milestones M7–M8). This README is a placeholder and will be completed with "how it was implemented" and "how it was tested" sections.

## Purpose
Show that OwoRail's money movement is **ACID**. A wallet transfer function commits, rolls back, uses savepoints, handles duplicate requests through an idempotency key, and reverses transactions atomically. Then reproduce concurrency problems (non-repeatable read, lost update, deadlock) and the mechanisms that control them (row locks, isolation levels, ordered locking).

## Required evidence (CA §4)
- [ ] Transaction examples showing commit
- [ ] Rollback
- [ ] Isolation
- [ ] Concurrency issue or control mechanism
- [ ] Screenshots / output evidence

## Course concepts applied
- §2.2.1 CAP Theorem, DBASE vs ACID Models (ACID properties)
- §1.1.6 Characteristics of a Good Database (consistency, concurrency control)
- §1.1.8 Limitations of Traditional DBMS (concurrency and locking issues, deadlocks)
- §4.1.3 Query Execution Plans and Cost Estimation (synchronisation across sites, two-phase commit), used for the bridge to distributed transactions
- Supplementary (PostgreSQL documentation): MVCC snapshots, isolation levels, `SELECT … FOR UPDATE`, serialisation failures, deadlock detection

## Planned contents
| Path | Contents | Milestone |
|---|---|---|
| `sql/` | `transfer_funds()` function; commit, rollback, savepoint and reversal demos | M7 |
| `scripts/` | Two-connection Python concurrency demos with timestamped logs | M8 |
| `manual-two-terminal-guides/` | Step-by-step scripts to replay each scenario in two terminals | M8 |
| `evidence/` | Captured outputs and screenshots | M7–M8 |
