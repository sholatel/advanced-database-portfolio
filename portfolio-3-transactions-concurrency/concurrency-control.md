# Concurrency control in OwoRail

A wallet operator handles many payments at once. Two people can pay the same merchant in the same second, a customer can tap "send" twice, and a support agent can reverse a transfer while the customer is spending. Each scenario below reproduces one of these situations with real database sessions. The timings and outcomes come from the evidence files.

## Transactions: all or nothing, and durable

| Scenario | What happened | What it shows |
|---|---|---|
| T1 commit | B could not see A's transfer until A committed, then saw it at once | **isolation** of uncommitted work and **atomic** visibility at COMMIT |
| T2 rollback | after ROLLBACK, the balance, the transaction, its ledger lines, status history and audit rows were all gone, and the idempotency key could be used again | **atomicity**: a posting writes five tables, and ROLLBACK undoes all five |
| T3 error | a forbidden payment (a biller paid as a merchant, BR-10) failed; PostgreSQL then refused every further statement (`25P02`) until ROLLBACK, which also undid the valid payment before it | an error makes the *whole* transaction unusable; nothing is half-saved |
| T4 savepoint | in a batch of three payments, the bad second one was undone with `ROLLBACK TO SAVEPOINT`; the other two committed, and the balance moved by exactly their amounts and fee | savepoints give partial rollback inside one transaction |
| T5 atomic failure | a reversal refused halfway (the receiver had spent the money) left no rows in any of the five tables it writes, and the original stayed SUCCESSFUL | a single function call is atomic too: everything it did is rolled back |
| T6 durability | the server was killed with SIGKILL. On restart, PostgreSQL reported "not properly shut down; automatic recovery in progress", replayed the WAL ("redo starts … redo done", 0.4 s), and the committed transfer was there while the open one was gone | **durability** comes from the write-ahead log: a transaction counts as committed once its WAL record is flushed, and recovery replays it |

## Isolation levels: what each level allows

PostgreSQL uses **MVCC** (multi-version concurrency control): an update writes a new version of the row, and each statement or transaction reads from a *snapshot* of what was committed. So readers never block writers, and writers never block readers. The isolation level decides how long a snapshot lasts.

| Anomaly | READ COMMITTED (the default) | REPEATABLE READ | SERIALIZABLE |
|---|---|---|---|
| Dirty read (I1) | not possible; even `READ UNCOMMITTED` behaves as READ COMMITTED in PostgreSQL | not possible | not possible |
| Non-repeatable read (I2) | **happens**: a balance read twice in one transaction changed by 6,000 kobo when B committed a transfer in between | prevented: one snapshot for the whole transaction | prevented |
| Phantom (I3) | **happens**: a count of today's incoming transfers went from 2 to 3 | prevented in PostgreSQL (stricter than the SQL standard requires) | prevented |
| Write skew (I4) | happens | **happens**: two withdrawals each checked that the *combined* balance of two accounts covered them, both committed, and the combined balance ended at −100,000 | prevented: the second COMMIT failed with `40001`; the retry saw the first withdrawal and refused |

Write skew is the subtle case. The two transactions update *different* rows, so no row lock ever conflicts, and each snapshot on its own looks fine. SERIALIZABLE (Serializable Snapshot Isolation) tracks which rows each transaction *read* as well as what it wrote. It aborts one of them when the read/write dependencies would make the result impossible in any serial order. The price is that the application must be ready to **retry** on `40001`, which the demo does.

## Locks: lost updates and deadlocks

| Scenario | What happened | Control |
|---|---|---|
| L1 lost update, READ COMMITTED | both sessions read 100,000 and wrote back their own result; one of two withdrawals (30,000 and 50,000) was lost, leaving 50,000 instead of 20,000 | the bug is computing the new balance in the application from a stale read |
| L1 lost update, REPEATABLE READ | B's write waited for A, then failed with `40001 could not serialize access due to concurrent update` | the database refuses to overwrite a version B never saw |
| L2 `SELECT ... FOR UPDATE` | B's read waited (`pg_blocking_pids` named A), then returned A's result, 70,000; both withdrawals counted (20,000) | a row lock makes read-modify-write safe |
| L3 deadlock | A waited for B and B for A; after `deadlock_timeout` (1 s) PostgreSQL aborted one session with `40P01` and let the other finish | deadlock **detection**: the database breaks the cycle, and the victim must retry |
| L4 under load | 200 transfers in opposite directions between two accounts: locking in arrival order produced 100 deadlocks; locking both rows in key order first produced **0**, with money conserved in both runs | deadlock **prevention** by a global lock order |

`post_transaction` uses the same remedies. It locks both wallets with `SELECT ... FOR UPDATE` in `wallet_id` order before reading any balance, and it locks the FEES wallet last. It never computes from a stale read: under READ COMMITTED, each statement after the lock sees the latest committed balance.

## The posting function under concurrent load

| Scenario | Result |
|---|---|
| L5 two transfers that together overspend | a wallet held 50,000; two transfers of 40,000 (+1,000 fee) started at once. The second waited on the first one's lock on the sender's wallet, re-read the balance after the first committed (9,000) and was recorded as FAILED, insufficient funds. The wallet was never overdrawn. |
| L6 opposite transfers | 4 sessions sent 200 transfers between the same two wallets in both directions: 0 deadlocks, 0 errors, all 200 successful, and the pair lost exactly the 200 fees |
| L7 duplicate requests at the same moment | 20 times, two sessions sent the same request (same idempotency key) simultaneously: in every pair both got the same transaction id, each key was stored once, and the sender paid for 20 transfers, not 40 |
| L8 a hot row | 400 postings with 1 and with 8 sessions. Transfers all credit the single FEES wallet, so with 8 sessions they queue on its row lock: 535 lock waits were sampled, against none for merchant payments, which share no row. With 8 sessions, transfers managed 234 postings per second and merchant payments 624. |

L7 works because the uniqueness of `idempotency_key` is enforced by the database, not by a lookup in the application. When both requests miss the first lookup, `INSERT ... ON CONFLICT ON CONSTRAINT uq_transaction_idempotency_key DO NOTHING` makes the second one wait for the first to commit. It then inserts nothing, and the function returns the first one's id.

L8 shows a design limit worth stating plainly. Every fee is added to one row, so fee-paying transfers serialise on it, however many sessions there are. The lock is taken last and held only until COMMIT, which keeps the queue short. But it would become the bottleneck long before the wallets themselves. Two common fixes are spreading fees over several FEES sub-wallets chosen by hash, or not updating a stored FEES balance at all and deriving it from the ledger (it is a system wallet, so no limit check needs it). In a sharded design (Portfolio 5), the same row would also be a hot spot across nodes.

The scaling ratio from one session to eight is less reliable than those two findings. In this run, merchant payments rose 4.8× and transfers 1.9×. When I reran everything from a fresh clone, the single-session transfer rate was 45 per second instead of 123, and the ratios came out 2.1× and 3.3×. The lock waits (606) and the gap at eight sessions (148 against 315 per second) held in both runs ([fresh-run-check.md](../docs/fresh-run-check.md)).

## What I'd tell a developer joining the team

1. Never compute a new balance in application code from an earlier SELECT. Lock the row (`FOR UPDATE`), or let the database do the arithmetic.
2. Lock several rows in one global order (lowest id first), so transactions can't deadlock.
3. Use READ COMMITTED with row locks for postings. Use REPEATABLE READ or SERIALIZABLE for reports that must see one consistent moment, or for rules that span several rows without a common row to lock. Be ready to retry on `40001` and `40P01`.
4. Make retries safe with an idempotency key backed by a UNIQUE constraint.
5. Keep transactions short. Locks are held until COMMIT, so anything slow inside a transaction (network calls, user input) makes everyone else wait.

## References

PostgreSQL Global Development Group. (n.d.). *PostgreSQL 16 documentation: Chapter 13, Concurrency control; Chapter 30, Reliability and the write-ahead log*. Retrieved November 11, 2026, from https://www.postgresql.org/docs/16/

Silberschatz, A., Korth, H. F., & Sudarshan, S. (2020). *Database system concepts* (7th ed.). McGraw-Hill Education.
