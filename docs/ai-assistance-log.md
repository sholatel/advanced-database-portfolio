# AI Assistance Log

This log records, milestone by milestone, how I (Yusuf O. Sholadoye) used an AI assistant in this portfolio, what I changed, and how I verified the results. It is the basis for the AI Use Declaration required by the assessment.

- **AI tool:** Claude Code (Anthropic), used in VS Code as a coding and writing assistant. Model: Claude Opus 5.5.
- **How I work with it:** I define the case study, the architecture, the data-design conventions and the milestone plan, and I make the design decisions. For each milestone I specify the work. The assistant generates scripts and drafts documentation to that specification and saves time on repetitive work. I review, run and test the output, modify it where needed, and commit it myself.

---

## M0: Discovery and overall plan (7 Nov 2026)

**My decisions:** the OwoRail case study and its design conventions (from my specification); the milestone plan; environment choices (non-default localhost ports, LF line endings, a standard evidence-capture format, Python runners, container memory limits, pinned dependencies); installing Poppler (to read the scanned course PDF) and Graphviz (for the ER diagram); the three-day deadline.

**AI assistance used:** inspection of the local environment (repository state, installed tools, port conflicts); a summary of the CA brief; a check that the name "OwoRail" isn't used by a real company; drafting the implementation plan.


**How it was verified:** checked against command output (`git status`, `docker info`, `netstat`, tool versions) before I approved the plan.

---

## M1: Repository scaffold and case-study statement (7 Nov 2026)

**My decisions:** repository layout; container configuration (PostgreSQL 16 and MongoDB 7.0, localhost-only ports 5433/27018, healthchecks, memory settings); the evidence-capture format; how secrets are kept out of Git.

**AI assistance used:** generated the scaffold files to the approved plan: folder structure, README drafts (the case-study text follows my specification), configuration files, the evidence helper `tools/capture_evidence.py`, and the references list.


**How it was verified:**
- `docker compose config --quiet` succeeded; `docker compose up -d` brought both services to `(healthy)` within about 10 s.
- Captured PostgreSQL 16.15 (time zone UTC, UTF8) and MongoDB 7.0.45 (FCV 7.0, WiredTiger cache capped at 512 MB) to `evidence/`, with image digests.
- Checked that no `.env` secret appears in any evidence file.
- `git status` / `git check-ignore` confirmed that `.env`, `.venv/`, `_reference/` and `notes/` are ignored; `git check-attr` confirmed LF line endings for scripts.
- A fresh virtual environment installed from `requirements.txt` matched the pinned versions exactly.
- `docker compose down` removed the containers and kept the data volumes.

---

## M2: Requirements, business rules and Chen ERD (8 Nov 2026)

**My decisions:** the scope of the requirements (users, wallet types, transaction types, channels, statuses); integer kobo amounts, a double-entry ledger and idempotency keys as data conventions; Chen notation for the ER diagram, with the diagram kept as source (Graphviz DOT) rather than drawn by hand.

**Design decisions (approved at review):**
- Billers modelled as merchants (`merchant_type` BILLER) rather than as a separate entity.
- LEDGER_ENTRY and TRANSACTION_STATUS_HISTORY as weak entities with identifying relationships.
- A KYC_TIER entity holding the limits, so limits depend on the tier, not the individual (avoids a transitive dependency).
- KYC data kept separate from CUSTOMER (privacy by design).
- A WALLET_FUNDING transaction type, so every balance is backed by the ledger.
- No `merchant_id` or initiator stored on TRANSACTION: both are determined through the wallets (avoids transitive dependencies).
- No timestamp on ledger entries: the time comes from the transaction (avoids a partial dependency).
- REVERSES as a recursive 1:1 relationship with its own attributes.
- An audit log with a polymorphic target and no foreign keys; staff referenced by username.
- Three deliberate redundancies, to be justified in M3: the cached wallet balance, the fee snapshot and the current transaction status.

**AI assistance used:** drafted the requirements document (data dictionary, business rules, functional and non-functional requirements, relationship and traceability tables) to my specification; generated the Graphviz DOT source for the Chen ERD and rendered it to SVG and PNG; generated the render-and-count check captured as evidence.

**How it was verified:**
- Graphviz 16.1 rendered SVG and PNG with exit code 0 (`evidence/m2_erd_render.txt`).
- An automated count of the rendered SVG matched the source: 22 entities and relationships, 65 attributes (legend and page background excluded).
- I inspected the rendered diagram for readability; the first layout was unreadable and was rebuilt with fixed node positions.
- The traceability table was checked so that every entity and relationship maps to a business rule, and BR-01 to BR-17 each appear in the ERD (BR-18, access control, is implemented in M4).
- Confirmed that PostgreSQL 16 accepts `transaction` as an unquoted table name.

---

## M3: Logical design: relational schema, keys, constraints and normalisation (10 Nov 2026)

**My decisions:** named CHECK constraints rather than ENUM types; `ON DELETE RESTRICT` for all financial foreign keys (records are closed, never deleted), with CASCADE only for phone numbers and saved beneficiaries; surrogate identity keys with every natural key kept as a UNIQUE alternate key; integer kobo and UTC timestamps throughout.

**Design decisions (approved at review):**
- HOLDS mapped as a UNIQUE foreign key on `wallet` (not on `merchant`), so every wallet's owner sits in one table under one exclusive-ownership CHECK.
- REVERSES mapped to its own `reversal` relation, so "reversed at most once" is a primary key and transactions carry no reversal-only NULL columns.
- The national ID number is unique per ID type (BVN and NIN are separate numbering schemes); the requirements document was updated to match.
- The national ID CHECK requires the synthetic `999` prefix, so the portfolio database cannot hold a real BVN or NIN.
- Non-overlapping fee rules enforced with an exclusion constraint (`btree_gist`).
- A foreign-key note added to the ERD notation section (prompted by my question about where the wallet links are on the diagram).

**AI assistance used:** drafted `schema.md` (mapping rules, keys, column and constraint tables) and `normalisation.md` (sample report, functional dependencies, UNF to BCNF steps, redundancy justification) to my specification.

---

## M4: Physical design: PostgreSQL implementation and tests (10 Nov 2026)

**My decisions:** the implementation as plain, re-runnable SQL scripts in a dedicated `oworail` schema; one database role per user group from the requirements, with least privilege; tests that switch roles with `SET ROLE` instead of creating login accounts; a small fixed seed that reproduces the normalisation sample, with the large volume dataset kept for Portfolio 2; the standard evidence format for every test output.

**Design decisions (approved at review):**
- The posting, reversal, onboarding and KYC functions are `SECURITY DEFINER` and owned by a separate `oworail_owner` role. They are the only way the application can change money; it has no direct write access to wallets, transactions or the ledger.
- Five roles instead of the three first planned: compliance and analyst roles were added so that every user group in the requirements has a matching role.
- The balanced-ledger rule is a deferred constraint trigger on both `ledger_entry` and `transaction`, so a SUCCESSFUL transaction without lines is caught as well as an unbalanced one.
- Business refusals (insufficient funds, KYC limits, frozen wallets) are recorded as FAILED transactions with a reason; invalid requests (wrong wallet type, unknown wallet) raise an error and record nothing.
- A customer whose KYC is not yet verified is held to Tier 1 limits.
- A reversal is refused if the receiver no longer holds the funds.
- The seed includes an expired fee rule, to show that past transactions keep the fee they were charged.
- Views use `security_invoker`, so they can't be used to bypass table privileges.
- Tests identify each failure by the constraint name PostgreSQL reports and run in a subtransaction that is always rolled back; a catalogue check compares the built database with schema.md.

**AI assistance used:** generated the SQL build scripts, the seed, the four test scripts and their harness, the catalogue-check and build-and-test Python scripts, and drafted the implementation and testing sections of the Portfolio 1 README, to my specification.

**How it was verified:**
- The full build ran twice in a row without error (`evidence/m4_build.txt`).
- Constraint tests: 120 of 120 passed. Each of the 94 constraints rejected a bad row with its own name, and an unbalanced posting was rejected at a real COMMIT, leaving no rows behind. One test first failed because a wallet with an unknown type breaks two CHECK constraints and PostgreSQL reports the other one first; the test was corrected to record that, and a second test shows the wallet-type check on its own.
- Procedure tests 40 of 40, role tests 41 of 41, consistency checks 13 of 13 with zero violations, catalogue check 9 of 9.
- The FK-index part of the catalogue check was itself tested: with one index dropped (in a rolled-back transaction) it reported the uncovered foreign key.
- The balances, fees, ledger lines and statuses of the 2 November sample matched normalisation.md, and the balances after all tests were unchanged.
- No `.env` secret appears in any evidence file; all new files have LF line endings.

---

## M5–M6: Query processing and optimisation (10 Nov 2026)

**My decisions:** a dataset of about one million transactions on the Portfolio 1 schema; a workload of queries taken from OwoRail's real operations (support lookups, statements, the KYC limit check, reconciliation, fraud, settlement, failure reporting, dormant wallets); measuring with `EXPLAIN (ANALYZE, BUFFERS)` under the server's default settings; optimising in separate, measured steps.

**Design decisions (approved at review):**
- The volume data is generated in SQL from hashes of the row number, so it is identical on every run, and loaded in bulk with the two balanced-ledger triggers switched off; the full Portfolio 1 consistency checks are run over it afterwards instead.
- Buffers are recorded next to times, because timings on a shared laptop vary, and every phase checks that each query returns exactly the same rows.
- A 30-second limit per query, so the NOT IN baseline is recorded as "did not finish" instead of running for hours.
- Composite and covering indexes that replace three single-column foreign-key indexes; a higher statistics target for `ledger_entry.wallet_id`; a materialised view for monthly settlement; NOT EXISTS for the dormant-wallet query; a statement query rewritten to read the transaction indexes backwards.
- Alternatives that were tested and rejected are kept as evidence: more work_mem for the reconciliation, pre-aggregation for settlement, the partial index for failures.
- MongoDB is stopped during the measurements; its healthcheck was taking CPU.

**AI assistance used:** generated the volume generator, the workload and rewritten queries, the index and tuning scripts, the experiment, size and write-cost scripts, and the Python runner and pipeline, and drafted the Portfolio 2 README and the performance analysis, to my specification.

**How it was verified:**
- The volume dataset (1,101,109 transactions, 2,870,951 ledger lines) passed all 13 consistency checks with zero violations.
- All nine queries returned identical rows (hash of every row) in each phase that finished; the NOT IN and NOT EXISTS versions of Q9 were compared directly and match.
- The whole pipeline ran from a fresh build with every step exiting 0; no `.env` secret appears in any output.
- Figures in the analysis were checked against the captured plans; two that came from exploratory runs were corrected or removed.
- Honest negatives kept in the analysis: the partial index was never chosen by the planner, and the indexes made posting about 16 % slower and more than doubled index space.

---

## M7–M8: Transactions and concurrency (11 Nov 2026)

**My decisions:** demonstrate every ACID property and every classic anomaly with real concurrent sessions rather than describing them; test the real posting function under load, not only toy examples;

**Design decisions (approved at review):**
- Sessions are driven in a fixed order, and a session's wait is confirmed in `pg_stat_activity` / `pg_blocking_pids()` before the script continues, so every interleaving is repeatable.
- The deliberately unsafe patterns (lost update, unordered locking, write skew) run on a separate `lab` table, so the OwoRail ledger is never made invalid.
- Durability is tested by killing the server with SIGKILL and reading PostgreSQL's own recovery log.
- `deadlock_timeout` is lowered to 100 ms only inside the deadlock load test, so 100 deadlocks don't take 100 seconds.
- The FEES wallet hot row is measured and reported as a design limit, with possible fixes.

**AI assistance used:** generated the session helper, the three demo scripts, the lab schema and the pipeline script, and drafted the README, the two-terminal guide and the concurrency analysis, to my specification.

**How it was verified:**
- The pipeline ran from a fresh build: transactions 18 of 18, isolation 10 of 10, locking and concurrency 21 of 21 checks; the Portfolio 1 consistency checks afterwards passed 13 of 13 with zero violations.
- Problems found and fixed before the final run: polling `pg_stat_activity` from a session inside an open transaction returns a stale snapshot, so blocking is now detected from a separate connection; test phone numbers had one digit too many; one load-test wallet would have hit the Tier 1 daily limit before "insufficient funds", so it is now funded with exactly 50,000; the crash test's log window also picked up an earlier run's recovery, so it now reads the log from the moment of the kill.
- Every figure in the analysis was checked against the captured evidence; no `.env` secret appears in any output.

---
