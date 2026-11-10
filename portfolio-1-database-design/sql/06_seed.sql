-- OwoRail physical design, step 6: small fixed seed (synthetic data only).
--
-- Reproduces the transaction report used in normalisation.md (2 November
-- 2026, transactions OWR000000000101 to 104) and adds a few rows so every
-- table, fee band and failure path has an example. Everything goes through
-- the onboarding, KYC, posting and reversal functions, the same way the
-- application would, except reference data (tiers, fee rules, system wallets).
--
-- Fixed timestamps, references and idempotency keys make the result identical
-- on every run. National ID numbers carry the synthetic 999 prefix; emails
-- use example.com. The large volume dataset for Portfolio 2 is separate.

SET ROLE oworail_owner;
SET search_path = oworail, public;

BEGIN;

-- ---------------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------------
INSERT INTO kyc_tier (tier_level, tier_name, single_txn_limit_kobo, daily_limit_kobo, max_balance_kobo) VALUES
    (1, 'Tier 1: basic',      5000000,    5000000,   30000000),   -- N50k / N50k / N300k
    (2, 'Tier 2: standard',  10000000,   20000000,   50000000),   -- N100k / N200k / N500k
    (3, 'Tier 3: full',     500000000, 2500000000,       NULL);   -- N5m / N25m / no limit

INSERT INTO wallet (wallet_number, wallet_type, system_purpose, created_at) VALUES
    ('9000000001', 'SYSTEM', 'FEES',       '2026-10-01 00:00:00+00'),
    ('9000000002', 'SYSTEM', 'SETTLEMENT', '2026-10-01 00:00:00+00'),
    ('9000000003', 'SYSTEM', 'SUSPENSE',   '2026-10-01 00:00:00+00');

-- Fee rules. Rule 1 is the old small-transfer fee, replaced by rule 2 on
-- 1 July 2026; both exist so past transactions keep the fee they were charged.
INSERT INTO fee_rule (transaction_type, min_amount_kobo, max_amount_kobo, flat_fee_kobo,
                      percent_bps, cap_kobo, effective_from, effective_to) VALUES
    ('TRANSFER',           1,  500000,  500,  0,  NULL, '2026-01-01 00:00:00+00', '2026-07-01 00:00:00+00'),
    ('TRANSFER',           1,  500000, 1000,  0,  NULL, '2026-07-01 00:00:00+00', NULL),
    ('TRANSFER',      500001, 5000000, 2500,  0,  NULL, '2026-01-01 00:00:00+00', NULL),
    ('TRANSFER',     5000001,    NULL, 5000,  0,  NULL, '2026-01-01 00:00:00+00', NULL),
    ('BILL_PAYMENT',       1,    NULL,    0, 50, 10000, '2026-01-01 00:00:00+00', NULL);
    -- 50 bps = 0.5 %, capped at N100. WALLET_FUNDING and MERCHANT_PAYMENT have no rule: free.

-- ---------------------------------------------------------------------------
-- Customers, merchants and KYC
-- ---------------------------------------------------------------------------
SELECT onboard_customer('Adaeze Okafor', 'adaeze.okafor@example.com', '1991-04-12',
           '14 Allen Avenue', 'Ikeja', 'Lagos', ARRAY['+2348030000001', '+2349050000001'],
           '3000000001', '2026-10-05 10:00:00+00');
SELECT onboard_customer('Tunde Bakare', 'tunde.bakare@example.com', '1996-08-30',
           '3 Herbert Macaulay Way', 'Yaba', 'Lagos', ARRAY['+2348120000002'],
           '3000000002', '2026-10-06 14:30:00+00');
SELECT onboard_customer('Chiamaka Eze', 'chiamaka.eze@example.com', '1985-01-20',
           '22 Ogui Road', 'Enugu', 'Enugu', ARRAY['+2347010000003'],
           '3000000003', '2026-10-08 09:10:00+00');
SELECT onboard_customer('Ibrahim Musa', 'ibrahim.musa@example.com', '1999-11-02',
           '7 Ahmadu Bello Way', 'Kaduna', 'Kaduna', ARRAY['+2349130000004'],
           '3000000004', '2026-10-20 16:45:00+00');
SELECT onboard_customer('Funmilayo Adeyemi', 'funmilayo.adeyemi@example.com', '2001-03-15',
           '9 Ring Road', 'Ibadan', 'Oyo', ARRAY['+2348050000005'],
           '3000000005', '2026-10-25 11:20:00+00');

SELECT onboard_merchant('MRC00042', 'Mama Put Kitchen',          'MERCHANT', 'FOOD',
           '3000000042', '2026-10-02 08:00:00+00');
SELECT onboard_merchant('MRC00043', 'Danfo Rides',               'MERCHANT', 'TRANSPORT',
           '3000000043', '2026-10-02 08:05:00+00');
SELECT onboard_merchant('MRC00101', 'Lagoon Power Distribution', 'BILLER',   'ELECTRICITY',
           '3000000101', '2026-10-02 08:10:00+00');
SELECT onboard_merchant('MRC00102', 'StarView Cable',            'BILLER',   'CABLE_TV',
           '3000000102', '2026-10-02 08:15:00+00');

SELECT submit_kyc(c.customer_id, k.id_type, k.national_id_number, k.ts)
FROM (VALUES ('adaeze.okafor@example.com', 'BVN', '99900000001', '2026-10-05 10:05:00+00'::timestamptz),
             ('tunde.bakare@example.com',  'NIN', '99900000002', '2026-10-06 14:35:00+00'),
             ('chiamaka.eze@example.com',  'BVN', '99900000003', '2026-10-08 09:15:00+00'),
             ('ibrahim.musa@example.com',  'NIN', '99900000004', '2026-10-20 16:50:00+00'))
     AS k (email, id_type, national_id_number, ts)
JOIN customer c ON c.email = k.email
ORDER BY k.ts;

-- Ibrahim's profile stays PENDING; Funmilayo has not submitted KYC yet.
SELECT review_kyc(c.customer_id, 'VERIFIED', r.tier::smallint, 'compliance.kemi', r.ts)
FROM (VALUES ('adaeze.okafor@example.com', 2, '2026-10-05 12:00:00+00'::timestamptz),
             ('tunde.bakare@example.com',  1, '2026-10-07 09:00:00+00'),
             ('chiamaka.eze@example.com',  3, '2026-10-08 15:30:00+00'))
     AS r (email, tier, ts)
JOIN customer c ON c.email = r.email
ORDER BY r.ts;

-- A wallet frozen by compliance (BR-05), with its audit record (BR-17).
UPDATE wallet SET status = 'FROZEN' WHERE wallet_number = '3000000005';
INSERT INTO audit_log (occurred_at, actor, action, target_type, target_id, details)
SELECT '2026-10-30 10:00:00+00', 'compliance.kemi', 'WALLET_FROZEN', 'wallet', w.wallet_id::text,
       jsonb_build_object('wallet_number', w.wallet_number, 'reason', 'identity documents not provided')
FROM wallet w WHERE w.wallet_number = '3000000005';

-- ---------------------------------------------------------------------------
-- Money movement
-- ---------------------------------------------------------------------------
-- 1 November: wallets funded from the partner bank (SETTLEMENT wallet).
SELECT post_transaction(k::uuid, 'WALLET_FUNDING', '9000000002', dst, amt, 'APP',
                        p_transaction_ref => ref, p_at => ts)
FROM (VALUES ('00000000-0000-4000-8000-000000000091', 'OWR000000000091', '3000000001',  2000000, '2026-11-01 08:00:00+00'::timestamptz),
             ('00000000-0000-4000-8000-000000000092', 'OWR000000000092', '3000000002',    50000, '2026-11-01 08:05:00+00'),
             ('00000000-0000-4000-8000-000000000093', 'OWR000000000093', '3000000003', 20000000, '2026-11-01 08:10:00+00'),
             ('00000000-0000-4000-8000-000000000094', 'OWR000000000094', '3000000004',   100000, '2026-11-01 08:15:00+00'))
     AS f (k, ref, dst, amt, ts)
ORDER BY ts;

-- 2 November: the four transactions of the normalisation sample.
SELECT post_transaction('00000000-0000-4000-8000-000000000101', 'TRANSFER',
           '3000000001', '3000000002', 500000, 'APP',
           p_transaction_ref => 'OWR000000000101', p_at => '2026-11-02 09:15:02+00');
SELECT post_transaction('00000000-0000-4000-8000-000000000102', 'MERCHANT_PAYMENT',
           '3000000001', '3000000042', 250000, 'USSD',
           p_transaction_ref => 'OWR000000000102', p_at => '2026-11-02 11:40:17+00');
-- fails: Tunde holds 550000 and needs 1000000 + 2500 fee
SELECT post_transaction('00000000-0000-4000-8000-000000000103', 'TRANSFER',
           '3000000002', '3000000001', 1000000, 'WEB',
           p_transaction_ref => 'OWR000000000103', p_at => '2026-11-02 13:05:55+00');
SELECT reverse_transaction('OWR000000000101', 'duplicate transfer reported by customer',
           'support.ifeoma', '00000000-0000-4000-8000-000000000104',
           p_transaction_ref => 'OWR000000000104', p_at => '2026-11-02 16:20:41+00');

-- 3 November: percentage fee, fee cap, a frozen receiver and a merchant payment.
SELECT post_transaction('00000000-0000-4000-8000-000000000105', 'BILL_PAYMENT',
           '3000000003', '3000000102', 1200000, 'APP', p_bill_reference => 'SVC-1029384756',
           p_transaction_ref => 'OWR000000000105', p_at => '2026-11-03 10:02:11+00');   -- fee 6000 (0.5 %)
SELECT post_transaction('00000000-0000-4000-8000-000000000106', 'BILL_PAYMENT',
           '3000000003', '3000000101', 5000000, 'WEB', p_bill_reference => 'LPD-45000012345',
           p_transaction_ref => 'OWR000000000106', p_at => '2026-11-03 10:15:40+00');   -- fee capped at 10000
SELECT post_transaction('00000000-0000-4000-8000-000000000107', 'TRANSFER',
           '3000000004', '3000000005', 50000, 'USSD', p_narration => 'for transport',
           p_transaction_ref => 'OWR000000000107', p_at => '2026-11-03 12:30:00+00');   -- fails: receiver FROZEN
SELECT post_transaction('00000000-0000-4000-8000-000000000108', 'MERCHANT_PAYMENT',
           '3000000003', '3000000043', 150000, 'APP',
           p_transaction_ref => 'OWR000000000108', p_at => '2026-11-03 18:45:09+00');

-- Saved beneficiaries (FR-11)
INSERT INTO saved_beneficiary (customer_id, wallet_id, nickname, saved_at)
SELECT c.customer_id, w.wallet_id, b.nickname, b.ts
FROM (VALUES ('adaeze.okafor@example.com', '3000000002', 'Tunde B', '2026-10-10 09:00:00+00'::timestamptz),
             ('chiamaka.eze@example.com',  '3000000001', 'Ada',     '2026-10-12 19:30:00+00'),
             ('chiamaka.eze@example.com',  '3000000042', 'Mama Put', '2026-10-12 19:31:00+00'))
     AS b (email, wallet_number, nickname, ts)
JOIN customer c ON c.email = b.email
JOIN wallet w   ON w.wallet_number = b.wallet_number;

COMMIT;   -- the deferred balanced-ledger triggers run here

RESET ROLE;
