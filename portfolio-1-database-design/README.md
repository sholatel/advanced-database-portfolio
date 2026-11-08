# Portfolio 1: Database Design and Modelling (7 marks)

> **Status:** in progress. M2 is done: [requirements, business rules and conceptual design](requirements-and-business-rules.md), plus the [Chen ERD](erd/erd-chen.png). Logical design (M3) and implementation (M4) follow; "how it was implemented" and "how it was tested" sections will be added in M4.

## Purpose
Design OwoRail's relational database through the course's **stages of database design** (Course §1.1.2): Requirements Analysis → Conceptual Design (ER model, Chen notation) → Logical Design (relational schema, keys, constraints, normalisation) → Physical Design (PostgreSQL 16 implementation, roles, indexes) → Testing and Evaluation.

## Required evidence (CA §4)
- [ ] Chosen case study description (see the [root README](../README.md#1-selected-case-study-oworail))
- [ ] ER diagram (Chen notation)
- [ ] Relational schema
- [ ] Keys
- [ ] Constraints
- [ ] Normalisation explanation

## Course concepts applied
- §1.1.2 Stages of Database Design
- §1.1.6 Characteristics of a Good Database
- §1.1.7 Normalisation (1NF, 2NF, 3NF, BCNF; balancing normalisation against performance)
- §3.2.2 Introduction to Database Security (role-based access control, least privilege)

## Planned contents
| Path | Contents | Milestone |
|---|---|---|
| `requirements-and-business-rules.md` | Stage 1 Requirements Analysis, numbered business rules | M2 |
| `erd/` | Chen-notation ERD: DOT source, SVG and PNG | M2 |
| `schema.md` | Relational schema; keys and constraints traced to business rules | M3 |
| `normalisation.md` | Functional dependencies, UNF → 1NF → 2NF → 3NF → BCNF | M3 |
| `sql/` | Schema, roles, seed data, volume data, constraint tests | M4 |
| `evidence/` | Captured outputs | M1–M4 |
