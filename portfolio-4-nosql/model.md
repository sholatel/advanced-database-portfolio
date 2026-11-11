# OwoRail as documents

In a relational design I start from the data and normalise it. In a document design I start from how the data is used, and shape each document so that the common operations read one document, or a few. This page takes the same OwoRail data as Portfolio 1 and models it for MongoDB 7.0. The documents are loaded straight from the PostgreSQL database, so both models hold exactly the same facts.

## Access patterns

| # | Operation | How often | What it needs together |
|---|---|---|---|
| A1 | find a customer by phone, with their wallets | very often (support, login) | customer, phones, wallets |
| A2 | show a wallet statement, newest first | very often (app) | a wallet's transactions with their amounts and times |
| A3 | show one transaction and its status history | often (support) | transaction, history, reversal link |
| A4 | check today's spend before posting (KYC limit) | every posting | a wallet's outgoing transactions today |
| A5 | post a transfer | every posting | two or three wallet balances and one new transaction, atomically |
| A6 | reconcile balances, settle merchants, velocity checks | daily / monthly reports | all transactions in a period, grouped |
| A7 | verify KYC | rarely, compliance only | the customer's identity data, kept from other staff |

## Collections

| Collection | One document per | Embedded | Referenced |
|---|---|---|---|
| `customers` | customer | address, phone numbers, KYC profile | wallets point to the customer |
| `wallets` | wallet (`_id` = wallet number) | owner summary: kind, id or code, name | the owning customer or merchant |
| `merchants` | merchant or biller (`_id` = merchant code) | | its wallet number |
| `transactions` | transaction (`_id` = reference) | source and destination (wallet + name), ledger entries, status history, reversal link | the wallets |
| `kyc_tiers`, `fee_rules` | tier, fee rule | | used by posting |
| `audit_log` | audit event | target (type, id), details | nothing |
| `customers_support` | *(a view)* | `customers` without `kyc` | |

The 13 relational tables become 7 collections. The lost tables are each embedded in their parent document:

| Relational table | Document form | Why |
|---|---|---|
| `customer_phone` | `customers.phones` array | always read with the customer; a few per customer (A1) |
| `kyc_profile` | `customers.kyc` subdocument | one-to-one and read with the customer; access is controlled with a view (see below) |
| `ledger_entry` | `transactions.entries` array | written once with the transaction, never changed, always read with it (A2, A3) |
| `transaction_status_history` | `transactions.history` array | the same reasons (A3) |
| `reversal` | `transactions.reverses` / `reversed_by` | a one-to-one link with two attributes; stored on both sides so either end finds the other |
| `saved_beneficiary` | not loaded | not used by any of the workload's operations |

## Embed or reference: the rules I used

1. **Embed what is owned by the parent and read with it.** Ledger entries and status history belong to exactly one transaction, never change after posting and are bounded (2–3 entries, 2–3 history rows). Embedding them makes a transaction one self-contained document. Showing a transaction (A3) is then one read by `_id`, with no joins.
2. **Reference what changes on its own, or what is shared.** A wallet's balance changes with every posting. Embedding wallets in customers would make every posting rewrite the customer document. Embedding the balance in transactions would copy it thousands of times. So wallets are their own documents, referenced by number.
3. **Don't embed what grows without limit.** A busy wallet has thousands of transactions, so they are never embedded in the wallet: the 16 MB document limit and the cost of rewriting a growing array rule it out. The statement (A2) is a query on `transactions` instead, served by a multikey index on `entries.wallet` and `created_at`.
4. **Copy small, stable values for display (the extended reference pattern).** Each transaction stores the source and destination *names* as well as the wallet numbers, so a statement needs no join. The trade-off is that the copies don't follow a later name change. That's acceptable for a statement, which should show the name at the time of payment, much like the fee snapshot in Portfolio 1.

### What the ledger looks like now

A transaction from the normalisation sample, exactly as loaded. Amounts are 64-bit integers (`NumberLong`) and times are BSON dates in UTC; they're shown here as plain JSON:

```json
{
  "_id": "OWR000000000101",
  "idempotency_key": "00000000-0000-4000-8000-000000000101",
  "type": "TRANSFER",
  "source":      { "wallet": "3000000001", "name": "Adaeze Okafor" },
  "destination": { "wallet": "3000000002", "name": "Tunde Bakare" },
  "amount_kobo": 500000,
  "fee_kobo": 1000,
  "fee_rule_id": 2,
  "status": "REVERSED",
  "channel": "APP",
  "created_at": "2026-11-02T09:15:02Z",
  "entries": [
    { "line": 1, "wallet": "3000000001", "type": "DEBIT",  "amount": 501000 },
    { "line": 2, "wallet": "3000000002", "type": "CREDIT", "amount": 500000 },
    { "line": 3, "wallet": "9000000001", "type": "CREDIT", "amount": 1000 }
  ],
  "history": [
    { "seq": 1, "status": "PENDING",    "at": "2026-11-02T09:15:02Z" },
    { "seq": 2, "status": "SUCCESSFUL", "at": "2026-11-02T09:15:02Z" },
    { "seq": 3, "status": "REVERSED",   "at": "2026-11-02T16:20:41Z", "reason": "reversed by OWR000000000104" }
  ],
  "reversed_by": "OWR000000000104"
}
```

In PostgreSQL the same facts sit in four tables: one `transaction` row, three `ledger_entry` rows, three `transaction_status_history` rows and one `reversal` row.

In Portfolio 1 a ledger line has no time of its own, so a statement has to join every line of a wallet to its transaction before it can sort (Portfolio 2, Q2). Here each line sits inside its transaction, next to `created_at`. A single compound multikey index, `{entries.wallet: 1, created_at: -1, _id: -1}`, returns a wallet's newest entries in order.

## Integrity: what the database enforces

Every collection has a validator (`$jsonSchema` plus query rules) with `validationLevel: strict` and `validationAction: error`. Inserts and updates that break it are rejected. [scripts/schema.py](scripts/schema.py) defines them, and [m9_validation.txt](evidence/m9_validation.txt) tests each one.

| Rule | Relational (Portfolio 1) | Document (here) |
|---|---|---|
| types, formats, allowed values (statuses, `999` IDs, phone format, kobo as 64-bit integers) | CHECK constraints | `$jsonSchema` (`bsonType: long`, `pattern`, `enum`) |
| unknown fields refused | implicit (fixed columns) | `additionalProperties: false` |
| unique email, phone, national ID, idempotency key | UNIQUE constraints | unique indexes (one is a unique multikey index on `phones`) |
| a customer or merchant balance never below zero | `chk_wallet_balance_non_negative` | `$or: [{type: SYSTEM}, {balance_kobo: {$gte: 0}}]` |
| debits = credits; posted ⇒ 2+ entries; failed ⇒ none | deferred constraint trigger, checked at COMMIT | `$expr` on the embedded `entries`, **checked on every write of the document** |
| current status = last history entry | consistency query only | `$expr` on the embedded `history` |
| the wallet a transaction names exists | foreign key | **not enforced**: MongoDB has no foreign keys |
| stored balance = sum of the wallet's entries | posting in one transaction, plus reconciliation | the same: a multi-document transaction, plus the reconciliation pipeline |

Embedding moves some rules *into* a single document, and those become easier to enforce than in SQL. Any rule that spans documents now relies on the application and on transactions, because nothing like a foreign key exists.

## Indexes

| Index | Kind | Serves |
|---|---|---|
| `uq_customers_email`, `uq_customers_phones`, `uq_customers_national_id` | unique (multikey; partial) | integrity; A1 |
| `uq_wallets_merchant`, `uq_wallets_system_purpose` | unique, partial | one wallet per merchant / per system purpose |
| `uq_transactions_idempotency_key` | unique | BR-11 retries |
| `ix_transactions_entry_wallet_created` | compound multikey | A2 statement |
| `ix_transactions_source_created` | compound | A4 daily spend; the dormant-wallet lookup |
| `ix_transactions_created` | single field | velocity check |
| `ix_transactions_status_type_created` | compound, in equality–sort–range order | monthly settlement |
| `ix_transactions_failed_created` | partial (`status: FAILED`) | failure report |
| `ix_wallets_customer`, `ix_wallets_balance` | single / compound | A1 lookup of a customer's wallets; dormant wallets by balance |

## Least privilege with embedded identity data

Portfolio 1 keeps KYC data in its own table, so support staff can simply be denied that table. Embedding KYC in the customer document removes that boundary, so it has to be rebuilt. A view, `customers_support`, projects the customer *without* `kyc`. The `supportRead` role may `find` on that view, on `wallets` and on `transactions`, but not on `customers`. In the test, a support user was refused the `customers` collection, read the view without any KYC field, and was refused every write.

## Transactions

A transfer changes two or three wallet documents and inserts one transaction document, so it needs a **multi-document transaction**. MongoDB supports these only on a replica set, so the Portfolio 4 container runs as a single-node replica set (`rs0`). [scripts/transfers.py](scripts/transfers.py) does a transfer in one transaction, with snapshot read concern and majority write concern:

- the debit is a conditional update (`balance_kobo >= amount + fee`, wallet ACTIVE);
- then the credit, the fee and the transaction document are written;
- any failure aborts all of it.

The results are in [suitability.md](suitability.md).
