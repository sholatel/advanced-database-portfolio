# Technical reflection

Yusuf O. Sholadoye

## Design choices I would make again

**Money as whole kobo, in a double-entry ledger.** Storing amounts as integers in kobo removes rounding errors. Recording every movement as balanced debit and credit lines turns "are the books right?" into a query anyone can run. That paid off repeatedly. After bulk-loading 1.1 million transactions, after hundreds of concurrent postings and after a crash test, the same consistency checks confirmed that every balance still matched its ledger.

**Rules in the database, not only in the application.** I gave every constraint a name tied to a business rule, checked the balanced-ledger rule at COMMIT with a deferred trigger, and let the application change money only through the posting and reversal functions. Because each constraint has a name, each of the 120 constraint tests could check *which* rule refused a bad row, not just that something failed.

**PostgreSQL as the system of record, MongoDB as a read model.** I didn't start with that conclusion; the measurements led me to it. MongoDB made the wallet statement easy: one index, 20 documents read. But reconciling the whole ledger took about 31 seconds there, against under a second in PostgreSQL. A second writer on a wallet gets an immediate conflict, where PostgreSQL makes it wait, and there are no foreign keys. For money, I want PostgreSQL's guarantees.

## Challenges

**A normalisation decision came back later.** Removing the timestamp from ledger lines was correct for second normal form. In Portfolio 2, though, it meant the statement query had to join every line of a wallet before it could sort them. Fixing that took a rewrite and two composite indexes. In MongoDB, where the lines sit inside their transaction, the same query needed only one index. A choice I made at the start showed up again in three later portfolios.

**The query planner is only as good as its statistics.** The reconciliation query spilled to disk because PostgreSQL estimated 32,000 distinct wallets where there were 102,000. Raising the statistics target fixed it without changing the query. A partial index I built was faster when forced but was never chosen. A `NOT IN` query didn't finish in 30 seconds, while the same question asked with `NOT EXISTS` took about a tenth of a second. I knew these as rules. Reading them in real plans made me understand them.

**Measuring on a laptop.** Timings moved by two or three times between runs, partly because an idle MongoDB container's health check was using a whole CPU. I switched to comparing buffers and documents examined, which don't depend on what else the machine is doing, and kept the timings as supporting figures.

**Concurrency problems stay hidden until you force them.** I found the FEES wallet hot spot by accident, while measuring write cost: every transfer adds its fee to that one row. Portfolio 3 then measured it. With eight sessions, only transfers waited on that row's lock, and they managed well under half the throughput of payments that share no row. My first way of showing it, that transfers scaled 1.9 times against 4.8, did not survive a rerun from a fresh clone, because the single-session rate it divides by moved too much. The lost-update and deadlock demonstrations only worked once the sessions were driven in a fixed order and each wait was confirmed.

**Results that look too good need checking.** My first failover test reported a zero-second outage, because it measured around the kill command instead of between the writes. My first rollback test used `docker pause` to cut off the primary. That isn't a network partition: the paused nodes received the writes from socket buffers when they resumed, so the "lost" write survived. Both were wrong, and both looked fine at first.

## Lessons learned

1. **Measure before deciding, and measure the right thing.** Buffers instead of milliseconds, the longest gap between writes instead of a timestamp around a command.
2. **Every optimisation has a cost.** The indexes on the two largest tables more than doubled their space, from 252 MB to 560 MB, and made posting about 16 % slower. Two of the indexes were never used.
3. **Consistency is a setting, chosen for each operation.** A write acknowledged with `w: 1` was rolled back after a failover. The same write with `w: majority` was reported as not durable instead. For a payment operator, that difference decides whether money disappears.
4. **Tests should check the outcome, not only that there was no error:** the named constraint, identical result rows, MongoDB results compared with PostgreSQL's.

## What I would do next

I would simulate the daily KYC limits in the volume data, run the clusters on separate machines to get real network latency, add TLS, split the FEES wallet into sub-wallets, and feed MongoDB from PostgreSQL by change data capture instead of a batch load.

Working with an AI coding assistant made writing the scripts much faster. It didn't remove the need to check its work: several of its outputs were wrong in ways that only running them showed. Keeping a log of what it did and what I changed made it clear which parts I had to be able to explain, and I can explain all of them.
