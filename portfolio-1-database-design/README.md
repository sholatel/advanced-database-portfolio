# Portfolio 1: Database Design and Modelling

> **Status:** in progress. Done so far: [requirements, business rules and conceptual design](requirements-and-business-rules.md) with the [Chen ERD](erd/erd-chen.png), and the logical design: [relational schema, keys and constraints](schema.md) and [normalisation to BCNF](normalisation.md). The PostgreSQL implementation comes next, with "how it was implemented" and "how it was tested" sections.

## Purpose
Design OwoRail's relational database through the **stages of database design**: Requirements Analysis → Conceptual Design (ER model, Chen notation) → Logical Design (relational schema, keys, constraints, normalisation) → Physical Design (PostgreSQL 16 implementation, roles, indexes) → Testing and Evaluation.

## Required evidence
- [x] Chosen case study description (see the [root README](../README.md#1-selected-case-study-oworail))
- [x] ER diagram (Chen notation): [erd/erd-chen.png](erd/erd-chen.png)
- [x] Relational schema: [schema.md: relational schema](schema.md#2-relational-schema-text-notation)
- [x] Keys: [schema.md: keys](schema.md#3-keys)
- [x] Constraints: [schema.md: constraints](schema.md#4-relations-columns-and-constraints) (implementation and tests to follow)
- [x] Normalisation explanation: [normalisation.md](normalisation.md)

## Planned contents
| Path | Contents |
|---|---|
| `requirements-and-business-rules.md` | Stage 1 Requirements Analysis, numbered business rules |
| `erd/` | Chen-notation ERD: DOT source, SVG and PNG |
| `schema.md` | Relational schema; keys and constraints traced to business rules |
| `normalisation.md` | Functional dependencies, UNF → 1NF → 2NF → 3NF → BCNF |
| `sql/` | Schema, roles, seed data, volume data, constraint tests |
| `evidence/` | Captured outputs |
