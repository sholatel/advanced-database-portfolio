# Portfolio 5: Distributed and Cloud Database Exercise

> **Status:** planned (milestone M10). This README is a placeholder and will be completed with "how it was implemented" and "how it was tested" sections.

## Purpose
Design how OwoRail's database would be distributed and deployed in the cloud: fragmentation, allocation, replication, consistency per data type, availability and CAP position, sharding, and the deployment model under Nigerian data-protection rules. Back the design with a **working three-node MongoDB replica set** that demonstrates replication, automatic failover and consistency settings.

## Required evidence
- [ ] Distributed / cloud database discussion based on the same case study
- [ ] Setup evidence
- [ ] Replication
- [ ] Sharding
- [ ] Availability
- [ ] Consistency
- [ ] Deployment

## Planned contents
| Path | Contents | Milestone |
|---|---|---|
| `design.md` | Distributed and cloud design with an architecture diagram | M10 |
| `docker-compose.replicaset.yml` | Three `mongo:7.0` nodes (replica set `rs0`) | M10 |
| `setup.md` | Exact reproducible commands | M10 |
| `scripts/`, `evidence/` | Init, failover and consistency demos; captured outputs | M10 |
