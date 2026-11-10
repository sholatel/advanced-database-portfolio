

SET client_min_messages = warning;
DROP SCHEMA IF EXISTS oworail CASCADE;
RESET client_min_messages;

CREATE SCHEMA oworail AUTHORIZATION oworail_owner;
COMMENT ON SCHEMA oworail IS 'OwoRail digital wallet: operational and ledger data';

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;

SET ROLE oworail_owner;
SET search_path = oworail, public;

-- ---------------------------------------------------------------------------
-- customer (BR-01)
-- ---------------------------------------------------------------------------
CREATE TABLE customer (
    customer_id     BIGINT      GENERATED ALWAYS AS IDENTITY,
    full_name       TEXT        NOT NULL,
    email           TEXT        NOT NULL,
    date_of_birth   DATE        NOT NULL,
    address_street  TEXT        NOT NULL,
    address_city    TEXT        NOT NULL,
    address_state   TEXT        NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_customer PRIMARY KEY (customer_id),
    CONSTRAINT uq_customer_email UNIQUE (email),
    CONSTRAINT chk_customer_full_name_not_blank CHECK (btrim(full_name) <> ''),
    CONSTRAINT chk_customer_email_format
        CHECK (email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'),
    CONSTRAINT chk_customer_status CHECK (status IN ('ACTIVE', 'SUSPENDED', 'CLOSED')),
    CONSTRAINT chk_customer_adult_at_onboarding
        CHECK (date_of_birth <= (created_at AT TIME ZONE 'UTC')::date - INTERVAL '18 years')
);

-- ---------------------------------------------------------------------------
-- customer_phone (BR-02): multi-valued attribute of CUSTOMER
-- ---------------------------------------------------------------------------
CREATE TABLE customer_phone (
    phone_number  TEXT   NOT NULL,
    customer_id   BIGINT NOT NULL,
    CONSTRAINT pk_customer_phone PRIMARY KEY (phone_number),
    CONSTRAINT fk_customer_phone_customer FOREIGN KEY (customer_id)
        REFERENCES customer (customer_id) ON DELETE CASCADE,
    CONSTRAINT chk_customer_phone_format
        CHECK (phone_number ~ '^\+234[789][01][0-9]{8}$')
);

-- ---------------------------------------------------------------------------
-- kyc_tier (BR-04): limits belong to the tier, not the person
-- ---------------------------------------------------------------------------
CREATE TABLE kyc_tier (
    tier_level             SMALLINT NOT NULL,
    tier_name              TEXT     NOT NULL,
    single_txn_limit_kobo  BIGINT   NOT NULL,
    daily_limit_kobo       BIGINT   NOT NULL,
    max_balance_kobo       BIGINT,             -- NULL = no limit
    CONSTRAINT pk_kyc_tier PRIMARY KEY (tier_level),
    CONSTRAINT uq_kyc_tier_name UNIQUE (tier_name),
    CONSTRAINT chk_kyc_tier_level CHECK (tier_level BETWEEN 1 AND 3),
    CONSTRAINT chk_kyc_tier_single_limit_positive CHECK (single_txn_limit_kobo > 0),
    CONSTRAINT chk_kyc_tier_daily_ge_single CHECK (daily_limit_kobo >= single_txn_limit_kobo),
    CONSTRAINT chk_kyc_tier_max_balance_positive
        CHECK (max_balance_kobo IS NULL OR max_balance_kobo > 0)
);

-- ---------------------------------------------------------------------------
-- kyc_profile (BR-03, BR-04): identity data kept apart from customer
-- ---------------------------------------------------------------------------
CREATE TABLE kyc_profile (
    kyc_profile_id       BIGINT      GENERATED ALWAYS AS IDENTITY,
    customer_id          BIGINT      NOT NULL,
    tier_level           SMALLINT    NOT NULL DEFAULT 1,
    id_type              TEXT        NOT NULL,
    national_id_number   TEXT        NOT NULL,
    verification_status  TEXT        NOT NULL DEFAULT 'PENDING',
    verified_at          TIMESTAMPTZ,
    verified_by          TEXT,
    CONSTRAINT pk_kyc_profile PRIMARY KEY (kyc_profile_id),
    CONSTRAINT uq_kyc_profile_customer UNIQUE (customer_id),
    CONSTRAINT uq_kyc_profile_national_id UNIQUE (id_type, national_id_number),
    CONSTRAINT fk_kyc_profile_customer FOREIGN KEY (customer_id)
        REFERENCES customer (customer_id) ON DELETE RESTRICT,
    CONSTRAINT fk_kyc_profile_tier FOREIGN KEY (tier_level)
        REFERENCES kyc_tier (tier_level) ON DELETE RESTRICT,
    CONSTRAINT chk_kyc_profile_id_type CHECK (id_type IN ('BVN', 'NIN')),
    -- portfolio safeguard: only synthetic 999-prefixed numbers can be stored
    CONSTRAINT chk_kyc_profile_synthetic_id CHECK (national_id_number ~ '^999[0-9]{8}$'),
    CONSTRAINT chk_kyc_profile_verification_status
        CHECK (verification_status IN ('PENDING', 'VERIFIED', 'REJECTED')),
    CONSTRAINT chk_kyc_profile_reviewer_pair
        CHECK ((verified_at IS NULL) = (verified_by IS NULL)),
    CONSTRAINT chk_kyc_profile_decision_recorded
        CHECK ((verification_status = 'PENDING') = (verified_at IS NULL))
);

-- ---------------------------------------------------------------------------
-- merchant (BR-09): merchants and billers
-- ---------------------------------------------------------------------------
CREATE TABLE merchant (
    merchant_id    BIGINT      GENERATED ALWAYS AS IDENTITY,
    merchant_code  TEXT        NOT NULL,
    business_name  TEXT        NOT NULL,
    merchant_type  TEXT        NOT NULL,
    category       TEXT        NOT NULL,
    status         TEXT        NOT NULL DEFAULT 'ACTIVE',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_merchant PRIMARY KEY (merchant_id),
    CONSTRAINT uq_merchant_code UNIQUE (merchant_code),
    CONSTRAINT chk_merchant_code_format CHECK (merchant_code ~ '^MRC[0-9]{5}$'),
    CONSTRAINT chk_merchant_business_name_not_blank CHECK (btrim(business_name) <> ''),
    CONSTRAINT chk_merchant_type CHECK (merchant_type IN ('MERCHANT', 'BILLER')),
    CONSTRAINT chk_merchant_category CHECK (category IN (
        'RETAIL', 'FOOD', 'TRANSPORT', 'HEALTH', 'EDUCATION',
        'AIRTIME', 'ELECTRICITY', 'CABLE_TV')),
    CONSTRAINT chk_merchant_status CHECK (status IN ('ACTIVE', 'SUSPENDED'))
);

-- ---------------------------------------------------------------------------
-- wallet (BR-05, BR-06, BR-07, BR-14): owned by a customer, a merchant or the system
-- ---------------------------------------------------------------------------
CREATE TABLE wallet (
    wallet_id       BIGINT      GENERATED ALWAYS AS IDENTITY,
    wallet_number   TEXT        NOT NULL,
    wallet_type     TEXT        NOT NULL,
    customer_id     BIGINT,
    merchant_id     BIGINT,
    system_purpose  TEXT,
    currency        CHAR(3)     NOT NULL DEFAULT 'NGN',
    balance_kobo    BIGINT      NOT NULL DEFAULT 0,
    status          TEXT        NOT NULL DEFAULT 'ACTIVE',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_wallet PRIMARY KEY (wallet_id),
    CONSTRAINT uq_wallet_number UNIQUE (wallet_number),
    CONSTRAINT uq_wallet_merchant UNIQUE (merchant_id),            -- HOLDS is 1:1
    CONSTRAINT uq_wallet_system_purpose UNIQUE (system_purpose),   -- one FEES, SETTLEMENT, SUSPENSE
    CONSTRAINT fk_wallet_customer FOREIGN KEY (customer_id)
        REFERENCES customer (customer_id) ON DELETE RESTRICT,
    CONSTRAINT fk_wallet_merchant FOREIGN KEY (merchant_id)
        REFERENCES merchant (merchant_id) ON DELETE RESTRICT,
    CONSTRAINT chk_wallet_number_format CHECK (wallet_number ~ '^[0-9]{10}$'),
    CONSTRAINT chk_wallet_type CHECK (wallet_type IN ('CUSTOMER', 'MERCHANT', 'SYSTEM')),
    CONSTRAINT chk_wallet_system_purpose
        CHECK (system_purpose IN ('FEES', 'SETTLEMENT', 'SUSPENSE')),
    CONSTRAINT chk_wallet_currency CHECK (currency = 'NGN'),
    -- last line of defence for BR-07: no customer or merchant wallet below zero
    CONSTRAINT chk_wallet_balance_non_negative
        CHECK (wallet_type = 'SYSTEM' OR balance_kobo >= 0),
    CONSTRAINT chk_wallet_status CHECK (status IN ('ACTIVE', 'FROZEN', 'CLOSED')),
    -- exclusive arc: exactly one kind of owner, matching the wallet type
    CONSTRAINT chk_wallet_owner_matches_type CHECK (
           (wallet_type = 'CUSTOMER' AND customer_id IS NOT NULL
                AND merchant_id IS NULL AND system_purpose IS NULL)
        OR (wallet_type = 'MERCHANT' AND merchant_id IS NOT NULL
                AND customer_id IS NULL AND system_purpose IS NULL)
        OR (wallet_type = 'SYSTEM'   AND system_purpose IS NOT NULL
                AND customer_id IS NULL AND merchant_id IS NULL))
);

-- ---------------------------------------------------------------------------
-- saved_beneficiary (BR-08): M:N between customer and wallet
-- ---------------------------------------------------------------------------
CREATE TABLE saved_beneficiary (
    customer_id  BIGINT      NOT NULL,
    wallet_id    BIGINT      NOT NULL,
    nickname     TEXT        NOT NULL,
    saved_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_saved_beneficiary PRIMARY KEY (customer_id, wallet_id),
    CONSTRAINT fk_saved_beneficiary_customer FOREIGN KEY (customer_id)
        REFERENCES customer (customer_id) ON DELETE CASCADE,
    CONSTRAINT fk_saved_beneficiary_wallet FOREIGN KEY (wallet_id)
        REFERENCES wallet (wallet_id) ON DELETE CASCADE,
    CONSTRAINT chk_saved_beneficiary_nickname_length
        CHECK (char_length(btrim(nickname)) BETWEEN 1 AND 40)
);

-- ---------------------------------------------------------------------------
-- fee_rule (BR-12)
-- ---------------------------------------------------------------------------
CREATE TABLE fee_rule (
    fee_rule_id       BIGINT      GENERATED ALWAYS AS IDENTITY,
    transaction_type  TEXT        NOT NULL,
    min_amount_kobo   BIGINT      NOT NULL,
    max_amount_kobo   BIGINT,                 -- NULL = no upper bound
    flat_fee_kobo     BIGINT      NOT NULL DEFAULT 0,
    percent_bps       INTEGER     NOT NULL DEFAULT 0,
    cap_kobo          BIGINT,                 -- NULL = no cap
    effective_from    TIMESTAMPTZ NOT NULL,
    effective_to      TIMESTAMPTZ,            -- NULL = current rule
    CONSTRAINT pk_fee_rule PRIMARY KEY (fee_rule_id),
    CONSTRAINT chk_fee_rule_transaction_type CHECK (transaction_type IN (
        'WALLET_FUNDING', 'TRANSFER', 'MERCHANT_PAYMENT', 'BILL_PAYMENT')),
    CONSTRAINT chk_fee_rule_min_positive CHECK (min_amount_kobo > 0),
    CONSTRAINT chk_fee_rule_band
        CHECK (max_amount_kobo IS NULL OR max_amount_kobo >= min_amount_kobo),
    CONSTRAINT chk_fee_rule_flat_non_negative CHECK (flat_fee_kobo >= 0),
    CONSTRAINT chk_fee_rule_percent_bps CHECK (percent_bps BETWEEN 0 AND 10000),
    CONSTRAINT chk_fee_rule_cap CHECK (cap_kobo IS NULL OR cap_kobo >= flat_fee_kobo),
    CONSTRAINT chk_fee_rule_period
        CHECK (effective_to IS NULL OR effective_to > effective_from),
    -- one rule at most for any (type, amount, moment)
    CONSTRAINT excl_fee_rule_no_overlap EXCLUDE USING gist (
        transaction_type WITH =,
        int8range(min_amount_kobo, max_amount_kobo, '[]') WITH &&,
        tstzrange(effective_from, effective_to, '[)') WITH &&)
);

-- ---------------------------------------------------------------------------
-- transaction (BR-10, BR-11, BR-12, BR-15)
-- ---------------------------------------------------------------------------
CREATE TABLE transaction (
    transaction_id         BIGINT      GENERATED ALWAYS AS IDENTITY,
    transaction_ref        TEXT        NOT NULL,
    idempotency_key        UUID        NOT NULL,
    transaction_type       TEXT        NOT NULL,
    source_wallet_id       BIGINT      NOT NULL,
    destination_wallet_id  BIGINT      NOT NULL,
    amount_kobo            BIGINT      NOT NULL,
    fee_kobo               BIGINT      NOT NULL DEFAULT 0,
    fee_rule_id            BIGINT,
    status                 TEXT        NOT NULL DEFAULT 'PENDING',
    channel                TEXT        NOT NULL,
    bill_reference         TEXT,
    narration              TEXT,
    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT pk_transaction PRIMARY KEY (transaction_id),
    CONSTRAINT uq_transaction_ref UNIQUE (transaction_ref),
    CONSTRAINT uq_transaction_idempotency_key UNIQUE (idempotency_key),
    CONSTRAINT fk_transaction_source_wallet FOREIGN KEY (source_wallet_id)
        REFERENCES wallet (wallet_id) ON DELETE RESTRICT,
    CONSTRAINT fk_transaction_destination_wallet FOREIGN KEY (destination_wallet_id)
        REFERENCES wallet (wallet_id) ON DELETE RESTRICT,
    CONSTRAINT fk_transaction_fee_rule FOREIGN KEY (fee_rule_id)
        REFERENCES fee_rule (fee_rule_id) ON DELETE RESTRICT,
    CONSTRAINT chk_transaction_ref_format CHECK (transaction_ref ~ '^OWR[0-9]{12}$'),
    CONSTRAINT chk_transaction_type CHECK (transaction_type IN (
        'WALLET_FUNDING', 'TRANSFER', 'MERCHANT_PAYMENT', 'BILL_PAYMENT', 'REVERSAL')),
    CONSTRAINT chk_transaction_amount_positive CHECK (amount_kobo > 0),
    CONSTRAINT chk_transaction_fee_non_negative CHECK (fee_kobo >= 0),
    CONSTRAINT chk_transaction_status
        CHECK (status IN ('PENDING', 'SUCCESSFUL', 'FAILED', 'REVERSED')),
    CONSTRAINT chk_transaction_channel CHECK (channel IN ('APP', 'USSD', 'WEB')),
    CONSTRAINT chk_transaction_narration_length
        CHECK (narration IS NULL OR char_length(narration) <= 100),
    CONSTRAINT chk_transaction_distinct_wallets
        CHECK (source_wallet_id <> destination_wallet_id),
    CONSTRAINT chk_transaction_bill_reference
        CHECK ((transaction_type = 'BILL_PAYMENT') = (bill_reference IS NOT NULL)),
    CONSTRAINT chk_transaction_fee_has_rule CHECK (fee_kobo = 0 OR fee_rule_id IS NOT NULL),
    CONSTRAINT chk_transaction_reversal_no_fee
        CHECK (transaction_type <> 'REVERSAL' OR (fee_kobo = 0 AND fee_rule_id IS NULL))
);

-- ---------------------------------------------------------------------------
-- ledger_entry (BR-13, BR-14): weak entity, double-entry lines
-- ---------------------------------------------------------------------------
CREATE TABLE ledger_entry (
    transaction_id  BIGINT   NOT NULL,
    line_no         SMALLINT NOT NULL,
    wallet_id       BIGINT   NOT NULL,
    entry_type      TEXT     NOT NULL,
    amount_kobo     BIGINT   NOT NULL,
    CONSTRAINT pk_ledger_entry PRIMARY KEY (transaction_id, line_no),
    CONSTRAINT fk_ledger_entry_transaction FOREIGN KEY (transaction_id)
        REFERENCES transaction (transaction_id) ON DELETE RESTRICT,
    CONSTRAINT fk_ledger_entry_wallet FOREIGN KEY (wallet_id)
        REFERENCES wallet (wallet_id) ON DELETE RESTRICT,
    CONSTRAINT chk_ledger_entry_line_no CHECK (line_no >= 1),
    CONSTRAINT chk_ledger_entry_type CHECK (entry_type IN ('DEBIT', 'CREDIT')),
    CONSTRAINT chk_ledger_entry_amount_positive CHECK (amount_kobo > 0)
);

-- ---------------------------------------------------------------------------
-- transaction_status_history (BR-15): weak entity
-- ---------------------------------------------------------------------------
CREATE TABLE transaction_status_history (
    transaction_id  BIGINT      NOT NULL,
    seq_no          SMALLINT    NOT NULL,
    status          TEXT        NOT NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    reason          TEXT,
    CONSTRAINT pk_transaction_status_history PRIMARY KEY (transaction_id, seq_no),
    CONSTRAINT fk_transaction_status_history_transaction FOREIGN KEY (transaction_id)
        REFERENCES transaction (transaction_id) ON DELETE RESTRICT,
    CONSTRAINT chk_transaction_status_history_seq_no CHECK (seq_no >= 1),
    CONSTRAINT chk_transaction_status_history_status
        CHECK (status IN ('PENDING', 'SUCCESSFUL', 'FAILED', 'REVERSED'))
);

-- ---------------------------------------------------------------------------
-- reversal (BR-16): the recursive REVERSES relationship
-- ---------------------------------------------------------------------------
CREATE TABLE reversal (
    original_transaction_id  BIGINT NOT NULL,
    reversal_transaction_id  BIGINT NOT NULL,
    reason                   TEXT   NOT NULL,
    requested_by             TEXT   NOT NULL,
    CONSTRAINT pk_reversal PRIMARY KEY (original_transaction_id),   -- at most once
    CONSTRAINT uq_reversal_reversal_transaction UNIQUE (reversal_transaction_id),
    CONSTRAINT fk_reversal_original_transaction FOREIGN KEY (original_transaction_id)
        REFERENCES transaction (transaction_id) ON DELETE RESTRICT,
    CONSTRAINT fk_reversal_reversal_transaction FOREIGN KEY (reversal_transaction_id)
        REFERENCES transaction (transaction_id) ON DELETE RESTRICT,
    CONSTRAINT chk_reversal_reason_not_blank CHECK (btrim(reason) <> ''),
    CONSTRAINT chk_reversal_not_self
        CHECK (original_transaction_id <> reversal_transaction_id)
);

-- ---------------------------------------------------------------------------
-- audit_log (BR-17): no foreign keys on purpose
-- ---------------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id     BIGINT      GENERATED ALWAYS AS IDENTITY,
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor        TEXT        NOT NULL DEFAULT current_user,
    action       TEXT        NOT NULL,
    target_type  TEXT        NOT NULL,
    target_id    TEXT        NOT NULL,
    details      JSONB,
    CONSTRAINT pk_audit_log PRIMARY KEY (audit_id),
    CONSTRAINT chk_audit_log_action_format CHECK (action ~ '^[A-Z][A-Z_]*$'),
    CONSTRAINT chk_audit_log_target_type CHECK (target_type IN (
        'customer', 'kyc_profile', 'merchant', 'wallet', 'fee_rule', 'transaction', 'role'))
);

-- ---------------------------------------------------------------------------
-- Foreign-key indexes
-- ---------------------------------------------------------------------------
-- PostgreSQL indexes primary and unique keys automatically, but not foreign
-- keys. Without these, every ON DELETE RESTRICT check and every join from a
-- parent to its children scans the child table. FKs already covered by the
-- leading column of a PK or UNIQUE index need no extra index:
-- kyc_profile.customer_id, wallet.merchant_id, saved_beneficiary.customer_id,
-- ledger_entry.transaction_id, transaction_status_history.transaction_id and
-- both reversal columns. Workload-specific indexes are added and measured in
-- Portfolio 2.
CREATE INDEX ix_customer_phone_customer      ON customer_phone (customer_id);
CREATE INDEX ix_kyc_profile_tier             ON kyc_profile (tier_level);
CREATE INDEX ix_wallet_customer              ON wallet (customer_id);
CREATE INDEX ix_saved_beneficiary_wallet     ON saved_beneficiary (wallet_id);
CREATE INDEX ix_transaction_source_wallet    ON transaction (source_wallet_id);
CREATE INDEX ix_transaction_destination_wallet ON transaction (destination_wallet_id);
CREATE INDEX ix_transaction_fee_rule         ON transaction (fee_rule_id);
CREATE INDEX ix_ledger_entry_wallet          ON ledger_entry (wallet_id);

-- Transaction references come from this sequence unless the caller supplies
-- one (the seed uses fixed references so the normalisation sample is
-- reproduced exactly).
CREATE SEQUENCE transaction_ref_seq START WITH 1000;

RESET ROLE;
