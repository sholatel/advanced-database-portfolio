# Portfolio 3: Transactions and Concurrency

> **Status:** complete. 49 automated checks across transactions, isolation and locking, all passing; the analysis is in [concurrency-control.md](concurrency-control.md).

## Purpose
Show that OwoRail's money movement is **ACID**: postings commit or roll back as a whole, a failing step can be undone with a savepoint, and a committed transfer survives a crash. Then reproduce the classic concurrency problems (dirty, non-repeatable and phantom reads, lost updates, write skew, deadlocks) and show the mechanism that controls each one in PostgreSQL: MVCC snapshots, isolation levels, row locks and ordered locking. Finally, test the real posting function under concurrent load.

## Required evidence
- [x] Transaction examples showing commit: [m7_transactions.txt](evidence/m7_transactions.txt), T1
- [x] Rollback: T2 (ROLLBACK), T3 (error aborts the transaction), T4 (savepoints), T5 (atomic failure)
- [x] Isolation: [m8_isolation.txt](evidence/m8_isolation.txt), I1 to I4 at each isolation level
- [x] Concurrency issue or control mechanism: [m8_locking.txt](evidence/m8_locking.txt), L1 to L8
- [x] Screenshots / output evidence: the timelines in [evidence/](evidence/); [two-terminal-guide.md](two-terminal-guide.md) replays the main scenarios by hand for screenshots

## Contents
| Path | Contents |
|---|---|
| [scripts/transactions.py](scripts/transactions.py) | T1–T6: commit, rollback, an error inside a transaction, savepoints, statement atomicity, durability after a crash |
| [scripts/isolation.py](scripts/isolation.py) | I1–I4: dirty reads, non-repeatable reads, phantoms and write skew under each isolation level |
| [scripts/locking.py](scripts/locking.py) | L1–L8: lost update, `SELECT ... FOR UPDATE`, deadlock, ordered locking, and `post_transaction` under concurrent load |
| [scripts/lab.py](scripts/lab.py) | shared helpers: named sessions, the timeline log, detecting a blocked session, checks |
| [scripts/run_portfolio3.py](scripts/run_portfolio3.py) | everything end to end, with evidence capture |
| [sql/lab.sql](sql/lab.sql) | a small `lab` schema for the deliberately unsafe patterns |
| [two-terminal-guide.md](two-terminal-guide.md) | the main scenarios as step-by-step psql commands for two terminals |
| [concurrency-control.md](concurrency-control.md) | what the demos show and why |

## How it was implemented

Each scenario drives two or more **real database sessions**, each with its own connection, and runs their statements in a fixed order. When one session has to wait for a lock, its statement runs in a background thread. The script then confirms that the session really is waiting before going on: it watches `pg_stat_activity`, and `pg_blocking_pids()` names the blocking session. That makes every interleaving repeatable. Each step is printed with a timestamp and the session that ran it (A, B), so the evidence files read as timelines. Each scenario ends with checks that compare what happened with what should happen.

The scenarios that break a rule on purpose (a lost update, unordered locking, write skew) run on a separate `lab.account` table. That way the real ledger is never put into an invalid state. Everything else runs on the OwoRail schema from Portfolio 1 and calls the real `post_transaction` and `reverse_transaction`. The load tests (L4, L6, L7, L8) use 2 to 8 threads, each with its own connection. Sixteen extra customers and merchants are onboarded for them through the normal onboarding functions.

The durability test kills the database server with SIGKILL while one transfer is committed and another is still open. It then restarts the server and reads PostgreSQL's own log, which reports the WAL recovery.

## How it was tested

```bash
docker compose up -d postgres
.venv/Scripts/python portfolio-3-transactions-concurrency/scripts/run_portfolio3.py
```

The script rebuilds the database from scratch, runs all three demo scripts and finishes with the Portfolio 1 consistency checks. That last step shows the concurrent tests left every business rule intact. It takes about a minute.

| Step | Result | Evidence |
|---|---|---|
| Transactions (T1–T6) | 18 of 18 checks | [m7_transactions.txt](evidence/m7_transactions.txt) |
| Isolation (I1–I4) | 10 of 10 checks | [m8_isolation.txt](evidence/m8_isolation.txt) |
| Locking and concurrency (L1–L8) | 21 of 21 checks | [m8_locking.txt](evidence/m8_locking.txt) |
| Consistency after all tests | 13 of 13 rules, 0 violations | [m8_consistency_after.txt](evidence/m8_consistency_after.txt) |
