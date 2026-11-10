-- Constraint tests: every named constraint in schema.md is violated on purpose
-- at least once, and the database must reject the change with exactly that
-- constraint's name. A few valid changes are included to show the rules don't
-- over-reject. The ledger triggers, the append-only triggers and the
-- ON DELETE rules are tested the same way.
--
-- Each test runs in a subtransaction that is always rolled back, so the
-- database is unchanged afterwards (consistency_checks.sql confirms this).
--
--   docker compose exec -T postgres psql -U postgres -d oworail -X \
--       -v ON_ERROR_STOP=1 -f /workspace/portfolio-1-database-design/sql/tests/constraint_tests.sql

\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
\ir _harness.sql

INSERT INTO test_case (area, label, expected, test_sql, check_sql) VALUES
-- customer --------------------------------------------------------------------
('customer', 'blank full name', 'chk_customer_full_name_not_blank',
 $t$INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state)
    VALUES ('   ', 'test.person@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos')$t$, NULL),
('customer', 'email with capitals', 'chk_customer_email_format',
 $t$INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state)
    VALUES ('Test Person', 'Test.Person@Example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos')$t$, NULL),
('customer', 'duplicate email', 'uq_customer_email',
 $t$INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state)
    VALUES ('Test Person', 'adaeze.okafor@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos')$t$, NULL),
('customer', 'unknown status', 'chk_customer_status',
 $t$INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state, status)
    VALUES ('Test Person', 'test.person@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos', 'DELETED')$t$, NULL),
('customer', 'under 18 at onboarding', 'chk_customer_adult_at_onboarding',
 $t$INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state, created_at)
    VALUES ('Test Person', 'test.person@example.com', '2010-05-01', '1 Test St', 'Ikeja', 'Lagos', '2026-11-01')$t$, NULL),
('customer', 'missing email', 'not null: customer.email',
 $t$INSERT INTO customer (full_name, date_of_birth, address_street, address_city, address_state)
    VALUES ('Test Person', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos')$t$, NULL),
('customer', 'application supplies its own key', 'error 428C9%',
 $t$INSERT INTO customer (customer_id, full_name, email, date_of_birth, address_street, address_city, address_state)
    VALUES (500, 'Test Person', 'test.person@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos')$t$, NULL),
('customer', 'valid customer is accepted', 'NO ERROR',
 $t$INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state)
    VALUES ('Test Person', 'test.person@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos')$t$, NULL),
-- customer_phone --------------------------------------------------------------
('customer_phone', 'number already belongs to another customer', 'pk_customer_phone',
 $t$INSERT INTO customer_phone VALUES ('+2348030000001', pg_temp.c('tunde.bakare@example.com'))$t$, NULL),
('customer_phone', 'not a Nigerian mobile number in E.164', 'chk_customer_phone_format',
 $t$INSERT INTO customer_phone VALUES ('08030000009', pg_temp.c('tunde.bakare@example.com'))$t$, NULL),
('customer_phone', 'unknown customer', 'fk_customer_phone_customer',
 $t$INSERT INTO customer_phone VALUES ('+2348030000009', 999999)$t$, NULL),
-- kyc_tier --------------------------------------------------------------------
('kyc_tier', 'duplicate tier level', 'pk_kyc_tier',
 $t$INSERT INTO kyc_tier VALUES (2, 'Tier 2: other', 100, 100, NULL)$t$, NULL),
('kyc_tier', 'duplicate tier name', 'uq_kyc_tier_name',
 $t$UPDATE kyc_tier SET tier_name = 'Tier 1: basic' WHERE tier_level = 2$t$, NULL),
('kyc_tier', 'tier 4 does not exist', 'chk_kyc_tier_level',
 $t$INSERT INTO kyc_tier VALUES (4, 'Tier 4: premium', 100, 100, NULL)$t$, NULL),
('kyc_tier', 'zero single-transaction limit', 'chk_kyc_tier_single_limit_positive',
 $t$UPDATE kyc_tier SET single_txn_limit_kobo = 0 WHERE tier_level = 1$t$, NULL),
('kyc_tier', 'daily limit below single limit', 'chk_kyc_tier_daily_ge_single',
 $t$UPDATE kyc_tier SET daily_limit_kobo = 1000 WHERE tier_level = 1$t$, NULL),
('kyc_tier', 'zero maximum balance', 'chk_kyc_tier_max_balance_positive',
 $t$UPDATE kyc_tier SET max_balance_kobo = 0 WHERE tier_level = 1$t$, NULL),
-- kyc_profile -----------------------------------------------------------------
('kyc_profile', 'second profile for a customer', 'uq_kyc_profile_customer',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number)
    VALUES (pg_temp.c('adaeze.okafor@example.com'), 'NIN', '99900000099')$t$, NULL),
('kyc_profile', 'BVN already registered', 'uq_kyc_profile_national_id',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 'BVN', '99900000001')$t$, NULL),
('kyc_profile', 'same digits as a BVN but as a NIN (separate scheme)', 'NO ERROR',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 'NIN', '99900000001')$t$, NULL),
('kyc_profile', 'unknown customer', 'fk_kyc_profile_customer',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number)
    VALUES (999999, 'NIN', '99900000099')$t$, NULL),
('kyc_profile', 'unknown tier', 'fk_kyc_profile_tier',
 $t$INSERT INTO kyc_profile (customer_id, tier_level, id_type, national_id_number)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 4, 'NIN', '99900000099')$t$, NULL),
('kyc_profile', 'unsupported ID type', 'chk_kyc_profile_id_type',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 'PASSPORT', '99900000099')$t$, NULL),
('kyc_profile', 'real-looking (non-synthetic) BVN', 'chk_kyc_profile_synthetic_id',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 'BVN', '22212345678')$t$, NULL),
('kyc_profile', 'unknown verification status', 'chk_kyc_profile_verification_status',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number, verification_status, verified_at, verified_by)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 'NIN', '99900000099', 'APPROVED', now(), 'compliance.test')$t$, NULL),
('kyc_profile', 'review time without reviewer', 'chk_kyc_profile_reviewer_pair',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number, verification_status, verified_at)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 'NIN', '99900000099', 'VERIFIED', now())$t$, NULL),
('kyc_profile', 'VERIFIED with no review recorded', 'chk_kyc_profile_decision_recorded',
 $t$INSERT INTO kyc_profile (customer_id, id_type, national_id_number, verification_status)
    VALUES (pg_temp.c('funmilayo.adeyemi@example.com'), 'NIN', '99900000099', 'VERIFIED')$t$, NULL),
-- merchant --------------------------------------------------------------------
('merchant', 'duplicate merchant code', 'uq_merchant_code',
 $t$INSERT INTO merchant (merchant_code, business_name, merchant_type, category)
    VALUES ('MRC00042', 'Test Shop', 'MERCHANT', 'RETAIL')$t$, NULL),
('merchant', 'badly formed merchant code', 'chk_merchant_code_format',
 $t$INSERT INTO merchant (merchant_code, business_name, merchant_type, category)
    VALUES ('M42', 'Test Shop', 'MERCHANT', 'RETAIL')$t$, NULL),
('merchant', 'blank business name', 'chk_merchant_business_name_not_blank',
 $t$INSERT INTO merchant (merchant_code, business_name, merchant_type, category)
    VALUES ('MRC00999', ' ', 'MERCHANT', 'RETAIL')$t$, NULL),
('merchant', 'unknown merchant type', 'chk_merchant_type',
 $t$INSERT INTO merchant (merchant_code, business_name, merchant_type, category)
    VALUES ('MRC00999', 'Test Shop', 'AGENT', 'RETAIL')$t$, NULL),
('merchant', 'unknown category', 'chk_merchant_category',
 $t$INSERT INTO merchant (merchant_code, business_name, merchant_type, category)
    VALUES ('MRC00999', 'Test Shop', 'MERCHANT', 'GAMBLING')$t$, NULL),
('merchant', 'CLOSED is not a merchant status', 'chk_merchant_status',
 $t$UPDATE merchant SET status = 'CLOSED' WHERE merchant_code = 'MRC00042'$t$, NULL),
-- wallet ----------------------------------------------------------------------
('wallet', 'duplicate wallet number', 'uq_wallet_number',
 $t$INSERT INTO wallet (wallet_number, wallet_type, customer_id)
    VALUES ('3000000001', 'CUSTOMER', pg_temp.c('funmilayo.adeyemi@example.com'))$t$, NULL),
('wallet', 'second wallet for a merchant', 'uq_wallet_merchant',
 $t$INSERT INTO wallet (wallet_number, wallet_type, merchant_id)
    VALUES ('3000000998', 'MERCHANT', pg_temp.m('MRC00042'))$t$, NULL),
('wallet', 'second FEES wallet', 'uq_wallet_system_purpose',
 $t$INSERT INTO wallet (wallet_number, wallet_type, system_purpose)
    VALUES ('9000000009', 'SYSTEM', 'FEES')$t$, NULL),
('wallet', 'second wallet for a customer (allowed)', 'NO ERROR',
 $t$INSERT INTO wallet (wallet_number, wallet_type, customer_id)
    VALUES ('3000000999', 'CUSTOMER', pg_temp.c('adaeze.okafor@example.com'))$t$, NULL),
('wallet', 'unknown customer', 'fk_wallet_customer',
 $t$INSERT INTO wallet (wallet_number, wallet_type, customer_id) VALUES ('3000000999', 'CUSTOMER', 999999)$t$, NULL),
('wallet', 'unknown merchant', 'fk_wallet_merchant',
 $t$INSERT INTO wallet (wallet_number, wallet_type, merchant_id) VALUES ('3000000999', 'MERCHANT', 999999)$t$, NULL),
('wallet', 'wallet number not 10 digits', 'chk_wallet_number_format',
 $t$INSERT INTO wallet (wallet_number, wallet_type, customer_id)
    VALUES ('30000', 'CUSTOMER', pg_temp.c('funmilayo.adeyemi@example.com'))$t$, NULL),
-- An unknown type also breaks the owner arc, and PostgreSQL checks CHECK
-- constraints in name order, so it reports the arc first. The second test
-- sets the arc aside (inside the rolled-back test) to show chk_wallet_type alone.
('wallet', 'unknown wallet type (arc check reported first)', 'chk_wallet_owner_matches_type',
 $t$INSERT INTO wallet (wallet_number, wallet_type, customer_id)
    VALUES ('3000000999', 'SAVINGS', pg_temp.c('funmilayo.adeyemi@example.com'))$t$, NULL),
('wallet', 'unknown wallet type, arc check set aside', 'chk_wallet_type',
 $t$ALTER TABLE wallet DROP CONSTRAINT chk_wallet_owner_matches_type;
    INSERT INTO wallet (wallet_number, wallet_type, customer_id)
    VALUES ('3000000999', 'SAVINGS', pg_temp.c('funmilayo.adeyemi@example.com'))$t$, NULL),
('wallet', 'unknown system purpose', 'chk_wallet_system_purpose',
 $t$INSERT INTO wallet (wallet_number, wallet_type, system_purpose) VALUES ('9000000009', 'SYSTEM', 'PAYROLL')$t$, NULL),
('wallet', 'foreign currency', 'chk_wallet_currency',
 $t$INSERT INTO wallet (wallet_number, wallet_type, customer_id, currency)
    VALUES ('3000000999', 'CUSTOMER', pg_temp.c('funmilayo.adeyemi@example.com'), 'USD')$t$, NULL),
('wallet', 'customer balance below zero', 'chk_wallet_balance_non_negative',
 $t$UPDATE wallet SET balance_kobo = -1 WHERE wallet_number = '3000000002'$t$, NULL),
('wallet', 'system balance below zero (allowed)', 'NO ERROR',
 $t$UPDATE wallet SET balance_kobo = -1 WHERE wallet_number = '9000000003'$t$, NULL),
('wallet', 'unknown wallet status', 'chk_wallet_status',
 $t$UPDATE wallet SET status = 'DORMANT' WHERE wallet_number = '3000000002'$t$, NULL),
('wallet', 'CUSTOMER wallet with no customer', 'chk_wallet_owner_matches_type',
 $t$INSERT INTO wallet (wallet_number, wallet_type) VALUES ('3000000999', 'CUSTOMER')$t$, NULL),
('wallet', 'SYSTEM wallet that also names a customer', 'chk_wallet_owner_matches_type',
 $t$INSERT INTO wallet (wallet_number, wallet_type, system_purpose, customer_id)
    VALUES ('9000000009', 'SYSTEM', 'SUSPENSE', pg_temp.c('funmilayo.adeyemi@example.com'))$t$, NULL),
-- saved_beneficiary -----------------------------------------------------------
('saved_beneficiary', 'same wallet saved twice', 'pk_saved_beneficiary',
 $t$INSERT INTO saved_beneficiary (customer_id, wallet_id, nickname)
    VALUES (pg_temp.c('adaeze.okafor@example.com'), pg_temp.w('3000000002'), 'Tunde again')$t$, NULL),
('saved_beneficiary', 'unknown customer', 'fk_saved_beneficiary_customer',
 $t$INSERT INTO saved_beneficiary (customer_id, wallet_id, nickname) VALUES (999999, pg_temp.w('3000000002'), 'X')$t$, NULL),
('saved_beneficiary', 'unknown wallet', 'fk_saved_beneficiary_wallet',
 $t$INSERT INTO saved_beneficiary (customer_id, wallet_id, nickname)
    VALUES (pg_temp.c('tunde.bakare@example.com'), 999999, 'X')$t$, NULL),
('saved_beneficiary', 'nickname longer than 40 characters', 'chk_saved_beneficiary_nickname_length',
 $t$INSERT INTO saved_beneficiary (customer_id, wallet_id, nickname)
    VALUES (pg_temp.c('tunde.bakare@example.com'), pg_temp.w('3000000001'), repeat('x', 41))$t$, NULL),
-- fee_rule --------------------------------------------------------------------
('fee_rule', 'fee rule for reversals', 'chk_fee_rule_transaction_type',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, effective_from) VALUES ('REVERSAL', 1, '2026-01-01')$t$, NULL),
('fee_rule', 'band starting at zero', 'chk_fee_rule_min_positive',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, effective_from) VALUES ('WALLET_FUNDING', 0, '2026-01-01')$t$, NULL),
('fee_rule', 'band maximum below minimum', 'chk_fee_rule_band',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, max_amount_kobo, effective_from)
    VALUES ('WALLET_FUNDING', 1000, 500, '2026-01-01')$t$, NULL),
('fee_rule', 'negative flat fee', 'chk_fee_rule_flat_non_negative',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, flat_fee_kobo, effective_from)
    VALUES ('WALLET_FUNDING', 1, -1, '2026-01-01')$t$, NULL),
('fee_rule', 'percentage over 100 %', 'chk_fee_rule_percent_bps',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, percent_bps, effective_from)
    VALUES ('WALLET_FUNDING', 1, 10001, '2026-01-01')$t$, NULL),
('fee_rule', 'cap below the flat fee', 'chk_fee_rule_cap',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, flat_fee_kobo, cap_kobo, effective_from)
    VALUES ('WALLET_FUNDING', 1, 1000, 500, '2026-01-01')$t$, NULL),
('fee_rule', 'period ends before it starts', 'chk_fee_rule_period',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, effective_from, effective_to)
    VALUES ('WALLET_FUNDING', 1, '2026-06-01', '2026-01-01')$t$, NULL),
('fee_rule', 'new transfer band overlapping current rules', 'excl_fee_rule_no_overlap',
 $t$INSERT INTO fee_rule (transaction_type, min_amount_kobo, max_amount_kobo, flat_fee_kobo, effective_from)
    VALUES ('TRANSFER', 400000, 600000, 2000, '2026-08-01')$t$, NULL),
('fee_rule', 'rule 2 closed and replaced from 2027 (no overlap)', 'NO ERROR',
 $t$UPDATE fee_rule SET effective_to = '2027-01-01' WHERE fee_rule_id = 2;
    INSERT INTO fee_rule (transaction_type, min_amount_kobo, max_amount_kobo, flat_fee_kobo, effective_from)
    VALUES ('TRANSFER', 1, 500000, 1500, '2027-01-01')$t$, NULL),
-- transaction -----------------------------------------------------------------
('transaction', 'duplicate transaction reference', 'uq_transaction_ref',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR000000000101', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'APP')$t$, NULL),
('transaction', 'duplicate idempotency key (retried request)', 'uq_transaction_idempotency_key',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-000000000101', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'APP')$t$, NULL),
('transaction', 'unknown source wallet', 'fk_transaction_source_wallet',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            999999, pg_temp.w('3000000002'), 1000, 'APP')$t$, NULL),
('transaction', 'unknown destination wallet', 'fk_transaction_destination_wallet',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), 999999, 1000, 'APP')$t$, NULL),
('transaction', 'unknown fee rule', 'fk_transaction_fee_rule',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, fee_kobo, fee_rule_id, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 100, 999, 'APP')$t$, NULL),
('transaction', 'badly formed reference', 'chk_transaction_ref_format',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('TXN1', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'APP')$t$, NULL),
('transaction', 'unknown transaction type', 'chk_transaction_type',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'LOAN',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'APP')$t$, NULL),
('transaction', 'zero amount', 'chk_transaction_amount_positive',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 0, 'APP')$t$, NULL),
('transaction', 'negative fee', 'chk_transaction_fee_non_negative',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, fee_kobo, fee_rule_id, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, -1, 2, 'APP')$t$, NULL),
('transaction', 'unknown status', 'chk_transaction_status',
 $t$UPDATE transaction SET status = 'DONE' WHERE transaction_ref = 'OWR000000000102'$t$, NULL),
('transaction', 'unknown channel', 'chk_transaction_channel',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'POS')$t$, NULL),
('transaction', 'narration over 100 characters', 'chk_transaction_narration_length',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel, narration)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'APP', repeat('x', 101))$t$, NULL),
('transaction', 'sending to the same wallet', 'chk_transaction_distinct_wallets',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000001'), 1000, 'APP')$t$, NULL),
('transaction', 'bill payment without bill reference', 'chk_transaction_bill_reference',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'BILL_PAYMENT',
            pg_temp.w('3000000001'), pg_temp.w('3000000101'), 1000, 'APP')$t$, NULL),
('transaction', 'transfer carrying a bill reference', 'chk_transaction_bill_reference',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, channel, bill_reference)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'APP', 'SVC-1')$t$, NULL),
('transaction', 'fee charged without a fee rule', 'chk_transaction_fee_has_rule',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, fee_kobo, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 1000, 'APP')$t$, NULL),
('transaction', 'reversal charged a fee', 'chk_transaction_reversal_no_fee',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, fee_kobo, fee_rule_id, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'REVERSAL',
            pg_temp.w('3000000002'), pg_temp.w('3000000001'), 1000, 1000, 2, 'WEB')$t$, NULL),
('transaction', 'missing channel', 'not null: transaction.channel',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000)$t$, NULL),
-- ledger_entry ----------------------------------------------------------------
('ledger_entry', 'duplicate line number', 'pk_ledger_entry',
 $t$INSERT INTO ledger_entry VALUES (pg_temp.t('OWR000000000101'), 1, pg_temp.w('9000000001'), 'CREDIT', 1)$t$, NULL),
('ledger_entry', 'unknown transaction', 'fk_ledger_entry_transaction',
 $t$INSERT INTO ledger_entry VALUES (999999, 1, pg_temp.w('9000000001'), 'CREDIT', 1)$t$, NULL),
('ledger_entry', 'unknown wallet', 'fk_ledger_entry_wallet',
 $t$INSERT INTO ledger_entry VALUES (pg_temp.t('OWR000000000102'), 3, 999999, 'CREDIT', 1)$t$, NULL),
('ledger_entry', 'line number zero', 'chk_ledger_entry_line_no',
 $t$INSERT INTO ledger_entry VALUES (pg_temp.t('OWR000000000102'), 0, pg_temp.w('9000000001'), 'CREDIT', 1)$t$, NULL),
('ledger_entry', 'entry type other than DEBIT/CREDIT', 'chk_ledger_entry_type',
 $t$INSERT INTO ledger_entry VALUES (pg_temp.t('OWR000000000102'), 3, pg_temp.w('9000000001'), 'DR', 1)$t$, NULL),
('ledger_entry', 'negative amount', 'chk_ledger_entry_amount_positive',
 $t$INSERT INTO ledger_entry VALUES (pg_temp.t('OWR000000000102'), 3, pg_temp.w('9000000001'), 'CREDIT', -5)$t$, NULL),
-- transaction_status_history --------------------------------------------------
('transaction_status_history', 'duplicate sequence number', 'pk_transaction_status_history',
 $t$INSERT INTO transaction_status_history (transaction_id, seq_no, status)
    VALUES (pg_temp.t('OWR000000000101'), 1, 'PENDING')$t$, NULL),
('transaction_status_history', 'unknown transaction', 'fk_transaction_status_history_transaction',
 $t$INSERT INTO transaction_status_history (transaction_id, seq_no, status) VALUES (999999, 1, 'PENDING')$t$, NULL),
('transaction_status_history', 'sequence number zero', 'chk_transaction_status_history_seq_no',
 $t$INSERT INTO transaction_status_history (transaction_id, seq_no, status)
    VALUES (pg_temp.t('OWR000000000102'), 0, 'PENDING')$t$, NULL),
('transaction_status_history', 'unknown status', 'chk_transaction_status_history_status',
 $t$INSERT INTO transaction_status_history (transaction_id, seq_no, status)
    VALUES (pg_temp.t('OWR000000000102'), 3, 'CANCELLED')$t$, NULL),
-- reversal --------------------------------------------------------------------
('reversal', 'transaction reversed a second time', 'pk_reversal',
 $t$INSERT INTO reversal VALUES (pg_temp.t('OWR000000000101'), pg_temp.t('OWR000000000108'), 'again', 'support.test')$t$, NULL),
('reversal', 'one reversal used for two originals', 'uq_reversal_reversal_transaction',
 $t$INSERT INTO reversal VALUES (pg_temp.t('OWR000000000102'), pg_temp.t('OWR000000000104'), 'reuse', 'support.test')$t$, NULL),
('reversal', 'unknown original transaction', 'fk_reversal_original_transaction',
 $t$INSERT INTO reversal VALUES (999999, pg_temp.t('OWR000000000108'), 'test', 'support.test')$t$, NULL),
('reversal', 'unknown reversal transaction', 'fk_reversal_reversal_transaction',
 $t$INSERT INTO reversal VALUES (pg_temp.t('OWR000000000102'), 999999, 'test', 'support.test')$t$, NULL),
('reversal', 'blank reason', 'chk_reversal_reason_not_blank',
 $t$INSERT INTO reversal VALUES (pg_temp.t('OWR000000000102'), pg_temp.t('OWR000000000108'), '  ', 'support.test')$t$, NULL),
('reversal', 'transaction reversing itself', 'chk_reversal_not_self',
 $t$INSERT INTO reversal VALUES (pg_temp.t('OWR000000000102'), pg_temp.t('OWR000000000102'), 'test', 'support.test')$t$, NULL),
-- audit_log -------------------------------------------------------------------
('audit_log', 'action not in UPPER_SNAKE_CASE', 'chk_audit_log_action_format',
 $t$INSERT INTO audit_log (action, target_type, target_id) VALUES ('kyc verified', 'kyc_profile', '1')$t$, NULL),
('audit_log', 'unknown target type', 'chk_audit_log_target_type',
 $t$INSERT INTO audit_log (action, target_type, target_id) VALUES ('TEST_EVENT', 'ledger_entry', '1')$t$, NULL),
('audit_log', 'valid event records the database role as actor', 'postgres',
 $t$INSERT INTO audit_log (action, target_type, target_id) VALUES ('TEST_EVENT', 'customer', '1')$t$,
 $c$SELECT actor FROM audit_log ORDER BY audit_id DESC LIMIT 1$c$),
-- balanced double entry (deferred constraint triggers) --------------------------
-- SET CONSTRAINTS ... IMMEDIATE runs the deferred check now instead of at COMMIT.
('ledger trigger', 'extra line makes a posted transaction unbalanced', 'trg_ledger_entry_balanced',
 $t$INSERT INTO ledger_entry VALUES (pg_temp.t('OWR000000000102'), 3, pg_temp.w('9000000001'), 'CREDIT', 1);
    SET CONSTRAINTS trg_ledger_entry_balanced IMMEDIATE$t$, NULL),
('ledger trigger', 'ledger lines on a FAILED transaction', 'trg_ledger_entry_balanced',
 $t$INSERT INTO ledger_entry VALUES (pg_temp.t('OWR000000000103'), 1, pg_temp.w('3000000002'), 'DEBIT', 100),
                                    (pg_temp.t('OWR000000000103'), 2, pg_temp.w('3000000001'), 'CREDIT', 100);
    SET CONSTRAINTS ALL IMMEDIATE$t$, NULL),
('ledger trigger', 'SUCCESSFUL transaction with no ledger lines', 'trg_transaction_balanced',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, status, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'SUCCESSFUL', 'APP');
    SET CONSTRAINTS ALL IMMEDIATE$t$, NULL),
('ledger trigger', 'FAILED transaction flipped to SUCCESSFUL without lines', 'trg_transaction_balanced',
 $t$UPDATE transaction SET status = 'SUCCESSFUL' WHERE transaction_ref = 'OWR000000000103';
    SET CONSTRAINTS ALL IMMEDIATE$t$, NULL),
('ledger trigger', 'balanced two-line posting is accepted', 'NO ERROR',
 $t$INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                             destination_wallet_id, amount_kobo, status, channel)
    VALUES ('OWR900000000001', '00000000-0000-4000-8000-900000000001', 'TRANSFER',
            pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'SUCCESSFUL', 'APP');
    INSERT INTO ledger_entry VALUES (pg_temp.t('OWR900000000001'), 1, pg_temp.w('3000000001'), 'DEBIT', 1000),
                                    (pg_temp.t('OWR900000000001'), 2, pg_temp.w('3000000002'), 'CREDIT', 1000);
    SET CONSTRAINTS ALL IMMEDIATE$t$, NULL),
-- append-only tables ------------------------------------------------------------
('append-only', 'edit a ledger amount', 'trg_ledger_entry_append_only',
 $t$UPDATE ledger_entry SET amount_kobo = amount_kobo + 1 WHERE transaction_id = pg_temp.t('OWR000000000102')$t$, NULL),
('append-only', 'delete ledger lines', 'trg_ledger_entry_append_only',
 $t$DELETE FROM ledger_entry WHERE transaction_id = pg_temp.t('OWR000000000101')$t$, NULL),
('append-only', 'truncate the ledger', 'trg_ledger_entry_no_truncate',
 $t$TRUNCATE ledger_entry$t$, NULL),
('append-only', 'rewrite a status-history reason', 'trg_transaction_status_history_append_only',
 $t$UPDATE transaction_status_history SET reason = 'edited' WHERE transaction_id = pg_temp.t('OWR000000000103')$t$, NULL),
('append-only', 'delete status history', 'trg_transaction_status_history_append_only',
 $t$DELETE FROM transaction_status_history WHERE transaction_id = pg_temp.t('OWR000000000103')$t$, NULL),
('append-only', 'truncate status history', 'trg_transaction_status_history_no_truncate',
 $t$TRUNCATE transaction_status_history$t$, NULL),
('append-only', 'change an audit record''s actor', 'trg_audit_log_append_only',
 $t$UPDATE audit_log SET actor = 'someone.else' WHERE action = 'TXN_REVERSED'$t$, NULL),
('append-only', 'delete audit records', 'trg_audit_log_append_only',
 $t$DELETE FROM audit_log$t$, NULL),
('append-only', 'truncate the audit log', 'trg_audit_log_no_truncate',
 $t$TRUNCATE audit_log$t$, NULL),
-- ON DELETE rules -------------------------------------------------------------
('on delete', 'delete a customer who has a wallet', 'fk_wallet_customer',
 $t$DELETE FROM customer WHERE email = 'funmilayo.adeyemi@example.com'$t$, NULL),
('on delete', 'delete a wallet that has transactions', 'fk_transaction_destination_wallet',
 $t$DELETE FROM wallet WHERE wallet_number = '3000000042'$t$, NULL),
('on delete', 'delete a merchant that has a wallet', 'fk_wallet_merchant',
 $t$DELETE FROM merchant WHERE merchant_code = 'MRC00042'$t$, NULL),
('on delete', 'delete a KYC tier in use', 'fk_kyc_profile_tier',
 $t$DELETE FROM kyc_tier WHERE tier_level = 1$t$, NULL),
('on delete', 'delete a fee rule used by transactions', 'fk_transaction_fee_rule',
 $t$DELETE FROM fee_rule WHERE fee_rule_id = 2$t$, NULL),
('on delete', 'delete a posted transaction', 'fk_ledger_entry_transaction',
 $t$DELETE FROM transaction WHERE transaction_ref = 'OWR000000000101'$t$, NULL),
('on delete', 'erasing a customer removes phones and beneficiaries (CASCADE)', 'phones=0 beneficiaries=0',
 $t$INSERT INTO customer (full_name, email, date_of_birth, address_street, address_city, address_state)
    VALUES ('Erasure Test', 'erasure.test@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos');
    INSERT INTO customer_phone VALUES ('+2348099999999', pg_temp.c('erasure.test@example.com'));
    INSERT INTO saved_beneficiary (customer_id, wallet_id, nickname)
    VALUES (pg_temp.c('erasure.test@example.com'), pg_temp.w('3000000001'), 'Ada');
    DELETE FROM customer WHERE email = 'erasure.test@example.com'$t$,
 $c$SELECT format('phones=%s beneficiaries=%s',
               (SELECT count(*) FROM customer_phone WHERE phone_number = '+2348099999999'),
               (SELECT count(*) FROM saved_beneficiary sb
                WHERE NOT EXISTS (SELECT 1 FROM customer c WHERE c.customer_id = sb.customer_id)))$c$);

\ir _run.sql

-- The deferred check at a real COMMIT: an unbalanced posting is accepted
-- statement by statement, then the whole transaction is rejected at COMMIT.
\echo
\echo '== deferred check at COMMIT (an error is expected here)'
\set ON_ERROR_STOP off
BEGIN;
INSERT INTO transaction (transaction_ref, idempotency_key, transaction_type, source_wallet_id,
                         destination_wallet_id, amount_kobo, status, channel)
VALUES ('OWR900000000002', '00000000-0000-4000-8000-900000000002', 'TRANSFER',
        pg_temp.w('3000000001'), pg_temp.w('3000000002'), 1000, 'SUCCESSFUL', 'APP');
INSERT INTO ledger_entry VALUES (pg_temp.t('OWR900000000002'), 1, pg_temp.w('3000000001'), 'DEBIT', 1000);
\echo '-- both inserts were accepted; now COMMIT:'
COMMIT;
\set ON_ERROR_STOP on
SELECT count(*) AS rows_left_behind FROM transaction WHERE transaction_ref = 'OWR900000000002';
