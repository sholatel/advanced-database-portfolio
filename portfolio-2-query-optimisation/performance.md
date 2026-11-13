# Performance analysis

I ran nine queries that OwoRail runs every day against about 1.1 million transactions and 2.9 million ledger lines. I measured each one as first written, then after adding indexes, then after a second round of changes: better statistics, a materialised view and two rewritten queries. For each slow query I read the execution plan to find out why it was slow before deciding what to change.

## Setup

- **Data:** 100,000 customers, 2,000 merchants and billers, 1,101,109 transactions (nearly all from May to October 2026), 2,870,951 ledger lines. Usage is uneven on purpose. The busiest customer sent 3,123 payments and a typical one about ten. About 3 % of transactions failed.
- **Server:** PostgreSQL 16.15 in Docker on a Windows laptop, with default settings (shared_buffers 128 MB, work_mem 4 MB, random_page_cost 4, up to 2 parallel workers). Fresh statistics after the load (`VACUUM ANALYZE`).
- **Method:** one warm-up run, then the median of five `EXPLAIN (ANALYZE, BUFFERS)` runs, with a 30-second limit. Times on a laptop move with whatever else is running, so I also compare **buffers**: the 8 kB pages a plan touched. Buffers depend only on the plan, so they are the steadier measure. Every phase hashes each query's result rows to prove the changed queries still return exactly the same rows.

## Results

| Query | What it does | Before | After indexes | Final | Buffers before → final | Speed-up |
|---|---|---|---|---|---|---|
| Q1 | customer by phone | 0.07 ms | 0.10 ms | 0.06 ms | 11 → 11 | none needed |
| Q2 | statement, first page (busiest wallet) | 14.6 ms | 19.0 ms | 4.2 ms | 15,041 → 2,966 | 3.5× |
| Q3 | transaction by reference | 0.06 ms | 0.07 ms | 0.05 ms | 8 → 8 | none needed |
| Q4 | today's spend, for the KYC limit | 3.2 ms | 0.07 ms | 0.05 ms | 2,891 → 8 | 62× |
| Q5 | balance reconciliation | 1,613 ms | 1,511 ms | 768 ms | 26,736 → 17,062 | 2.1× |
| Q6 | velocity check, one day | 148 ms | 22 ms | 25 ms | 24,477 → 20,881 | 5.9× |
| Q7 | monthly merchant settlement | 1,778 ms | 276 ms | 3.6 ms | 1,399,934 → 124 | 499× |
| Q8 | failed transactions, 7 days | 112 ms | 25 ms | 33 ms | 26,287 → 5,667 | 3.4× |
| Q9 | dormant wallets | over 30 s | over 30 s | 133 ms | – → 7,573 | more than 225× |

All nine queries return the same rows in every phase ([results/comparison.md](results/comparison.md)). Q6 and Q8 are the same query in the last two phases. Their times differ a little while their buffers are identical, which shows how much of the timing is just noise.

## What the plans showed

### Q1 and Q3: already right

Both are single-row lookups through a primary or unique key (`pk_customer_phone`, `uq_transaction_ref`), then a few index lookups to fetch the related rows. They touch 8 to 11 pages and need nothing more. The keys from Portfolio 1 already serve the most frequent support queries.

### Q4 and Q6: the right index turns a filter into a range

Before, Q4 found the busiest wallet's 3,123 transactions through the plain foreign-key index on `source_wallet_id`. It then fetched every row from the table just to check the date, and threw 3,103 of them away (2,891 buffers). The composite index `(source_wallet_id, created_at, transaction_id)` puts the date in the index key, so the scan only reads that one day. Its `INCLUDE` columns (status, type, amount, fee) let PostgreSQL answer from the index alone: an index-only scan with 0 heap fetches, because `VACUUM` had set the visibility map. The query fell to 8 buffers. Q4 runs inside every `post_transaction` call, so this is the change that matters most to customers.

Q6 asks for one day out of 184, about 0.5 % of the table. Without an index on time, the only option was a parallel sequential scan of all 1.1 million rows. With `ix_transaction_created` the planner reads the 5,554 rows of that day from the index alone. The remaining buffers are the 5,209 primary-key lookups for each sender's wallet number.

### Q8: a partial index the planner didn't choose

Failed transactions are only 2.8 % of the table, so I built a partial index holding just those (`WHERE status = 'FAILED'`, 680 kB). The planner chose the general time index instead and filtered out the successful rows. That was still a big improvement over the baseline (26,287 → 5,667 buffers). In a separate test I set the time index aside, and the partial index ran the query in 17 ms against 33 ms ([experiments](evidence/m6_experiments.txt), section 7). So the planner's cost estimate ranked the two the wrong way round.

The reason is physical order. Transactions were inserted in time order, so `created_at` has a correlation of 1.000 with the row order on disk. The planner therefore expects a time-range scan to read the table almost sequentially, which it costs as cheap. The usage statistics (section 8) show the partial index was never used. As things stand it costs a little on every insert and gives nothing back. It is a candidate to drop, or to keep only if failure reports become more frequent.

### Q7: a bad join plan, then a materialised view

This was the slowest plan, and the reason wasn't obvious at first. The planner joined `wallet` to `transaction` with a nested loop over **all 102,012 wallets**, customer wallets included, probing the transaction index once for each. It only then matched them to merchants. It estimated about 35,000 rows from the inner side and a cost of a few thousand units. In fact the query touched 1.4 million buffers and took 1.8 seconds. The underlying problem is that the planner has no idea that only 2,000 of the 102,012 wallets belong to merchants.

The composite index on `(destination_wallet_id, created_at, ...)` made each of those 102,012 probes cheap: an index-only range scan on the month instead of a heap fetch per row. That cut it to 311,250 buffers and 276 ms, but the plan shape stayed the same. Rewriting the query to add up the month's payments first and join afterwards gave 224 ms (section 5): better, but still reading 65,282 transactions every time.

A settlement report is about closed months, and those don't change once late reversals are done. So I made it a **materialised view** of totals per merchant per month (12,004 rows, 1.4 MB). The report then reads 2,000 rows by its unique index: 124 buffers and 3.6 ms. The cost moves to the refresh, which takes 1.1 s. `REFRESH ... CONCURRENTLY` keeps the view readable during a refresh, which is why it has a unique index. The trade-off is staleness: the view is only as current as its last refresh. That's acceptable for a month-end report run after the refresh, and it would not be acceptable for a live balance.

### Q2: the cost of a normalisation decision

A ledger line has no time of its own. In Portfolio 1 I removed `line_posted_at` from it, because the time depends only on the transaction (a partial dependency, so it failed 2NF). The statement query therefore has to join *every* line of the wallet (3,046 for the busiest one) to its transaction before it can sort them by time and keep 20. New indexes can't help with that: the "after indexes" plan was identical (15,054 buffers).

The rewrite gets the order from the transaction table instead. It takes the 20 latest posted transactions where the wallet is the sender, and the 20 latest where it is the receiver. Each is read *backwards* from its composite index, and the scan stops after 20 rows. A Merge Append then keeps the top 20 of those 40, and only those are joined to their ledger lines. This returns the same rows for any customer or merchant wallet, because such a wallet is always the sender or the receiver of every transaction it has a line in. It does not hold for the FEES wallet, whose fee lines aren't tied to either side.

Buffers fell from 15,041 to 2,966. They don't fall further for a reason the plan shows plainly. The wallet id comes from a subquery, so the planner doesn't know it while planning. It falls back on an average and expects 32 ledger lines for the wallet instead of 3,046. That makes a hash join over all of the wallet's lines look cheap. Normalisation kept the ledger free of a redundant timestamp, and the price is paid here, in a query that has to be written with care.

### Q5: a statistics problem disguised as a memory problem

The reconciliation adds up 2.9 million ledger lines per wallet. The plan used a hash aggregate that **spilled to disk** (5 batches, about 11 MB in temporary files), because it didn't fit in the 4 MB work_mem. The root cause was the estimate. The default statistics sample (30,000 rows) put the number of distinct `wallet_id` values at 32,174, against 102,010 in reality. A hash table for 32,000 groups looks as if it fits in memory, so the planner chose hashing.

New indexes alone didn't change that. Raising the column's statistics target to 1000 brought the estimate to 88,941. With that estimate the planner switched by itself to a sorted aggregate over the covering index `(wallet_id) INCLUDE (entry_type, amount_kobo)`: an index-only scan that never has to hash. It ran in 768 ms against 1,613 ms. The other fix, giving this report 64 MB of work_mem, also stopped the spill, but at 1,410 ms it was slower (section 4), and it spends memory on every hash in the session. I'd rather correct the estimate than hide it behind memory.

### Q9: NOT IN versus NOT EXISTS

`NOT IN (subquery)` and `NOT EXISTS` look interchangeable, but they treat NULLs differently: if the subquery returns a NULL, NOT IN is never true. Because of that, PostgreSQL can't turn NOT IN into an anti-join. It ran it as a filter that, for every one of about 100,000 wallets, searched a materialised list of 490,000 sender ids. The plan's estimated cost was 2.4 billion units, and it didn't finish within 30 seconds in either the baseline or the indexed phase.

`source_wallet_id` is NOT NULL, so `NOT EXISTS` means exactly the same thing here, and it becomes a **nested-loop anti-join**. The planner sorts the wallets by balance and, for each candidate, makes one index-only probe into `ix_transaction_source_created`. It stops as soon as it has 50 dormant wallets, after checking only 1,597 of them: 133 ms. With 64 MB of work_mem, NOT IN does finish (in 346 ms) using a hashed subplan, and an experiment confirms it returns the same 50 rows as NOT EXISTS (section 3). Even so, the rewrite is the better fix, because its speed doesn't depend on a memory setting.

## Statistics and selectivity

The planner's choices come from the statistics `ANALYZE` collects ([experiments](evidence/m6_experiments.txt), section 1):

| Column | What the statistics say | Effect |
|---|---|---|
| `transaction.source_wallet_id` | ~52,700 distinct; most common: the SETTLEMENT wallet (9.1 % of rows, one funding per customer) and the busiest customer (0.26 %) | a common value gets its own estimate; others get an average |
| `transaction.status` | SUCCESSFUL 97.1 %, FAILED 2.8 %, REVERSED 0.09 % | a status filter on its own is not selective; FAILED is the only useful one |
| `transaction.created_at` | correlation 1.000 with physical order | time-range scans read the table almost in order, so the planner costs them as cheap (see Q8) |
| `ledger_entry.wallet_id` | the FEES wallet alone holds 25 % of all ledger lines | very uneven; the default sample underestimated the distinct count (Q5) |

How a value reaches the planner matters too. For the busiest wallet given as a literal (`source_wallet_id = 13`), the planner found it among the most common values and estimated 2,719 rows (actual 3,123). Given through a subquery, the same wallet was estimated at 20 rows, and a typical wallet at 18 (actual 11). A value the planner can't see while planning gets the average estimate. That's harmless for typical wallets and wrong for the busy ones, and it's what held Q2 back.

## What the optimisation costs

Indexes aren't free, and two measurements show what they cost:

- **Space.** The indexes on `transaction` and `ledger_entry` grew from 252 MB to 560 MB. The largest single one is the covering ledger index, at 113 MB against 26 MB for the plain index it replaced. A plain single-column index can store each repeated wallet id once (B-tree deduplication); an index with INCLUDE columns can't. It is used only by the reconciliation (Q5). That 2× gain on a nightly job is worth 87 MB to me, but it is the first index I'd revisit if space mattered.
- **Writes.** Posting 1,800 merchant payments through `post_transaction` took a median of 1.51 ms each before the workload indexes and 1.75 ms after, about 16 % slower. Each posting now updates more index entries. It's an acceptable price for a 62× faster limit check (Q4) inside the same posting.
- **Unused indexes.** The usage counts (section 8) show two indexes never scanned in this workload. One is the partial index on failed transactions (Q8). The other is the Portfolio 1 foreign-key index on `fee_rule_id`, which exists so that deleting a fee rule doesn't scan the transaction table; since fee rules are never deleted, it only costs space and write time.
- **Staleness.** The materialised view needs a 1.1-second refresh to stay current.

## Limits of these measurements

- All timings are from a warm cache on a shared laptop, so small differences (under about 2×) aren't meaningful on their own. That is why I report buffers next to them.
- The bulk-loaded data obeys every business rule (13 of 13 consistency checks), but it doesn't simulate daily KYC limits.
- Production would need a different emphasis: `pg_stat_statements` to find the real heavy queries, and index usage tracked over weeks, not one run.

## References

PostgreSQL Global Development Group. (n.d.). *PostgreSQL 16 documentation: Chapter 14, Performance tips; Chapter 11, Indexes; Section 76.1, Row estimation examples*. Retrieved November 10, 2026, from https://www.postgresql.org/docs/16/

Silberschatz, A., Korth, H. F., & Sudarshan, S. (2020). *Database system concepts* (7th ed.). McGraw-Hill Education.
