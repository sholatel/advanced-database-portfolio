-- Procedure tests: the rules that live in fee_for, the onboarding and KYC
-- functions, post_transaction and reverse_transaction. Each test runs one or
-- more calls, then a check query whose result is compared with the expected
-- value. Everything is rolled back afterwards.
--
--   docker compose exec -T postgres psql -U postgres -d oworail -X \
--       -v ON_ERROR_STOP=1 -f /workspace/portfolio-1-database-design/sql/tests/procedure_tests.sql

\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
\ir _harness.sql

-- "rule/fee" for a fee_for() call; 'none/0' when no rule applies
CREATE FUNCTION pg_temp.fee(p_type text, p_amount bigint, p_at timestamptz DEFAULT '2026-11-05 12:00:00+00')
RETURNS text LANGUAGE sql STABLE
AS $$ SELECT coalesce(f.fee_rule_id::text, 'none') || '/' || coalesce(f.fee_kobo, 0)
      FROM oworail.fee_for(p_type, p_amount, p_at) f $$;

-- "status | reason of the last status row | ledger lines" for a transaction
CREATE FUNCTION pg_temp.outcome(p_ref text) RETURNS text LANGUAGE sql STABLE
AS $$ SELECT t.status || ' | ' || coalesce(h.reason, '-') || ' | '
             || (SELECT count(*) FROM oworail.ledger_entry l WHERE l.transaction_id = t.transaction_id) || ' lines'
      FROM oworail.transaction t
      JOIN LATERAL (SELECT reason FROM oworail.transaction_status_history s
                    WHERE s.transaction_id = t.transaction_id
                    ORDER BY s.seq_no DESC LIMIT 1) h ON true
      WHERE t.transaction_ref = p_ref $$;

-- balance of a wallet
CREATE FUNCTION pg_temp.bal(p_wallet_number text) RETURNS bigint LANGUAGE sql STABLE
AS $$ SELECT balance_kobo FROM oworail.wallet WHERE wallet_number = p_wallet_number $$;

INSERT INTO test_case (area, label, expected, test_sql, check_sql) VALUES
-- fee_for (BR-12) -------------------------------------------------------------
('fee_for', 'transfer of N5,000: top of band 1, flat N10', '2/1000',
 'SELECT 1', $c$SELECT pg_temp.fee('TRANSFER', 500000)$c$),
('fee_for', 'transfer of N5,000.01: band 2, flat N25', '3/2500',
 'SELECT 1', $c$SELECT pg_temp.fee('TRANSFER', 500001)$c$),
('fee_for', 'transfer of N100,000: band 3, flat N50', '4/5000',
 'SELECT 1', $c$SELECT pg_temp.fee('TRANSFER', 10000000)$c$),
('fee_for', 'same transfer in June 2026 uses the old rule 1', '1/500',
 'SELECT 1', $c$SELECT pg_temp.fee('TRANSFER', 500000, '2026-06-30 23:59:59+00')$c$),
('fee_for', 'rule 2 starts exactly at 1 July 00:00 UTC', '2/1000',
 'SELECT 1', $c$SELECT pg_temp.fee('TRANSFER', 500000, '2026-07-01 00:00:00+00')$c$),
('fee_for', 'bill of N12,000: 0.5 %', '5/6000',
 'SELECT 1', $c$SELECT pg_temp.fee('BILL_PAYMENT', 1200000)$c$),
('fee_for', 'bill of N50,000: 0.5 % = N250, capped at N100', '5/10000',
 'SELECT 1', $c$SELECT pg_temp.fee('BILL_PAYMENT', 5000000)$c$),
('fee_for', 'bill of 1999 kobo: 9.995 kobo rounds down', '5/9',
 'SELECT 1', $c$SELECT pg_temp.fee('BILL_PAYMENT', 1999)$c$),
('fee_for', 'merchant payment: no rule, free', 'none/0',
 'SELECT 1', $c$SELECT pg_temp.fee('MERCHANT_PAYMENT', 250000)$c$),
-- post_transaction: success and idempotency (BR-11, BR-13, BR-14) ---------------
('post_transaction', 'transfer moves amount + fee: sender / receiver / FEES', '1649000 / 150000 / 17000',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000001', '3000000002',
                            100000, 'APP', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT format('%s / %s / %s', pg_temp.bal('3000000001'), pg_temp.bal('3000000002'), pg_temp.bal('9000000001'))$c$),
('post_transaction', 'retry with the same idempotency key posts once', '1 transaction, sender 1649000',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000001', '3000000002',
                            100000, 'APP', p_at => '2026-11-05 10:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000001', '3000000002',
                            100000, 'APP', p_at => '2026-11-05 10:00:05+00')$t$,
 $c$SELECT format('%s transaction, sender %s',
               (SELECT count(*) FROM transaction WHERE idempotency_key = '00000000-0000-4000-8000-800000000001'),
               pg_temp.bal('3000000001'))$c$),
('post_transaction', 'retry of a seeded request returns the original transaction', 'true',
 'SELECT 1',
 $c$SELECT (post_transaction('00000000-0000-4000-8000-000000000101', 'TRANSFER', '3000000001', '3000000002',
                             500000, 'APP') = pg_temp.t('OWR000000000101'))::text$c$),
('post_transaction', 'generated reference follows the OWR format', 'true',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000001', '3000000002',
                            1000, 'APP', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT (transaction_ref ~ '^OWR[0-9]{12}$')::text FROM transaction
    WHERE idempotency_key = '00000000-0000-4000-8000-800000000001'$c$),
-- post_transaction: business refusals become FAILED (BR-04, BR-05, BR-07) -------
('post_transaction', 'insufficient funds', 'FAILED | insufficient funds | 0 lines',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000002', '3000000001',
                            100000, 'APP', p_transaction_ref => 'OWR800000000001', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT pg_temp.outcome('OWR800000000001')$c$),
('post_transaction', 'Tier 1 single-transaction limit (N50,000)', 'FAILED | single transaction limit exceeded | 0 lines',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000002', '3000000001',
                            6000000, 'APP', p_transaction_ref => 'OWR800000000001', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT pg_temp.outcome('OWR800000000001')$c$),
('post_transaction', 'Tier 2 daily limit (N200,000) on the third transfer of the day', 'FAILED | daily limit exceeded | 0 lines',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'WALLET_FUNDING', '9000000002', '3000000001',
                            25000000, 'APP', p_at => '2026-11-05 08:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000002', 'TRANSFER', '3000000001', '3000000003',
                            9000000, 'APP', p_at => '2026-11-05 09:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000003', 'TRANSFER', '3000000001', '3000000003',
                            9000000, 'APP', p_at => '2026-11-05 10:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000004', 'TRANSFER', '3000000001', '3000000003',
                            2000000, 'APP', p_transaction_ref => 'OWR800000000004', p_at => '2026-11-05 11:00:00+00')$t$,
 $c$SELECT pg_temp.outcome('OWR800000000004')$c$),
('post_transaction', 'the daily limit resets the next UTC day', 'SUCCESSFUL | - | 3 lines',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'WALLET_FUNDING', '9000000002', '3000000001',
                            25000000, 'APP', p_at => '2026-11-05 08:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000002', 'TRANSFER', '3000000001', '3000000003',
                            9000000, 'APP', p_at => '2026-11-05 09:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000003', 'TRANSFER', '3000000001', '3000000003',
                            9000000, 'APP', p_at => '2026-11-05 10:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000004', 'TRANSFER', '3000000001', '3000000003',
                            2000000, 'APP', p_transaction_ref => 'OWR800000000004', p_at => '2026-11-06 00:00:01+00')$t$,
 $c$SELECT pg_temp.outcome('OWR800000000004')$c$),
('post_transaction', 'Tier 1 receiver maximum balance (N300,000)', 'FAILED | receiver maximum balance exceeded | 0 lines',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'WALLET_FUNDING', '9000000002', '3000000002',
                            31000000, 'APP', p_transaction_ref => 'OWR800000000001', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT pg_temp.outcome('OWR800000000001')$c$),
('post_transaction', 'frozen sender', 'FAILED | source wallet is FROZEN | 0 lines',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000005', '3000000001',
                            1000, 'APP', p_transaction_ref => 'OWR800000000001', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT pg_temp.outcome('OWR800000000001')$c$),
('post_transaction', 'unverified KYC is held to Tier 1 limits', 'FAILED | single transaction limit exceeded | 0 lines',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'WALLET_FUNDING', '9000000002', '3000000004',
                            6000000, 'APP', p_at => '2026-11-05 09:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000002', 'TRANSFER', '3000000004', '3000000001',
                            5500000, 'APP', p_transaction_ref => 'OWR800000000002', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT pg_temp.outcome('OWR800000000002')$c$),
-- post_transaction: invalid requests raise and leave nothing (BR-10) ------------
('post_transaction', 'merchant payment to a biller', 'error P0001: MERCHANT_PAYMENT from wallet 3000000001%not allowed (BR-10)',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'MERCHANT_PAYMENT', '3000000001', '3000000101',
                            1000, 'APP')$t$, NULL),
('post_transaction', 'bill payment to an ordinary merchant', 'error P0001: BILL_PAYMENT from wallet 3000000001%not allowed (BR-10)',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'BILL_PAYMENT', '3000000001', '3000000042',
                            1000, 'APP', p_bill_reference => 'X-1')$t$, NULL),
('post_transaction', 'transfer out of a merchant wallet', 'error P0001: TRANSFER from wallet 3000000042%not allowed (BR-10)',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000042', '3000000001',
                            1000, 'APP')$t$, NULL),
('post_transaction', 'funding from a wallet other than SETTLEMENT', 'error P0001: WALLET_FUNDING from wallet 9000000001%not allowed (BR-10)',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'WALLET_FUNDING', '9000000001', '3000000001',
                            1000, 'APP')$t$, NULL),
('post_transaction', 'unknown destination wallet', 'error P0001: unknown destination wallet 3999999999',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000001', '3999999999',
                            1000, 'APP')$t$, NULL),
('post_transaction', 'reversal through post_transaction', 'error P0001: post_transaction cannot post REVERSAL%',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'REVERSAL', '3000000002', '3000000001',
                            1000, 'WEB')$t$, NULL),
-- reverse_transaction (BR-16) -------------------------------------------------
('reverse_transaction', 'reversing a merchant payment: original / buyer / merchant / audit rows', 'REVERSED / 2000000 / 0 / 2',
 $t$SELECT reverse_transaction('OWR000000000102', 'goods not delivered', 'support.test',
                               '00000000-0000-4000-8000-800000000001', p_at => '2026-11-05 10:00:00+00')$t$,
 $c$SELECT format('%s / %s / %s / %s',
               (SELECT status FROM transaction WHERE transaction_ref = 'OWR000000000102'),
               pg_temp.bal('3000000001'), pg_temp.bal('3000000042'),
               (SELECT count(*) FROM audit_log WHERE action = 'TXN_REVERSED'))$c$),
('reverse_transaction', 'retrying a reversal returns the existing one', 'true',
 'SELECT 1',
 $c$SELECT (reverse_transaction('OWR000000000101', 'duplicate transfer reported by customer', 'support.ifeoma',
                                '00000000-0000-4000-8000-000000000104') = pg_temp.t('OWR000000000104'))::text$c$),
('reverse_transaction', 'a FAILED transaction cannot be reversed', 'error P0001: only a SUCCESSFUL transaction can be reversed; OWR000000000103 is FAILED%',
 $t$SELECT reverse_transaction('OWR000000000103', 'test', 'support.test', '00000000-0000-4000-8000-800000000001')$t$, NULL),
('reverse_transaction', 'a transaction is reversed at most once', 'error P0001: only a SUCCESSFUL transaction can be reversed; OWR000000000101 is REVERSED%',
 $t$SELECT reverse_transaction('OWR000000000101', 'again', 'support.test', '00000000-0000-4000-8000-800000000001')$t$, NULL),
('reverse_transaction', 'a reversal cannot itself be reversed', 'error P0001: transaction OWR000000000104 is itself a reversal%',
 $t$SELECT reverse_transaction('OWR000000000104', 'test', 'support.test', '00000000-0000-4000-8000-800000000001')$t$, NULL),
('reverse_transaction', 'receiver has already spent the money', 'error P0001: cannot reverse OWR800000000001: wallet 3000000002 no longer holds the funds',
 $t$SELECT post_transaction('00000000-0000-4000-8000-800000000001', 'TRANSFER', '3000000001', '3000000002',
                            1000000, 'APP', p_transaction_ref => 'OWR800000000001', p_at => '2026-11-05 10:00:00+00');
    SELECT post_transaction('00000000-0000-4000-8000-800000000002', 'MERCHANT_PAYMENT', '3000000002', '3000000042',
                            900000, 'APP', p_at => '2026-11-05 11:00:00+00');
    SELECT reverse_transaction('OWR800000000001', 'test', 'support.test', '00000000-0000-4000-8000-800000000003')$t$, NULL),
-- onboarding and KYC (BR-02, BR-03, BR-06, BR-17) -------------------------------
('onboarding', 'customer created with phones and wallet; email stored in lower case', 'mixed.case@example.com / 2 phones / 1 wallet',
 $t$SELECT onboard_customer('Mixed Case', 'Mixed.Case@Example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos',
                            ARRAY['+2348099999998', '+2348099999999'], '3000000999')$t$,
 $c$SELECT format('%s / %s phones / %s wallet', c.email,
               (SELECT count(*) FROM customer_phone p WHERE p.customer_id = c.customer_id),
               (SELECT count(*) FROM wallet w WHERE w.customer_id = c.customer_id))
    FROM customer c WHERE c.full_name = 'Mixed Case'$c$),
('onboarding', 'no phone number', 'error P0001: a customer needs at least one phone number (BR-02)',
 $t$SELECT onboard_customer('No Phone', 'no.phone@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos',
                            ARRAY[]::text[], '3000000999')$t$, NULL),
('onboarding', 'bad wallet number rolls back the customer and phones too', '0 customers, 0 phones',
 $t$DO $d$ BEGIN
        PERFORM oworail.onboard_customer('Atomic Test', 'atomic.test@example.com', '1990-01-01', '1 Test St',
                                         'Ikeja', 'Lagos', ARRAY['+2348099999997'], '123');
    EXCEPTION WHEN check_violation THEN NULL;   -- chk_wallet_number_format
    END $d$$t$,
 $c$SELECT format('%s customers, %s phones',
               (SELECT count(*) FROM customer WHERE email = 'atomic.test@example.com'),
               (SELECT count(*) FROM customer_phone WHERE phone_number = '+2348099999997'))$c$),
('onboarding', 'merchant created with its single wallet', 'MERCHANT wallet 3000000999',
 $t$SELECT onboard_merchant('MRC00999', 'Test Pharmacy', 'MERCHANT', 'HEALTH', '3000000999')$t$,
 $c$SELECT w.wallet_type || ' wallet ' || w.wallet_number FROM wallet w JOIN merchant m USING (merchant_id)
    WHERE m.merchant_code = 'MRC00999'$c$),
('kyc', 'verification sets tier, reviewer and an audit record', 'VERIFIED / tier 2 / compliance.test / KYC_VERIFIED by compliance.test',
 $t$SELECT review_kyc(pg_temp.c('ibrahim.musa@example.com'), 'VERIFIED', 2::smallint, 'compliance.test')$t$,
 $c$SELECT format('%s / tier %s / %s / %s by %s', k.verification_status, k.tier_level, k.verified_by, a.action, a.actor)
    FROM kyc_profile k
    JOIN audit_log a ON a.target_type = 'kyc_profile' AND a.target_id = k.kyc_profile_id::text
                    AND a.action = 'KYC_VERIFIED'
    WHERE k.customer_id = pg_temp.c('ibrahim.musa@example.com')$c$),
('kyc', 'rejection keeps the current tier', 'REJECTED / tier 1',
 $t$SELECT review_kyc(pg_temp.c('ibrahim.musa@example.com'), 'REJECTED', 3::smallint, 'compliance.test')$t$,
 $c$SELECT format('%s / tier %s', verification_status, tier_level) FROM kyc_profile
    WHERE customer_id = pg_temp.c('ibrahim.musa@example.com')$c$),
('kyc', 'unknown decision', 'error P0001: a KYC decision is VERIFIED or REJECTED, not MAYBE',
 $t$SELECT review_kyc(pg_temp.c('ibrahim.musa@example.com'), 'MAYBE', 2::smallint, 'compliance.test')$t$, NULL),
('kyc', 'audit log keeps no national ID number', '0',
 'SELECT 1',
 $c$SELECT count(*)::text FROM audit_log a JOIN kyc_profile k ON a.details::text LIKE '%' || k.national_id_number || '%'$c$);

\ir _run.sql
