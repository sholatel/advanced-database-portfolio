# Portfolio 2: Query Processing and Optimisation

> **Status:** planned (milestones M5–M6). This README is a placeholder and will be completed with "how it was implemented" and "how it was tested" sections.

## Purpose
Run a realistic OwoRail query workload on a large synthetic dataset (around 1 million transactions). Analyse PostgreSQL **execution plans** before and after optimisation, and explain the results using cost-based optimisation, selectivity, statistics and access paths.

## Required evidence
- [ ] SQL queries
- [ ] Query results
- [ ] Execution plans
- [ ] Indexing / optimisation evidence
- [ ] Brief performance analysis

## Planned contents
| Path | Contents | Milestone |
|---|---|---|
| `queries.sql` | 8–10 queries mapped to OwoRail key operations | M5 |
| `scripts/run_plans.py` | Runs `EXPLAIN (ANALYZE, BUFFERS)` 5 times per query and records medians | M5 |
| `plans/before/`, `plans/after/` | Saved execution plans | M5–M6 |
| `results/` | Sample query results and timing tables | M5–M6 |
| `indexes.sql`, `rewrites.sql`, `matview.sql` | Optimisations, applied one at a time | M6 |
| `performance.md` | Before/after comparison and analysis | M6 |
