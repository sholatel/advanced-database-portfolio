-- OwoRail physical design, step 4: procedures for the multi-row rules.
--
--   onboard_customer, onboard_merchant   BR-02, BR-06: parent and children in one transaction
--   submit_kyc, review_kyc               BR-03, BR-04, BR-17
--   post_transaction                     BR-04, BR-05, BR-07, BR-10 to BR-15
--   reverse_transaction                  BR-13, BR-15, BR-16, BR-17
--
-- Each is a function, so it runs inside the caller's transaction: if any step
-- fails, everything it did is rolled back. They are SECURITY DEFINER (run as
-- oworail_owner) with a fixed search_path, so the application can post money
-- only through them and has no direct write access to the financial tables.
--
-- Row locking here is the minimum needed for correctness: the wallets
-- involved are locked in wallet_id order, so two postings can't deadlock on
-- them. Portfolio 3 tests this under real concurrency.

SET ROLE oworail_owner;
SET search_path = oworail, public;

-- ---------------------------------------------------------------------------
-- FR-01: a customer is created together with at least one phone number and a
-- CUSTOMER wallet, so "every customer has a phone and a wallet" always holds.
-- ---------------------------------------------------------------------------
CREATE FUNCTION onboard_customer(
    p_full_name       text,
    p_email           text,
    p_date_of_birth   date,
    p_address_street  text,
    p_address_city    text,
    p_address_state   text,
    p_phone_numbers   text[],
    p_wallet_number   text,
    p_created_at      timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = oworail, pg_temp
AS $$
DECLARE
    v_customer_id bigint;
BEGIN
    IF coalesce(cardinality(p_phone_numbers), 0) = 0 THEN
        RAISE EXCEPTION 'a customer needs at least one phone number (BR-02)';
    END IF;

    INSERT INTO customer (full_name, email, date_of_birth,
                          address_street, address_city, address_state, created_at)
    VALUES (btrim(p_full_name), lower(btrim(p_email)), p_date_of_birth,
            p_address_street, p_address_city, p_address_state, p_created_at)
    RETURNING customer_id INTO v_customer_id;

    INSERT INTO customer_phone (phone_number, customer_id)
    SELECT DISTINCT p, v_customer_id FROM unnest(p_phone_numbers) AS p;

    INSERT INTO wallet (wallet_number, wallet_type, customer_id, created_at)
    VALUES (p_wallet_number, 'CUSTOMER', v_customer_id, p_created_at);

    RETURN v_customer_id;
END
$$;

-- ---------------------------------------------------------------------------
-- A merchant or biller is created together with its single MERCHANT wallet.
-- ---------------------------------------------------------------------------
CREATE FUNCTION onboard_merchant(
    p_merchant_code  text,
    p_business_name  text,
    p_merchant_type  text,
    p_category       text,
    p_wallet_number  text,
    p_created_at     timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = oworail, pg_temp
AS $$
DECLARE
    v_merchant_id bigint;
BEGIN
    INSERT INTO merchant (merchant_code, business_name, merchant_type, category, created_at)
    VALUES (p_merchant_code, btrim(p_business_name), p_merchant_type, p_category, p_created_at)
    RETURNING merchant_id INTO v_merchant_id;

    INSERT INTO wallet (wallet_number, wallet_type, merchant_id, created_at)
    VALUES (p_wallet_number, 'MERCHANT', v_merchant_id, p_created_at);

    RETURN v_merchant_id;
END
$$;

-- ---------------------------------------------------------------------------
-- FR-02: KYC is submitted (PENDING, Tier 1) and later reviewed by compliance.
-- ---------------------------------------------------------------------------
CREATE FUNCTION submit_kyc(
    p_customer_id         bigint,
    p_id_type             text,
    p_national_id_number  text,
    p_at                  timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = oworail, pg_temp
AS $$
DECLARE
    v_profile_id bigint;
BEGIN
    INSERT INTO kyc_profile (customer_id, id_type, national_id_number)
    VALUES (p_customer_id, p_id_type, p_national_id_number)
    RETURNING kyc_profile_id INTO v_profile_id;

    -- the identity number itself is not copied into the audit log
    INSERT INTO audit_log (occurred_at, actor, action, target_type, target_id, details)
    VALUES (p_at, session_user, 'KYC_SUBMITTED', 'kyc_profile', v_profile_id::text,
            jsonb_build_object('customer_id', p_customer_id, 'id_type', p_id_type));

    RETURN v_profile_id;
END
$$;

CREATE FUNCTION review_kyc(
    p_customer_id  bigint,
    p_decision     text,          -- VERIFIED or REJECTED
    p_tier_level   smallint,
    p_reviewer     text,          -- staff username
    p_at           timestamptz DEFAULT now()
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = oworail, pg_temp
AS $$
DECLARE
    v_profile kyc_profile%ROWTYPE;
BEGIN
    IF p_decision NOT IN ('VERIFIED', 'REJECTED') THEN
        RAISE EXCEPTION 'a KYC decision is VERIFIED or REJECTED, not %', p_decision;
    END IF;

    SELECT * INTO v_profile FROM kyc_profile
    WHERE customer_id = p_customer_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'customer % has no KYC profile', p_customer_id;
    END IF;

    UPDATE kyc_profile
    SET verification_status = p_decision,
        -- a rejected profile stays at its current tier
        tier_level  = CASE WHEN p_decision = 'VERIFIED' THEN p_tier_level ELSE tier_level END,
        verified_at = p_at,
        verified_by = p_reviewer
    WHERE kyc_profile_id = v_profile.kyc_profile_id;

    INSERT INTO audit_log (occurred_at, actor, action, target_type, target_id, details)
    VALUES (p_at, p_reviewer, 'KYC_' || p_decision, 'kyc_profile',
            v_profile.kyc_profile_id::text,
            jsonb_build_object('customer_id', p_customer_id,
                               'tier_from', v_profile.tier_level,
                               'tier_to', CASE WHEN p_decision = 'VERIFIED'
                                               THEN p_tier_level ELSE v_profile.tier_level END));
END
$$;

-- ---------------------------------------------------------------------------
-- FR-03, FR-04, FR-05: post a funding, transfer, merchant or bill payment.
--
-- Returns the transaction_id. A business refusal (insufficient funds, a KYC
-- limit, a frozen wallet) is not an error: the transaction is recorded as
-- FAILED with the reason in its status history and no ledger lines. Requests
-- that are invalid in themselves (unknown wallet, wrong wallet type for the
-- transaction type) raise an exception and leave nothing behind.
--
-- BR-11: a repeated idempotency key returns the original transaction and posts
-- nothing new. ON CONFLICT also covers two identical requests arriving at the
-- same moment: the second waits for the first, then returns its id.
-- ---------------------------------------------------------------------------
CREATE FUNCTION post_transaction(
    p_idempotency_key        uuid,
    p_transaction_type       text,
    p_source_wallet_number   text,
    p_destination_wallet_number text,
    p_amount_kobo            bigint,
    p_channel                text,
    p_bill_reference         text        DEFAULT NULL,
    p_narration              text        DEFAULT NULL,
    p_transaction_ref        text        DEFAULT NULL,
    p_at                     timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = oworail, pg_temp
AS $$
DECLARE
    v_txn_id         bigint;
    v_ref            text;
    v_src            wallet%ROWTYPE;
    v_dst            wallet%ROWTYPE;
    v_fees_wallet_id bigint;
    v_dst_mtype      text;
    v_type_ok        boolean;
    v_fee_rule_id    bigint;
    v_fee            bigint;
    v_total          bigint;
    v_tier           kyc_tier%ROWTYPE;
    v_spent_today    bigint;
    v_fail           text;
BEGIN
    -- BR-11 fast path: this request was already processed
    SELECT transaction_id INTO v_txn_id FROM transaction
    WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN v_txn_id;
    END IF;

    IF p_transaction_type NOT IN ('WALLET_FUNDING', 'TRANSFER', 'MERCHANT_PAYMENT', 'BILL_PAYMENT') THEN
        RAISE EXCEPTION 'post_transaction cannot post %; reversals use reverse_transaction',
            p_transaction_type;
    END IF;

    -- lock both wallets, always in wallet_id order
    PERFORM 1 FROM wallet
    WHERE wallet_number IN (p_source_wallet_number, p_destination_wallet_number)
    ORDER BY wallet_id
    FOR UPDATE;

    SELECT * INTO v_src FROM wallet WHERE wallet_number = p_source_wallet_number;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown source wallet %', p_source_wallet_number;
    END IF;
    SELECT * INTO v_dst FROM wallet WHERE wallet_number = p_destination_wallet_number;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown destination wallet %', p_destination_wallet_number;
    END IF;

    -- BR-10: the right kind of wallet on each side
    SELECT m.merchant_type INTO v_dst_mtype FROM merchant m WHERE m.merchant_id = v_dst.merchant_id;
    v_type_ok := CASE p_transaction_type
        WHEN 'WALLET_FUNDING'   THEN v_src.system_purpose = 'SETTLEMENT' AND v_dst.wallet_type = 'CUSTOMER'
        WHEN 'TRANSFER'         THEN v_src.wallet_type = 'CUSTOMER' AND v_dst.wallet_type = 'CUSTOMER'
        WHEN 'MERCHANT_PAYMENT' THEN v_src.wallet_type = 'CUSTOMER' AND v_dst_mtype IS NOT DISTINCT FROM 'MERCHANT'
        WHEN 'BILL_PAYMENT'     THEN v_src.wallet_type = 'CUSTOMER' AND v_dst_mtype IS NOT DISTINCT FROM 'BILLER'
    END;
    IF NOT coalesce(v_type_ok, false) THEN   -- a NULL (e.g. no system_purpose) counts as not allowed
        RAISE EXCEPTION '% from wallet % (%) to wallet % (%) is not allowed (BR-10)',
            p_transaction_type, v_src.wallet_number, v_src.wallet_type,
            v_dst.wallet_number, coalesce(v_dst_mtype, v_dst.wallet_type);
    END IF;

    -- BR-12: fee snapshot from the rule in force now
    SELECT f.fee_rule_id, coalesce(f.fee_kobo, 0) INTO v_fee_rule_id, v_fee
    FROM fee_for(p_transaction_type, p_amount_kobo, p_at) f;
    v_total := p_amount_kobo + v_fee;

    -- business checks; the first one that fails becomes the FAILED reason
    IF v_src.status <> 'ACTIVE' THEN
        v_fail := format('source wallet is %s', v_src.status);                  -- BR-05
    ELSIF v_dst.status <> 'ACTIVE' THEN
        v_fail := format('destination wallet is %s', v_dst.status);             -- BR-05
    END IF;

    IF v_fail IS NULL AND v_src.wallet_type = 'CUSTOMER' THEN
        -- BR-04: limits of the sender's verified tier (Tier 1 until verified)
        SELECT t.* INTO v_tier FROM kyc_tier t
        WHERE t.tier_level = coalesce(
            (SELECT k.tier_level FROM kyc_profile k
             WHERE k.customer_id = v_src.customer_id AND k.verification_status = 'VERIFIED'), 1);

        SELECT coalesce(sum(t.amount_kobo + t.fee_kobo), 0) INTO v_spent_today
        FROM transaction t
        WHERE t.source_wallet_id = v_src.wallet_id
          AND t.status = 'SUCCESSFUL'
          AND t.transaction_type <> 'REVERSAL'
          AND t.created_at >= date_trunc('day', p_at, 'UTC')
          AND t.created_at <  date_trunc('day', p_at, 'UTC') + INTERVAL '1 day';

        IF p_amount_kobo > v_tier.single_txn_limit_kobo THEN
            v_fail := 'single transaction limit exceeded';
        ELSIF v_spent_today + v_total > v_tier.daily_limit_kobo THEN
            v_fail := 'daily limit exceeded';
        ELSIF v_src.balance_kobo < v_total THEN
            v_fail := 'insufficient funds';                                     -- BR-07
        END IF;
    END IF;

    IF v_fail IS NULL AND v_dst.wallet_type = 'CUSTOMER' THEN
        -- BR-04: maximum balance of the receiver's tier
        SELECT t.* INTO v_tier FROM kyc_tier t
        WHERE t.tier_level = coalesce(
            (SELECT k.tier_level FROM kyc_profile k
             WHERE k.customer_id = v_dst.customer_id AND k.verification_status = 'VERIFIED'), 1);
        IF v_tier.max_balance_kobo IS NOT NULL
           AND v_dst.balance_kobo + p_amount_kobo > v_tier.max_balance_kobo THEN
            v_fail := 'receiver maximum balance exceeded';
        END IF;
    END IF;

    v_ref := coalesce(p_transaction_ref,
                      'OWR' || lpad(nextval('transaction_ref_seq')::text, 12, '0'));

    INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type,
                             source_wallet_id, destination_wallet_id, amount_kobo,
                             fee_kobo, fee_rule_id, status, channel,
                             bill_reference, narration, created_at)
    VALUES (v_ref, p_idempotency_key, p_transaction_type,
            v_src.wallet_id, v_dst.wallet_id, p_amount_kobo,
            v_fee, v_fee_rule_id, 'PENDING', p_channel,
            p_bill_reference, p_narration, p_at)
    ON CONFLICT ON CONSTRAINT uq_transaction_idempotency_key DO NOTHING
    RETURNING transaction_id INTO v_txn_id;

    IF v_txn_id IS NULL THEN
        -- a concurrent request with the same key won the race (BR-11)
        SELECT transaction_id INTO v_txn_id FROM transaction
        WHERE idempotency_key = p_idempotency_key;
        RETURN v_txn_id;
    END IF;

    INSERT INTO transaction_status_history (transaction_id, seq_no, status, changed_at)
    VALUES (v_txn_id, 1, 'PENDING', p_at);

    IF v_fail IS NOT NULL THEN
        UPDATE transaction SET status = 'FAILED' WHERE transaction_id = v_txn_id;
        INSERT INTO transaction_status_history (transaction_id, seq_no, status, changed_at, reason)
        VALUES (v_txn_id, 2, 'FAILED', p_at, v_fail);
        RETURN v_txn_id;
    END IF;

    -- BR-13: double entry. The sender pays amount + fee; the fee goes to FEES.
    INSERT INTO ledger_entry (transaction_id, line_no, wallet_id, entry_type, amount_kobo)
    VALUES (v_txn_id, 1, v_src.wallet_id, 'DEBIT',  v_total),
           (v_txn_id, 2, v_dst.wallet_id, 'CREDIT', p_amount_kobo);

    UPDATE wallet SET balance_kobo = balance_kobo - v_total
    WHERE wallet_id = v_src.wallet_id;
    UPDATE wallet SET balance_kobo = balance_kobo + p_amount_kobo
    WHERE wallet_id = v_dst.wallet_id;

    IF v_fee > 0 THEN
        -- FEES is always locked last, after the wallets above, so lock order stays consistent
        SELECT wallet_id INTO v_fees_wallet_id FROM wallet
        WHERE system_purpose = 'FEES' FOR UPDATE;
        INSERT INTO ledger_entry (transaction_id, line_no, wallet_id, entry_type, amount_kobo)
        VALUES (v_txn_id, 3, v_fees_wallet_id, 'CREDIT', v_fee);
        UPDATE wallet SET balance_kobo = balance_kobo + v_fee
        WHERE wallet_id = v_fees_wallet_id;
    END IF;

    UPDATE transaction SET status = 'SUCCESSFUL' WHERE transaction_id = v_txn_id;
    INSERT INTO transaction_status_history (transaction_id, seq_no, status, changed_at)
    VALUES (v_txn_id, 2, 'SUCCESSFUL', p_at);

    RETURN v_txn_id;
END
$$;

-- ---------------------------------------------------------------------------
-- FR-06: reverse a SUCCESSFUL transaction (BR-16).
--
-- A new REVERSAL transaction posts the mirror image of every original ledger
-- line (debits become credits and the other way round), so the amount and the
-- fee are both returned. The original becomes REVERSED, the link is recorded in
-- reversal (whose primary key allows only one reversal per original) and the
-- action is audited.
-- ---------------------------------------------------------------------------
CREATE FUNCTION reverse_transaction(
    p_original_ref     text,
    p_reason           text,
    p_requested_by     text,           -- staff username
    p_idempotency_key  uuid,
    p_transaction_ref  text        DEFAULT NULL,
    p_at               timestamptz DEFAULT now()
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = oworail, pg_temp
AS $$
DECLARE
    v_orig     transaction%ROWTYPE;
    v_txn_id   bigint;
    v_ref      text;
    v_short    text;
BEGIN
    SELECT * INTO v_orig FROM transaction
    WHERE transaction_ref = p_original_ref
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown transaction %', p_original_ref;
    END IF;

    -- checked after the lock, so a retried request that waited here sees the
    -- reversal the first request created and returns it (BR-11)
    SELECT transaction_id INTO v_txn_id FROM transaction
    WHERE idempotency_key = p_idempotency_key;
    IF FOUND THEN
        RETURN v_txn_id;
    END IF;

    IF v_orig.transaction_type = 'REVERSAL' THEN
        RAISE EXCEPTION 'transaction % is itself a reversal and cannot be reversed', p_original_ref;
    END IF;
    IF v_orig.status <> 'SUCCESSFUL' THEN
        RAISE EXCEPTION 'only a SUCCESSFUL transaction can be reversed; % is % (BR-16)',
            p_original_ref, v_orig.status;
    END IF;

    -- lock every wallet the original touched, in wallet_id order
    PERFORM 1 FROM wallet
    WHERE wallet_id IN (SELECT wallet_id FROM ledger_entry WHERE transaction_id = v_orig.transaction_id)
    ORDER BY wallet_id
    FOR UPDATE;

    -- the receiver may already have spent the money
    SELECT w.wallet_number INTO v_short
    FROM ledger_entry l
    JOIN wallet w ON w.wallet_id = l.wallet_id
    WHERE l.transaction_id = v_orig.transaction_id
    GROUP BY w.wallet_id, w.wallet_number, w.wallet_type, w.balance_kobo
    HAVING w.wallet_type <> 'SYSTEM'
       AND w.balance_kobo - sum(CASE l.entry_type WHEN 'CREDIT' THEN l.amount_kobo ELSE 0 END)
                          + sum(CASE l.entry_type WHEN 'DEBIT'  THEN l.amount_kobo ELSE 0 END) < 0
    LIMIT 1;
    IF v_short IS NOT NULL THEN
        RAISE EXCEPTION 'cannot reverse %: wallet % no longer holds the funds', p_original_ref, v_short;
    END IF;

    v_ref := coalesce(p_transaction_ref,
                      'OWR' || lpad(nextval('transaction_ref_seq')::text, 12, '0'));

    INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type,
                             source_wallet_id, destination_wallet_id, amount_kobo,
                             fee_kobo, fee_rule_id, status, channel, narration, created_at)
    VALUES (v_ref, p_idempotency_key, 'REVERSAL',
            v_orig.destination_wallet_id, v_orig.source_wallet_id, v_orig.amount_kobo,
            0, NULL, 'PENDING', 'WEB', 'reversal of ' || v_orig.transaction_ref, p_at)
    RETURNING transaction_id INTO v_txn_id;

    INSERT INTO transaction_status_history (transaction_id, seq_no, status, changed_at)
    VALUES (v_txn_id, 1, 'PENDING', p_at);

    -- mirror lines: debits first, each group in the original line order
    INSERT INTO ledger_entry (transaction_id, line_no, wallet_id, entry_type, amount_kobo)
    SELECT v_txn_id,
           row_number() OVER (ORDER BY (m.entry_type = 'DEBIT') DESC, m.line_no),
           m.wallet_id, m.entry_type, m.amount_kobo
    FROM (
        SELECT l.line_no, l.wallet_id, l.amount_kobo,
               CASE l.entry_type WHEN 'DEBIT' THEN 'CREDIT' ELSE 'DEBIT' END AS entry_type
        FROM ledger_entry l
        WHERE l.transaction_id = v_orig.transaction_id
    ) m;

    UPDATE wallet w
    SET balance_kobo = w.balance_kobo + d.delta
    FROM (
        SELECT wallet_id,
               sum(CASE entry_type WHEN 'CREDIT' THEN amount_kobo ELSE -amount_kobo END) AS delta
        FROM ledger_entry
        WHERE transaction_id = v_txn_id
        GROUP BY wallet_id
    ) d
    WHERE w.wallet_id = d.wallet_id;

    UPDATE transaction SET status = 'SUCCESSFUL' WHERE transaction_id = v_txn_id;
    INSERT INTO transaction_status_history (transaction_id, seq_no, status, changed_at)
    VALUES (v_txn_id, 2, 'SUCCESSFUL', p_at);

    INSERT INTO reversal (original_transaction_id, reversal_transaction_id, reason, requested_by)
    VALUES (v_orig.transaction_id, v_txn_id, p_reason, p_requested_by);

    UPDATE transaction SET status = 'REVERSED' WHERE transaction_id = v_orig.transaction_id;
    INSERT INTO transaction_status_history (transaction_id, seq_no, status, changed_at, reason)
    SELECT v_orig.transaction_id, max(h.seq_no) + 1, 'REVERSED', p_at, 'reversed by ' || v_ref
    FROM transaction_status_history h
    WHERE h.transaction_id = v_orig.transaction_id;

    INSERT INTO audit_log (occurred_at, actor, action, target_type, target_id, details)
    VALUES (p_at, p_requested_by, 'TXN_REVERSED', 'transaction', v_orig.transaction_id::text,
            jsonb_build_object('original_ref', v_orig.transaction_ref,
                               'reversal_ref', v_ref,
                               'reason', p_reason));

    RETURN v_txn_id;
END
$$;

RESET ROLE;
