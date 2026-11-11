"""Sharded cluster: setup, a hashed shard key, query targeting, a monotonic-key hot spot, a shard outage."""
from __future__ import annotations

import random
import sys
import time
from datetime import datetime, timedelta, timezone

from bson.int64 import Int64
from pymongo.errors import PyMongoError
from tabulate import tabulate

from cluster import Checks, client, compose, log, mongosh, scenario

FILE = "docker-compose.sharded.yml"
ROUTER = 27030
WALLETS = 20000
START = datetime(2026, 5, 1, tzinfo=timezone.utc)


def initiate(service: str, port: int, rs: str, configsvr: bool = False) -> None:
    status = mongosh(FILE, service, port, "try { rs.status().ok } catch (e) { e.codeName }")
    if "NotYetInitialized" in status:
        extra = "configsvr: true, " if configsvr else ""
        mongosh(FILE, service, port, f'rs.initiate({{_id: "{rs}", {extra}members: [{{_id: 0, host: "127.0.0.1:{port}"}}]}})')
    for _ in range(90):
        if "true" in mongosh(FILE, service, port, "db.hello().isWritablePrimary"):
            log("sys", f"{rs} ({service}, port {port}) is primary")
            return
        time.sleep(1)
    raise TimeoutError(rs)


def per_shard(db, coll: str) -> dict[str, int]:
    return {d["shard"]: d["storageStats"]["count"]
            for d in db[coll].aggregate([{"$collStats": {"storageStats": {}}}])}


def wallet(rng: random.Random) -> str:
    return f"31{1 + int(WALLETS * rng.random() ** 2):08d}"


def docs(rng: random.Random, n: int, first: int, start: datetime, span_s: int) -> list[dict]:
    return [{"_id": f"OWR6{first + i:011d}", "type": "TRANSFER",
             "source": {"wallet": wallet(rng)}, "destination": {"wallet": wallet(rng)},
             "amount_kobo": Int64(10000 * (1 + int(500 * rng.random() ** 3))), "status": "SUCCESSFUL",
             "created_at": start + timedelta(seconds=int(span_s * (i / n)))} for i in range(n)]


def targeting(db, flt: dict) -> tuple[str, list[str]]:
    plan = db.command("explain", {"find": "transactions", "filter": flt}, verbosity="queryPlanner")
    winning = plan["queryPlanner"]["winningPlan"]
    return winning["stage"], sorted(s["shardName"] for s in winning.get("shards", []))


def setup(c: Checks) -> None:
    scenario("S0  Config server, two shards and a mongos router")
    initiate("config", 27031, "cfg", configsvr=True)
    initiate("shard_a", 27032, "shardA")
    initiate("shard_b", 27033, "shardB")
    for _ in range(90):
        if "1" in mongosh(FILE, "router", ROUTER, "db.adminCommand('ping').ok"):
            break
        time.sleep(2)
    created = mongosh(FILE, "router", ROUTER,
                      "try { db.getSiblingDB('admin').createUser({user: process.env.OWR_USER, pwd: process.env.OWR_PW, "
                      "roles: ['root']}); 'created' } catch (e) { 'already exists (' + e.codeName + ')' }")
    log("sys", f"admin user on the cluster {created.splitlines()[-1]}")
    mongos = client([ROUTER])
    shards = {s["_id"] for s in mongos.admin.command("listShards")["shards"]}
    for name, port in (("shardA", 27032), ("shardB", 27033)):
        if name not in shards:
            mongos.admin.command("addShard", f"{name}/127.0.0.1:{port}", name=name)
    listed = mongos.admin.command("listShards")["shards"]
    print(tabulate([[s["_id"], s["host"], s["state"]] for s in listed], headers=["shard", "host", "state"],
                   tablefmt="github"))
    c.check("two shards are registered with the router", len(listed) == 2)
    mongos.drop_database("owr")


def hashed_key(c: Checks) -> None:
    scenario("S1  transactions sharded on a hashed source wallet")
    mongos = client([ROUTER])
    db = mongos.owr
    mongos.admin.command("shardCollection", "owr.transactions", key={"source.wallet": "hashed"})
    rng, t0 = random.Random(2026), time.perf_counter()
    for b in range(40):
        db.transactions.insert_many(docs(rng, 5000, b * 5000, START + timedelta(days=4.6 * b), 4 * 86400), ordered=False)
    log("sys", f"200,000 transactions inserted through mongos in {time.perf_counter() - t0:.1f} s")
    spread = per_shard(db, "transactions")
    chunks = mongos.config.chunks.aggregate([
        {"$lookup": {"from": "collections", "localField": "uuid", "foreignField": "uuid", "as": "c"}},
        {"$match": {"c._id": "owr.transactions"}}, {"$group": {"_id": "$shard", "chunks": {"$sum": 1}}}])
    log("sys", f"documents per shard: {spread}; chunks per shard: {{{', '.join(f'{d['_id']}: {d['chunks']}' for d in chunks)}}}")
    share = min(spread.values()) / sum(spread.values())
    c.check("the hashed key spreads the data over both shards", share > 0.35, f"smaller shard holds {share:.0%}")

    busy = "3100000001"
    rows = []
    for label, flt in (("one wallet's payments (shard key)", {"source.wallet": busy}),
                       ("one wallet's incoming payments (not the shard key)", {"destination.wallet": busy}),
                       ("one day (not the shard key)", {"created_at": {"$gte": datetime(2026, 7, 1, tzinfo=timezone.utc),
                                                                       "$lt": datetime(2026, 7, 2, tzinfo=timezone.utc)}})):
        stage, shards = targeting(db, flt)
        rows.append([label, stage, ", ".join(shards)])
    print(tabulate(rows, headers=["query", "plan at mongos", "shards asked"], tablefmt="github"))
    c.check("a query on the shard key goes to one shard", rows[0][1] == "SINGLE_SHARD" and len(rows[0][2].split(", ")) == 1)
    c.check("a query without the shard key is sent to every shard (scatter-gather)",
            rows[1][1] == "SHARD_MERGE" and len(rows[1][2].split(", ")) == 2)


def hot_spot(c: Checks) -> None:
    scenario("S2  A shard key that only grows: created_at")
    mongos = client([ROUTER])
    db = mongos.owr
    mongos.admin.command("shardCollection", "owr.txn_by_time", key={"created_at": 1})
    middle = datetime(2026, 8, 1, tzinfo=timezone.utc)
    mongos.admin.command("split", "owr.txn_by_time", middle={"created_at": middle})
    for point, shard in ((START, "shardA"), (middle + timedelta(days=1), "shardB")):
        try:
            mongos.admin.command("moveChunk", "owr.txn_by_time", find={"created_at": point}, to=shard, _waitForDelete=True)
        except PyMongoError as exc:
            if "already" not in str(exc):
                raise
    rng = random.Random(7)
    db.txn_by_time.insert_many(docs(rng, 50000, 0, START, 183 * 86400), ordered=False)
    history = per_shard(db, "txn_by_time")
    log("sys", f"May-October history, split at 1 August: {history}")

    before_time, before_hash = per_shard(db, "txn_by_time"), per_shard(db, "transactions")
    now = datetime(2026, 11, 11, 9, tzinfo=timezone.utc)
    new = docs(rng, 10000, 900000, now, 3600)
    db.txn_by_time.insert_many([dict(d) for d in new], ordered=False)
    db.transactions.insert_many([dict(d) for d in new], ordered=False)
    after_time, after_hash = per_shard(db, "txn_by_time"), per_shard(db, "transactions")
    rows = [[key, *[after[s] - before[s] for s in sorted(after)]]
            for key, before, after in (("created_at (ranged)", before_time, after_time),
                                       ("source.wallet (hashed)", before_hash, after_hash))]
    print(tabulate(rows, headers=["shard key", *sorted(after_time)], tablefmt="github"))
    time_new = rows[0][1:]
    hash_new = rows[1][1:]
    c.check("with a ranged time key, every new write lands on one shard", min(time_new) == 0 and max(time_new) == 10000,
            str(time_new))
    c.check("with a hashed wallet key, new writes are shared", min(hash_new) > 3000, str(hash_new))


def outage(c: Checks) -> None:
    scenario("S3  One shard is down")
    mongos = client([ROUTER], serverSelectionTimeoutMS=5000)
    db = mongos.owr
    on_a = next(d["source"]["wallet"] for d in db.transactions.find({}, {"source.wallet": 1}).limit(200)
                if targeting(db, {"source.wallet": d["source"]["wallet"]})[1] == ["shardA"])
    log("sys", "docker compose stop shard_b")
    compose(FILE, "stop", "shard_b")
    try:
        targeted = db.transactions.count_documents({"source.wallet": on_a}, maxTimeMS=20000)
        targeted_ok = True
    except PyMongoError as exc:
        targeted, targeted_ok = type(exc).__name__, False
    try:
        db.transactions.count_documents({}, maxTimeMS=20000)
        scatter_ok = True
        scatter = "answered"
    except PyMongoError as exc:
        scatter_ok, scatter = False, type(exc).__name__
    partial = len(list(db.transactions.find({"amount_kobo": {"$gt": 0}}, {"_id": 1}, allow_partial_results=True,
                                            max_time_ms=20000)))
    log("app", f"query for wallet {on_a} (on shardA): {targeted}")
    log("app", f"count over the whole collection: {scatter}")
    log("app", f"the same scan with allowPartialResults: {partial:,} documents (shardA only)")
    compose(FILE, "start", "shard_b")
    c.check("queries that only need the healthy shard still work", targeted_ok)
    c.check("queries that need every shard fail", not scatter_ok)
    c.check("a partial answer is possible if the application asks for it", 0 < partial < 210000, f"{partial:,}")


def main() -> int:
    c = Checks("Sharded cluster")
    setup(c)
    hashed_key(c)
    hot_spot(c)
    outage(c)
    return c.summary()


if __name__ == "__main__":
    sys.exit(main())
