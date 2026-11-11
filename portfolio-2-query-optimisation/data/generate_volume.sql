-- Volume data for Portfolio 2: ~100k customers, 2,000 merchants, ~1.1M transactions.
-- Run on a fresh build (portfolio-1-database-design/sql/build.sql).

\set ON_ERROR_STOP on
\set n_customers 100000
\set n_merchants 2000
\set n_billers 200
\set n_txn 1000000
SET search_path = oworail, public;
SET client_min_messages = warning;

-- Deterministic pseudo-random number in [0, 1) for (row, stream). Hash-based,
-- so the result doesn't depend on execution order or parallel workers.
CREATE FUNCTION pg_temp.u(i bigint, stream bigint) RETURNS float8
LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT ((hashint8extended(i, stream) >> 11) & 4503599627370495)::float8 / 4503599627370496.0 $$;

BEGIN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM oworail.wallet WHERE wallet_number LIKE '31%') THEN
        RAISE EXCEPTION 'volume data already loaded; rebuild first';
    END IF;
END $$;

-- The balanced-ledger triggers check one transaction per row event; for a bulk
-- load they are switched off and the same rules are checked set-based afterwards
-- (consistency_checks.sql). Every other constraint stays on.
ALTER TABLE ledger_entry DISABLE TRIGGER trg_ledger_entry_balanced;
ALTER TABLE transaction  DISABLE TRIGGER trg_transaction_balanced;

\echo '-- customers, phones, KYC, wallets'
INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state, created_at)
SELECT n.first_name || ' ' || n.last_name,
       lower(n.first_name || '.' || n.last_name || '.' || i || '@example.com'),
       date '1960-01-01' + floor(pg_temp.u(i, 1) * 16800)::int,
       (1 + floor(pg_temp.u(i, 2) * 200))::int || ' ' || n.street,
       n.city, n.state,
       timestamptz '2026-01-01 00:00:00+00' + floor(pg_temp.u(i, 3) * 119 * 86400) * interval '1 second'
FROM generate_series(1, :n_customers) AS i
CROSS JOIN LATERAL (
    SELECT (ARRAY['Adebayo','Chinedu','Aisha','Emeka','Fatima','Oluwaseun','Ngozi','Ibrahim','Yetunde','Uche',
                  'Bola','Kelechi','Zainab','Tobi','Amaka','Musa','Folake','Ikenna','Halima','Segun'])
               [1 + floor(pg_temp.u(i, 4) * 20)::int] AS first_name,
           (ARRAY['Okafor','Adeyemi','Bello','Eze','Ogunleye','Abubakar','Nwosu','Balogun','Okonkwo','Lawal',
                  'Obi','Adewale','Sani','Chukwu','Afolabi','Danjuma','Onyeka','Ajayi','Garba','Uzor'])
               [1 + floor(pg_temp.u(i, 5) * 20)::int] AS last_name,
           (ARRAY['Allen Avenue','Awolowo Road','Ogui Road','Ahmadu Bello Way','Ring Road','Herbert Macaulay Way',
                  'Aba Road','Zik Avenue'])[1 + floor(pg_temp.u(i, 6) * 8)::int] AS street,
           c.city, c.state
    FROM (SELECT (ARRAY['Ikeja','Yaba','Lekki','Abuja','Kano','Ibadan','Port Harcourt','Enugu','Kaduna','Benin City'])[k] AS city,
                 (ARRAY['Lagos','Lagos','Lagos','FCT','Kano','Oyo','Rivers','Enugu','Kaduna','Edo'])[k] AS state
          FROM (SELECT 1 + floor(pg_temp.u(i, 7) * 10)::int AS k) kk) c
) n
ORDER BY i;

-- volume customer number i, recovered from the email
CREATE TEMP TABLE vc AS
SELECT substring(email FROM '\.(\d+)@')::int AS i, customer_id, created_at
FROM customer WHERE email ~ '\.\d+@example\.com$';
CREATE UNIQUE INDEX ON vc (i);

INSERT INTO customer_phone (phone_number, customer_id)
SELECT '+23480' || lpad(i::text, 8, '0'), customer_id FROM vc
UNION ALL
SELECT '+23490' || lpad(i::text, 8, '0'), customer_id FROM vc WHERE pg_temp.u(i, 8) < 0.3;

INSERT INTO kyc_profile (customer_id, tier_level, id_type, national_id_number,
                         verification_status, verified_at, verified_by)
SELECT customer_id,
       CASE WHEN NOT verified THEN 1 WHEN pg_temp.u(i, 9) < 0.5 THEN 1 WHEN pg_temp.u(i, 9) < 0.85 THEN 2 ELSE 3 END,
       CASE WHEN pg_temp.u(i, 10) < 0.6 THEN 'BVN' ELSE 'NIN' END,
       '999' || lpad((1000000 + i)::text, 8, '0'),
       CASE WHEN verified THEN 'VERIFIED' ELSE 'PENDING' END,
       CASE WHEN verified THEN created_at + interval '2 hours' END,
       CASE WHEN verified THEN 'compliance.batch' END
FROM (SELECT vc.*, pg_temp.u(i, 11) < 0.95 AS verified FROM vc) v;

INSERT INTO audit_log (occurred_at, actor, action, target_type, target_id, details)
SELECT k.verified_at, k.verified_by, 'KYC_VERIFIED', 'kyc_profile', k.kyc_profile_id::text,
       jsonb_build_object('customer_id', k.customer_id, 'tier_to', k.tier_level)
FROM kyc_profile k JOIN vc ON vc.customer_id = k.customer_id
WHERE k.verification_status = 'VERIFIED';

INSERT INTO wallet (wallet_number, wallet_type, customer_id, created_at)
SELECT '31' || lpad(i::text, 8, '0'), 'CUSTOMER', customer_id, created_at FROM vc ORDER BY i;

\echo '-- merchants and billers'
INSERT INTO merchant (merchant_code, business_name, merchant_type, category, created_at)
SELECT 'MRC' || (10000 + j),
       initcap(replace(cat, '_', ' ')) || CASE WHEN j <= :n_merchants - :n_billers THEN ' Merchant ' ELSE ' Biller ' END || j,
       CASE WHEN j <= :n_merchants - :n_billers THEN 'MERCHANT' ELSE 'BILLER' END,
       cat,
       timestamptz '2026-01-01 00:00:00+00' + floor(pg_temp.u(j, 12) * 100 * 86400) * interval '1 second'
FROM generate_series(1, :n_merchants) AS j
CROSS JOIN LATERAL (
    SELECT CASE WHEN j <= :n_merchants - :n_billers
                THEN (ARRAY['RETAIL','FOOD','TRANSPORT','HEALTH','EDUCATION'])[1 + floor(pg_temp.u(j, 13) * 5)::int]
                ELSE (ARRAY['AIRTIME','ELECTRICITY','CABLE_TV'])[1 + floor(pg_temp.u(j, 13) * 3)::int]
           END AS cat
) c
ORDER BY j;

INSERT INTO wallet (wallet_number, wallet_type, merchant_id, created_at)
SELECT '32' || lpad((substring(m.merchant_code FROM 4)::int - 10000)::text, 8, '0'),
       'MERCHANT', m.merchant_id, m.created_at
FROM merchant m WHERE m.merchant_code >= 'MRC10001'
ORDER BY m.merchant_id;

CREATE TEMP TABLE vw AS          -- customer number -> wallet
SELECT substring(wallet_number FROM 3)::int AS i, wallet_id FROM wallet WHERE wallet_number LIKE '31%';
CREATE UNIQUE INDEX ON vw (i);
CREATE TEMP TABLE vm AS          -- merchant number -> wallet
SELECT (substring(m.merchant_code FROM 4)::int - 10000) AS j, w.wallet_id
FROM merchant m JOIN wallet w ON w.merchant_id = m.merchant_id
WHERE m.merchant_code >= 'MRC10001';
CREATE UNIQUE INDEX ON vm (j);

\echo '-- payments and transfers'
-- Senders are skewed (u^2): a few customers are very active, most are not.
CREATE TEMP TABLE vt AS
SELECT g.i, g.ty, src.wallet_id AS src, dst_wallet AS dst, amount, created_at, channel,
       CASE WHEN pg_temp.u(g.i, 17) < 0.03 THEN 'FAILED' ELSE 'SUCCESSFUL' END AS status,
       CASE WHEN pg_temp.u(g.i, 17) < 0.024 THEN 'insufficient funds'
            WHEN pg_temp.u(g.i, 17) < 0.03  THEN 'daily limit exceeded' END AS fail_reason
FROM (
    SELECT i,
           CASE WHEN pg_temp.u(i, 14) < 0.60 THEN 'TRANSFER'
                WHEN pg_temp.u(i, 14) < 0.85 THEN 'MERCHANT_PAYMENT'
                ELSE 'BILL_PAYMENT' END AS ty,
           1 + floor(:n_customers * pg_temp.u(i, 15) ^ 2)::int AS src_i,
           timestamptz '2026-05-01 00:00:00+00' + floor(pg_temp.u(i, 16) * 184 * 86400) * interval '1 second' AS created_at,
           CASE WHEN pg_temp.u(i, 18) < 0.7 THEN 'APP' WHEN pg_temp.u(i, 18) < 0.9 THEN 'USSD' ELSE 'WEB' END AS channel
    FROM generate_series(1, :n_txn) AS i
) g
JOIN vw src ON src.i = g.src_i
CROSS JOIN LATERAL (
    SELECT CASE g.ty
             WHEN 'TRANSFER'         THEN 10000 * (1 + floor(500 * pg_temp.u(g.i, 19) ^ 3))
             WHEN 'MERCHANT_PAYMENT' THEN  5000 * (1 + floor(400 * pg_temp.u(g.i, 19) ^ 2))
             ELSE                         10000 * (1 + floor(300 * pg_temp.u(g.i, 19)))
           END::bigint AS amount,
           CASE g.ty
             WHEN 'TRANSFER' THEN (SELECT wallet_id FROM vw WHERE vw.i =
                                     CASE WHEN d = g.src_i THEN d % :n_customers + 1 ELSE d END)
             WHEN 'MERCHANT_PAYMENT' THEN (SELECT wallet_id FROM vm WHERE vm.j =
                                     1 + floor((:n_merchants - :n_billers) * pg_temp.u(g.i, 20) ^ 3)::int)
             ELSE (SELECT wallet_id FROM vm WHERE vm.j =
                                     :n_merchants - :n_billers + 1 + floor(:n_billers * pg_temp.u(g.i, 20))::int)
           END AS dst_wallet
    FROM (SELECT 1 + floor(:n_customers * pg_temp.u(g.i, 20))::int AS d) dd
) x;

-- one row per transaction to insert, with its ledger shape
CREATE TEMP TABLE vall (
    kind        text,            -- funding | original | reversal
    ref         text, idem uuid, ty text, src bigint, dst bigint,
    amount      bigint, fee bigint, fee_rule_id bigint,
    status      text, fail_reason text, channel text, bill_reference text, narration text,
    created_at  timestamptz,
    orig_ref    text, orig_fee bigint, reversed_at timestamptz, reversal_ref text
);

INSERT INTO vall (kind, ref, idem, ty, src, dst, amount, fee, fee_rule_id, status, fail_reason,
                  channel, bill_reference, created_at)
SELECT 'original', 'OWR1' || lpad(vt.i::text, 11, '0'), md5('owr-volume-' || vt.i)::uuid,
       vt.ty, vt.src, vt.dst, vt.amount, coalesce(f.fee_kobo, 0), f.fee_rule_id,
       vt.status, vt.fail_reason, vt.channel,
       CASE WHEN vt.ty = 'BILL_PAYMENT' THEN 'BILL-' || lpad(vt.i::text, 10, '0') END,
       vt.created_at
FROM vt CROSS JOIN LATERAL fee_for(vt.ty, vt.amount, vt.created_at) f;

\echo '-- reversals'
-- 0.2 % of successful transfers are reversed between 1 and 48 hours later.
INSERT INTO vall (kind, ref, idem, ty, src, dst, amount, fee, status, channel, narration, created_at,
                  orig_ref, orig_fee)
SELECT 'reversal', 'OWR2' || substring(o.ref FROM 5), md5('owr-volume-rev-' || o.ref)::uuid,
       'REVERSAL', o.dst, o.src, o.amount, 0, 'SUCCESSFUL', 'WEB', 'reversal of ' || o.ref,
       least(o.created_at + (1 + floor(pg_temp.u(substring(o.ref FROM 5)::bigint, 21) * 48)) * interval '1 hour',
             timestamptz '2026-10-31 23:59:59+00'),
       o.ref, o.fee
FROM vall o
WHERE o.kind = 'original' AND o.ty = 'TRANSFER' AND o.status = 'SUCCESSFUL'
  AND pg_temp.u(substring(o.ref FROM 5)::bigint, 22) < 0.002;

UPDATE vall o
SET status = 'REVERSED', reversed_at = r.created_at, reversal_ref = r.ref
FROM vall r
WHERE r.kind = 'reversal' AND r.orig_ref = o.ref;

\echo '-- opening funding per customer'
-- Each customer is funded before their first payment with everything they will
-- ever send plus a buffer, so no balance can go below zero at any point.
INSERT INTO vall (kind, ref, idem, ty, src, dst, amount, fee, status, channel, created_at)
SELECT 'funding', 'OWR3' || lpad(vw.i::text, 11, '0'), md5('owr-volume-fund-' || vw.i)::uuid,
       'WALLET_FUNDING', (SELECT wallet_id FROM wallet WHERE system_purpose = 'SETTLEMENT'), vw.wallet_id,
       (ceil((coalesce(d.out_kobo, 0) + 100000 * (1 + floor(pg_temp.u(vw.i, 23) * 50))) / 100000.0) * 100000)::bigint,
       0, 'SUCCESSFUL', 'APP', vc.created_at + interval '1 hour'
FROM vw
JOIN vc ON vc.i = vw.i
LEFT JOIN (
    SELECT src, sum(CASE WHEN kind = 'reversal' THEN amount + orig_fee ELSE amount + fee END) AS out_kobo
    FROM vall WHERE status <> 'FAILED' GROUP BY src
) d ON d.src = vw.wallet_id;

\echo '-- transactions, in time order'
INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                         destination_wallet_id, amount_kobo, fee_kobo, fee_rule_id, status, channel,
                         bill_reference, narration, created_at)
SELECT ref, idem, ty, src, dst, amount, fee, fee_rule_id, status, channel, bill_reference, narration, created_at
FROM vall
ORDER BY created_at, ref;

CREATE TEMP TABLE vid AS
SELECT v.ref, t.transaction_id FROM vall v JOIN transaction t ON t.transaction_ref = v.ref;
CREATE UNIQUE INDEX ON vid (ref);

\echo '-- ledger lines'
INSERT INTO ledger_entry (transaction_id, line_no, wallet_id, entry_type, amount_kobo)
SELECT id.transaction_id, l.line_no, l.wallet_id, l.entry_type, l.amount
FROM vall v
JOIN vid id ON id.ref = v.ref
CROSS JOIN LATERAL (VALUES
    (1::smallint, v.src, 'DEBIT',  v.amount + v.fee),
    (2::smallint, v.dst, 'CREDIT', v.amount),
    (3::smallint, (SELECT wallet_id FROM wallet WHERE system_purpose = 'FEES'), 'CREDIT', v.fee)
) AS l (line_no, wallet_id, entry_type, amount)
WHERE v.kind IN ('funding', 'original') AND v.status <> 'FAILED' AND l.amount > 0
ORDER BY id.transaction_id, l.line_no;

-- a reversal mirrors the original: debits first, then the credit of amount + fee
INSERT INTO ledger_entry (transaction_id, line_no, wallet_id, entry_type, amount_kobo)
SELECT id.transaction_id, l.line_no, l.wallet_id, l.entry_type, l.amount
FROM vall v
JOIN vid id ON id.ref = v.ref
CROSS JOIN LATERAL (VALUES
    (1::smallint, v.src, 'DEBIT', v.amount),
    (2::smallint, (SELECT wallet_id FROM wallet WHERE system_purpose = 'FEES'), 'DEBIT', v.orig_fee),
    ((CASE WHEN v.orig_fee > 0 THEN 3 ELSE 2 END)::smallint, v.dst, 'CREDIT', v.amount + v.orig_fee)
) AS l (line_no, wallet_id, entry_type, amount)
WHERE v.kind = 'reversal' AND l.amount > 0
ORDER BY id.transaction_id, l.line_no;

\echo '-- status history, reversal links, audit'
INSERT INTO transaction_status_history (transaction_id, seq_no, status, changed_at, reason)
SELECT id.transaction_id, h.seq_no, h.status, h.changed_at, h.reason
FROM vall v
JOIN vid id ON id.ref = v.ref
CROSS JOIN LATERAL (VALUES
    (1::smallint, 'PENDING', v.created_at, NULL::text),
    (2::smallint, CASE WHEN v.status = 'FAILED' THEN 'FAILED' ELSE 'SUCCESSFUL' END, v.created_at, v.fail_reason),
    (3::smallint, 'REVERSED', v.reversed_at, 'reversed by ' || v.reversal_ref)
) AS h (seq_no, status, changed_at, reason)
WHERE h.seq_no < 3 OR v.status = 'REVERSED'
ORDER BY id.transaction_id, h.seq_no;

INSERT INTO reversal (original_transaction_id, reversal_transaction_id, reason, requested_by)
SELECT o.transaction_id, r.transaction_id,
       CASE WHEN pg_temp.u(r.transaction_id, 24) < 0.5 THEN 'duplicate transfer reported by customer'
            ELSE 'transfer disputed by customer' END,
       'support.batch'
FROM vall v
JOIN vid r ON r.ref = v.ref
JOIN vid o ON o.ref = v.orig_ref
WHERE v.kind = 'reversal';

INSERT INTO audit_log (occurred_at, actor, action, target_type, target_id, details)
SELECT t.created_at, rv.requested_by, 'TXN_REVERSED', 'transaction', rv.original_transaction_id::text,
       jsonb_build_object('original_ref', o.transaction_ref, 'reversal_ref', t.transaction_ref, 'reason', rv.reason)
FROM reversal rv
JOIN transaction t ON t.transaction_id = rv.reversal_transaction_id
JOIN transaction o ON o.transaction_id = rv.original_transaction_id
WHERE o.transaction_ref LIKE 'OWR1%';

\echo '-- wallet balances from the ledger'
UPDATE wallet w
SET balance_kobo = s.ledger_balance
FROM (SELECT wallet_id,
             sum(CASE entry_type WHEN 'CREDIT' THEN amount_kobo ELSE -amount_kobo END) AS ledger_balance
      FROM ledger_entry GROUP BY wallet_id) s
WHERE s.wallet_id = w.wallet_id AND w.balance_kobo <> s.ledger_balance;

ALTER TABLE ledger_entry ENABLE TRIGGER trg_ledger_entry_balanced;
ALTER TABLE transaction  ENABLE TRIGGER trg_transaction_balanced;

COMMIT;

\echo '-- vacuum and fresh planner statistics'
VACUUM (ANALYZE) customer, customer_phone, kyc_profile, merchant, wallet, transaction,
                 ledger_entry, transaction_status_history, reversal, audit_log;

\pset footer off
SELECT c.relname AS table_name, c.reltuples::bigint AS rows,
       pg_size_pretty(pg_table_size(c.oid)) AS table_size,
       pg_size_pretty(pg_indexes_size(c.oid)) AS index_size
FROM pg_class c
WHERE c.relnamespace = 'oworail'::regnamespace AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;
