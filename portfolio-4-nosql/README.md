# Portfolio 4: NoSQL and Advanced Data Models

> **Status:** complete. OwoRail as a MongoDB 7.0 document model, loaded from the same PostgreSQL data, with 58 automated checks passing. The design is in [model.md](model.md) and the comparison in [suitability.md](suitability.md).

## Purpose
Model OwoRail's data in **MongoDB (document model)**, starting from its access patterns. Load the same data used in Portfolios 1 and 2. Demonstrate CRUD, aggregation pipelines, schema validation, indexing with `explain()` and multi-document transactions. Then argue which OwoRail data belongs in a document store and which must stay relational.

## Required evidence
- [x] NoSQL model based on the same case study: [model.md](model.md)
- [x] Document / key-value / column / graph example: the document model, implemented ([scripts/](scripts/)); the other three models are discussed for OwoRail in [suitability.md](suitability.md)
- [x] Implementation evidence: [evidence/](evidence/), [results/comparison.md](results/comparison.md), [explain/](explain/)
- [x] Explanation of suitability: [suitability.md](suitability.md)

## Contents
| Path | Contents |
|---|---|
| [model.md](model.md) | access patterns, collections, embed-or-reference decisions, a sample document, validators, indexes |
| [suitability.md](suitability.md) | measurements against PostgreSQL, integrity and transactions, CAP, other NoSQL models, recommendation |
| [scripts/schema.py](scripts/schema.py) | collections with validators, and the integrity (unique) indexes |
| [scripts/load.py](scripts/load.py) | loads PostgreSQL into documents and checks the copy |
| [scripts/queries.py](scripts/queries.py) | the nine workload operations as aggregation pipelines; `explain()` before and after indexes; each result checked against PostgreSQL |
| [scripts/validation.py](scripts/validation.py) | documents and updates that must be rejected; a least-privilege view and role |
| [scripts/transfers.py](scripts/transfers.py) | a transfer as a multi-document transaction: commit, abort, isolation, write conflict, idempotency |
| [scripts/run_portfolio4.py](scripts/run_portfolio4.py) | everything end to end, with evidence capture |
| [explain/](explain/) | full `explain("executionStats")` output for each query, before and after indexes |

## How it was implemented

**Same data, two models.** `load.py` reads the PostgreSQL database built in Portfolio 1 and filled in Portfolio 2, and writes MongoDB documents:

- each customer with their phones, address and KYC profile embedded;
- each wallet with a summary of its owner;
- each transaction with its ledger entries, status history and reversal link embedded.

Money is stored as 64-bit integers (`NumberLong`, enforced by the validator) and times as UTC dates. After the copy, the loader compares counts and totals with PostgreSQL. All 1,101,109 transactions, 2,870,951 entries and 2,203,316 history rows were copied, and the customer and merchant balances add up to the same total. The copy took about 5 minutes.

**Replica set.** A transfer changes several documents, so it needs a multi-document transaction, and MongoDB only allows those on a replica set. The `mongo` service in `docker-compose.yml` therefore runs as a single-node replica set (`rs0`). With authentication on, a replica set needs a keyfile, which the container generates at start-up. `schema.py` initiates the replica set on first use. Clients connect with `directConnection=true`.

**Queries.** The nine operations are the ones measured in Portfolio 2, written as aggregation pipelines. `queries.py` runs them twice, first with only the integrity indexes and then with the workload indexes. For each run it records the median time, the documents and keys examined (from `explain("executionStats")`) and whether a collection scan was used. It then checks each result against the same query in PostgreSQL.

## How it was tested

```bash
docker compose up -d
.venv/Scripts/python portfolio-4-nosql/scripts/run_portfolio4.py          # about 30 min, mostly loading
.venv/Scripts/python portfolio-4-nosql/scripts/run_portfolio4.py --from 5 # reruns queries, validation, transactions
```

| Step | Result | Evidence |
|---|---|---|
| Source data in PostgreSQL | fresh build and volume load | [m9_source_data.txt](evidence/m9_source_data.txt) |
| Collections and validators | 7 collections, 7 unique indexes | [m9_schema.txt](evidence/m9_schema.txt) |
| Load and copy checks | 4 of 4 | [m9_load.txt](evidence/m9_load.txt) |
| Workload, before and after indexes | 18 of 18 (same result before and after, and same as PostgreSQL) | [m9_queries.txt](evidence/m9_queries.txt) |
| Validation and least privilege | 22 of 22 | [m9_validation.txt](evidence/m9_validation.txt) |
| Multi-document transactions | 14 of 14 | [m9_transactions.txt](evidence/m9_transactions.txt) |
