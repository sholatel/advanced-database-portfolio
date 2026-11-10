# P1: Normalisation: from an Unnormalised Report to BCNF

To show why the OwoRail tables look the way they do, I start from data as the operations team might keep it: a single transaction report. I then take it step by step through 1NF, 2NF, 3NF and BCNF, and end with exactly the schema in [schema.md](schema.md).

**Normal forms used:**

| Normal form | Test applied (Silberschatz et al., 2020; Elmasri & Navathe, 2016) |
|---|---|
| 1NF | every attribute holds one atomic value; no repeating groups |
| 2NF | 1NF, and no non-key attribute depends on only part of a candidate key (no **partial dependency**) |
| 3NF | 2NF, and no non-key attribute depends on another non-key attribute (no **transitive dependency**) |
| BCNF | for every non-trivial functional dependency X → Y, X is a candidate key or superkey |

The point of all this is to stop the same fact being stored in many places, because that is where insertion, update and deletion anomalies come from. Normalising too far makes queries harder, though, so I kept a few derivable values on purpose and explain why near the end.

---

## 1. The unnormalised starting point (UNF)

OwoRail's operations team keeps a daily **transaction report** with one row per transaction. Each row also carries the sender's details, the destination's details, the ledger lines and the status history. Braces `{ }` mark a repeating group:

```text
TRANSACTION_REPORT (transaction_ref, created_at, transaction_type, channel, amount_kobo, fee_kobo,
    fee_rule_id, fee_rule_terms, status,
    sender_name, sender_email, sender_address, {sender_phone}, sender_tier, sender_tier_daily_limit_kobo,
    src_wallet_number, src_wallet_balance_kobo,
    dst_wallet_number, dst_owner_name, dst_merchant_code, dst_merchant_category,
    {line_no, line_wallet_number, line_wallet_owner, entry_type, line_amount_kobo, line_posted_at},
    {seq_no, history_status, changed_at, history_reason},
    reverses_ref, reversal_reason, requested_by)
```

Sample report for 2 November 2026 (synthetic data; amounts in kobo; times UTC). Related attributes share a cell to keep the table narrow.

| transaction_ref | created_at · type · channel | amount · fee · fee rule | sender (name, email, address, tier, daily limit) | sender phones | source wallet (number, balance) | destination (wallet, owner, merchant code, category) | ledger lines (line, wallet, owner, D/C, amount, posted) | status history (seq, status, time, reason) | reversal of · reason · by |
|---|---|---|---|---|---|---|---|---|---|
| OWR000000000101 | 09:15:02 · TRANSFER · APP | 500000 · 1000 · rule 2 "flat 1000, 0 bps, no cap" | Adaeze Okafor, adaeze.okafor@example.com, "14 Allen Avenue, Ikeja, Lagos", Tier 2, 20000000 | +2348030000001<br>+2349050000001 | 3000000001, 1750000 | 3000000002, Tunde Bakare, –, – | 1, 3000000001, Adaeze Okafor, D, 501000, 09:15:02<br>2, 3000000002, Tunde Bakare, C, 500000, 09:15:02<br>3, 9000000001, OwoRail FEES, C, 1000, 09:15:02 | 1 PENDING 09:15:02<br>2 SUCCESSFUL 09:15:02<br>3 REVERSED 16:20:41 "reversed by OWR000000000104" | – |
| OWR000000000102 | 11:40:17 · MERCHANT_PAYMENT · USSD | 250000 · 0 · – | Adaeze Okafor, adaeze.okafor@example.com, "14 Allen Avenue, Ikeja, Lagos", Tier 2, 20000000 | +2348030000001<br>+2349050000001 | 3000000001, 1750000 | 3000000042, Mama Put Kitchen, MRC00042, FOOD | 1, 3000000001, Adaeze Okafor, D, 250000, 11:40:17<br>2, 3000000042, Mama Put Kitchen, C, 250000, 11:40:17 | 1 PENDING 11:40:17<br>2 SUCCESSFUL 11:40:17 | – |
| OWR000000000103 | 13:05:55 · TRANSFER · WEB | 1000000 · 2500 · rule 3 "flat 2500, 0 bps, no cap" | Tunde Bakare, tunde.bakare@example.com, "3 Herbert Macaulay Way, Yaba, Lagos", Tier 1, 5000000 | +2348120000002 | 3000000002, 50000 | 3000000001, Adaeze Okafor, –, – | (none: failed) | 1 PENDING 13:05:55<br>2 FAILED 13:05:56 "insufficient funds" | – |
| OWR000000000104 | 16:20:41 · REVERSAL · WEB | 500000 · 0 · – | Tunde Bakare, tunde.bakare@example.com, "3 Herbert Macaulay Way, Yaba, Lagos", Tier 1, 5000000 | +2348120000002 | 3000000002, 50000 | 3000000001, Adaeze Okafor, –, – | 1, 3000000002, Tunde Bakare, D, 500000, 16:20:41<br>2, 9000000001, OwoRail FEES, D, 1000, 16:20:41<br>3, 3000000001, Adaeze Okafor, C, 501000, 16:20:41 | 1 PENDING 16:20:41<br>2 SUCCESSFUL 16:20:41 | OWR000000000101 · "duplicate transfer reported by customer" · support.ifeoma |

The balances are the wallets' **current** balances on the day the report was printed. Adaeze started the day with 2000000 kobo: 2000000 − 501000 − 250000 + 501000 = 1750000.

### Anomalies in the unnormalised report

Even with four rows, the report already shows all three kinds of anomaly:

| Anomaly | Example from the sample |
|---|---|
| **Insertion** | A newly onboarded customer with no transactions can't be recorded at all: every row needs a `transaction_ref`. The same goes for a new merchant (say MRC00043), and for new Tier 3 limits before any Tier 3 customer sends money. |
| **Update** | Adaeze's address is repeated in rows 101 and 102, and will be repeated in every future row she sends. If she moves house and one row is missed, the report holds two addresses for her. Raising the Tier 2 daily limit means updating every row of every Tier 2 sender. The "current balance" column is out of date in every earlier row after each new posting. |
| **Deletion** | Purging failed transactions removes row 103, the only row where Tunde is the sender, so his email, address, phone number and tier are lost. Deleting row 102 loses the only record of Mama Put Kitchen's merchant code and category. |

---

## 2. Functional dependencies

The functional dependencies (FDs) come from the business rules ([requirements-and-business-rules.md](requirements-and-business-rules.md)). The list covers the report's attributes and the remaining data-dictionary attributes, using the attribute names of the final schema. Attributes with the same name in different entities are different attributes, for example `customer.status` and `wallet.status`.

| FD | Dependency | Source |
|---|---|---|
| FD1 | customer_id → full_name, email, date_of_birth, address_street, address_city, address_state, customer.status, customer.created_at | BR-01 |
| FD2 | email → customer_id | BR-01 (email is unique) |
| FD3 | phone_number → customer_id | BR-02 (a number belongs to one customer) |
| FD4 | kyc_profile_id → customer_id, tier_level, id_type, national_id_number, verification_status, verified_at, verified_by | BR-03, BR-04 |
| FD5 | customer_id → kyc_profile_id | BR-03 (at most one profile per customer) |
| FD6 | id_type, national_id_number → kyc_profile_id | BR-03 |
| FD7 | tier_level → tier_name, single_txn_limit_kobo, daily_limit_kobo, max_balance_kobo | BR-04 (limits belong to the tier) |
| FD8 | tier_name → tier_level | BR-04 |
| FD9 | merchant_id → merchant_code, business_name, merchant_type, category, merchant.status, merchant.created_at | BR-09 |
| FD10 | merchant_code → merchant_id | BR-09 |
| FD11 | wallet_id → wallet_number, wallet_type, customer_id, merchant_id, system_purpose, currency, balance_kobo, wallet.status, wallet.created_at | BR-05, BR-06 |
| FD12 | wallet_number → wallet_id | BR-05 |
| FD13 | merchant_id → wallet_id | BR-06 (a merchant has exactly one wallet) |
| FD14 | system_purpose → wallet_id | BR-06 (one wallet per system purpose) |
| FD15 | customer_id, wallet_id → nickname, saved_at | BR-08 |
| FD16 | fee_rule_id → fee_rule.transaction_type, min_amount_kobo, max_amount_kobo, flat_fee_kobo, percent_bps, cap_kobo, effective_from, effective_to | BR-12 |
| FD17 | transaction_id → transaction_ref, idempotency_key, transaction_type, source_wallet_id, destination_wallet_id, amount_kobo, fee_kobo, fee_rule_id, transaction.status, channel, bill_reference, narration, transaction.created_at | BR-10, BR-11, BR-12 |
| FD18 | transaction_ref → transaction_id | BR-10 |
| FD19 | idempotency_key → transaction_id | BR-11 |
| FD20 | transaction_id, line_no → ledger_entry.wallet_id, entry_type, ledger_entry.amount_kobo | BR-13 |
| FD21 | transaction_id, seq_no → history.status, changed_at, history.reason | BR-15 |
| FD22 | original_transaction_id → reversal_transaction_id, reversal.reason, requested_by | BR-16 (at most once) |
| FD23 | reversal_transaction_id → original_transaction_id | BR-16 (a reversal undoes one transaction) |
| FD24 | audit_id → occurred_at, actor, action, target_type, target_id, details | BR-17 |

**Dependencies that look plausible but do not hold.** These had to be ruled out, because any of them would change the decomposition:

| Candidate FD | Holds? | Why |
|---|---|---|
| category → merchant_type | **No** | BR-09 lets any category be either type. TRANSPORT covers ride-hailing merchants and toll-road billers. If this FD held, `merchant` would violate 3NF. |
| customer_id → wallet_id | **No** | A customer may own several wallets (BR-06). |
| fee_rule_id, amount_kobo → fee_kobo | **No, not over time** | It holds on the day of posting. BR-12 says later rule changes must not alter past transactions, so if a rule is corrected, the stored fee and the recomputed fee differ. `fee_kobo` records a historical fact. |
| transaction_id → merchant_id | Yes, but **only transitively** | transaction_id → destination_wallet_id → merchant_id (FD17, then FD11). This is exactly why `merchant_id` is not a column of `transaction`. |
| transaction_id → sender customer | Yes, but **only transitively** | transaction_id → source_wallet_id → customer_id. This is why the sender is not stored on a transaction; it is the owner of the source wallet. |

---

## 3. First normal form (1NF)

1NF is about atomic values, and the report breaks it in two ways.

**Non-atomic values are split into their components:**
- `sender_address` ("14 Allen Avenue, Ikeja, Lagos") becomes `sender_street`, `sender_city`, `sender_state`. This is the composite attribute from the ERD.
- `fee_rule_terms` ("flat 1000, 0 bps, no cap") becomes `flat_fee_kobo`, `percent_bps`, `cap_kobo`.

**Repeating groups move into their own relations.** Each new relation takes the key of whatever the group repeats for:
- **Ledger lines and status history** repeat per transaction, so they take `transaction_ref`.
- **Phones** repeat per sender, not per transaction. They take the sender's identifier, `sender_email`. Keyed by `transaction_ref`, every phone number would be copied into every transaction its owner sends.

```text
TXN_1NF          (#transaction_ref, created_at, transaction_type, channel, amount_kobo, fee_kobo,
                  fee_rule_id, flat_fee_kobo, percent_bps, cap_kobo, status,
                  sender_name, sender_email, sender_street, sender_city, sender_state,
                  sender_tier, sender_tier_daily_limit_kobo, src_wallet_number, src_wallet_balance_kobo,
                  dst_wallet_number, dst_owner_name, dst_merchant_code, dst_merchant_category,
                  reverses_ref, reversal_reason, requested_by)
SENDER_PHONE_1NF (#phone_number, sender_email)
LEDGER_LINE_1NF  (#transaction_ref, #line_no, line_wallet_number, line_wallet_owner, entry_type, line_amount_kobo, line_posted_at)
STATUS_LINE_1NF  (#transaction_ref, #seq_no, history_status, changed_at, history_reason)
```

`SENDER_PHONE_1NF` is keyed by `phone_number` alone, because of FD3: a number belongs to one customer.

All relations are now in 1NF. The redundancy is still there. Here is `LEDGER_LINE_1NF` for the sample:

| transaction_ref | line_no | line_wallet_number | line_wallet_owner | entry_type | line_amount_kobo | line_posted_at |
|---|---|---|---|---|---|---|
| OWR000000000101 | 1 | 3000000001 | Adaeze Okafor | DEBIT | 501000 | 2026-11-02 09:15:02 |
| OWR000000000101 | 2 | 3000000002 | Tunde Bakare | CREDIT | 500000 | 2026-11-02 09:15:02 |
| OWR000000000101 | 3 | 9000000001 | OwoRail FEES | CREDIT | 1000 | 2026-11-02 09:15:02 |
| OWR000000000102 | 1 | 3000000001 | Adaeze Okafor | DEBIT | 250000 | 2026-11-02 11:40:17 |
| OWR000000000102 | 2 | 3000000042 | Mama Put Kitchen | CREDIT | 250000 | 2026-11-02 11:40:17 |
| OWR000000000104 | 1 | 3000000002 | Tunde Bakare | DEBIT | 500000 | 2026-11-02 16:20:41 |
| OWR000000000104 | 2 | 9000000001 | OwoRail FEES | DEBIT | 1000 | 2026-11-02 16:20:41 |
| OWR000000000104 | 3 | 3000000001 | Adaeze Okafor | CREDIT | 501000 | 2026-11-02 16:20:41 |

`line_posted_at` repeats the same value on every line of a transaction, and `line_wallet_owner` repeats the same name on every line for a wallet. These are the next two problems to remove.

---

## 4. Second normal form (2NF): remove partial dependencies

2NF only matters for relations with a **composite key**. A relation whose key is a single attribute is automatically in 2NF.

| Relation | Key | Partial dependency? |
|---|---|---|
| TXN_1NF | transaction_ref (single) | none possible |
| SENDER_PHONE_1NF | phone_number (single) | none possible |
| LEDGER_LINE_1NF | (transaction_ref, line_no) | **Yes:** `transaction_ref → line_posted_at`. Every line of a transaction is posted at the transaction's own time, so `line_posted_at` depends on only part of the key. |
| STATUS_LINE_1NF | (transaction_ref, seq_no) | none: each status change has its own time and reason |

**Decomposition:** remove `line_posted_at` from the ledger lines. It is the same value as `TXN_1NF.created_at`, which already depends on the whole key `transaction_ref`, so no information is lost.

```text
LEDGER_LINE_2NF (#transaction_ref, #line_no, line_wallet_number, line_wallet_owner, entry_type, line_amount_kobo)
```

The other three relations carry over unchanged as TXN_2NF, SENDER_PHONE_2NF and STATUS_LINE_2NF.

**Anomaly removed:** correcting a transaction's time used to mean updating every one of its lines. The ERD already reflected this: LEDGER_ENTRY has no timestamp of its own.

---

## 5. Third normal form (3NF): remove transitive dependencies

TXN_2NF is in 2NF but full of **transitive dependencies**: non-key attributes that depend on other non-key attributes.

| Transitive chain | Dependency on a non-key attribute |
|---|---|
| transaction_ref → src_wallet_number → src_wallet_balance_kobo, owner | a wallet's balance and owner depend on the wallet, not the transaction (FD11) |
| transaction_ref → … → sender_email → sender_name, sender_street, sender_city, sender_state, sender_tier | the customer's details depend on the customer (FD1, FD2) |
| sender_email → sender_tier → sender_tier_daily_limit_kobo | limits depend on the tier (FD7). This is the reason for KYC_TIER in the ERD. |
| transaction_ref → dst_wallet_number → dst_owner_name, dst_merchant_code | the owner depends on the wallet (FD11, FD13) |
| dst_merchant_code → dst_merchant_category, business name | the merchant's details depend on the merchant (FD9, FD10) |
| transaction_ref → fee_rule_id → flat_fee_kobo, percent_bps, cap_kobo | rule terms depend on the rule (FD16) |
| (in LEDGER_LINE_2NF) line_wallet_number → line_wallet_owner | the owner depends on the wallet |

**Decomposition:** each determinant becomes the key of a new relation and stays behind as a foreign key.

```text
CUSTOMER_3NF        (#email, full_name, address_street, address_city, address_state, tier_level → KYC_TIER_3NF)
CUSTOMER_PHONE_3NF  (#phone_number, email → CUSTOMER_3NF)
KYC_TIER_3NF        (#tier_level, daily_limit_kobo)
MERCHANT_3NF        (#merchant_code, business_name, category)
WALLET_3NF          (#wallet_number, owner_email → CUSTOMER_3NF, owner_merchant_code → MERCHANT_3NF, system_purpose, balance_kobo)
FEE_RULE_3NF        (#fee_rule_id, flat_fee_kobo, percent_bps, cap_kobo)
TRANSACTION_3NF     (#transaction_ref, created_at, transaction_type, channel, amount_kobo, fee_kobo,
                     fee_rule_id → FEE_RULE_3NF, status,
                     src_wallet_number → WALLET_3NF, dst_wallet_number → WALLET_3NF,
                     reverses_ref, reversal_reason, requested_by)
LEDGER_ENTRY_3NF    (#transaction_ref → TRANSACTION_3NF, #line_no, wallet_number → WALLET_3NF, entry_type, amount_kobo)
STATUS_HISTORY_3NF  (#transaction_ref → TRANSACTION_3NF, #seq_no, status, changed_at, reason)
```

A few things change at this step:
- **The sender and the destination owner disappear from the transaction.** Both are found through the wallets. `sender_name` and `dst_owner_name` were the same kind of fact, "who owns this wallet", which now lives once in WALLET_3NF. To find whose transaction it is, you go from `source_wallet_id` or `destination_wallet_id` to the wallet's owner.
- **WALLET_3NF gets three owner columns:** a customer's email, a merchant's code, or a system purpose for OwoRail's own wallets (`OwoRail FEES` in the report). Exactly one is filled. This is the exclusive arc in schema.md (`chk_wallet_owner_matches_type`).
- **`line_wallet_owner` is gone** from the ledger lines for the same reason.

---

## 6. Boyce–Codd normal form (BCNF)

BCNF requires that **every determinant is a candidate key**. 3NF still allows one exception: a non-key attribute determining part of a candidate key. To check, list every non-trivial FD that holds within each 3NF relation:

| Relation | Candidate keys | Determinants found | BCNF? |
|---|---|---|---|
| CUSTOMER_3NF | email | email | yes |
| CUSTOMER_PHONE_3NF | phone_number | phone_number | yes |
| KYC_TIER_3NF | tier_level | tier_level | yes |
| MERCHANT_3NF | merchant_code | merchant_code. `category → merchant_type` does not hold, since any category can be either type. | yes |
| WALLET_3NF | wallet_number | wallet_number; owner_merchant_code and system_purpose are unique where filled (FD13, FD14), so they are candidate keys | yes |
| FEE_RULE_3NF | fee_rule_id | fee_rule_id | yes |
| TRANSACTION_3NF | transaction_ref | transaction_ref; reverses_ref is unique where filled (FD22: a transaction is reversed at most once) | yes |
| LEDGER_ENTRY_3NF | (transaction_ref, line_no) | (transaction_ref, line_no) | yes |
| STATUS_HISTORY_3NF | (transaction_ref, seq_no) | (transaction_ref, seq_no) | yes |

The 3NF relations are already in BCNF. The case BCNF exists to catch doesn't arise. For example, if ledger lines were keyed by (transaction_ref, wallet_number), with a rule "line_no → wallet_number", part of the key would depend on a non-key. OwoRail's ledger is keyed by line number, and a wallet may appear more than once in a transaction.

---

## 7. From the BCNF relations to the final schema

Getting from these relations to the final 13 tables in schema.md took four more design decisions, none of which breaks BCNF.

1. **Surrogate keys.** `customer_id`, `merchant_id`, `wallet_id`, `transaction_id`, `kyc_profile_id` and `fee_rule_id` become primary keys, and foreign keys switch to them. The natural keys (`email`, `merchant_code`, `wallet_number`, `transaction_ref`) stay as UNIQUE alternate keys. A surrogate key is one-to-one with the natural key (FD2, FD10, FD12, FD18), so it adds a candidate key and changes no other dependency. BCNF is preserved.
2. **KYC data split from the customer.** `tier_level` and the identity attributes move to `kyc_profile`, linked one-to-one (FD5). Normal forms don't require this; it is a privacy decision. Identity data is held separately, so support staff can be denied access to it (BR-18, NFR-04, NFR-05), and a customer can exist before KYC is done without a NULL tier. Both parts keep their own keys, so both stay in BCNF.
3. **Reversal split from the transaction.** `reverses_ref`, `reversal_reason` and `requested_by` move to `reversal`. They didn't break BCNF in TRANSACTION_3NF, but they are NULL for every non-reversal row. As a separate relation, "reversed at most once" becomes a primary key (`pk_reversal`).
4. **Attributes and relations that weren't on the report** are added from the data dictionary:
   - customer: date_of_birth, status, created_at
   - kyc_profile: id_type, national_id_number, verification fields
   - kyc_tier: tier_name, the other limits
   - merchant: merchant_type, status
   - wallet: wallet_type, currency, status
   - fee_rule: transaction_type, band and dates
   - transaction: idempotency_key, bill_reference, narration
   - `saved_beneficiary` (FD15)
   - `audit_log` (FD24)

   Each attribute is placed in the relation whose key determines it, according to the FD list, so no new partial or transitive dependency arises.

### Final BCNF check

| Relation | Candidate keys | FDs holding in it | BCNF? |
|---|---|---|---|
| customer | {customer_id}, {email} | FD1, FD2 | yes |
| customer_phone | {phone_number} | FD3 | yes |
| kyc_tier | {tier_level}, {tier_name} | FD7, FD8 | yes |
| kyc_profile | {kyc_profile_id}, {customer_id}, {id_type, national_id_number} | FD4, FD5, FD6 | yes |
| merchant | {merchant_id}, {merchant_code} | FD9, FD10 | yes |
| wallet | {wallet_id}, {wallet_number}; merchant_id and system_purpose where filled | FD11–FD14 | yes; see the note on `wallet_type` below |
| saved_beneficiary | {customer_id, wallet_id} | FD15 | yes |
| fee_rule | {fee_rule_id}; also {transaction_type, min_amount_kobo, effective_from}, implied by `excl_fee_rule_no_overlap` (two such rules would overlap) | FD16 | yes |
| transaction | {transaction_id}, {transaction_ref}, {idempotency_key} | FD17–FD19 | yes |
| ledger_entry | {transaction_id, line_no} | FD20 | yes |
| transaction_status_history | {transaction_id, seq_no} | FD21 | yes |
| reversal | {original_transaction_id}, {reversal_transaction_id} | FD22, FD23 | yes |
| audit_log | {audit_id} | FD24 | yes |

### Final relations

These are the same relations as in schema.md.

```text
customer                   (#customer_id, full_name, email, date_of_birth, address_street, address_city, address_state, status, created_at)
customer_phone             (#phone_number, customer_id → customer)
kyc_tier                   (#tier_level, tier_name, single_txn_limit_kobo, daily_limit_kobo, max_balance_kobo)
kyc_profile                (#kyc_profile_id, customer_id → customer, tier_level → kyc_tier, id_type, national_id_number, verification_status, verified_at, verified_by)
merchant                   (#merchant_id, merchant_code, business_name, merchant_type, category, status, created_at)
wallet                     (#wallet_id, wallet_number, wallet_type, customer_id → customer, merchant_id → merchant, system_purpose, currency, balance_kobo, status, created_at)
saved_beneficiary          (#customer_id → customer, #wallet_id → wallet, nickname, saved_at)
fee_rule                   (#fee_rule_id, transaction_type, min_amount_kobo, max_amount_kobo, flat_fee_kobo, percent_bps, cap_kobo, effective_from, effective_to)
transaction                (#transaction_id, transaction_ref, idempotency_key, transaction_type, source_wallet_id → wallet, destination_wallet_id → wallet, amount_kobo, fee_kobo, fee_rule_id → fee_rule, status, channel, bill_reference, narration, created_at)
ledger_entry               (#transaction_id → transaction, #line_no, wallet_id → wallet, entry_type, amount_kobo)
transaction_status_history (#transaction_id → transaction, #seq_no, status, changed_at, reason)
reversal                   (#original_transaction_id → transaction, reversal_transaction_id → transaction, reason, requested_by)
audit_log                  (#audit_id, occurred_at, actor, action, target_type, target_id, details)
```

---

## 8. The decomposition loses nothing

Every decomposition step above split a relation R on a dependency X → Y. The determinant X became the key of the new relation and stayed in R as a foreign key. Two properties follow (Silberschatz et al., 2020, ch. 7):

- **Lossless join.** The shared attribute X is a key of the new relation, so joining the pieces back on X recreates exactly the original rows, with no spurious ones. The original report can be rebuilt with joins: transaction → wallet → customer or merchant, plus ledger and status lines. Portfolio 2 runs that kind of join as its statement query.
- **Dependency preservation.** Every FD from FD1 to FD24 holds within a single final relation, so each one can be enforced by that relation's primary key or UNIQUE constraint, with no cross-table check needed.

---

## 9. Deliberate redundancy: balancing normalisation and performance

Normalising everything has a cost: going too far makes queries more complex, so it has to be balanced against performance. I kept three stored values that could in principle be derived.

Normal forms judge **one relation at a time**. These three redundancies sit **between** relations: a value in one table duplicates something computable from another. No relation breaks BCNF because of them, but nothing in the normal forms protects them either. Each needs an explicit control.

| Stored value | Derivable from | Why it is kept | How it is kept correct |
|---|---|---|---|
| `wallet.balance_kobo` | Σ credits − Σ debits of the wallet's `ledger_entry` rows | Every debit must check "is there enough money?" (BR-07). Summing a busy wallet's ledger on each transfer gets slower as the ledger grows (NFR-03). The wallet row is also what concurrent transfers lock to serialise debits (Portfolio 3). | Updated only by the posting procedure, in the **same ACID transaction** as the ledger lines. `chk_wallet_balance_non_negative` guards it. A reconciliation query compares it with the ledger (BR-14, FR-08). Only the application role can write it (BR-18). |
| `transaction.fee_kobo` | the fee rule's terms applied to `amount_kobo` | It is a **historical fact**: what the customer was actually charged. If a rule is later corrected, recomputing would change history (BR-12). It also saves recomputing every fee in settlement and fee-income reports. | Never updated after posting. Constraints `chk_transaction_fee_non_negative` and `chk_transaction_fee_has_rule`, and the rule used is recorded (`fee_rule_id`). The ledger lines must sum to amount + fee (BR-13). |
| `transaction.status` | the latest `transaction_status_history` row | Nearly every query filters on the current status: statements, reports, velocity checks (FR-07 to FR-10). Finding "the latest history row" for each transaction needs a correlated subquery or LATERAL join. The reversal procedure also locks the transaction row to check its status (BR-16, Portfolio 3). | The procedures write the new history row and the new status in the same transaction (BR-15). A consistency query checks that they agree. |

**A smaller, constrained redundancy: `wallet.wallet_type`.** The type can be inferred from which owner column is filled: `customer_id` means CUSTOMER, `merchant_id` means MERCHANT, `system_purpose` means SYSTEM. Treated as an FD over non-NULL values, `customer_id → wallet_type` has a determinant that isn't a key, because a customer owns several wallets. `wallet_type` is kept as an explicit discriminator for readability and for `chk_wallet_balance_non_negative`. It can never disagree with the owner columns, because `chk_wallet_owner_matches_type` checks all of them in the same row. A row-level CHECK makes the update anomaly impossible.

Everything else is fully normalised. Deliberately **not** stored: `customer.age` (it would go stale), `wallet.ledger_balance_kobo` (that is the reconciliation value itself), `transaction.total_debit_kobo`, `transaction.merchant_id`, and the sender (the source wallet's owner). These are the derived attributes and transitive dependencies identified above.

---

## 10. How the final schema removes the anomalies

| Anomaly in the report | Removed because |
|---|---|
| A customer, merchant or tier can't be recorded without a transaction | `customer`, `merchant` and `kyc_tier` are separate relations with their own keys |
| Adaeze's address repeated in every row she sends | the address is stored once, in `customer` (FD1) |
| A tier limit change touches every row for that tier | limits are stored once per tier, in `kyc_tier` (FD7) |
| Balances in earlier rows go out of date | the balance is stored once per wallet, in `wallet`, and kept equal to the ledger |
| Purging a failed transaction loses the sender's details | deleting a `transaction` row doesn't touch `customer`. Deleting financial rows is refused anyway (`ON DELETE RESTRICT`, append-only ledger). |
| A ledger line's time could disagree with its transaction | `ledger_entry` has no time column; it uses `transaction.created_at` |

In short, each fact is now stored once, apart from the three deliberate cases, and the anomalies from the report can't happen any more. The keys and named constraints in schema.md protect the data, and the redundancies I kept are there for performance, which Portfolio 2 measures.

## References

Elmasri, R., & Navathe, S. B. (2016). *Fundamentals of database systems* (7th ed.). Pearson.

Silberschatz, A., Korth, H. F., & Sudarshan, S. (2020). *Database system concepts* (7th ed.). McGraw-Hill Education.
