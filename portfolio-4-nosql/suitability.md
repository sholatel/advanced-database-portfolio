# Is a document store right for OwoRail?

MongoDB now holds the same 1.1 million transactions as PostgreSQL, loaded from it and checked against it. That makes it possible to answer the question with measurements rather than slogans. My conclusion: the document model is a good fit for how OwoRail *reads* its data, and a weaker fit for how it must *guarantee* money movement.

## What the measurements show

All nine operations return the same rows as PostgreSQL (18 of 18 checks in [m9_queries.txt](evidence/m9_queries.txt)).

| Operation | MongoDB, no workload indexes | MongoDB, indexed | Docs examined (indexed) | PostgreSQL, optimised (Portfolio 2) |
|---|---|---|---|---|
| Q1 customer by phone | 79 ms | 3.2 ms | 2 | 0.06 ms |
| Q2 statement, 20 latest | 2,357 ms | 2.9 ms | 20 | 4.2 ms |
| Q3 transaction + history | 3.0 ms | 2.8 ms | 1 | 0.05 ms |
| Q4 today's spend | 1,798 ms | 2.7 ms | 20 | 0.05 ms |
| Q5 reconciliation | 34,061 ms | 30,890 ms | 1,203,119 | 768 ms |
| Q6 velocity check | 2,306 ms | 55 ms | 5,562 | 25 ms |
| Q7 monthly settlement | 3,110 ms | 555 ms | 67,282 | 3.6 ms (materialised view) |
| Q8 failures by channel | 1,991 ms | 14 ms | 1,151 | 33 ms |
| Q9 dormant wallets | over 30 s | 646 ms | 29,928 | 133 ms |

The two columns of times aren't measured the same way. MongoDB times are wall-clock from the Python client, so they include the network round trip and decoding the results, about 2–3 ms even for a one-document read. The PostgreSQL times are the server's own `EXPLAIN ANALYZE` figure. For the small queries, compare *documents examined* rather than milliseconds. Q2 and Q4 read exactly 20 documents, which is the minimum possible.

What stands out:

- **The statement (Q2) is where embedding wins.** Each ledger entry sits inside its transaction, next to the time. One multikey index on `(entries.wallet, created_at, _id)` returns a wallet's 20 newest entries by reading 20 index keys and 20 documents. In PostgreSQL the same query needed a rewrite and two composite indexes, because normalisation had moved the time away from the ledger line (Portfolio 2, Q2).
- **One-document reads need no joins.** A transaction with its history (Q3) is one document fetched by `_id`. In PostgreSQL it's a join across two tables, which is cheap too, but it is a join.
- **Whole-ledger aggregation is where embedding loses.** Reconciliation (Q5) has to unwind 2.87 million embedded entries out of 1.1 million documents, then group them. It took about 31 s against 0.8 s in PostgreSQL, and no index helps, because every entry has to be read. PostgreSQL reads a narrow table of fixed-width rows with two parallel workers. MongoDB decodes every BSON document (674 bytes on average) in one pipeline, inside a 512 MB cache. For a job that runs once a night this is tolerable. It's still a 40× difference.
- **Reports rely on the right compound index.** Settlement (Q7) still reads 67,282 documents after indexing. There is no MongoDB equivalent of PostgreSQL's planner choosing a better join, so the fix would be the same one as in Portfolio 2: an on-demand materialised view (`$merge` into a settlement collection).

## Integrity and transactions

| Guarantee | PostgreSQL | MongoDB |
|---|---|---|
| Types, formats, allowed values | CHECK constraints | `$jsonSchema`: every rule tested and enforced ([m9_validation.txt](evidence/m9_validation.txt)) |
| Balanced entries, status = last history | a deferred trigger at COMMIT; a consistency query | **stronger**: a validator `$expr` on the embedded arrays rejects any write that breaks them |
| A transaction refers to an existing wallet | foreign key | none: MongoDB has no foreign keys |
| Stored balance = sum of the entries | posting function + reconciliation | the same pattern, done by the application |
| A transfer across several wallets is atomic | every transaction, by default | only inside an explicit multi-document transaction, and only on a replica set |
| Two writers on one balance | the second **waits** for the row lock, then continues | the second **fails at once** with `WriteConflict` (`TransientTransactionError`) and must retry |
| Least privilege for identity data | a separate `kyc_profile` table, no grant | KYC is embedded, so it needs a view without `kyc` and a role limited to that view |

The transaction demos ([m9_transactions.txt](evidence/m9_transactions.txt)) show both sides:

- **Inside a transaction, a transfer is all or nothing.** A frozen receiver made the transfer fail after the debit, and the debit was rolled back.
- **Other readers are isolated.** They kept seeing the old balance until COMMIT (snapshot read concern).
- **Concurrent writers conflict.** A second writer on the same wallet got an immediate write conflict, and the automatic retry in `with_transaction` then succeeded.
- **Retries are safe.** A duplicate request failed on the unique idempotency key.
- **Without a transaction, money can vanish.** The same failure after a debit simply lost 11,000 kobo.

In PostgreSQL every statement already runs in a transaction. In MongoDB, atomicity covers *one document* unless the developer remembers to open a session.

## CAP, ACID and BASE

On one node there is no network partition to reason about. The Portfolio 4 server is a single-member replica set only so that it can run transactions. With `writeConcern: majority` and `readConcern: snapshot`, as the transfer demo uses them, MongoDB behaves as an ACID database for that transaction. The trade-offs of CAP and BASE appear once data is replicated: whether a write waits for a majority, and whether reads may go to a secondary that is behind. Portfolio 5 measures exactly that, on a three-node replica set.

## Other NoSQL models for OwoRail

The brief asks for one NoSQL example; the document model is the one implemented here. Other models would each suit a narrow part of OwoRail better than either PostgreSQL or MongoDB:

| Model | OwoRail use | Why |
|---|---|---|
| Key-value (e.g. Redis) | idempotency keys for in-flight requests, sessions, rate limits on USSD | a lookup by key with a time-to-live, at very high request rates |
| Wide-column (e.g. Cassandra) | a per-wallet event history at national scale | partition by wallet and cluster by time: the statement query by design, spread over many nodes |
| Graph (e.g. Neo4j) | fraud: rings of wallets passing money in circles, mule accounts | multi-hop questions ("money that came back to its sender within 3 hops") are path searches, which SQL handles poorly |

## Recommendation: polyglot persistence

| Data | Store | Reason |
|---|---|---|
| wallets, transactions, ledger, KYC, fee rules | **PostgreSQL** (system of record) | money needs multi-row atomicity by default, foreign keys, row locks that wait instead of failing, and fast whole-ledger reconciliation; Portfolios 1–3 test all of it |
| statement history and transaction detail for the app | **MongoDB** read model, fed from PostgreSQL | one indexed read per statement page or transaction, with no joins, and a flexible schema for app-specific fields |
| idempotency cache, sessions | key-value store | short-lived, very fast lookups |
| fraud analysis | graph store, fed from the ledger | path queries |

PostgreSQL stays the single source of truth. MongoDB is copied from it (the loader here is a batch version of that feed). If the copy falls behind or breaks, the money is still correct, and the read model can be rebuilt.

## References

MongoDB, Inc. (n.d.). *MongoDB manual 7.0: Data modeling; Schema validation; Transactions; Indexes; Explain results*. Retrieved November 11, 2026, from https://www.mongodb.com/docs/v7.0/

Sadalage, P. J., & Fowler, M. (2012). *NoSQL distilled: A brief guide to the emerging world of polyglot persistence*. Addison-Wesley.
