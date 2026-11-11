"""Load the OwoRail data from PostgreSQL into MongoDB documents."""
from __future__ import annotations

import sys
import time
from datetime import date, datetime, time as dtime, timezone

from bson.int64 import Int64

from common import Checks, mongo_client, pg_connect, section

BATCH = 5000

CUSTOMERS = """
SELECT c.customer_id, c.full_name, c.email, c.date_of_birth, c.address_street, c.address_city, c.address_state,
       c.status, c.created_at,
       (SELECT array_agg(p.phone_number ORDER BY p.phone_number) FROM oworail.customer_phone p
        WHERE p.customer_id = c.customer_id),
       k.tier_level, k.id_type, k.national_id_number, k.verification_status, k.verified_at, k.verified_by
FROM oworail.customer c LEFT JOIN oworail.kyc_profile k ON k.customer_id = c.customer_id
ORDER BY c.customer_id"""

WALLETS = """
SELECT w.wallet_number, w.wallet_type, w.customer_id, m.merchant_code, w.system_purpose,
       coalesce(c.full_name, m.business_name, 'OwoRail ' || w.system_purpose),
       w.currency, w.balance_kobo, w.status, w.created_at
FROM oworail.wallet w
LEFT JOIN oworail.customer c ON c.customer_id = w.customer_id
LEFT JOIN oworail.merchant m ON m.merchant_id = w.merchant_id
ORDER BY w.wallet_id"""

MERCHANTS = """
SELECT m.merchant_code, m.business_name, m.merchant_type, m.category, m.status, w.wallet_number, m.created_at
FROM oworail.merchant m JOIN oworail.wallet w ON w.merchant_id = m.merchant_id ORDER BY m.merchant_id"""

TRANSACTIONS = """
SELECT t.transaction_ref, t.idempotency_key::text, t.transaction_type,
       sw.wallet_number, coalesce(sc.full_name, sm.business_name, 'OwoRail ' || sw.system_purpose),
       dw.wallet_number, coalesce(dc.full_name, dm.business_name, 'OwoRail ' || dw.system_purpose),
       t.amount_kobo, t.fee_kobo, t.fee_rule_id, t.status, t.channel, t.bill_reference, t.narration, t.created_at,
       (SELECT array_agg(ARRAY[l.line_no::text, lw.wallet_number, l.entry_type, l.amount_kobo::text] ORDER BY l.line_no)
        FROM oworail.ledger_entry l JOIN oworail.wallet lw ON lw.wallet_id = l.wallet_id
        WHERE l.transaction_id = t.transaction_id),
       (SELECT array_agg(ARRAY[h.seq_no::text, h.status, h.changed_at::text, h.reason] ORDER BY h.seq_no)
        FROM oworail.transaction_status_history h WHERE h.transaction_id = t.transaction_id),
       o.transaction_ref, r1.reason, r1.requested_by, rv.transaction_ref
FROM oworail.transaction t
JOIN oworail.wallet sw ON sw.wallet_id = t.source_wallet_id
JOIN oworail.wallet dw ON dw.wallet_id = t.destination_wallet_id
LEFT JOIN oworail.customer sc ON sc.customer_id = sw.customer_id
LEFT JOIN oworail.merchant sm ON sm.merchant_id = sw.merchant_id
LEFT JOIN oworail.customer dc ON dc.customer_id = dw.customer_id
LEFT JOIN oworail.merchant dm ON dm.merchant_id = dw.merchant_id
LEFT JOIN oworail.reversal r1 ON r1.reversal_transaction_id = t.transaction_id
LEFT JOIN oworail.transaction o ON o.transaction_id = r1.original_transaction_id
LEFT JOIN oworail.reversal r2 ON r2.original_transaction_id = t.transaction_id
LEFT JOIN oworail.transaction rv ON rv.transaction_id = r2.reversal_transaction_id
ORDER BY t.transaction_id"""


def as_datetime(d: date) -> datetime:
    return datetime.combine(d, dtime.min, tzinfo=timezone.utc)


def customer_doc(r) -> dict:
    doc = {"_id": Int64(r[0]), "full_name": r[1], "email": r[2], "date_of_birth": as_datetime(r[3]),
           "address": {"street": r[4], "city": r[5], "state": r[6]}, "phones": r[9], "status": r[7],
           "created_at": r[8]}
    if r[10] is not None:
        doc["kyc"] = {"tier": int(r[10]), "id_type": r[11], "national_id_number": r[12], "verification_status": r[13]}
        if r[14] is not None:
            doc["kyc"].update(verified_at=r[14], verified_by=r[15])
    return doc


def wallet_doc(r) -> dict:
    kind = {"CUSTOMER": "customer", "MERCHANT": "merchant", "SYSTEM": "system"}[r[1]]
    owner = {"kind": kind, "name": r[5]}
    if kind == "customer":
        owner["customer_id"] = Int64(r[2])
    elif kind == "merchant":
        owner["merchant_code"] = r[3]
    else:
        owner["system_purpose"] = r[4]
    return {"_id": r[0], "type": r[1], "owner": owner, "currency": r[6].strip(), "balance_kobo": Int64(r[7]),
            "status": r[8], "created_at": r[9]}


def transaction_doc(r) -> dict:
    doc = {"_id": r[0], "idempotency_key": r[1], "type": r[2],
           "source": {"wallet": r[3], "name": r[4]}, "destination": {"wallet": r[5], "name": r[6]},
           "amount_kobo": Int64(r[7]), "fee_kobo": Int64(r[8]), "status": r[10], "channel": r[11],
           "created_at": r[14],
           "entries": [{"line": int(e[0]), "wallet": e[1], "type": e[2], "amount": Int64(int(e[3]))}
                       for e in (r[15] or [])],
           "history": [dict({"seq": int(h[0]), "status": h[1], "at": datetime.fromisoformat(h[2])},
                            **({"reason": h[3]} if h[3] is not None else {})) for h in r[16]]}
    if r[9] is not None:
        doc["fee_rule_id"] = int(r[9])
    if r[12] is not None:
        doc["bill_reference"] = r[12]
    if r[13] is not None:
        doc["narration"] = r[13]
    if r[17] is not None:
        doc["reverses"] = {"ref": r[17], "reason": r[18], "requested_by": r[19]}
    if r[20] is not None:
        doc["reversed_by"] = r[20]
    return doc


def copy(pg, collection, sql: str, make) -> int:
    n, batch = 0, []
    with pg.cursor(name=f"load_{collection.name}") as cur:
        cur.itersize = BATCH
        cur.execute(sql)
        for row in cur:
            batch.append(make(row))
            if len(batch) == BATCH:
                collection.insert_many(batch, ordered=False)
                n += len(batch)
                batch = []
    if batch:
        collection.insert_many(batch, ordered=False)
        n += len(batch)
    return n


def main() -> int:
    pg, db = pg_connect(), mongo_client().oworail
    c = Checks("Load from PostgreSQL")
    section("Copy")
    t0 = time.perf_counter()
    with pg.cursor() as cur:
        cur.execute("SELECT tier_level, tier_name, single_txn_limit_kobo, daily_limit_kobo, max_balance_kobo FROM oworail.kyc_tier")
        db.kyc_tiers.insert_many([{"_id": int(r[0]), "name": r[1], "single_txn_limit_kobo": Int64(r[2]),
                                   "daily_limit_kobo": Int64(r[3]),
                                   "max_balance_kobo": None if r[4] is None else Int64(r[4])} for r in cur])
        cur.execute("""SELECT fee_rule_id, transaction_type, min_amount_kobo, max_amount_kobo, flat_fee_kobo,
                              percent_bps, cap_kobo, effective_from, effective_to FROM oworail.fee_rule""")
        db.fee_rules.insert_many([{"_id": int(r[0]), "transaction_type": r[1], "min_amount_kobo": Int64(r[2]),
                                   "max_amount_kobo": None if r[3] is None else Int64(r[3]), "flat_fee_kobo": Int64(r[4]),
                                   "percent_bps": int(r[5]), "cap_kobo": None if r[6] is None else Int64(r[6]),
                                   "effective_from": r[7], "effective_to": r[8]} for r in cur])
        cur.execute("SELECT occurred_at, actor, action, target_type, target_id, details FROM oworail.audit_log ORDER BY audit_id")
        db.audit_log.insert_many([{"occurred_at": r[0], "actor": r[1], "action": r[2],
                                   "target": {"type": r[3], "id": r[4]}, "details": r[5]} for r in cur])
    counts = {}
    for name, sql, make in (("customers", CUSTOMERS, customer_doc), ("wallets", WALLETS, wallet_doc),
                            ("merchants", MERCHANTS, merchant_doc), ("transactions", TRANSACTIONS, transaction_doc)):
        t1 = time.perf_counter()
        counts[name] = copy(pg, db[name], sql, make)
        print(f"  {name:<13} {counts[name]:>9,} documents in {time.perf_counter() - t1:6.1f} s", flush=True)
    print(f"  total {time.perf_counter() - t0:.1f} s")

    section("Checks against PostgreSQL")
    with pg.cursor() as cur:
        cur.execute("""SELECT (SELECT count(*) FROM oworail.customer), (SELECT count(*) FROM oworail.wallet),
                              (SELECT count(*) FROM oworail.merchant), (SELECT count(*) FROM oworail.transaction),
                              (SELECT count(*) FROM oworail.ledger_entry), (SELECT count(*) FROM oworail.transaction_status_history),
                              (SELECT sum(balance_kobo) FROM oworail.wallet WHERE wallet_type <> 'SYSTEM'),
                              (SELECT count(*) FROM oworail.reversal)""")
        pg_counts = cur.fetchone()
    entries = next(db.transactions.aggregate([{"$project": {"e": {"$size": "$entries"}, "h": {"$size": "$history"}}},
                                              {"$group": {"_id": None, "e": {"$sum": "$e"}, "h": {"$sum": "$h"}}}]))
    balance = next(db.wallets.aggregate([{"$match": {"type": {"$ne": "SYSTEM"}}},
                                         {"$group": {"_id": None, "s": {"$sum": "$balance_kobo"}}}]))["s"]
    c.check("one document per customer, wallet, merchant and transaction",
            (counts["customers"], counts["wallets"], counts["merchants"], counts["transactions"]) == pg_counts[:4],
            f"{counts}")
    c.check("every ledger line and status-history row is embedded", (entries["e"], entries["h"]) == pg_counts[4:6],
            f"{entries['e']:,} entries, {entries['h']:,} history rows")
    c.check("customer and merchant balances add up to the same total", balance == pg_counts[6], f"{balance:,} kobo")
    c.check("every reversal is linked both ways",
            db.transactions.count_documents({"reverses": {"$exists": True}}) == pg_counts[7]
            == db.transactions.count_documents({"reversed_by": {"$exists": True}}))
    return c.summary()


def merchant_doc(r) -> dict:
    return {"_id": r[0], "business_name": r[1], "merchant_type": r[2], "category": r[3], "status": r[4],
            "wallet_number": r[5], "created_at": r[6]}


if __name__ == "__main__":
    sys.exit(main())
