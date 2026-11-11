# Portfolio 2: Query Processing and Optimisation

> **Status:** complete. A workload of nine OwoRail queries on about 1.1 million transactions, measured before and after optimisation. The analysis is in [performance.md](performance.md).

## Purpose
Run a realistic OwoRail query workload on a large synthetic dataset and use PostgreSQL's **execution plans** to find out why each query is slow. Then improve it with indexes, better statistics, a materialised view and query rewrites, and explain the results in terms of cost-based optimisation, selectivity, statistics and access paths.

## Required evidence
- [x] SQL queries: [queries.sql](queries.sql) (baseline) and [queries_rewritten.sql](queries_rewritten.sql) (after optimisation)
- [x] Query results: [results/](results/) (one file per query and phase)
- [x] Execution plans: [plans/before/](plans/before/), [plans/indexes/](plans/indexes/), [plans/final/](plans/final/)
- [x] Indexing / optimisation evidence: [indexes.sql](indexes.sql), [tuning.sql](tuning.sql), [results/comparison.md](results/comparison.md), [evidence/](evidence/)
- [x] Brief performance analysis: [performance.md](performance.md)

## Contents
| Path | Contents |
|---|---|
| [data/generate_volume.sql](data/generate_volume.sql) | the volume dataset: 100,000 customers, 2,000 merchants and billers, about 1.1 million transactions |
| [queries.sql](queries.sql) | the nine workload queries as first written |
| [indexes.sql](indexes.sql) | workload indexes (step 1) |
| [tuning.sql](tuning.sql) | statistics target and materialised view (step 2) |
| [queries_rewritten.sql](queries_rewritten.sql) | the workload with Q2, Q7 and Q9 rewritten (step 2) |
| [write_cost.sql](write_cost.sql) | what the extra indexes cost when posting payments |
| [experiments.sql](experiments.sql) | statistics, estimates and the alternatives I tried and rejected |
| [sizes.sql](sizes.sql) | table and index sizes |
| [scripts/run_plans.py](scripts/run_plans.py) | runs the workload, saves plans, results and timings |
| [scripts/run_portfolio2.py](scripts/run_portfolio2.py) | the whole portfolio end to end, with evidence capture |
| [plans/](plans/), [results/](results/), [evidence/](evidence/) | outputs |

## How it was implemented

**Dataset.** The generator works entirely in SQL, with no external tools. Every "random" value comes from a hash of the row number (`hashint8extended`), so the data is identical on every run, whatever order PostgreSQL processes the rows in. The dataset has:

- 100,000 customers, each with a KYC profile, a wallet and one or two phones;
- 2,000 merchants and billers;
- 1,000,000 payments and transfers spread over May to October 2026, plus an opening funding transaction for each customer;
- about 1,100 reversals;
- 2.87 million ledger lines and 2.2 million status-history rows.

It's deliberately uneven, the way real usage is. A few customers send thousands of payments while most send around ten, and a few merchants take most of the payments. About 3 % of transactions fail.

Each customer is funded at the start with everything they will later send, plus a buffer, so no balance goes below zero. The data goes straight into the tables in bulk rather than through `post_transaction`, which would take far longer for a million rows. During the load the two balanced-ledger triggers are switched off, because they check one transaction per row. Instead, all the Portfolio 1 consistency checks are run over the full dataset afterwards (13 of 13, no violations). Every other constraint stays on throughout. What the bulk load doesn't reproduce is the daily KYC limits. They are enforced only when `post_transaction` is called, and simulating them wasn't needed here.

**Measuring.** `run_plans.py` runs each query once to warm the cache and to save its result. It then runs `EXPLAIN (ANALYZE, BUFFERS)` five times, keeps the median time and saves the plan from the median run. A run is cancelled after 30 seconds. The server keeps its default settings (shared_buffers 128 MB, work_mem 4 MB), and they are recorded with every timing. Timings on a laptop vary with whatever else is running, so I also record the buffers each plan touched. That count depends only on the plan, which makes it the steadier comparison. Every phase hashes each query's result rows, which proves the optimised queries return exactly what the originals did.

**Optimising** happens in two steps, each measured on its own:

1. **Indexes** ([indexes.sql](indexes.sql)): composite indexes on (wallet, time) for the sender and receiver sides, a time index, a partial index for failed transactions and a covering index on the ledger. Three of the single-column foreign-key indexes from Portfolio 1 become redundant and are dropped.
2. **Statistics, a materialised view and rewrites** ([tuning.sql](tuning.sql), [queries_rewritten.sql](queries_rewritten.sql)): a larger statistics sample for `ledger_entry.wallet_id`, a monthly settlement materialised view, and rewritten versions of the statement query (Q2) and the dormant-wallet query (Q9).

## How it was tested

```bash
docker compose up -d
.venv/Scripts/python portfolio-2-query-optimisation/scripts/run_portfolio2.py
```

The script rebuilds the database from scratch, loads the data, checks it, measures the baseline, applies each optimisation step, measures again and runs the experiments. Every output goes to [evidence/](evidence/). It stops MongoDB first, because Portfolio 2 doesn't use it, and the idle MongoDB healthcheck was taking CPU away from the measurements. Start it again with `docker compose start mongo`.

| Check | Evidence |
|---|---|
| The volume data obeys every business rule (13 consistency checks) | [m5_volume_consistency.txt](evidence/m5_volume_consistency.txt) |
| Each optimised query returns the same rows as the original | "same result" column in [results/comparison.md](results/comparison.md) |
| Q9's NOT EXISTS rewrite returns the same rows as the NOT IN original | [m6_experiments.txt](evidence/m6_experiments.txt), section 3 |
| Cost of the new indexes when writing | [m5_write_cost_before.txt](evidence/m5_write_cost_before.txt), [m6_write_cost_after.txt](evidence/m6_write_cost_after.txt) |
