"""A wallet transfer as a multi-document transaction: commit, abort, isolation, write conflicts, idempotency."""
from __future__ import annotations

import sys
import uuid
from datetime import datetime, timezone
from itertools import count

from bson.int64 import Int64
from pymongo.errors import DuplicateKeyError, OperationFailure
from pymongo.read_concern import ReadConcern
from pymongo.write_concern import WriteConcern

from common import Checks, mongo_client, section

ADAEZE, TUNDE, CHIAMAKA, FROZEN, FEES = "3000000001", "3000000002", "3000000003", "3000000005", "9000000001"
REFS = count(1)


class Refused(Exception):
    pass


def fee_for(db, kind: str, amount: int, at: datetime, session=None) -> tuple[int | None, int]:
    rule = db.fee_rules.find_one({"transaction_type": kind, "min_amount_kobo": {"$lte": amount},
                                  "$and": [{"$or": [{"max_amount_kobo": None}, {"max_amount_kobo": {"$gte": amount}}]},
                                           {"$or": [{"effective_to": None}, {"effective_to": {"$gt": at}}]}],
                                  "effective_from": {"$lte": at}}, session=session)
    if rule is None:
        return None, 0
    fee = rule["flat_fee_kobo"] + amount * rule["percent_bps"] // 10000
    return rule["_id"], fee if rule["cap_kobo"] is None else min(fee, rule["cap_kobo"])


def transfer(db, session, src: str, dst: str, amount: int, key: str, fail_after_debit: bool = False) -> str:
    now = datetime.now(timezone.utc).replace(microsecond=0)
    rule_id, fee = fee_for(db, "TRANSFER", amount, now, session)
    total = amount + fee
    debit = db.wallets.update_one({"_id": src, "status": "ACTIVE", "balance_kobo": {"$gte": Int64(total)}},
                                  {"$inc": {"balance_kobo": Int64(-total)}}, session=session)
    if debit.modified_count != 1:
        raise Refused(f"wallet {src} can't pay {total}")
    if fail_after_debit:
        raise Refused("simulated failure after the debit")
    credit = db.wallets.update_one({"_id": dst, "status": "ACTIVE"}, {"$inc": {"balance_kobo": Int64(amount)}},
                                   session=session)
    if credit.modified_count != 1:
        raise Refused(f"wallet {dst} can't receive")
    entries = [{"line": 1, "wallet": src, "type": "DEBIT", "amount": Int64(total)},
               {"line": 2, "wallet": dst, "type": "CREDIT", "amount": Int64(amount)}]
    if fee:
        db.wallets.update_one({"_id": FEES}, {"$inc": {"balance_kobo": Int64(fee)}}, session=session)
        entries.append({"line": 3, "wallet": FEES, "type": "CREDIT", "amount": Int64(fee)})
    names = {w["_id"]: w["owner"]["name"] for w in db.wallets.find({"_id": {"$in": [src, dst]}}, session=session)}
    ref = f"OWR8{now:%m%d%H%M%S}{next(REFS) % 10:01d}"
    doc = {"_id": ref, "idempotency_key": key, "type": "TRANSFER",
           "source": {"wallet": src, "name": names[src]}, "destination": {"wallet": dst, "name": names[dst]},
           "amount_kobo": Int64(amount), "fee_kobo": Int64(fee), "status": "SUCCESSFUL", "channel": "APP",
           "created_at": now, "entries": entries,
           "history": [{"seq": 1, "status": "PENDING", "at": now}, {"seq": 2, "status": "SUCCESSFUL", "at": now}]}
    if rule_id is not None:
        doc["fee_rule_id"] = rule_id
    db.transactions.insert_one(doc, session=session)
    return ref


def in_transaction(client, db, *args, **kwargs) -> str:
    with client.start_session() as s:
        return s.with_transaction(lambda s_: transfer(db, s_, *args, **kwargs),
                                  read_concern=ReadConcern("snapshot"), write_concern=WriteConcern("majority"))


def balances(db, *wallets) -> dict:
    return {w["_id"]: w["balance_kobo"] for w in db.wallets.find({"_id": {"$in": list(wallets)}})}


def main() -> int:
    client = mongo_client()
    db = client.oworail
    c = Checks("Multi-document transactions")

    section("D1  Commit: debit, credit, fee and the transaction document in one transaction")
    before = balances(db, ADAEZE, TUNDE, FEES)
    ref = in_transaction(client, db, ADAEZE, TUNDE, 10000, str(uuid.uuid4()))
    after = balances(db, ADAEZE, TUNDE, FEES)
    print(f"  {ref}: {before} -> {after}")
    c.check("all three wallets moved and the transaction exists",
            after[ADAEZE] == before[ADAEZE] - 11000 and after[TUNDE] == before[TUNDE] + 10000
            and after[FEES] == before[FEES] + 1000 and db.transactions.count_documents({"_id": ref}) == 1)

    section("D2  Abort: a failure after the debit undoes the debit")
    before, n_before = balances(db, CHIAMAKA, FROZEN), db.transactions.estimated_document_count()
    try:
        in_transaction(client, db, CHIAMAKA, FROZEN, 10000, str(uuid.uuid4()))
        refused = None
    except Refused as exc:
        refused = str(exc)
    print(f"  refused: {refused}")
    c.check("the frozen receiver makes the transfer fail", refused == f"wallet {FROZEN} can't receive")
    c.check("the sender's debit was rolled back", balances(db, CHIAMAKA, FROZEN) == before)
    c.check("no transaction document was written", db.transactions.estimated_document_count() == n_before)

    section("D3  The same failure without a transaction leaves the money missing")
    before = balances(db, CHIAMAKA)[CHIAMAKA]
    try:
        transfer(db, None, CHIAMAKA, TUNDE, 10000, str(uuid.uuid4()), fail_after_debit=True)
    except Refused as exc:
        print(f"  refused: {exc}")
    lost = before - balances(db, CHIAMAKA)[CHIAMAKA]
    c.check("without a transaction the debit stays: money has vanished", lost == 11000, f"{lost} kobo missing")
    db.wallets.update_one({"_id": CHIAMAKA}, {"$inc": {"balance_kobo": Int64(lost)}})
    print(f"  repaired by hand: +{lost} back to {CHIAMAKA}")

    section("D4  Isolation: other readers don't see a transaction until it commits")
    s = client.start_session()
    s.start_transaction(read_concern=ReadConcern("snapshot"), write_concern=WriteConcern("majority"))
    outside_before = balances(db, ADAEZE)[ADAEZE]
    transfer(db, s, ADAEZE, CHIAMAKA, 20000, str(uuid.uuid4()))
    inside = db.wallets.find_one({"_id": ADAEZE}, session=s)["balance_kobo"]
    outside_during = balances(db, ADAEZE)[ADAEZE]
    s.commit_transaction()
    s.end_session()
    outside_after = balances(db, ADAEZE)[ADAEZE]
    print(f"  inside {inside}, outside during {outside_during}, outside after commit {outside_after}")
    c.check("inside the transaction the debit is visible", inside == outside_before - 21000)
    c.check("outside, the old balance is read until COMMIT", outside_during == outside_before)
    c.check("after COMMIT everyone sees it", outside_after == inside)

    section("D5  Write conflict: two transactions update the same wallet")
    start = balances(db, ADAEZE)[ADAEZE]
    s1, s2 = client.start_session(), client.start_session()
    s1.start_transaction()
    db.wallets.update_one({"_id": ADAEZE}, {"$inc": {"balance_kobo": Int64(-1000)}}, session=s1)
    s2.start_transaction()
    try:
        db.wallets.update_one({"_id": ADAEZE}, {"$inc": {"balance_kobo": Int64(-2000)}}, session=s2)
        conflict = None
    except OperationFailure as exc:
        conflict = exc
        print(f"  second transaction: {exc.code} {exc.details.get('codeName')}, labels {exc.details.get('errorLabels')}")
    s2.abort_transaction()
    s1.commit_transaction()
    s2.with_transaction(lambda s_: db.wallets.update_one({"_id": ADAEZE}, {"$inc": {"balance_kobo": Int64(-2000)}},
                                                         session=s_))
    s1.end_session(), s2.end_session()
    end = balances(db, ADAEZE)[ADAEZE]
    c.check("the second writer fails at once with WriteConflict instead of waiting",
            conflict is not None and conflict.code == 112)
    c.check("the error is labelled TransientTransactionError, so it is safe to retry",
            conflict is not None and conflict.has_error_label("TransientTransactionError"))
    c.check("after a retry both updates are applied", end == start - 3000, f"{start} -> {end}")
    db.wallets.update_one({"_id": ADAEZE}, {"$inc": {"balance_kobo": Int64(3000)}})

    section("D6  Idempotency: the same request twice is posted once")
    key, before = str(uuid.uuid4()), balances(db, ADAEZE)[ADAEZE]
    in_transaction(client, db, ADAEZE, TUNDE, 5000, key)
    try:
        in_transaction(client, db, ADAEZE, TUNDE, 5000, key)
        duplicate = False
    except DuplicateKeyError:
        duplicate = True
    c.check("the retry fails on the unique idempotency key and its transaction aborts", duplicate)
    c.check("the sender paid once", before - balances(db, ADAEZE)[ADAEZE] == 6000)

    section("Afterwards: every wallet balance still matches its entries")
    diff = list(db.transactions.aggregate([
        {"$unwind": "$entries"},
        {"$group": {"_id": "$entries.wallet", "ledger": {"$sum": {"$cond": [
            {"$eq": ["$entries.type", "CREDIT"]}, "$entries.amount", {"$multiply": ["$entries.amount", -1]}]}}}},
        {"$lookup": {"from": "wallets", "localField": "_id", "foreignField": "_id", "as": "w"}},
        {"$unwind": "$w"}, {"$match": {"$expr": {"$ne": ["$ledger", "$w.balance_kobo"]}}}], allowDiskUse=True))
    c.check("reconciliation finds no differences", not diff, f"{len(diff)} wallets differ")
    return c.summary()


if __name__ == "__main__":
    sys.exit(main())
