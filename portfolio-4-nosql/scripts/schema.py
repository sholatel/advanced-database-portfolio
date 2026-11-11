"""Create the oworail database: collections, validators and integrity indexes."""
from __future__ import annotations

import sys

from pymongo import ASCENDING, IndexModel

from common import ensure_replica_set, mongo_client

LONG = {"bsonType": "long"}
POSITIVE_LONG = {"bsonType": "long", "minimum": 1}
DATE = {"bsonType": "date"}
WALLET_NO = {"bsonType": "string", "pattern": "^[0-9]{10}$"}
TXN_TYPES = ["WALLET_FUNDING", "TRANSFER", "MERCHANT_PAYMENT", "BILL_PAYMENT", "REVERSAL"]
STATUSES = ["PENDING", "SUCCESSFUL", "FAILED", "REVERSED"]


def sum_of(entry_type: str) -> dict:
    return {"$sum": {"$map": {"input": {"$filter": {"input": "$entries", "cond": {"$eq": ["$$this.type", entry_type]}}},
                              "in": "$$this.amount"}}}


CUSTOMERS = {"$jsonSchema": {
    "bsonType": "object",
    "required": ["_id", "full_name", "email", "date_of_birth", "address", "phones", "status", "created_at"],
    "additionalProperties": False,
    "properties": {
        "_id": LONG,
        "full_name": {"bsonType": "string", "minLength": 1},
        "email": {"bsonType": "string", "pattern": "^[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}$"},
        "date_of_birth": DATE,
        "address": {"bsonType": "object", "required": ["street", "city", "state"], "additionalProperties": False,
                    "properties": {k: {"bsonType": "string"} for k in ("street", "city", "state")}},
        "phones": {"bsonType": "array", "minItems": 1, "uniqueItems": True,
                   "items": {"bsonType": "string", "pattern": "^\\+234[789][01][0-9]{8}$"}},
        "status": {"enum": ["ACTIVE", "SUSPENDED", "CLOSED"]},
        "created_at": DATE,
        "kyc": {"bsonType": "object", "required": ["tier", "id_type", "national_id_number", "verification_status"],
                "additionalProperties": False,
                "properties": {
                    "tier": {"bsonType": "int", "minimum": 1, "maximum": 3},
                    "id_type": {"enum": ["BVN", "NIN"]},
                    "national_id_number": {"bsonType": "string", "pattern": "^999[0-9]{8}$"},
                    "verification_status": {"enum": ["PENDING", "VERIFIED", "REJECTED"]},
                    "verified_at": DATE,
                    "verified_by": {"bsonType": "string"}}},
    }}}

WALLETS = {"$and": [
    {"$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "type", "owner", "currency", "balance_kobo", "status", "created_at"],
        "additionalProperties": False,
        "properties": {
            "_id": WALLET_NO,
            "type": {"enum": ["CUSTOMER", "MERCHANT", "SYSTEM"]},
            "owner": {"bsonType": "object", "required": ["kind", "name"], "additionalProperties": False,
                      "properties": {"kind": {"enum": ["customer", "merchant", "system"]},
                                     "customer_id": LONG,
                                     "merchant_code": {"bsonType": "string"},
                                     "system_purpose": {"enum": ["FEES", "SETTLEMENT", "SUSPENSE"]},
                                     "name": {"bsonType": "string"}}},
            "currency": {"enum": ["NGN"]},
            "balance_kobo": LONG,
            "status": {"enum": ["ACTIVE", "FROZEN", "CLOSED"]},
            "created_at": DATE}}},
    {"$or": [{"type": "CUSTOMER", "owner.kind": "customer", "owner.customer_id": {"$exists": True}},
             {"type": "MERCHANT", "owner.kind": "merchant", "owner.merchant_code": {"$exists": True}},
             {"type": "SYSTEM", "owner.kind": "system", "owner.system_purpose": {"$exists": True}}]},
    {"$or": [{"type": "SYSTEM"}, {"balance_kobo": {"$gte": 0}}]},
]}

MERCHANTS = {"$jsonSchema": {
    "bsonType": "object",
    "required": ["_id", "business_name", "merchant_type", "category", "status", "wallet_number", "created_at"],
    "additionalProperties": False,
    "properties": {
        "_id": {"bsonType": "string", "pattern": "^MRC[0-9]{5}$"},
        "business_name": {"bsonType": "string", "minLength": 1},
        "merchant_type": {"enum": ["MERCHANT", "BILLER"]},
        "category": {"enum": ["RETAIL", "FOOD", "TRANSPORT", "HEALTH", "EDUCATION", "AIRTIME", "ELECTRICITY", "CABLE_TV"]},
        "status": {"enum": ["ACTIVE", "SUSPENDED"]},
        "wallet_number": WALLET_NO,
        "created_at": DATE}}}

TRANSACTIONS = {"$and": [
    {"$jsonSchema": {
        "bsonType": "object",
        "required": ["_id", "idempotency_key", "type", "source", "destination", "amount_kobo", "fee_kobo",
                     "status", "channel", "created_at", "entries", "history"],
        "additionalProperties": False,
        "properties": {
            "_id": {"bsonType": "string", "pattern": "^OWR[0-9]{12}$"},
            "idempotency_key": {"bsonType": "string"},
            "type": {"enum": TXN_TYPES},
            "source": {"bsonType": "object", "required": ["wallet", "name"],
                       "properties": {"wallet": WALLET_NO, "name": {"bsonType": "string"}}},
            "destination": {"bsonType": "object", "required": ["wallet", "name"],
                            "properties": {"wallet": WALLET_NO, "name": {"bsonType": "string"}}},
            "amount_kobo": POSITIVE_LONG,
            "fee_kobo": {"bsonType": "long", "minimum": 0},
            "fee_rule_id": {"bsonType": "int"},
            "status": {"enum": STATUSES},
            "channel": {"enum": ["APP", "USSD", "WEB"]},
            "bill_reference": {"bsonType": "string"},
            "narration": {"bsonType": "string", "maxLength": 100},
            "created_at": DATE,
            "entries": {"bsonType": "array", "items": {
                "bsonType": "object", "required": ["line", "wallet", "type", "amount"], "additionalProperties": False,
                "properties": {"line": {"bsonType": "int", "minimum": 1}, "wallet": WALLET_NO,
                               "type": {"enum": ["DEBIT", "CREDIT"]}, "amount": POSITIVE_LONG}}},
            "history": {"bsonType": "array", "minItems": 1, "items": {
                "bsonType": "object", "required": ["seq", "status", "at"], "additionalProperties": False,
                "properties": {"seq": {"bsonType": "int", "minimum": 1}, "status": {"enum": STATUSES},
                               "at": DATE, "reason": {"bsonType": "string"}}}},
            "reverses": {"bsonType": "object", "required": ["ref", "reason", "requested_by"],
                         "properties": {"ref": {"bsonType": "string"}, "reason": {"bsonType": "string"},
                                        "requested_by": {"bsonType": "string"}}},
            "reversed_by": {"bsonType": "string"}}}},
    {"$expr": {"$and": [
        {"$ne": ["$source.wallet", "$destination.wallet"]},
        {"$eq": [sum_of("DEBIT"), sum_of("CREDIT")]},
        {"$eq": [{"$in": ["$status", ["SUCCESSFUL", "REVERSED"]]}, {"$gte": [{"$size": "$entries"}, 2]}]},
        {"$eq": ["$status", {"$arrayElemAt": ["$history.status", -1]}]},
        {"$eq": [{"$eq": ["$type", "BILL_PAYMENT"]}, {"$ne": [{"$type": "$bill_reference"}, "missing"]}]},
    ]}},
]}

TIERS = {"$jsonSchema": {"bsonType": "object", "required": ["_id", "name", "single_txn_limit_kobo", "daily_limit_kobo"],
                         "properties": {"_id": {"bsonType": "int", "minimum": 1, "maximum": 3}}}}
FEE_RULES = {"$jsonSchema": {"bsonType": "object", "required": ["_id", "transaction_type", "min_amount_kobo", "effective_from"]}}
AUDIT = {"$jsonSchema": {"bsonType": "object", "required": ["occurred_at", "actor", "action", "target"],
                         "properties": {"action": {"bsonType": "string", "pattern": "^[A-Z][A-Z_]*$"}}}}

COLLECTIONS = {
    "customers": (CUSTOMERS, [
        IndexModel([("email", ASCENDING)], unique=True, name="uq_customers_email"),
        IndexModel([("phones", ASCENDING)], unique=True, name="uq_customers_phones"),
        IndexModel([("kyc.id_type", ASCENDING), ("kyc.national_id_number", ASCENDING)], unique=True,
                   partialFilterExpression={"kyc": {"$exists": True}}, name="uq_customers_national_id")]),
    "wallets": (WALLETS, [
        IndexModel([("owner.merchant_code", ASCENDING)], unique=True,
                   partialFilterExpression={"owner.kind": "merchant"}, name="uq_wallets_merchant"),
        IndexModel([("owner.system_purpose", ASCENDING)], unique=True,
                   partialFilterExpression={"owner.kind": "system"}, name="uq_wallets_system_purpose")]),
    "merchants": (MERCHANTS, [IndexModel([("wallet_number", ASCENDING)], unique=True, name="uq_merchants_wallet")]),
    "transactions": (TRANSACTIONS, [
        IndexModel([("idempotency_key", ASCENDING)], unique=True, name="uq_transactions_idempotency_key")]),
    "kyc_tiers": (TIERS, []),
    "fee_rules": (FEE_RULES, []),
    "audit_log": (AUDIT, []),
}


def main() -> int:
    client = mongo_client()
    ensure_replica_set(client)
    client.drop_database("oworail")
    db = client.oworail
    for name, (validator, indexes) in COLLECTIONS.items():
        db.create_collection(name, validator=validator, validationLevel="strict", validationAction="error")
        if indexes:
            db[name].create_indexes(indexes)
        print(f"{name:<13} validator on, indexes: {', '.join(i.document['name'] for i in indexes) or '(_id only)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
