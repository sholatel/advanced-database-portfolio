# OwoRail: Advanced Database Systems Portfolio

**MIT 8103 Advanced Database Systems** · Continuous Assessment: Individual Practical Database Portfolio
Miva Open University, School of Postgraduate Studies · Master of Information Technology, September 2026 cohort
**Student:** Yusuf O. Sholadoye · **Matric number:** 2026/A/MIT/0663

> **OwoRail is a fictional organisation** created for this coursework. A name check (7 Nov 2026) found no company of that name.
> All people, phone numbers, identifiers (e.g. BVN-like values prefixed `999`) and transactions in this repository are **synthetic**. No real personal data or real company schema is used.

---

## 1. Selected case study: OwoRail

### 1.1 Organisation / scenario
**OwoRail** is a simulated Nigerian mobile-money and digital-wallet operator headquartered in **Lagos**, serving retail customers and merchants nationwide. (*Owó* is Yoruba for "money"; a *rail* is a payment network.) The database in this portfolio is OwoRail's core **wallet and payments system of record**.

### 1.2 Nature of the business / system
OwoRail holds customers' money in **naira (NGN) wallets** and moves it between parties:

- instant **peer-to-peer wallet transfers**;
- **payments to merchants**;
- **bill payments** (airtime, electricity, cable TV) through biller partners;
- **fee charging** on chargeable transactions;
- **reversals** of failed or disputed transactions;
- **daily reconciliation** of wallet balances against the double-entry ledger.

It is an **OLTP, integrity-critical** system: money must never be created, lost or posted twice.

### 1.3 Users of the database

| User | Uses the database to… |
|---|---|
| Customers (mobile app) | open a wallet, transfer money, pay merchants and bills, view statements (always through the payments application, never directly) |
| Merchants | receive payments and view monthly settlement reports |
| Customer-support agents | look up customers and transactions to resolve complaints, without seeing KYC identity detail |
| Compliance / KYC analysts | verify customer identity and manage KYC tiers |
| Fraud analysts | run velocity checks and flag suspicious activity |
| Finance / reconciliation officers | reconcile wallet balances against the ledger and settle merchants |
| Internal auditors | review all records, including the audit log, read-only |
| Payments application service account | execute every customer-facing operation |
| Database administrator (DBA) | manage the schema, roles, backup and performance |

Database roles and least-privilege grants for these users are designed in Portfolio 1 (Physical Design).

### 1.4 Major data stored

- **Customers and identity:** customers, customer phone numbers (a customer may have several), addresses, KYC profiles (tier, synthetic BVN-like ID, verification status)
- **Wallets:** customer wallets and internal system wallets (fees, settlement, suspense); saved beneficiaries
- **Counterparties and pricing:** merchants and billers; fee rules
- **Money movement:** transactions (transfer, merchant payment, bill payment, reversal), **double-entry ledger entries**, transaction status history, reversals
- **Governance:** audit log

Money is stored as integer **kobo** (₦1 = 100 kobo) and all timestamps are stored in **UTC**.

### 1.5 Key operations supported

1. Onboard a customer and open a wallet
2. Transfer funds between wallets
3. Pay a merchant or a biller
4. Charge fees
5. Reverse a failed or disputed transaction
6. Generate a wallet statement for a date range
7. Reconcile wallet balances against the ledger
8. Flag suspicious activity (velocity checks)
9. Produce merchant monthly settlement reports

---

## 2. Repository map

```
advanced-database-portfolio/
├── README.md                              ← you are here (case study, map, how to run, evidence index)
├── docker-compose.yml                     PostgreSQL 16 + MongoDB 7.0 (single node) for P1–P4
├── .env.example                           configuration template (copy to .env; .env is never committed)
├── requirements.txt                       pinned Python dependencies
├── tools/
│   └── capture_evidence.py                runs a command and saves timestamped evidence output
├── portfolio-1-database-design/           P1 Database Design and Modelling
├── portfolio-2-query-optimisation/        P2 Query Processing and Optimisation
├── portfolio-3-transactions-concurrency/  P3 Transactions and Concurrency
├── portfolio-4-nosql/                     P4 NoSQL and Advanced Data Models
├── portfolio-5-distributed-cloud/         P5 Distributed and Cloud Database Exercise
└── docs/
    ├── ai-assistance-log.md               record of AI assistance per milestone (feeds the AI Use Declaration)
    └── references.md                      references (APA 7)
```

Each portfolio folder has its own `README.md` explaining what was implemented, how to run it and how it was tested, plus an `evidence/` folder with captured outputs.

## 3. Progress

| Milestone | Scope | Status |
|---|---|---|
| M1 | Repository scaffold, case study, database containers | Done |
| M2–M4 | P1: requirements, ER diagram (Chen), relational schema, normalisation, implementation | Done |
| M5–M6 | P2: query workload, execution plans, indexing and optimisation | Done |
| M7–M8 | P3: transactions (commit, rollback, savepoint), isolation and concurrency control | Done |
| M9 | P4: MongoDB document model on the same case study | Planned |
| M10 | P5: distributed design and a three-node MongoDB replica set | Planned |
| M11 | Final documentation, fresh-run verification, LMS summary | Planned |

## 4. Technology stack

| Purpose | Technology | Version |
|---|---|---|
| Relational database (P1–P3) | PostgreSQL, Docker image `postgres:16` | 16.15 (exact version and image digest recorded in [evidence](portfolio-1-database-design/evidence/m1_postgres_environment.txt)) |
| Document database (P4) | MongoDB, Docker image `mongo:7.0` | 7.0.45 (exact version and image digest recorded in [evidence](portfolio-4-nosql/evidence/m1_mongo_environment.txt)) |
| Distributed database (P5) | MongoDB three-node replica set (Docker Compose) | 7.0 |
| Containers | Docker Engine + Docker Compose v2 | Docker 28.4, Compose 2.39 |
| Scripting | Python with `psycopg` 3, `pymongo`, `tabulate` | Python 3.11+ (developed on 3.13.5); see [requirements.txt](requirements.txt) |
| ER diagram | Graphviz (DOT source rendered to SVG/PNG) | 16.1 |

## 5. How to run

**Prerequisites:** Docker Desktop (or Docker Engine) with Compose v2, Python 3.11+, Git.

```bash
# 1. Configuration: copy the template, then set your own passwords in .env
cp .env.example .env

# 2. Start PostgreSQL and MongoDB (ports are bound to localhost only)
docker compose up -d
docker compose ps            # wait until both services show "(healthy)"

# 3. Quick checks
docker compose exec postgres psql -U postgres -d oworail -c "SELECT version();"
docker compose exec mongo mongosh -u root -p --authenticationDatabase admin --eval "db.version()"   # prompts for the password

# 4. Python environment (for the evidence helper and later scripts)
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements.txt     # Windows
# .venv/bin/python -m pip install -r requirements.txt       # macOS / Linux

# 5. Stop
docker compose down          # stop containers, keep data
docker compose down -v       # stop containers and DELETE the data volumes (clean slate)
```

| Service | Host address | Notes |
|---|---|---|
| PostgreSQL | `127.0.0.1:5433` | non-default port, so it doesn't clash with a local PostgreSQL on 5432 |
| MongoDB | `127.0.0.1:27018` | non-default port, so it doesn't clash with a local MongoDB on 27017 |

The repository is mounted read-only inside both containers at `/workspace`, so SQL and JavaScript files run in place (for example `psql -f /workspace/portfolio-1-database-design/sql/build.sql`). Portfolio-specific instructions are in each portfolio's README.

**Evidence capture.** Outputs used as evidence are saved with `tools/capture_evidence.py`. It writes a header (capture time in Africa/Lagos and UTC, exact command, exit code, tool and server versions) followed by the raw output, and redacts any secrets from `.env`.

## 6. Evidence index

Completed portfolio by portfolio; finalised in M11.

| CA requirement | Evidence |
|---|---|
| Case study stated | [Section 1 above](#1-selected-case-study-oworail) |
| Database environment (PostgreSQL) | [m1_postgres_environment.txt](portfolio-1-database-design/evidence/m1_postgres_environment.txt) |
| Database environment (MongoDB) | [m1_mongo_environment.txt](portfolio-4-nosql/evidence/m1_mongo_environment.txt) |
| Portfolio 1: design and implementation | [portfolio-1-database-design/README.md](portfolio-1-database-design/README.md#required-evidence) (ERD, schema, keys, constraints, normalisation, build and test outputs) |
| Portfolio 2: query processing and optimisation | [portfolio-2-query-optimisation/README.md](portfolio-2-query-optimisation/README.md#required-evidence) (queries, results, plans, indexes, before/after analysis) |
| Portfolio 3: transactions and concurrency | [portfolio-3-transactions-concurrency/README.md](portfolio-3-transactions-concurrency/README.md#required-evidence) (commit, rollback, isolation, locking timelines) |
| Portfolio 4–5 evidence | _added as each portfolio is completed_ |

## 7. Academic integrity and AI use

I designed this portfolio. I chose the OwoRail case study and defined the architecture, the technology stack, the data-design conventions (integer kobo, double-entry ledger, idempotency keys, role-based access) and the milestone plan, and I made the design decisions at each stage. I used **Claude Code** (Anthropic) as a coding and writing assistant: to generate scripts and draft documentation to my specifications, and to save time on repetitive work. I reviewed, ran and tested all generated output, modified it where needed, and verified every result before committing it. Details per milestone are in [docs/ai-assistance-log.md](docs/ai-assistance-log.md). The full AI Use Declaration is added in the final milestone.

## 8. References

See [docs/references.md](docs/references.md) (APA 7th edition).
