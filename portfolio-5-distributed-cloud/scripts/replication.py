"""Replica set rs5: setup, replication, write concerns, failover, a lost w:1 write, stale and causal reads."""
from __future__ import annotations

import statistics
import sys
import threading
import time
from datetime import datetime, timezone

from pymongo import ReadPreference
from pymongo.errors import DuplicateKeyError, PyMongoError, WTimeoutError
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern
from tabulate import tabulate

from cluster import Checks, client, compose, log, mongosh, node, scenario

FILE = "docker-compose.replicaset.yml"
PORTS = {"mongo1": 27021, "mongo2": 27022, "mongo3": 27023}
CONFIG = ('{_id: "rs5", members: ['
          '{_id: 0, host: "127.0.0.1:27021", priority: 2}, '
          '{_id: 1, host: "127.0.0.1:27022", priority: 1}, '
          '{_id: 2, host: "127.0.0.1:27023", priority: 1}]}')


def states() -> dict[str, str]:
    out = {}
    for name, port in PORTS.items():
        try:
            with node(port) as m:
                hello = m.admin.command("hello")
            out[name] = "PRIMARY" if hello.get("isWritablePrimary") else ("SECONDARY" if hello.get("secondary") else "OTHER")
        except PyMongoError:
            out[name] = "DOWN"
    return out


def wait_for(predicate, timeout: float = 60) -> float:
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < timeout:
        if predicate():
            return time.perf_counter() - t0
        time.sleep(0.2)
    raise TimeoutError("condition not reached")


def primary() -> str | None:
    return next((n for n, s in states().items() if s == "PRIMARY"), None)


def setup(c: Checks) -> None:
    scenario("R0  Initiate the replica set and create the admin user")
    status = mongosh(FILE, "mongo1", 27021, "try { rs.status().ok } catch (e) { e.codeName }")
    if "NotYetInitialized" in status:
        log("sys", mongosh(FILE, "mongo1", 27021, f"JSON.stringify(rs.initiate({CONFIG}))"))
    waited = wait_for(lambda: "PRIMARY" in mongosh(FILE, "mongo1", 27021, "db.hello().isWritablePrimary ? 'PRIMARY' : 'NO'"), 90)
    log("sys", f"mongo1 is primary after {waited:.1f} s")
    created = mongosh(FILE, "mongo1", 27021,
                      "try { db.getSiblingDB('admin').createUser({user: process.env.OWR_USER, pwd: process.env.OWR_PW, "
                      "roles: ['root']}); 'created' } catch (e) { 'already exists (' + e.codeName + ')' }")
    log("sys", f"admin user {created.splitlines()[-1]}")
    wait_for(lambda: list(states().values()).count("SECONDARY") == 2, 90)
    rs = client(list(PORTS.values()), "rs5")
    status = rs.admin.command("replSetGetStatus")
    rows = [[m["name"], m["stateStr"], m.get("syncSourceHost") or "-", m.get("health")] for m in status["members"]]
    print(tabulate(rows, headers=["member", "state", "syncing from", "health"], tablefmt="github"))
    settings = rs.admin.command("replSetGetConfig")["config"]["settings"]
    log("sys", f"electionTimeoutMillis {settings['electionTimeoutMillis']}, heartbeatIntervalMillis {settings['heartbeatIntervalMillis']}")
    c.check("three members: one PRIMARY and two SECONDARY", sorted(r[1] for r in rows) == ["PRIMARY", "SECONDARY", "SECONDARY"])
    rs.owr.drop_collection("transactions")
    rs.owr.drop_collection("ledger_probe")


def replication(c: Checks) -> None:
    scenario("R1  A write on the primary reaches both secondaries")
    rs = client(list(PORTS.values()), "rs5")
    coll = rs.owr.get_collection("transactions", write_concern=WriteConcern(w=1))
    secondaries = {n: node(PORTS[n]).owr.transactions for n, s in states().items() if s == "SECONDARY"}
    lags = {n: [] for n in secondaries}
    for i in range(20):
        ref = f"OWR5{i:011d}"
        coll.insert_one({"_id": ref, "amount_kobo": 1000 + i, "created_at": datetime.now(timezone.utc)})
        t0 = time.perf_counter()
        pending = set(secondaries)
        while pending:
            for n in list(pending):
                if secondaries[n].find_one({"_id": ref}, {"_id": 1}) is not None:
                    lags[n].append((time.perf_counter() - t0) * 1000)
                    pending.discard(n)
    for n, values in lags.items():
        log("sys", f"{n}: visible after median {statistics.median(values):.1f} ms, max {max(values):.1f} ms (20 writes)")
    entry = node(PORTS[next(iter(secondaries))]).local["oplog.rs"].find_one({"ns": "owr.transactions", "op": "i"},
                                                                          sort=[("$natural", -1)])
    log("sys", f"oplog entry on a secondary: op={entry['op']} ns={entry['ns']} o._id={entry['o']['_id']} ts={entry['ts']}")
    counts = {n: s.count_documents({}) for n, s in secondaries.items()}
    c.check("both secondaries hold all 20 documents", all(v == 20 for v in counts.values()), str(counts))
    c.check("the secondaries applied the writes from the oplog", entry["op"] == "i")


def write_concerns(c: Checks) -> None:
    scenario("R2  What each write concern costs")
    rs = client(list(PORTS.values()), "rs5")
    rows = []
    for label, wc in (("w: 1", WriteConcern(w=1)), ("w: majority", WriteConcern(w="majority")),
                      ("w: 3 (all)", WriteConcern(w=3)), ("w: majority, j: true", WriteConcern(w="majority", j=True))):
        coll = rs.owr.get_collection("ledger_probe", write_concern=wc)
        times = []
        for i in range(200):
            t0 = time.perf_counter()
            coll.insert_one({"label": label, "i": i})
            times.append((time.perf_counter() - t0) * 1000)
        rows.append([label, round(statistics.median(times), 2), round(sorted(times)[189], 2)])
    print(tabulate(rows, headers=["write concern", "median ms", "p95 ms"], tablefmt="github"))
    c.check("waiting for a majority costs more than w:1", rows[0][1] < rows[1][1], f"{rows[0][1]} < {rows[1][1]} ms")


def failover(c: Checks) -> None:
    scenario("R3  Automatic failover: the primary is killed while a client keeps writing")
    rs = client(list(PORTS.values()), "rs5", serverSelectionTimeoutMS=30000)
    coll = rs.owr.get_collection("failover", write_concern=WriteConcern(w="majority"))
    coll.drop()
    acknowledged, errors, stop = [], [], threading.Event()

    def writer():
        seq = 0
        while not stop.is_set():
            try:
                coll.insert_one({"_id": seq, "at": datetime.now(timezone.utc)})
                acknowledged.append((seq, time.perf_counter()))
                seq += 1
            except DuplicateKeyError:
                acknowledged.append((seq, time.perf_counter()))
                seq += 1
            except PyMongoError as exc:
                errors.append((type(exc).__name__, time.perf_counter()))
                time.sleep(0.1)
            time.sleep(0.02)

    t = threading.Thread(target=writer)
    t.start()
    time.sleep(3)
    old = primary()
    log("sys", f"docker compose kill {old}   (writes so far: {len(acknowledged)})")
    killed_at = time.perf_counter()
    compose(FILE, "kill", old)
    wait_for(lambda: primary() not in (None, old), 60)
    new = primary()
    log("sys", f"new primary: {new}")
    time.sleep(5)
    stop.set()
    t.join()
    times = [ts for _, ts in acknowledged]
    after = [ts for ts in times if ts > killed_at]
    gap = max(b - a for a, b in zip(times, times[1:]) if b > killed_at) if after else float("nan")
    log("sys", f"longest gap between two acknowledged writes: {gap:.1f} s; errors seen by the application: "
               f"{len(errors)} ({', '.join(sorted({e for e, _ in errors})) or 'none: the driver retried the write'})")
    stored = coll.count_documents({})
    c.check("a secondary was elected and writes resumed", new not in (None, old) and bool(after), f"{old} -> {new}")
    c.check("writes paused for about the election time, then resumed", 1 < gap < 30, f"{gap:.1f} s")
    c.check("every acknowledged majority write survived the failover", stored == len(acknowledged),
            f"{len(acknowledged)} acknowledged, {stored} stored")

    scenario("R3b The old primary comes back")
    compose(FILE, "start", old)
    rejoined = wait_for(lambda: states()[old] == "SECONDARY", 120)
    log("sys", f"{old} rejoined as SECONDARY after {rejoined:.1f} s and caught up from the oplog")
    takeover = wait_for(lambda: primary() == old, 120)
    log("sys", f"{old} (priority 2) took over as PRIMARY {takeover:.1f} s later")
    c.check("the restarted node rejoins and, with the highest priority, becomes primary again", primary() == old)


def lost_write(c: Checks) -> None:
    scenario("R4  A w:1 write acknowledged by an isolated primary is rolled back")
    wait_for(lambda: primary() == "mongo1", 120)
    p = node(27021)
    coll = p.owr.get_collection("rollback_demo", write_concern=WriteConcern(w=1))
    coll.drop()
    log("sys", "docker compose kill mongo2 mongo3   (the primary is cut off from both secondaries)")
    compose(FILE, "kill", "mongo2", "mongo3")
    coll.insert_one({"_id": "A", "note": "w:1 on the isolated primary"})
    log("app", "insert A with w:1 -> acknowledged")
    try:
        p.owr.get_collection("rollback_demo", write_concern=WriteConcern(w="majority", wtimeout=3000)).insert_one(
            {"_id": "B", "note": "w:majority on the isolated primary"})
        b_result = "acknowledged"
    except WTimeoutError:
        b_result = "WTimeoutError"
    log("app", f"insert B with w:majority -> {b_result} (the client is told it is not durable)")
    log("sys", "docker compose kill mongo1; docker compose start mongo2 mongo3")
    compose(FILE, "kill", "mongo1")
    compose(FILE, "start", "mongo2", "mongo3")
    elected = wait_for(lambda: any(s == "PRIMARY" for n, s in states().items() if n != "mongo1"), 90)
    new = next(n for n, s in states().items() if n != "mongo1" and s == "PRIMARY")
    log("sys", f"{new} elected after {elected:.1f} s")
    node(PORTS[new]).owr.get_collection("rollback_demo", write_concern=WriteConcern(w="majority")).insert_one(
        {"_id": "C", "note": "w:majority on the new primary"})
    log("app", "insert C with w:majority on the new primary -> acknowledged")
    log("sys", "docker compose start mongo1")
    compose(FILE, "start", "mongo1")
    wait_for(lambda: primary() == "mongo1", 180)
    rs = client(list(PORTS.values()), "rs5")
    present = sorted(d["_id"] for d in rs.owr.rollback_demo.find())
    rollback_files = compose(FILE, "exec", "-T", "mongo1", "sh", "-c", "ls -R /data/db/rollback 2>/dev/null | head -5")
    log("sys", f"documents now in the replica set: {present}")
    log("sys", "rollback files on mongo1: " + (" ".join(rollback_files.split()) or "none"))
    c.check("isolated primary: the w:majority write is not acknowledged", b_result == "WTimeoutError")
    c.check("the w:1 write A was acknowledged and then lost", "A" not in present)
    c.check("B was rolled back too, but the client had been told", "B" not in present)
    c.check("the majority write C on the new primary is kept", "C" in present)
    c.check("the rolled-back data is saved to a rollback file", "rollback_demo" in rollback_files or ".bson" in rollback_files)


def stale_and_causal(c: Checks) -> None:
    scenario("R5  Reading from a secondary: stale reads, and causal consistency")
    wait_for(lambda: primary() == "mongo1" and list(states().values()).count("SECONDARY") == 2, 120)
    rs = client(list(PORTS.values()), "rs5")
    rs.owr.reads.drop()
    lagging = node(27023)
    lagging.admin.command("fsync", lock=True)
    log("sys", "mongo3: fsyncLock (it stops applying the oplog, as a badly lagging secondary would)")
    rs.owr.get_collection("reads", write_concern=WriteConcern(w="majority")).insert_one({"_id": "D", "balance_kobo": 5000})
    log("app", "insert D with w:majority -> acknowledged by mongo1 and mongo2")
    on_lagging = lagging.owr.reads.find_one({"_id": "D"})
    on_primary = rs.owr.get_collection("reads", read_concern=ReadConcern("majority")).find_one({"_id": "D"})
    log("app", f"read D on mongo3: {on_lagging}; on the primary (majority): {on_primary is not None}")
    lagging.admin.command("fsyncUnlock")
    caught_up = wait_for(lambda: lagging.owr.reads.find_one({"_id": "D"}) is not None, 30)
    log("sys", f"mongo3 unlocked; D visible there after {caught_up * 1000:.0f} ms")
    c.check("a lagging secondary returns stale data (D missing)", on_lagging is None)
    c.check("the primary with majority read concern returns D", on_primary is not None)

    misses = 0
    with rs.start_session(causal_consistency=True) as s:
        coll = rs.owr.get_collection("reads", write_concern=WriteConcern(w="majority"),
                                     read_concern=ReadConcern("majority"), read_preference=ReadPreference.SECONDARY)
        for i in range(50):
            coll.update_one({"_id": "D"}, {"$inc": {"balance_kobo": 100}}, session=s)
            if coll.find_one({"_id": "D"}, session=s)["balance_kobo"] != 5000 + 100 * (i + 1):
                misses += 1
    log("app", f"causal session: 50 updates each read back from a secondary, {misses} stale reads")
    c.check("in a causally consistent session a secondary read always sees the session's own write", misses == 0)


def main() -> int:
    c = Checks("Replica set")
    setup(c)
    replication(c)
    write_concerns(c)
    failover(c)
    lost_write(c)
    stale_and_causal(c)
    return c.summary()


if __name__ == "__main__":
    sys.exit(main())
