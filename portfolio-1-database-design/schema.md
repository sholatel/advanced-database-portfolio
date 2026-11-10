# P1: Logical Design: Relational Schema, Keys and Constraints

Here the OwoRail ER diagram becomes a set of relational tables for PostgreSQL 16. I start from the Chen ERD and the business rules in [requirements-and-business-rules.md](requirements-and-business-rules.md). Each entity and relationship is mapped to a relation, the keys are chosen, and every constraint is written down with the business rule it enforces. This is the logical design stage of the portfolio. The normalisation of these tables is in [normalisation.md](normalisation.md). Indexes and the actual build come later, in the physical design (`sql/`).

---

## 1. Mapping the ER model to relations

Each ER construct is mapped with the standard ER-to-relational rules (Elmasri & Navathe, 2016, ch. 9).

| # | ER construct | Mapping rule | OwoRail result |
|---|---|---|---|
| 1 | Strong entity | One relation. Simple attributes become columns; the key attribute becomes the primary key. | `customer`, `kyc_profile`, `kyc_tier`, `merchant`, `wallet`, `fee_rule`, `transaction`, `audit_log` |
| 2 | Composite attribute | Store only its components. | CUSTOMER.address → `address_street`, `address_city`, `address_state` |
| 3 | Derived attribute | Not stored. Computed when needed, as views in the physical design. | CUSTOMER.age, WALLET.ledger_balance_kobo, TRANSACTION.total_debit_kobo |
| 4 | Multi-valued attribute | A new relation holding the attribute and a foreign key to the owner. | CUSTOMER.phone_number → `customer_phone`. Its key is `phone_number` alone, because BR-02 makes a number belong to only one customer (phone_number → customer_id). |
| 5 | Weak entity | A relation whose primary key is the owner's key plus the partial key, with a foreign key to the owner. | `ledger_entry` (transaction_id, line_no); `transaction_status_history` (transaction_id, seq_no) |
| 6 | 1:1 relationship | A foreign key with UNIQUE, normally on the side with total participation. | HAS_KYC → `kyc_profile.customer_id` (NOT NULL, UNIQUE). HOLDS → `wallet.merchant_id` (UNIQUE): a deliberate exception, explained below. |
| 7 | 1:N relationship | A foreign key on the N side. Two relationships between the same pair of entities give two foreign keys, named by role. | OWNS → `wallet.customer_id`; CLASSIFIED_AS → `kyc_profile.tier_level`; DEBITS → `transaction.source_wallet_id`; CREDITS → `transaction.destination_wallet_id`; PRICED_BY → `transaction.fee_rule_id`; POSTED_TO → `ledger_entry.wallet_id`; POSTS and HAS_STATUS → the owner key inside the weak entity's primary key |
| 8 | M:N relationship | A new relation whose primary key is both foreign keys. Relationship attributes become its columns. | SAVES_BENEFICIARY → `saved_beneficiary` (customer_id, wallet_id, nickname, saved_at) |
| 9 | Recursive 1:1 relationship with attributes, partial on both sides | A relationship relation with two foreign keys to the same table, one per role. | REVERSES → `reversal` (original_transaction_id, reversal_transaction_id, reason, requested_by) |
| 10 | An entity owned by exactly one of several owners | Nullable foreign keys plus a CHECK that exactly one owner is filled (an "exclusive arc"). | `wallet` belongs to a customer, a merchant or the system (`chk_wallet_owner_matches_type`) |
| 11 | Entity with no relationships | A plain relation with no foreign keys. | `audit_log` uses a polymorphic target (`target_type`, `target_id`) |

**Why HOLDS puts its foreign key on** `wallet` **rather than on** `merchant`**.** Rule 6 would put the foreign key on MERCHANT, the total side (`merchant.wallet_id NOT NULL UNIQUE`), which would enforce "every merchant has exactly one wallet" declaratively. I put it on `wallet` instead, next to `customer_id`. Every wallet's owner is then recorded in one table, and one row-level CHECK can guarantee that the owner matches the wallet type (`chk_wallet_owner_matches_type`). The cost is that "every merchant has at least one wallet" is no longer declarative; the onboarding procedure enforces it instead (see the integrity rules below). That is the same position as "every customer has at least one wallet": a minimum on a 1:N relationship can't be expressed with a foreign key either.

**Why REVERSES becomes its own relation** rather than a `reverses_transaction_id` column on `transaction`:

- `reason` and `requested_by` apply only to REVERSAL transactions. As columns of `transaction` they would be NULL in almost every row.
- Making `original_transaction_id` the primary key of `reversal` enforces "reversed at most once" (BR-16) declaratively.

---

## 2. Relational schema (text notation)

`#` marks a primary-key attribute; `→ table` marks a foreign key and the relation it references. The same relations are where [normalisation.md](normalisation.md) ends up.

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

13 relations: 10 from entities, 1 from a multi-valued attribute (`customer_phone`), 1 from an M:N relationship (`saved_beneficiary`) and 1 from a recursive relationship (`reversal`).

---

## 3. Keys

| Relation | Primary key | Alternate (candidate) keys, enforced UNIQUE | Foreign keys |
|---|---|---|---|
| customer | customer_id | email | none |
| customer_phone | phone_number | none | customer_id |
| kyc_tier | tier_level | tier_name | none |
| kyc_profile | kyc_profile_id | customer_id; (id_type, national_id_number) | customer_id, tier_level |
| merchant | merchant_id | merchant_code | none |
| wallet | wallet_id | wallet_number; merchant_id; system_purpose | customer_id, merchant_id |
| saved_beneficiary | (customer_id, wallet_id) | none | customer_id, wallet_id |
| fee_rule | fee_rule_id | none (overlapping rules are prevented by an exclusion constraint) | none |
| transaction | transaction_id | transaction_ref; idempotency_key | source_wallet_id, destination_wallet_id, fee_rule_id |
| ledger_entry | (transaction_id, line_no) | none | transaction_id, wallet_id |
| transaction_status_history | (transaction_id, seq_no) | none | transaction_id |
| reversal | original_transaction_id | reversal_transaction_id | original_transaction_id, reversal_transaction_id |
| audit_log | audit_id | none | none (polymorphic target) |

**Key choices:**

- **Surrogate primary keys** (`BIGINT GENERATED ALWAYS AS IDENTITY`) for the eight relations from strong entities, except `kyc_tier`.
  - Natural keys such as emails, wallet numbers and transaction references can change or are long text. A compact integer key keeps foreign keys and joins cheap.
  - `GENERATED ALWAYS` stops the application from supplying its own key values.
  - Every natural key is kept as an **alternate key with a UNIQUE constraint**, so duplicates are still impossible.
- `kyc_tier` **keeps its natural key** `tier_level` (1, 2, 3). It is a short, stable code that people actually use ("a Tier 2 customer").
- **Weak entities and relationship relations use composite or borrowed keys**, as rules 5, 8 and 9 produce: `(transaction_id, line_no)`, `(customer_id, wallet_id)`, `original_transaction_id`.
- **The idempotency key is an alternate key on purpose.** It is how a retried request is recognised as a duplicate (BR-11; tested under concurrency in Portfolio 3).
- **Nullable alternate keys.** `wallet.merchant_id` and `wallet.system_purpose` are NULL for most wallets. PostgreSQL allows any number of NULLs in a UNIQUE column, so the constraint applies only to the wallets that have a value. That gives "one wallet per merchant" (HOLDS is 1:1) and "one FEES, one SETTLEMENT and one SUSPENSE wallet".

---

## 4. Relations, columns and constraints

### Conventions

- **Constraint names:** `pk_<table>`, `fk_<table>_<role>`, `uq_<table>_<column>`, `chk_<table>_<rule>`, `excl_<table>_<rule>`. Every constraint is named, so a violation message says which business rule failed. The constraint tests rely on this.
- **Money:** `BIGINT` kobo (₦1 = 100 kobo), never `NUMERIC` with decimals or floating point (NFR-07). BIGINT holds up to about ₦92 quadrillion.
- **Time:** `TIMESTAMPTZ`, stored in UTC (NFR-07).
- **Text:** `TEXT` with a CHECK where the format matters. In PostgreSQL, `VARCHAR(n)` has no performance advantage over `TEXT`, and a CHECK can express more than a length limit.

### Decision: named CHECK constraints instead of ENUM types

Code values such as statuses, types and channels are `TEXT` columns with a named `CHECK (col IN (...))`. PostgreSQL `ENUM` types are not used:

| | CHECK constraint | ENUM type |
|---|---|---|
| Violation message | names the constraint, e.g. `chk_transaction_status`, so it traces to a BR | `invalid input value for enum` (generic) |
| Removing or renaming a value | drop and re-create the constraint | values can't be removed without re-creating the type |
| Portability | standard SQL | PostgreSQL-specific |
| Drawback | a list used in two tables must be repeated in both (e.g. transaction type in `transaction` and `fee_rule`) | defined once |

The alternative is a **lookup table** with a foreign key, which is fully normalised. I use one where the code has attributes of its own: `kyc_tier` has a name and three limits. Short, stable code lists with no attributes are better served by a CHECK.

### Default delete rule: `ON DELETE RESTRICT`

Every foreign key is `ON DELETE RESTRICT` except the two noted below. Financial and identity records must be kept, so customers, merchants and wallets are **closed** (`status = 'CLOSED'`), never deleted. RESTRICT makes the database refuse any delete that would orphan a wallet, a transaction or a ledger line.

The weak entities (`ledger_entry`, `transaction_status_history`) also use RESTRICT. The usual mapping for a weak entity is CASCADE, but the ledger and status history are append-only records (BR-13, BR-15), so deleting their transaction must fail rather than silently remove them.

The two exceptions, `customer_phone` and `saved_beneficiary`, use `ON DELETE CASCADE`. They are the customer's own contact and address-book data, with no financial meaning. If a customer record is ever erased (for example under a data-protection erasure request, NDPA 2023), they should go with it.

### customer

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| customer_id | BIGINT identity | NOT NULL | generated | `pk_customer` | BR-01 |
| full_name | TEXT | NOT NULL | | `chk_customer_full_name_not_blank`: `btrim(full_name) <> ''` | BR-01 |
| email | TEXT | NOT NULL | | `uq_customer_email`; `chk_customer_email_format`: `email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'`. Lower case only, so uniqueness is case-insensitive. | BR-01 |
| date_of_birth | DATE | NOT NULL | | `chk_customer_adult_at_onboarding` (table level, below) | BR-01 |
| address_street | TEXT | NOT NULL | | | BR-01 |
| address_city | TEXT | NOT NULL | | | BR-01 |
| address_state | TEXT | NOT NULL | | | BR-01 |
| status | TEXT | NOT NULL | `'ACTIVE'` | `chk_customer_status`: `IN ('ACTIVE','SUSPENDED','CLOSED')` | BR-01 |
| created_at | TIMESTAMPTZ | NOT NULL | `now()` | | BR-01 |

Table level: `chk_customer_adult_at_onboarding`: `date_of_birth <= (created_at AT TIME ZONE 'UTC')::date - INTERVAL '18 years'`. It compares against the onboarding date, not today's date, so the check always gives the same answer for the same row.

### customer_phone

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| phone_number | TEXT | NOT NULL | | `pk_customer_phone`; `chk_customer_phone_format`: `phone_number ~ '^\+234[789][01][0-9]{8}$'` (Nigerian mobile number in E.164 format) | BR-02 |
| customer_id | BIGINT | NOT NULL | | `fk_customer_phone_customer` → customer, ON DELETE CASCADE | BR-02 |

### kyc_tier

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| tier_level | SMALLINT | NOT NULL | | `pk_kyc_tier`; `chk_kyc_tier_level`: `BETWEEN 1 AND 3` | BR-04 |
| tier_name | TEXT | NOT NULL | | `uq_kyc_tier_name` | BR-04 |
| single_txn_limit_kobo | BIGINT | NOT NULL | | `chk_kyc_tier_single_limit_positive`: `> 0` | BR-04 |
| daily_limit_kobo | BIGINT | NOT NULL | | `chk_kyc_tier_daily_ge_single`: `daily_limit_kobo >= single_txn_limit_kobo` | BR-04 |
| max_balance_kobo | BIGINT | NULL (no limit) | | `chk_kyc_tier_max_balance_positive`: `max_balance_kobo IS NULL OR max_balance_kobo > 0` | BR-04 |

### kyc_profile

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| kyc_profile_id | BIGINT identity | NOT NULL | generated | `pk_kyc_profile` | BR-03 |
| customer_id | BIGINT | NOT NULL | | `uq_kyc_profile_customer` (makes HAS_KYC 1:1); `fk_kyc_profile_customer` → customer, RESTRICT | BR-03 |
| tier_level | SMALLINT | NOT NULL | `1` | `fk_kyc_profile_tier` → kyc_tier, RESTRICT | BR-04 |
| id_type | TEXT | NOT NULL | | `chk_kyc_profile_id_type`: `IN ('BVN','NIN')` | BR-03 |
| national_id_number | TEXT | NOT NULL | | `uq_kyc_profile_national_id`: UNIQUE (id_type, national_id_number); `chk_kyc_profile_synthetic_id`: `national_id_number ~ '^999[0-9]{8}$'` | BR-03 |
| verification_status | TEXT | NOT NULL | `'PENDING'` | `chk_kyc_profile_verification_status`: `IN ('PENDING','VERIFIED','REJECTED')` | BR-03 |
| verified_at | TIMESTAMPTZ | NULL | | see table level | BR-03 |
| verified_by | TEXT | NULL | | see table level | BR-03 |

Table level:

- `chk_kyc_profile_reviewer_pair`: `(verified_at IS NULL) = (verified_by IS NULL)`. The review time and the reviewer are recorded together or not at all.
- `chk_kyc_profile_decision_recorded`: `(verification_status = 'PENDING') = (verified_at IS NULL)`. A VERIFIED or REJECTED profile has a review time and reviewer; a PENDING one has neither.

`chk_kyc_profile_synthetic_id` is a **portfolio safeguard**. Requiring the `999` prefix means the database cannot store a real BVN or NIN, even by accident (NFR-05). A production system would use `'^[0-9]{11}$'` instead.

### merchant

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| merchant_id | BIGINT identity | NOT NULL | generated | `pk_merchant` | BR-09 |
| merchant_code | TEXT | NOT NULL | | `uq_merchant_code`; `chk_merchant_code_format`: `merchant_code ~ '^MRC[0-9]{5}$'` | BR-09 |
| business_name | TEXT | NOT NULL | | `chk_merchant_business_name_not_blank`: `btrim(business_name) <> ''` | BR-09 |
| merchant_type | TEXT | NOT NULL | | `chk_merchant_type`: `IN ('MERCHANT','BILLER')` | BR-09 |
| category | TEXT | NOT NULL | | `chk_merchant_category`: `IN ('RETAIL','FOOD','TRANSPORT','HEALTH','EDUCATION','AIRTIME','ELECTRICITY','CABLE_TV')` | BR-09 |
| status | TEXT | NOT NULL | `'ACTIVE'` | `chk_merchant_status`: `IN ('ACTIVE','SUSPENDED')` | BR-09 |
| created_at | TIMESTAMPTZ | NOT NULL | `now()` | | BR-09 |

Category and type are independent: there is deliberately no rule tying a category to a type. A TRANSPORT category can be a ride-hailing MERCHANT or a toll-road BILLER, and an AIRTIME seller can be either. normalisation.md checks this, because a rule "category determines type" would break BCNF.

### wallet

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| wallet_id | BIGINT identity | NOT NULL | generated | `pk_wallet` | BR-05 |
| wallet_number | TEXT | NOT NULL | | `uq_wallet_number`; `chk_wallet_number_format`: `wallet_number ~ '^[0-9]{10}$'` | BR-05 |
| wallet_type | TEXT | NOT NULL | | `chk_wallet_type`: `IN ('CUSTOMER','MERCHANT','SYSTEM')` | BR-05, BR-06 |
| customer_id | BIGINT | NULL | | `fk_wallet_customer` → customer, RESTRICT (OWNS) | BR-06 |
| merchant_id | BIGINT | NULL | | `uq_wallet_merchant` (makes HOLDS 1:1); `fk_wallet_merchant` → merchant, RESTRICT | BR-06 |
| system_purpose | TEXT | NULL | | `chk_wallet_system_purpose`: `IN ('FEES','SETTLEMENT','SUSPENSE')`; `uq_wallet_system_purpose` | BR-06 |
| currency | CHAR(3) | NOT NULL | `'NGN'` | `chk_wallet_currency`: `currency = 'NGN'` | BR-05 |
| balance_kobo | BIGINT | NOT NULL | `0` | `chk_wallet_balance_non_negative`: `wallet_type = 'SYSTEM' OR balance_kobo >= 0` | BR-07, BR-14 |
| status | TEXT | NOT NULL | `'ACTIVE'` | `chk_wallet_status`: `IN ('ACTIVE','FROZEN','CLOSED')` | BR-05 |
| created_at | TIMESTAMPTZ | NOT NULL | `now()` | | BR-05 |

Table level: `chk_wallet_owner_matches_type`, the exclusive arc (mapping rule 10):

```sql
   (wallet_type = 'CUSTOMER' AND customer_id IS NOT NULL AND merchant_id IS NULL AND system_purpose IS NULL)
OR (wallet_type = 'MERCHANT' AND merchant_id IS NOT NULL AND customer_id IS NULL AND system_purpose IS NULL)
OR (wallet_type = 'SYSTEM'   AND system_purpose IS NOT NULL AND customer_id IS NULL AND merchant_id IS NULL)
```

`chk_wallet_balance_non_negative` is the **last line of defence for BR-07**. Even if application code had a bug, the database would reject any UPDATE that takes a customer or merchant wallet below zero. Portfolio 3 relies on this under concurrency.

### saved_beneficiary

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| customer_id | BIGINT | NOT NULL | | `pk_saved_beneficiary` (customer_id, wallet_id); `fk_saved_beneficiary_customer` → customer, ON DELETE CASCADE | BR-08 |
| wallet_id | BIGINT | NOT NULL | | `fk_saved_beneficiary_wallet` → wallet, ON DELETE CASCADE | BR-08 |
| nickname | TEXT | NOT NULL | | `chk_saved_beneficiary_nickname_length`: `char_length(btrim(nickname)) BETWEEN 1 AND 40` | BR-08 |
| saved_at | TIMESTAMPTZ | NOT NULL | `now()` | | BR-08 |

The composite primary key enforces "a customer cannot save the same wallet twice" (BR-08).

### fee_rule

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| fee_rule_id | BIGINT identity | NOT NULL | generated | `pk_fee_rule` | BR-12 |
| transaction_type | TEXT | NOT NULL | | `chk_fee_rule_transaction_type`: `IN ('WALLET_FUNDING','TRANSFER','MERCHANT_PAYMENT','BILL_PAYMENT')`. Reversals are never priced. | BR-12 |
| min_amount_kobo | BIGINT | NOT NULL | | `chk_fee_rule_min_positive`: `> 0` | BR-12 |
| max_amount_kobo | BIGINT | NULL (no upper bound) | | `chk_fee_rule_band`: `max_amount_kobo IS NULL OR max_amount_kobo >= min_amount_kobo` | BR-12 |
| flat_fee_kobo | BIGINT | NOT NULL | `0` | `chk_fee_rule_flat_non_negative`: `>= 0` | BR-12 |
| percent_bps | INTEGER | NOT NULL | `0` | `chk_fee_rule_percent_bps`: `BETWEEN 0 AND 10000` | BR-12 |
| cap_kobo | BIGINT | NULL (no cap) | | `chk_fee_rule_cap`: `cap_kobo IS NULL OR cap_kobo >= flat_fee_kobo` | BR-12 |
| effective_from | TIMESTAMPTZ | NOT NULL | | | BR-12 |
| effective_to | TIMESTAMPTZ | NULL (current rule) | | `chk_fee_rule_period`: `effective_to IS NULL OR effective_to > effective_from` | BR-12 |

Table level: `excl_fee_rule_no_overlap`. For a given transaction type, no two rules may cover the same amount at the same time, so an amount always resolves to at most one fee:

```sql
EXCLUDE USING gist (
  transaction_type WITH =,
  int8range(min_amount_kobo, max_amount_kobo, '[]') WITH &&,
  tstzrange(effective_from, effective_to, '[)') WITH &&
)
```

This needs the `btree_gist` extension, which ships with PostgreSQL. A plain UNIQUE constraint can't express "ranges must not overlap".

**Fee formula (BR-12):** `fee = flat_fee_kobo + floor(amount_kobo × percent_bps / 10000)`, limited to `cap_kobo` when a cap is set. The percentage part is rounded down to the kobo, in the customer's favour.

### transaction

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| transaction_id | BIGINT identity | NOT NULL | generated | `pk_transaction` | BR-10 |
| transaction_ref | TEXT | NOT NULL | | `uq_transaction_ref`; `chk_transaction_ref_format`: `transaction_ref ~ '^OWR[0-9]{12}$'` | BR-10 |
| idempotency_key | UUID | NOT NULL | | `uq_transaction_idempotency_key` | BR-11 |
| transaction_type | TEXT | NOT NULL | | `chk_transaction_type`: `IN ('WALLET_FUNDING','TRANSFER','MERCHANT_PAYMENT','BILL_PAYMENT','REVERSAL')` | BR-10 |
| source_wallet_id | BIGINT | NOT NULL | | `fk_transaction_source_wallet` → wallet, RESTRICT (DEBITS) | BR-10 |
| destination_wallet_id | BIGINT | NOT NULL | | `fk_transaction_destination_wallet` → wallet, RESTRICT (CREDITS) | BR-10 |
| amount_kobo | BIGINT | NOT NULL | | `chk_transaction_amount_positive`: `> 0` | BR-10 |
| fee_kobo | BIGINT | NOT NULL | `0` | `chk_transaction_fee_non_negative`: `>= 0` | BR-12 |
| fee_rule_id | BIGINT | NULL | | `fk_transaction_fee_rule` → fee_rule, RESTRICT (PRICED_BY) | BR-12 |
| status | TEXT | NOT NULL | `'PENDING'` | `chk_transaction_status`: `IN ('PENDING','SUCCESSFUL','FAILED','REVERSED')` | BR-10, BR-15 |
| channel | TEXT | NOT NULL | | `chk_transaction_channel`: `IN ('APP','USSD','WEB')`. Staff reversals use WEB (the back-office console). | BR-10 |
| bill_reference | TEXT | NULL | | `chk_transaction_bill_reference` (table level) | BR-10 |
| narration | TEXT | NULL | | `chk_transaction_narration_length`: `narration IS NULL OR char_length(narration) <= 100` | BR-10 |
| created_at | TIMESTAMPTZ | NOT NULL | `now()` | | BR-10 |

Table level:

- `chk_transaction_distinct_wallets`: `source_wallet_id <> destination_wallet_id` (BR-10).
- `chk_transaction_bill_reference`: `(transaction_type = 'BILL_PAYMENT') = (bill_reference IS NOT NULL)`. A bill payment must have a bill reference, and nothing else may have one (BR-10).
- `chk_transaction_fee_has_rule`: `fee_kobo = 0 OR fee_rule_id IS NOT NULL`. A charged fee must cite the rule that produced it (BR-12).
- `chk_transaction_reversal_no_fee`: `transaction_type <> 'REVERSAL' OR (fee_kobo = 0 AND fee_rule_id IS NULL)`. A reversal is never charged; it returns the original fee (BR-16).

### ledger_entry

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| transaction_id | BIGINT | NOT NULL | | `pk_ledger_entry` (transaction_id, line_no); `fk_ledger_entry_transaction` → transaction, RESTRICT (POSTS) | BR-13 |
| line_no | SMALLINT | NOT NULL | | `chk_ledger_entry_line_no`: `line_no >= 1` | BR-13 |
| wallet_id | BIGINT | NOT NULL | | `fk_ledger_entry_wallet` → wallet, RESTRICT (POSTED_TO) | BR-13, BR-14 |
| entry_type | TEXT | NOT NULL | | `chk_ledger_entry_type`: `IN ('DEBIT','CREDIT')` | BR-13 |
| amount_kobo | BIGINT | NOT NULL | | `chk_ledger_entry_amount_positive`: `> 0` | BR-13 |

### transaction_status_history

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| transaction_id | BIGINT | NOT NULL | | `pk_transaction_status_history` (transaction_id, seq_no); `fk_transaction_status_history_transaction` → transaction, RESTRICT (HAS_STATUS) | BR-15 |
| seq_no | SMALLINT | NOT NULL | | `chk_transaction_status_history_seq_no`: `seq_no >= 1` | BR-15 |
| status | TEXT | NOT NULL | | `chk_transaction_status_history_status`: `IN ('PENDING','SUCCESSFUL','FAILED','REVERSED')` | BR-15 |
| changed_at | TIMESTAMPTZ | NOT NULL | `now()` | | BR-15 |
| reason | TEXT | NULL | | | BR-15 |

### reversal

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| original_transaction_id | BIGINT | NOT NULL | | `pk_reversal` (enforces "at most once"); `fk_reversal_original_transaction` → transaction, RESTRICT | BR-16 |
| reversal_transaction_id | BIGINT | NOT NULL | | `uq_reversal_reversal_transaction`; `fk_reversal_reversal_transaction` → transaction, RESTRICT | BR-16 |
| reason | TEXT | NOT NULL | | `chk_reversal_reason_not_blank`: `btrim(reason) <> ''` | BR-16 |
| requested_by | TEXT | NOT NULL | | staff username | BR-16 |

Table level: `chk_reversal_not_self`: `original_transaction_id <> reversal_transaction_id`.

### audit_log

| Column | Type | Null | Default | Key / constraint | BR |
|---|---|---|---|---|---|
| audit_id | BIGINT identity | NOT NULL | generated | `pk_audit_log` | BR-17 |
| occurred_at | TIMESTAMPTZ | NOT NULL | `now()` | | BR-17 |
| actor | TEXT | NOT NULL | `current_user` | database role or staff username | BR-17 |
| action | TEXT | NOT NULL | | `chk_audit_log_action_format`: `action ~ '^[A-Z][A-Z_]*$'` (e.g. `KYC_VERIFIED`, `WALLET_FROZEN`, `TXN_REVERSED`) | BR-17 |
| target_type | TEXT | NOT NULL | | `chk_audit_log_target_type`: `IN ('customer','kyc_profile','merchant','wallet','fee_rule','transaction','role')` | BR-17 |
| target_id | TEXT | NOT NULL | | TEXT because the target may be an integer key or a role name | BR-17 |
| details | JSONB | NULL | | structured detail | BR-17 |

No foreign keys, on purpose: an audit record must never stop a change to the record it describes, and it must outlive that record.

---

## 5. Integrity rules outside declarative constraints

Declarative constraints (PK, FK, UNIQUE, CHECK, EXCLUDE) look at one row, or at a key across a table. The rules below depend on several rows or on the state at the moment of posting, so they can't be declarative. Each is enforced by a named mechanism in the physical design, and the concurrency-sensitive ones are tested in Portfolio 3.

| Rule | Why it can't be a CHECK or foreign key | Enforced by |
|---|---|---|
| BR-02, BR-06: every customer has at least one phone and one wallet; every merchant has exactly one wallet | "at least one" child row across tables | onboarding procedures that insert parent and children in **one transaction** |
| BR-04: per-transaction and daily limits from the KYC tier | needs the sum of today's debits | posting procedure, tested under concurrency in Portfolio 3 |
| BR-05: FROZEN or CLOSED wallets cannot send or receive | depends on the wallet's status at posting time | posting procedure, which reads the wallet row with a lock (Portfolio 3) |
| BR-10: the right wallet type per transaction type (MERCHANT_PAYMENT credits a MERCHANT-type merchant's wallet; BILL_PAYMENT a BILLER's; WALLET_FUNDING debits the SETTLEMENT wallet) | spans `transaction`, `wallet` and `merchant` | posting procedure |
| BR-13: at least two lines per posted transaction; total debits = total credits | an aggregate over several rows | constraint trigger, `DEFERRABLE INITIALLY DEFERRED`, checked at COMMIT |
| BR-13, BR-17: ledger and audit log are append-only | about operations, not values | no UPDATE or DELETE privilege for any role, plus a trigger that rejects them |
| BR-14: stored balance = ledger balance | aggregate across tables | posting procedure updates both in one transaction; reconciliation query (FR-08) |
| BR-15: current status = latest status-history row | spans two tables | posting and reversal procedures write both together; consistency query |
| BR-16: only a SUCCESSFUL transaction can be reversed | depends on the original's status at that moment | reversal procedure locks the original row (Portfolio 3). "At most once" is declarative (`pk_reversal`). |
| BR-18: least privilege | about who, not what | roles and GRANTs |

---

## 6. Summary

- **13 relations** and **89 columns**.
- **94 named constraints**: 13 primary keys, 11 alternate keys (UNIQUE), 15 foreign keys, 54 CHECK constraints and 1 exclusion constraint. NOT NULL and DEFAULT are column properties and are listed in the tables above.
- Every column and constraint traces to a business rule (BR column). BR-18 is enforced by database roles in the physical design.
- Normalisation of these relations to BCNF, and the reasons for the three deliberate redundancies (`wallet.balance_kobo`, `transaction.fee_kobo`, `transaction.status`), are in [normalisation.md](normalisation.md).

## References

Elmasri, R., & Navathe, S. B. (2016). *Fundamentals of database systems* (7th ed.). Pearson.

PostgreSQL Global Development Group. (n.d.). *PostgreSQL 16 documentation*. Retrieved November 10, 2026, from https://www.postgresql.org/docs/16/
