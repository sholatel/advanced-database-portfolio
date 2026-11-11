# Portfolio 5: Distributed and Cloud Database Exercise

> **Status:** complete. A distributed and cloud design for OwoRail, backed by a three-node replica set and a small sharded cluster; 25 automated checks passing. The design is in [design.md](design.md).

## Purpose
Design how OwoRail's database would be distributed and deployed in the cloud: fragmentation, allocation, replication, consistency per data type, availability and CAP position, sharding, and the deployment model under Nigerian data-protection rules. Back the design with **working clusters** that demonstrate replication, automatic failover, consistency settings and sharding.

## Required evidence
- [x] Distributed / cloud database discussion based on the same case study: [design.md](design.md)
- [x] Setup evidence: [setup.md](setup.md), [m10_setup.txt](evidence/m10_setup.txt), R0 and S0 in the evidence files
- [x] Replication: [m10_replication.txt](evidence/m10_replication.txt), R1 (oplog, lag) and R2 (write concerns)
- [x] Sharding: [m10_sharding.txt](evidence/m10_sharding.txt), S1 (hashed key, query targeting) and S2 (hot spot)
- [x] Availability: R3 (failover under load), R3b (rejoin), S3 (a shard outage)
- [x] Consistency: R4 (a w:1 write rolled back, w:majority not), R5 (stale reads, causal consistency)
- [x] Deployment: [design.md](design.md#deployment)

## Contents
| Path | Contents |
|---|---|
| [design.md](design.md) | requirements, architecture diagram, fragmentation and allocation, measured replication and consistency, CAP/PACELC, sharding, deployment |
| [setup.md](setup.md) | exact commands to start, use and remove both clusters |
| [docker-compose.replicaset.yml](docker-compose.replicaset.yml) | replica set `rs5`: three `mongo:7.0` members on ports 27021–27023 |
| [docker-compose.sharded.yml](docker-compose.sharded.yml) | config server, two shards and a `mongos` router on ports 27030–27033 |
| [scripts/replication.py](scripts/replication.py) | R0–R5: setup, replication, write concerns, failover, rollback, stale and causal reads |
| [scripts/sharding.py](scripts/sharding.py) | S0–S3: setup, hashed key and targeting, hot spot, shard outage |
| [scripts/cluster.py](scripts/cluster.py) | shared helpers |
| [scripts/run_portfolio5.py](scripts/run_portfolio5.py) | everything from empty clusters, with evidence capture |

## How it was implemented

Each cluster is a Compose file of its own, separate from the main stack. All nodes in a cluster share the network namespace of a small `net` container and listen on their own ports. Member addresses such as `127.0.0.1:27022` are therefore the same inside the cluster and from the host, so a driver on the host can follow the replica set through a failover. Because the namespace belongs to `net`, nodes can be killed and restarted without the network going down. `net` also writes the keyfile the members share. Ports are bound to localhost only.

The scripts drive the clusters from the host with pymongo and Docker:
- **Failure:** a node is "crashed" with `docker compose kill` (SIGKILL).
- **Isolation:** a primary is isolated by killing both secondaries. I first tried `docker compose pause`, but a paused node's open replication connections stay up at the kernel level. The writes it was sent sat in socket buffers and were applied as soon as it was unpaused, so pausing is not a real network partition.
- **Lag:** a secondary that falls behind is simulated with `fsyncLock`, which stops it applying the oplog.

Each scenario prints a timestamped timeline and ends with checks.

## How it was tested

```bash
.venv/Scripts/python portfolio-5-distributed-cloud/scripts/run_portfolio5.py
```

The script stops the main MongoDB container, deletes and recreates both clusters, runs every scenario, and stops the clusters at the end. It takes about 6 minutes.

| Step | Result | Evidence |
|---|---|---|
| Replica set: setup, replication, write concerns, failover, rollback, stale and causal reads | 16 of 16 checks | [m10_replication.txt](evidence/m10_replication.txt) |
| Sharded cluster: setup, hashed key, targeting, hot spot, shard outage | 9 of 9 checks | [m10_sharding.txt](evidence/m10_sharding.txt) |
| Container setup and status | all steps exit 0 | [m10_setup.txt](evidence/m10_setup.txt) |
