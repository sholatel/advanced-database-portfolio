# Portfolio 4: NoSQL and Advanced Data Models (7 marks)

> **Status:** planned (milestone M9). This README is a placeholder and will be completed with "how it was implemented" and "how it was tested" sections.

## Purpose
Model OwoRail's data in **MongoDB (document model)**, starting from its access patterns. Load a consistent subset of the same data used in Portfolio 1. Demonstrate CRUD, aggregation pipelines, schema validation, and indexing with `explain()`. Then argue which OwoRail data belongs in a document store and which must stay relational (polyglot persistence).

## Required evidence (CA §4)
- [ ] NoSQL model based on the same case study
- [ ] Document / key-value / column / graph example
- [ ] Implementation evidence
- [ ] Explanation of suitability

## Course concepts applied
- §1.1.3 Types of Database Systems (NoSQL: document, key-value, column-family, graph)
- §2.2.1 CAP Theorem, DBASE vs ACID Models
- §2.2.2 Trade-offs in Distributed Systems (CAP, BASE and ACID)
- §5.2.1 Graph Databases and Knowledge Graphs (only if the optional graph example is approved)

## Planned contents
| Path | Contents | Milestone |
|---|---|---|
| `model.md` | Access patterns, collections, relational-to-document mapping, sample documents | M9 |
| `scripts/` | Loader from PostgreSQL; CRUD, aggregation, validation and index scripts | M9 |
| `suitability.md` | Relational vs document for OwoRail; CAP, ACID vs DBASE | M9 |
| `evidence/` | Captured outputs | M1, M9 |
