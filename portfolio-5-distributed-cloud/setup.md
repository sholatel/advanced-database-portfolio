# Setting up the Portfolio 5 clusters

Both clusters run on one machine in Docker. They use the MongoDB credentials from the repository's `.env` and listen on localhost only. They are separate from the main `docker-compose.yml` stack. Stop the main MongoDB while they run, so the machine isn't running seven `mongod` processes at once:

```bash
docker compose stop mongo
```

## Everything at once

```bash
.venv/Scripts/python portfolio-5-distributed-cloud/scripts/run_portfolio5.py
```

This deletes and recreates both clusters, runs every scenario and saves the output in `evidence/`. It takes about 6 minutes.

## Replica set rs5 by hand

```bash
docker compose -f portfolio-5-distributed-cloud/docker-compose.replicaset.yml --env-file .env up -d
.venv/Scripts/python portfolio-5-distributed-cloud/scripts/replication.py
```

| Member | Address | Priority |
|---|---|---|
| mongo1 | 127.0.0.1:27021 | 2 (preferred primary) |
| mongo2 | 127.0.0.1:27022 | 1 |
| mongo3 | 127.0.0.1:27023 | 1 |

The script initiates the replica set on its first run. It then creates the admin user through the localhost exception: before any user exists, MongoDB accepts that one command from inside the container. To connect yourself:

```bash
docker compose -f portfolio-5-distributed-cloud/docker-compose.replicaset.yml --env-file .env exec mongo1 \
    mongosh --port 27021 -u root -p --authenticationDatabase admin --eval "rs.status().members.map(m => m.name + ' ' + m.stateStr)"
```

From an application, use all three members and the replica set name, so the driver follows the primary through a failover:

```text
mongodb://root:<password>@127.0.0.1:27021,127.0.0.1:27022,127.0.0.1:27023/?replicaSet=rs5&authSource=admin
```

## Sharded cluster by hand

```bash
docker compose -f portfolio-5-distributed-cloud/docker-compose.sharded.yml --env-file .env up -d
.venv/Scripts/python portfolio-5-distributed-cloud/scripts/sharding.py
```

| Component | Replica set | Address |
|---|---|---|
| mongos router | | 127.0.0.1:27030 |
| config server | cfg | 127.0.0.1:27031 |
| shard A | shardA | 127.0.0.1:27032 |
| shard B | shardB | 127.0.0.1:27033 |

Applications connect only to the router (`mongodb://root:<password>@127.0.0.1:27030/?authSource=admin`).

## How the containers are wired

Every node in a cluster joins the network namespace of a small `net` container (`network_mode: service:net`), and each node listens on its own port. A member's address, such as `127.0.0.1:27022`, then means the same thing inside the cluster and from the host. That's what lets a driver on the host follow the replica set. A node can be killed, paused or restarted without the network disappearing, because the namespace belongs to `net`. `net` also writes the keyfile the members use to authenticate each other.

This is a single-machine teaching setup. In production, each member would run on a separate host or availability zone, with TLS between members and clients (see [design.md](design.md)).

## Clean up

```bash
docker compose -f portfolio-5-distributed-cloud/docker-compose.replicaset.yml --env-file .env down -v
docker compose -f portfolio-5-distributed-cloud/docker-compose.sharded.yml --env-file .env down -v
docker compose start mongo
```
