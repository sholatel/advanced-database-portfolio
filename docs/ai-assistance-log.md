# AI Assistance Log

This log records, milestone by milestone, how I (Yusuf O. Sholadoye) used an AI assistant in this portfolio, what I changed, and how I verified the results. It is the basis for the AI Use Declaration required by CA §11.

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
