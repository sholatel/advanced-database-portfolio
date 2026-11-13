# Fresh-run check

To make sure the repository works on its own, and not only on my working copy, I cloned it into an empty folder on 11 November 2026 and ran all five portfolios from nothing.

## How it was run

- A clone of commit `b852537`, the latest commit at the time, plus `tools/run_all.py`, which I added with this file.
- A new Python virtual environment installed from `requirements.txt` (psycopg 3.3.8, pymongo 4.19.0, tabulate 0.10.0). My `.env` was copied in, because it is never in the repository.
- PostgreSQL and MongoDB started in a separate Compose project (`COMPOSE_PROJECT_NAME=oworail-fresh`), so both began on new, empty volumes. My own containers were stopped for the whole run. Portfolio 5 removes its clusters' volumes before it starts, so it also began empty.
- `python tools/run_all.py 1 2 3 4`, then `docker compose down -v`, then `python tools/run_all.py 5`.
- Afterwards I deleted the clone and its volumes. The evidence files in the repository come from my working copy; I compared this run's output with them and did not copy anything over.

## Result

Every portfolio exited 0, and every check passed again.

| Portfolio | Exit code | Minutes | Checks in the fresh run | Committed evidence |
|---|---|---|---|---|
| 1 | 0 | 0.4 | constraint tests 120/120, procedure tests 40/40, role tests 41/41, consistency checks 13/13, catalogue 9/9 | the same |
| 2 | 0 | 15.1 | all nine queries returned the same rows before tuning, after indexing and after the final changes | the same |
| 3 | 0 | 1.3 | transactions 18/18, isolation 10/10, locking and concurrency 21/21 | the same |
| 4 | 0 | 41.9 | load 4/4, workload 18/18 (including every query against PostgreSQL), validation 22/22, transactions 14/14 | the same |
| 5 | 0 | 6.5 | replica set 16/16, sharded cluster 9/9 | the same |
| **Total** | | **65.2** | | |

## Figures that should not change, and didn't

The data is generated from fixed seeds, so counts that depend only on the data and the plan should be identical.

- **Portfolio 2 buffers.** The final-phase buffer count of every query was identical (for example 124 for the settlement query and 17,062 for reconciliation). The only differences anywhere were tiny: settlement before tuning read 1,399,936 pages against 1,399,934, and two queries after indexing differed by 4 and 18 pages.
- **Portfolio 4 documents and keys examined.** Identical for all nine queries, before and after indexing.
- **Portfolio 5 data distribution.** The hashed key split the data 99,490 / 100,510, the time key sent 0 / 10,000 new writes to the two shards, the hashed key sent 4,928 / 5,072, and the partial scan returned 104,418 documents. All four match exactly.
- **Correctness after stress.** After the crash test, the committed transfer was still there, the uncommitted one was gone, and every balance matched the ledger.

## Figures that depend on timing

These moved, as expected on a laptop. The conclusions stayed the same.

| Measure | Committed evidence | Fresh run |
|---|---|---|
| Portfolio 2 settlement query, final | 3.6 ms | 15.7 ms (124 buffers in both) |
| Portfolio 2 dormant-wallet query, final | 133 ms | 330 ms (the original still timed out) |
| Portfolio 2 reconciliation, before → final | 1,613 → 768 ms | 3,919 → 1,150 ms |
| Portfolio 4 reconciliation | 30.9 s | 46.1 s |
| Portfolio 3 deadlocks with unordered locking | 100 of 200 | 87 of 200 (0 with ordered locking in both) |
| Portfolio 5 failover: longest gap between acknowledged writes | 11.4 s | 11.6 s |
| Portfolio 5 majority writes acknowledged and stored during failover | 441 / 441 | 334 / 334 |

Every query whose plan changed was faster afterwards in both runs. Two Portfolio 4 queries keep the same plan before and after indexing (Q3 and Q5), and their timings moved in either direction, which is noise.

## What did not reproduce

**The hot-row scaling ratio in Portfolio 3 (L8).** I had reported that, going from one session to eight, merchant payments sped up 4.8× and fee-paying transfers only 1.9×. In the fresh run the ratios were 2.1× and 3.3×. The single-session transfer rate fell from 123 to 45 postings per second, and the ratio divides by that number, so it is not a reliable measure.

What held in both runs is what the checks actually test. With eight sessions, only transfers waited on a lock (535 and 606 waits sampled, none for merchant payments). Transfers also reached well under half the throughput of merchant payments: 234 against 624 postings per second, and 148 against 315. I changed the Portfolio 3 analysis and my reflection to rest on those two findings rather than on the ratio.
