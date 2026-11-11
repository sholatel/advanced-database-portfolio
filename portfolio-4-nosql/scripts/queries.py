"""The OwoRail workload in MongoDB: explain() before and after indexes, checked against PostgreSQL."""
from __future__ import annotations

import hashlib
import json
import statistics
import sys
import time
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path

from pymongo import ASCENDING, DESCENDING, IndexModel
from pymongo.errors import ExecutionTimeout
from tabulate import tabulate

from common import Checks, mongo_client, pg_connect, section

P4 = Path(__file__).resolve().parents[1]
RUNS, TIMEOUT_MS = 5, 30000
LONG_TIMEOUT_MS = {"Q5": 120000}
BUSY, PHONE, REF = "3100000001", "+2349000013424", "OWR100000470468"


def utc(*a) -> datetime:
    return datetime(*a, tzinfo=timezone.utc)


QUERIES = [
    ("Q1", "customer and wallets by phone", "customers", [
        {"$match": {"phones": PHONE}},
        {"$lookup": {"from": "wallets", "localField": "_id", "foreignField": "owner.customer_id", "as": "wallets"}},
        {"$unwind": "$wallets"},
        {"$project": {"_id": 0, "customer_id": "$_id", "full_name": 1, "wallet": "$wallets._id",
                      "balance": "$wallets.balance_kobo"}},
        {"$sort": {"wallet": 1}}],
     """SELECT c.customer_id, c.full_name, w.wallet_number, w.balance_kobo FROM oworail.customer_phone p
        JOIN oworail.customer c USING (customer_id) JOIN oworail.wallet w ON w.customer_id = c.customer_id
        WHERE p.phone_number = %(phone)s ORDER BY w.wallet_number"""),
    ("Q2", "statement: 20 latest entries of the busiest wallet", "transactions", [
        {"$match": {"entries.wallet": BUSY}},
        {"$sort": {"created_at": -1, "_id": -1}},
        {"$limit": 20},
        {"$unwind": "$entries"},
        {"$match": {"entries.wallet": BUSY}},
        {"$project": {"_id": 1, "created_at": 1, "type": 1, "entry": "$entries.type", "amount": "$entries.amount"}}],
     """SELECT t.transaction_ref, t.created_at, t.transaction_type, l.entry_type, l.amount_kobo
        FROM oworail.ledger_entry l JOIN oworail.transaction t USING (transaction_id)
        WHERE l.wallet_id = (SELECT wallet_id FROM oworail.wallet WHERE wallet_number = %(busy)s)
        ORDER BY t.created_at DESC, t.transaction_ref DESC LIMIT 20"""),
    ("Q3", "transaction with its status history by reference", "transactions", [
        {"$match": {"_id": REF}},
        {"$unwind": "$history"},
        {"$project": {"_id": 1, "type": 1, "amount_kobo": 1, "status": 1, "seq": "$history.seq",
                      "history_status": "$history.status"}}],
     """SELECT t.transaction_ref, t.transaction_type, t.amount_kobo, t.status, h.seq_no, h.status
        FROM oworail.transaction t JOIN oworail.transaction_status_history h USING (transaction_id)
        WHERE t.transaction_ref = %(ref)s ORDER BY h.seq_no"""),
    ("Q4", "amount sent today by the busiest wallet (KYC limit)", "transactions", [
        {"$match": {"source.wallet": BUSY, "status": "SUCCESSFUL", "type": {"$ne": "REVERSAL"},
                    "created_at": {"$gte": utc(2026, 10, 30), "$lt": utc(2026, 10, 31)}}},
        {"$group": {"_id": None, "sent": {"$sum": {"$add": ["$amount_kobo", "$fee_kobo"]}}}},
        {"$project": {"_id": 0, "sent": 1}}],
     """SELECT sum(t.amount_kobo + t.fee_kobo) FROM oworail.transaction t
        WHERE t.source_wallet_id = (SELECT wallet_id FROM oworail.wallet WHERE wallet_number = %(busy)s)
          AND t.status = 'SUCCESSFUL' AND t.transaction_type <> 'REVERSAL'
          AND t.created_at >= '2026-10-30' AND t.created_at < '2026-10-31'"""),
    ("Q5", "reconcile stored balances against the entries", "transactions", [
        {"$project": {"_id": 0, "entries.wallet": 1, "entries.type": 1, "entries.amount": 1}},
        {"$unwind": "$entries"},
        {"$group": {"_id": "$entries.wallet", "ledger": {"$sum": {"$cond": [
            {"$eq": ["$entries.type", "CREDIT"]}, "$entries.amount", {"$multiply": ["$entries.amount", -1]}]}}}},
        {"$lookup": {"from": "wallets", "localField": "_id", "foreignField": "_id", "as": "w"}},
        {"$unwind": "$w"},
        {"$match": {"$expr": {"$ne": ["$ledger", "$w.balance_kobo"]}}},
        {"$project": {"_id": 1, "ledger": 1, "stored": "$w.balance_kobo"}}],
     """SELECT wallet_number, ledger_balance_kobo, balance_kobo FROM oworail.v_wallet_balance
        WHERE difference_kobo <> 0"""),
    ("Q6", "wallets with 5+ outgoing payments in one day", "transactions", [
        {"$match": {"created_at": {"$gte": utc(2026, 10, 30), "$lt": utc(2026, 10, 31)},
                    "type": {"$in": ["TRANSFER", "MERCHANT_PAYMENT", "BILL_PAYMENT"]}}},
        {"$group": {"_id": "$source.wallet", "outgoing": {"$sum": 1}, "total": {"$sum": "$amount_kobo"}}},
        {"$match": {"outgoing": {"$gte": 5}}},
        {"$sort": {"outgoing": -1, "_id": 1}}],
     """SELECT w.wallet_number, count(*), sum(t.amount_kobo) FROM oworail.transaction t
        JOIN oworail.wallet w ON w.wallet_id = t.source_wallet_id
        WHERE t.created_at >= '2026-10-30' AND t.created_at < '2026-10-31'
          AND t.transaction_type IN ('TRANSFER', 'MERCHANT_PAYMENT', 'BILL_PAYMENT')
        GROUP BY w.wallet_number HAVING count(*) >= 5 ORDER BY count(*) DESC, w.wallet_number"""),
    ("Q7", "October settlement per merchant and biller", "transactions", [
        {"$match": {"status": "SUCCESSFUL", "type": {"$in": ["MERCHANT_PAYMENT", "BILL_PAYMENT"]},
                    "created_at": {"$gte": utc(2026, 10, 1), "$lt": utc(2026, 11, 1)}}},
        {"$group": {"_id": "$destination.wallet", "payments": {"$sum": 1}, "gross": {"$sum": "$amount_kobo"}}},
        {"$lookup": {"from": "merchants", "localField": "_id", "foreignField": "wallet_number", "as": "m"}},
        {"$unwind": "$m"},
        {"$project": {"_id": "$m._id", "business_name": "$m.business_name", "payments": 1, "gross": 1}},
        {"$sort": {"gross": -1, "_id": 1}}],
     """SELECT m.merchant_code, m.business_name, count(*), sum(t.amount_kobo) FROM oworail.transaction t
        JOIN oworail.wallet w ON w.wallet_id = t.destination_wallet_id JOIN oworail.merchant m ON m.merchant_id = w.merchant_id
        WHERE t.transaction_type IN ('MERCHANT_PAYMENT', 'BILL_PAYMENT') AND t.status = 'SUCCESSFUL'
          AND t.created_at >= '2026-10-01' AND t.created_at < '2026-11-01'
        GROUP BY m.merchant_code, m.business_name ORDER BY sum(t.amount_kobo) DESC, m.merchant_code"""),
    ("Q8", "failed transactions in the last 7 days by channel and reason", "transactions", [
        {"$match": {"status": "FAILED", "created_at": {"$gte": utc(2026, 10, 24), "$lt": utc(2026, 10, 31)}}},
        {"$group": {"_id": {"channel": "$channel", "reason": {"$last": "$history.reason"}}, "failures": {"$sum": 1}}},
        {"$sort": {"failures": -1, "_id.channel": 1}}],
     """SELECT t.channel, h.reason, count(*) FROM oworail.transaction t
        JOIN oworail.transaction_status_history h ON h.transaction_id = t.transaction_id AND h.status = 'FAILED'
        WHERE t.status = 'FAILED' AND t.created_at >= '2026-10-24' AND t.created_at < '2026-10-31'
        GROUP BY t.channel, h.reason ORDER BY count(*) DESC, t.channel"""),
    ("Q9", "50 largest customer wallets with no outgoing payment in 90 days", "wallets", [
        {"$match": {"type": "CUSTOMER", "status": "ACTIVE", "balance_kobo": {"$gt": 0}}},
        {"$sort": {"balance_kobo": -1, "_id": 1}},
        {"$lookup": {"from": "transactions", "localField": "_id", "foreignField": "source.wallet", "as": "recent",
                     "pipeline": [{"$match": {"created_at": {"$gte": utc(2026, 8, 2), "$lt": utc(2026, 10, 31)}}},
                                  {"$limit": 1}, {"$project": {"_id": 1}}]}},
        {"$match": {"recent": {"$size": 0}}},
        {"$limit": 50},
        {"$project": {"_id": 1, "balance_kobo": 1}}],
     """SELECT w.wallet_number, w.balance_kobo FROM oworail.wallet w
        WHERE w.wallet_type = 'CUSTOMER' AND w.status = 'ACTIVE' AND w.balance_kobo > 0
          AND NOT EXISTS (SELECT 1 FROM oworail.transaction t WHERE t.source_wallet_id = w.wallet_id
                          AND t.created_at >= '2026-08-02' AND t.created_at < '2026-10-31')
        ORDER BY w.balance_kobo DESC, w.wallet_number LIMIT 50"""),
]

WORKLOAD_INDEXES = {
    "wallets": [IndexModel([("owner.customer_id", ASCENDING)], name="ix_wallets_customer"),
                IndexModel([("balance_kobo", DESCENDING), ("_id", ASCENDING)], name="ix_wallets_balance")],
    "transactions": [
        IndexModel([("entries.wallet", ASCENDING), ("created_at", DESCENDING), ("_id", DESCENDING)],
                   name="ix_transactions_entry_wallet_created"),
        IndexModel([("source.wallet", ASCENDING), ("created_at", ASCENDING)], name="ix_transactions_source_created"),
        IndexModel([("created_at", ASCENDING)], name="ix_transactions_created"),
        IndexModel([("status", ASCENDING), ("type", ASCENDING), ("created_at", ASCENDING)],
                   name="ix_transactions_status_type_created"),
        IndexModel([("created_at", ASCENDING)], partialFilterExpression={"status": "FAILED"},
                   name="ix_transactions_failed_created")],
}


def normalise(value):
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).replace(microsecond=value.microsecond // 1000 * 1000).isoformat()
    if isinstance(value, (int, Decimal)) and not isinstance(value, bool):
        return int(value)
    return value


def comparable(rows: list) -> list:
    return sorted(sorted(str(v) for v in r) for r in rows)


def signature(rows) -> str:
    return hashlib.md5(json.dumps(rows, default=str).encode()).hexdigest()


def walk(node, out):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "rejectedPlans":
                continue
            if k in ("totalDocsExamined", "totalKeysExamined") and isinstance(v, int):
                out[k] += v
            elif k == "stage" and isinstance(v, str):
                out["stages"].append(v)
            elif k == "indexName" and isinstance(v, str):
                out["indexes"].add(v)
            elif k == "collectionScans" and isinstance(v, int):
                out["lookup_collscans"] += v
            walk(v, out)
    elif isinstance(node, list):
        for v in node:
            walk(v, out)


def explain(db, coll: str, pipeline, timeout: int) -> dict:
    plan = db.command({"explain": {"aggregate": coll, "pipeline": pipeline, "cursor": {}, "maxTimeMS": timeout},
                       "verbosity": "executionStats"})
    out = {"totalDocsExamined": 0, "totalKeysExamined": 0, "stages": [], "indexes": set(), "lookup_collscans": 0}
    walk(plan, out)
    return plan, out


def run_phase(db, phase: str) -> list[dict]:
    section(f"Workload: {phase}")
    out_dir = P4 / "explain" / phase
    out_dir.mkdir(parents=True, exist_ok=True)
    results = []
    for qid, title, coll, pipeline, _ in QUERIES:
        entry = {"query": qid, "title": title}
        timeout = LONG_TIMEOUT_MS.get(qid, TIMEOUT_MS)
        try:
            rows = list(db[coll].aggregate(pipeline, maxTimeMS=timeout, allowDiskUse=True))
            times = []
            for _ in range(RUNS):
                t0 = time.perf_counter()
                list(db[coll].aggregate(pipeline, maxTimeMS=timeout, allowDiskUse=True))
                times.append((time.perf_counter() - t0) * 1000)
            plan, stats = explain(db, coll, pipeline, timeout)
            (out_dir / f"{qid}.json").write_text(json.dumps(plan, default=str, indent=1), encoding="utf-8", newline="\n")
            scans = "COLLSCAN" in stats["stages"] or stats["lookup_collscans"] > 0
            entry.update(ms=round(statistics.median(times), 2), rows=len(rows), docs=stats["totalDocsExamined"],
                         keys=stats["totalKeysExamined"], scan="COLLSCAN" if scans else "IXSCAN",
                         indexes=", ".join(sorted(stats["indexes"])) or "-", result=rows)
        except ExecutionTimeout:
            entry.update(ms=None, rows=None, docs=None, keys=None, scan="COLLSCAN", indexes="-", result=None)
        results.append(entry)
        shown = "TIMEOUT" if entry["ms"] is None else f"{entry['ms']} ms"
        print(f"  {qid:4} {shown:>12}  docs {entry['docs']}  keys {entry['keys']}  {entry['scan']}  {entry['indexes']}",
              flush=True)
    return results


def pg_rows(pg, sql: str) -> list:
    with pg.cursor() as cur:
        cur.execute(sql, {"phone": PHONE, "busy": BUSY, "ref": REF})
        return [[normalise(v) for v in r] for r in cur.fetchall() if any(v is not None for v in r)]


def mongo_rows(rows: list[dict]) -> list:
    return [[normalise(v) for v in (r["_id"].values() if isinstance(r.get("_id"), dict) else [])]
            + [normalise(v) for k, v in r.items() if k != "_id" or not isinstance(v, dict)] for r in rows]


def main() -> int:
    db = mongo_client().oworail
    c = Checks("MongoDB workload")
    for coll, models in WORKLOAD_INDEXES.items():
        for name in [m.document["name"] for m in models]:
            if name in db[coll].index_information():
                db[coll].drop_index(name)
    before = run_phase(db, "before")
    for coll, models in WORKLOAD_INDEXES.items():
        db[coll].create_indexes(models)
    after = run_phase(db, "after")

    section("Results compared")
    table, pg = [], pg_connect()
    for b, a, q in zip(before, after, QUERIES):
        expected = pg_rows(pg, q[4])
        same = a["result"] is not None and (b["result"] is None or signature(b["result"]) == signature(a["result"]))
        matches_pg = a["result"] is not None and comparable(expected) == comparable(mongo_rows(a["result"]))
        c.check(f"{a['query']} same result before and after indexes", same)
        c.check(f"{a['query']} same result as PostgreSQL ({len(expected)} rows)", matches_pg)
        speed = "-" if a["ms"] is None else (f">{TIMEOUT_MS / a['ms']:,.0f}x" if b["ms"] is None else f"{b['ms'] / a['ms']:,.1f}x")
        table.append([a["query"], a["title"], b["ms"] if b["ms"] is not None else "timeout", a["ms"],
                      b["docs"] if b["docs"] is not None else "-", a["docs"], a["keys"], f"{b['scan']} -> {a['scan']}",
                      speed])
    md = tabulate(table, headers=["query", "title", "before ms", "after ms", "docs examined before", "docs examined after",
                                  "keys examined after", "plan", "speed-up"], tablefmt="github")
    print("\n" + md)
    (P4 / "results").mkdir(exist_ok=True)
    (P4 / "results" / "comparison.md").write_text(
        "# MongoDB workload before and after indexes\n\nMedian of 5 runs (ms, wall clock from the client). "
        "Docs and keys examined come from `explain(\"executionStats\")`; a timeout is 30 s (120 s for Q5).\n\n" + md + "\n",
        encoding="utf-8", newline="\n")
    return c.summary()


if __name__ == "__main__":
    sys.exit(main())
