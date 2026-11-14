# AI Use Declaration

Yusuf O. Sholadoye, MIT 8103 Advanced Database Systems, continuous assessment, September 2026 cohort.

## 1. The AI tool used

**Claude Code** (Anthropic), an AI coding assistant that works in the terminal and in VS Code, running the Claude Opus 5.5 model. I used no other AI tool.

## 2. What I used it for

I chose the case study (OwoRail, a Lagos digital-wallet operator) and its data conventions: integer kobo, a double-entry ledger, idempotency keys, UTC timestamps and synthetic `999` identity numbers. I chose the technology stack and the order of the work, and for each part of the portfolio I specified what had to be built and decided what to accept. I used Claude Code as a coding and writing assistant within that plan:

| Part | What the assistant did |
|---|---|
| Planning | inspected my machine (installed tools, free ports), summarised the assessment brief, and drafted a plan for each milestone, which I approved or changed before any work started |
| Portfolio 1 | drafted the requirements document, the Chen ER diagram source, the relational schema and the normalisation write-up; generated the PostgreSQL build scripts (tables and constraints, triggers, procedures, roles, seed data) and the test scripts |
| Portfolio 2 | generated the volume-data generator, the query workload, the index and tuning scripts and the measurement runner; drafted the performance analysis |
| Portfolio 3 | generated the concurrency demos that drive several database sessions; drafted the analysis and the two-terminal guide |
| Portfolio 4 | generated the MongoDB schema, loader, query, validation and transaction scripts; drafted the document model and the suitability analysis |
| Portfolio 5 | generated the replica set and sharded cluster configurations and the demo scripts; drafted the distributed and cloud design |
| Final documentation | drafted this declaration, the summary document and my reflection from my decisions and the problems recorded in the AI log; I reviewed the reflection against my own experience of the work and confirmed that it says what I think |

Some design choices were the assistant's recommendations, for example running the posting functions as `SECURITY DEFINER`, using a materialised view for monthly settlement, and running MongoDB as a single-node replica set. I accepted them only after reviewing each one. The [AI assistance log](ai-assistance-log.md) lists them separately for every milestone, under "Design decisions (approved at review)", so they are not presented as my own ideas.

## 3. How I reviewed, corrected, tested and verified the output

- **Everything was run, not just read.** Every script was executed against the real databases, and the outputs are saved unedited in each portfolio's `evidence/` folder, with the time, the exact command and the exit code.
- **Automated checks decide whether something works:**
  - Portfolio 1: 120 constraint tests, 40 procedure tests, 41 role tests, 13 consistency checks, and a check that the built database matches the design document;
  - Portfolio 2: each optimised query must return exactly the same rows as the original;
  - Portfolio 3: 49 checks across transactions, isolation and locking;
  - Portfolio 4: 58 checks, including every MongoDB query result compared with the same query in PostgreSQL;
  - Portfolio 5: 25 checks on the two clusters.
- **Fresh-run check.** At the end I cloned the repository into an empty folder, created new database volumes and ran all five portfolios from scratch ([fresh-run-check.md](fresh-run-check.md)). Every portfolio exited 0 and every check passed again. One measured ratio did not reproduce, so I corrected the analysis that relied on it.
- **Errors were found and corrected along the way,** some in the assistant's output and some in my plan:
  - a hand-counted total in the schema summary that the check script showed to be wrong;
  - a bug that left the original queries in the "rewritten" query file;
  - a first query rewrite that made the statement query slower;
  - a failover measurement that reported a zero-second outage;
  - a test that used `docker pause` as a network partition, which it isn't;
  - figures in the analyses that came from exploratory runs rather than the final evidence.
  Each one is recorded in the AI log with what was changed.
- **Numbers in the analyses were checked against the evidence files,** and claims the evidence didn't support were removed.
- **I reviewed the writing as well as the code.** I rewrote passages that read as machine-generated, removed mappings of the work to course sections, and checked that the documents explain decisions in my own terms.

Using an AI assistant doesn't change who is responsible for the work. I have checked what is submitted, I understand it, and I can explain any part of it: the schema, the query plans, the concurrency behaviour, the document model and the cluster behaviour.
