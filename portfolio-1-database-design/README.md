# Portfolio 1: Database Design and Modelling

> **Status:** complete. Requirements and conceptual design, logical design with normalisation, and a tested PostgreSQL 16 implementation.

## Purpose
Design OwoRail's relational database through the **stages of database design**: Requirements Analysis → Conceptual Design (ER model, Chen notation) → Logical Design (relational schema, keys, constraints, normalisation) → Physical Design (PostgreSQL 16 implementation, roles, indexes) → Testing and Evaluation.

## Required evidence
- [x] Chosen case study description (see the [root README](../README.md#1-selected-case-study-oworail))
- [x] ER diagram (Chen notation): [erd/erd-chen.png](erd/erd-chen.png)
- [x] Relational schema: [schema.md: relational schema](schema.md#2-relational-schema-text-notation), built by [sql/02_schema.sql](sql/02_schema.sql)
- [x] Keys: [schema.md: keys](schema.md#3-keys)
- [x] Constraints: [schema.md: constraints](schema.md#4-relations-columns-and-constraints), tested in [evidence/m4_constraint_tests.txt](evidence/m4_constraint_tests.txt)
- [x] Normalisation explanation: [normalisation.md](normalisation.md)

## Contents
| Path | Contents |
|---|---|
| [requirements-and-business-rules.md](requirements-and-business-rules.md) | users, data dictionary, business rules BR-01 to BR-18, functional and non-functional requirements |
| [erd/](erd/) | Chen-notation ERD: DOT source, SVG and PNG |
| [schema.md](schema.md) | relational schema; keys and constraints traced to business rules |
| [normalisation.md](normalisation.md) | functional dependencies, UNF → 1NF → 2NF → 3NF → BCNF, deliberate redundancy |
| [sql/](sql/) | the PostgreSQL build: roles, schema, rules, procedures, privileges, seed data |
| [sql/tests/](sql/tests/) | constraint, procedure, role and consistency tests |
| [scripts/](scripts/) | `build_and_test.py` (rebuild, test, capture evidence) and `check_catalogue.py` (database vs schema.md) |
| [evidence/](evidence/) | captured outputs |

## How it was implemented

The build is a chain of plain SQL scripts run by [sql/build.sql](sql/build.sql). It drops and recreates the `oworail` schema each time, so it can be run as often as needed and always gives the same result.

| Script | What it does |
|---|---|
| [01_roles.sql](sql/01_roles.sql) | creates the six roles if they don't exist yet (roles belong to the whole server, not the schema) |
| [02_schema.sql](sql/02_schema.sql) | the 13 tables with all 94 named constraints from schema.md, the foreign-key indexes and the reference-number sequence |
| [03_rules.sql](sql/03_rules.sql) | the fee function, the balanced-ledger check, the append-only triggers and three views for the derived attributes |
| [04_procedures.sql](sql/04_procedures.sql) | onboarding, KYC submission and review, posting and reversal |
| [05_grants.sql](sql/05_grants.sql) | privileges for each role, and an audit record of the grant |
| [06_seed.sql](sql/06_seed.sql) | a small fixed dataset that includes the transaction report used in normalisation.md |

**Constraints.** Every constraint has the name used in schema.md, so a rejected change says which business rule it broke. Code lists are TEXT columns with a CHECK, money is BIGINT kobo, times are TIMESTAMPTZ, and the surrogate keys are `GENERATED ALWAYS AS IDENTITY`, so the application can't choose its own key values. Fee rules for one transaction type may not overlap in amount or in time. A plain UNIQUE constraint can't say that, so it is an exclusion constraint over ranges (`btree_gist`).

**Rules that span several rows.** Some business rules can't be expressed as a constraint on one row, so I enforced them differently:

- *Balanced double entry (BR-13).* A transaction's ledger lines are inserted one at a time, so checking "debits equal credits" after each insert would always fail halfway through. The check is a constraint trigger declared `DEFERRABLE INITIALLY DEFERRED`, which PostgreSQL runs at COMMIT, once all the lines are there. It fires on both tables: lines added to a transaction, and a transaction's status changing. So a SUCCESSFUL transaction with no lines is caught too.
- *Append-only records (BR-13, BR-15, BR-17).* No role is granted UPDATE, DELETE or TRUNCATE on the ledger, the status history or the audit log. Triggers also reject those operations, so even the schema owner can't edit history. A mistake is corrected with a new record, such as a reversal.
- *Posting (BR-04, BR-05, BR-07, BR-10 to BR-15).* `post_transaction` does everything in one database transaction:
  - checks that the wallet types suit the transaction type;
  - takes the fee from the rule in force at that moment;
  - applies the sender's KYC limits and the receiver's maximum balance;
  - writes the ledger lines, the balances and the status history.
  A business refusal (insufficient funds, a limit, a frozen wallet) is kept as a FAILED transaction with the reason, which is what an operations team needs to see. A request that is wrong in itself, such as paying a biller as if it were a merchant, raises an error and leaves nothing behind. A repeated idempotency key returns the original transaction instead of posting twice.
- *Reversal (BR-16).* `reverse_transaction` posts the mirror image of the original ledger lines, so both the amount and the fee go back. It marks the original REVERSED and writes the audit record. It refuses anything that isn't SUCCESSFUL, and it refuses if the receiver has already spent the money.
- *Onboarding (BR-02, BR-06).* A customer is created together with at least one phone number and a wallet, and a merchant together with its wallet. Each is one function call, so either everything is saved or nothing is.

**Security.** The functions are `SECURITY DEFINER`: they run with the schema owner's rights and a fixed `search_path`. Because of that, the payments application can move money only by calling them. It has no INSERT or UPDATE on wallets, transactions or the ledger. PostgreSQL lets every user execute new functions by default, so the grants script removes that first. The views are `security_invoker`, so a view can't be used to read a table the user isn't allowed to read.

| Role | Reads | Can do |
|---|---|---|
| `oworail_app` | operational and ledger tables; not KYC identity data or the audit log | onboarding, posting, reversal; manage saved beneficiaries |
| `oworail_support` | customers, phones, wallets, transactions, ledger | nothing else; no KYC identity data, no audit log |
| `oworail_compliance` | customers, phones, KYC profiles and tiers | `review_kyc` |
| `oworail_analyst` | wallets, merchants, transactions, ledger, fee rules | nothing else; no customer personal data |
| `oworail_auditor` | everything, including the audit log and KYC profiles | nothing |

All roles are NOLOGIN. In a real deployment, each staff member or service would get a login role that is a member of one of these.

**Indexes.** PostgreSQL indexes primary and unique keys on its own, but not foreign keys. I added an index for each of the 8 foreign keys that had none. Without them, every RESTRICT check and every parent-to-child join scans the child table. The indexes for the actual query workload are added and measured in Portfolio 2.

**Seed data.** All of it is synthetic: example.com emails, and national ID numbers with the `999` prefix, the only kind the database accepts. It goes through the same functions the application would use. It recreates the four transactions of the 2 November report from normalisation.md exactly, and adds examples of the fee bands, a percentage fee hitting its cap, an expired fee rule, a pending KYC and a frozen wallet.

## How it was tested

```bash
docker compose up -d
.venv/Scripts/python portfolio-1-database-design/scripts/build_and_test.py
```

This rebuilds the database twice (the second run shows the build is safe to repeat), runs every test and saves each output under `evidence/`. It stops at the first failure.

| Test | What it shows | Result | Evidence |
|---|---|---|---|
| Build | all scripts run without error; row counts per table | ok, twice | [m4_build.txt](evidence/m4_build.txt) |
| Constraint tests | each of the 94 constraints rejects a bad row **with its own name**; valid rows are accepted; the ledger and append-only triggers; RESTRICT and CASCADE deletes; an unbalanced posting rejected at a real COMMIT | 120 of 120 | [m4_constraint_tests.txt](evidence/m4_constraint_tests.txt) |
| Procedure tests | fee bands, rounding, cap and effective dates; KYC limits; idempotent retries; FAILED outcomes; wrong wallet types; reversal rules; atomic onboarding; KYC review and audit | 40 of 40 | [m4_procedure_tests.txt](evidence/m4_procedure_tests.txt) |
| Role tests | each role can do its job and is refused everything else | 41 of 41 | [m4_role_tests.txt](evidence/m4_role_tests.txt) |
| Consistency checks | the multi-row rules hold across all data, including balance reconciliation (FR-08); the 2 November report rebuilt from the normalised tables | 13 of 13, 0 violations | [m4_consistency.txt](evidence/m4_consistency.txt) |
| Catalogue check | the database matches schema.md: constraint names and counts, 89 columns in order, delete rules, deferred triggers, FK indexes, privileges | 9 of 9 | [m4_catalogue_check.txt](evidence/m4_catalogue_check.txt) |

Each test runs inside a subtransaction that is always rolled back, so the tests don't change the data. The consistency checks run after all the other tests and still show the seeded balances.

A test identifies a failure by the constraint name PostgreSQL reports, not just by "an error happened". That matters because a bad row can break two rules at once. A wallet of an unknown type, for example, also breaks the ownership rule, and PostgreSQL checks CHECK constraints in name order, so it reports the ownership rule. The test records that as it is. A second test sets the ownership rule aside inside the rolled-back test, to show the wallet-type check working on its own.

Rebuilding the 2 November report from the normalised tables gives the same transactions, parties, tiers, phone numbers, balances, ledger lines, status history and reversal details as the report in normalisation.md. The decomposition lost no information: the join is lossless.
