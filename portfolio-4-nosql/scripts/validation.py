"""Schema validation, unique indexes and a least-privilege view, tested with documents that must be rejected."""
from __future__ import annotations

import secrets
import sys
from copy import deepcopy
from datetime import datetime, timezone

from bson.int64 import Int64
from pymongo.errors import DuplicateKeyError, OperationFailure, WriteError

from common import Checks, mongo_client, section

NOW = datetime(2026, 11, 11, 9, 0, tzinfo=timezone.utc)

CUSTOMER = {"_id": Int64(900001), "full_name": "Validation Test", "email": "validation.test@example.com",
            "date_of_birth": datetime(1990, 1, 1, tzinfo=timezone.utc),
            "address": {"street": "1 Test St", "city": "Ikeja", "state": "Lagos"},
            "phones": ["+2348099990001"], "status": "ACTIVE", "created_at": NOW,
            "kyc": {"tier": 1, "id_type": "BVN", "national_id_number": "99988800001", "verification_status": "PENDING"}}

TXN = {"_id": "OWR900000000001", "idempotency_key": "validation-1", "type": "TRANSFER",
       "source": {"wallet": "3000000001", "name": "Adaeze Okafor"},
       "destination": {"wallet": "3000000002", "name": "Tunde Bakare"},
       "amount_kobo": Int64(10000), "fee_kobo": Int64(1000), "fee_rule_id": 2, "status": "SUCCESSFUL",
       "channel": "APP", "created_at": NOW,
       "entries": [{"line": 1, "wallet": "3000000001", "type": "DEBIT", "amount": Int64(11000)},
                   {"line": 2, "wallet": "3000000002", "type": "CREDIT", "amount": Int64(10000)},
                   {"line": 3, "wallet": "9000000001", "type": "CREDIT", "amount": Int64(1000)}],
       "history": [{"seq": 1, "status": "PENDING", "at": NOW}, {"seq": 2, "status": "SUCCESSFUL", "at": NOW}]}


def variant(base: dict, **changes) -> dict:
    doc = deepcopy(base)
    for path, value in changes.items():
        target, *keys = path.split("__")
        node = doc
        for k in [target, *keys][:-1]:
            node = node[k]
        last = [target, *keys][-1]
        if value is ...:
            node.pop(last, None)
        else:
            node[last] = value
    return doc


def attempt(fn) -> str:
    try:
        fn()
        return "accepted"
    except DuplicateKeyError as exc:
        return f"duplicate key ({next(iter(exc.details.get('keyPattern', {})), '?')})"
    except WriteError as exc:
        return "rejected by validator" if exc.code == 121 else f"error {exc.code}"


def failing_rule(db, coll: str, doc: dict) -> str:
    try:
        db[coll].insert_one(doc)
        db[coll].delete_one({"_id": doc["_id"]})
        return "-"
    except WriteError as exc:
        details = exc.details.get("errInfo", {}).get("details", {})
        return str(details)[:300]


def main() -> int:
    client = mongo_client()
    db = client.oworail
    c = Checks("Validation")
    db.customers.delete_many({"_id": {"$gte": 900000}})
    db.transactions.delete_many({"_id": {"$regex": "^OWR9"}})

    section("Documents that must be rejected")
    cases = [
        ("customer with a real-looking (non-999) BVN", "customers",
         variant(CUSTOMER, kyc__national_id_number="22212345678"), "rejected by validator"),
        ("customer phone not in +234 mobile format", "customers", variant(CUSTOMER, phones=["08099990001"]),
         "rejected by validator"),
        ("customer email with capitals", "customers", variant(CUSTOMER, email="Validation@Example.com"),
         "rejected by validator"),
        ("customer with a field the schema doesn't allow", "customers", variant(CUSTOMER, nickname="Val"),
         "rejected by validator"),
        ("customer whose phone belongs to someone else", "customers", variant(CUSTOMER, phones=["+2348030000001"]),
         "duplicate key (phones)"),
        ("transaction whose debits and credits differ", "transactions",
         variant(TXN, entries=TXN["entries"][:2]), "rejected by validator"),
        ("SUCCESSFUL transaction with no entries", "transactions", variant(TXN, entries=[]), "rejected by validator"),
        ("FAILED transaction that still has entries", "transactions",
         variant(TXN, status="FAILED", history=[TXN["history"][0], {"seq": 2, "status": "FAILED", "at": NOW}]),
         "rejected by validator"),
        ("status different from the last history entry", "transactions", variant(TXN, status="REVERSED"),
         "rejected by validator"),
        ("bill payment without a bill reference", "transactions", variant(TXN, type="BILL_PAYMENT"),
         "rejected by validator"),
        ("amount stored as a 32-bit int instead of a long", "transactions", variant(TXN, amount_kobo=10000),
         "rejected by validator"),
        ("sending to the same wallet", "transactions",
         variant(TXN, destination__wallet="3000000001"), "rejected by validator"),
        ("customer wallet below zero", "wallets",
         {"_id": "3999999999", "type": "CUSTOMER", "owner": {"kind": "customer", "customer_id": Int64(1), "name": "X"},
          "currency": "NGN", "balance_kobo": Int64(-1), "status": "ACTIVE", "created_at": NOW}, "rejected by validator"),
        ("customer wallet owned by a merchant", "wallets",
         {"_id": "3999999999", "type": "CUSTOMER", "owner": {"kind": "merchant", "merchant_code": "MRC99999", "name": "X"},
          "currency": "NGN", "balance_kobo": Int64(0), "status": "ACTIVE", "created_at": NOW}, "rejected by validator"),
    ]
    for label, coll, doc, expected in cases:
        result = attempt(lambda: db[coll].insert_one(doc))
        c.check(label, result == expected, result)

    section("Valid documents and updates")
    c.check("a valid customer is accepted", attempt(lambda: db.customers.insert_one(deepcopy(CUSTOMER))) == "accepted")
    c.check("a valid, balanced transaction is accepted", attempt(lambda: db.transactions.insert_one(deepcopy(TXN))) == "accepted")
    c.check("the same idempotency key again is refused",
            attempt(lambda: db.transactions.insert_one(variant(TXN, _id="OWR900000000002"))) ==
            "duplicate key (idempotency_key)")
    c.check("updates are validated too: a customer balance can't be set below zero",
            attempt(lambda: db.wallets.update_one({"_id": "3000000002"}, {"$set": {"balance_kobo": Int64(-5)}}))
            == "rejected by validator")
    c.check("a SYSTEM wallet may go below zero (SUSPENSE)",
            attempt(lambda: db.wallets.update_one({"_id": "9000000003"}, {"$set": {"balance_kobo": Int64(-5)}})) == "accepted")
    db.wallets.update_one({"_id": "9000000003"}, {"$set": {"balance_kobo": Int64(0)}})
    db.customers.delete_one({"_id": CUSTOMER["_id"]})
    db.transactions.delete_one({"_id": TXN["_id"]})

    print("\n  why the unbalanced transaction failed (MongoDB's errInfo):")
    print("   ", failing_rule(db, "transactions", variant(TXN, entries=TXN["entries"][:2])))

    section("Least privilege with embedded KYC data")
    if "customers_support" not in db.list_collection_names():
        db.create_collection("customers_support", viewOn="customers", pipeline=[{"$project": {"kyc": 0}}])
    if db.command("usersInfo", "oworail_support")["users"]:
        db.command("dropUser", "oworail_support")
    if db.command("rolesInfo", "supportRead")["roles"]:
        db.command("dropRole", "supportRead")
    db.command("createRole", "supportRead", privileges=[
        {"resource": {"db": "oworail", "collection": c_}, "actions": ["find"]}
        for c_ in ("customers_support", "wallets", "transactions")], roles=[])
    password = secrets.token_urlsafe(24)
    db.command("createUser", "oworail_support", pwd=password, roles=["supportRead"])
    support = mongo_client("oworail_support", password).oworail
    try:
        support.customers.find_one()
        denied = False
    except OperationFailure as exc:
        denied = exc.code == 13
    view_doc = support.customers_support.find_one({"_id": Int64(1)})
    c.check("the support user can't read the customers collection (KYC inside)", denied)
    c.check("the support user reads customers through a view without KYC", view_doc is not None and "kyc" not in view_doc,
            ", ".join(sorted(view_doc)) if view_doc else "nothing")
    c.check("the support user can't write", write_denied(support))
    db.command("dropUser", "oworail_support")
    return c.summary()


def write_denied(support) -> bool:
    try:
        support.wallets.update_one({"_id": "3000000002"}, {"$set": {"status": "FROZEN"}})
        return False
    except OperationFailure as exc:
        return exc.code == 13


if __name__ == "__main__":
    sys.exit(main())
