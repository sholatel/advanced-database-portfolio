-- Role tests (BR-18, least privilege): each role tries things it should be
-- able to do and things it must not. ALLOWED means the statement ran (and was
-- then rolled back); DENIED means PostgreSQL refused it with a privilege
-- error. Run as postgres; each test switches to the role with SET LOCAL ROLE.
--
--   docker compose exec -T postgres psql -U postgres -d oworail -X \
--       -v ON_ERROR_STOP=1 -f /workspace/portfolio-1-database-design/sql/tests/role_tests.sql

\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;
\ir _harness.sql

-- probe() returns 'NO ERROR' when a statement succeeds; call that ALLOWED
INSERT INTO test_case (area, as_role, label, expected, test_sql) VALUES
-- payments application ------------------------------------------------------
('app', 'oworail_app', 'read transactions',                     'ALLOWED', 'SELECT count(*) FROM oworail.transaction'),
('app', 'oworail_app', 'post a transfer through post_transaction', 'ALLOWED',
 $t$SELECT oworail.post_transaction('00000000-0000-4000-8000-700000000001', 'TRANSFER', '3000000001', '3000000002', 1000, 'APP')$t$),
('app', 'oworail_app', 'onboard a customer',                    'ALLOWED',
 $t$SELECT oworail.onboard_customer('Role Test', 'role.test@example.com', '1990-01-01', '1 Test St', 'Ikeja', 'Lagos',
                                    ARRAY['+2348099999996'], '3000000998')$t$),
('app', 'oworail_app', 'save a beneficiary',                    'ALLOWED',
 $t$INSERT INTO oworail.saved_beneficiary (customer_id, wallet_id, nickname)
    SELECT c.customer_id, w.wallet_id, 'Mama Put' FROM oworail.customer c, oworail.wallet w
    WHERE c.email = 'tunde.bakare@example.com' AND w.wallet_number = '3000000042'$t$),
('app', 'oworail_app', 'insert a ledger line directly',         'DENIED',
 'INSERT INTO oworail.ledger_entry VALUES (1, 9, 1, ''CREDIT'', 1)'),
('app', 'oworail_app', 'change a wallet balance directly',      'DENIED',
 'UPDATE oworail.wallet SET balance_kobo = balance_kobo + 100000 WHERE wallet_number = ''3000000002'''),
('app', 'oworail_app', 'change a transaction status directly',  'DENIED',
 'UPDATE oworail.transaction SET status = ''SUCCESSFUL'' WHERE transaction_ref = ''OWR000000000103'''),
('app', 'oworail_app', 'read KYC identity data',                'DENIED', 'SELECT national_id_number FROM oworail.kyc_profile'),
('app', 'oworail_app', 'read the audit log',                    'DENIED', 'SELECT count(*) FROM oworail.audit_log'),
('app', 'oworail_app', 'verify KYC (compliance only)',          'DENIED',
 $t$SELECT oworail.review_kyc(4, 'VERIFIED', 3::smallint, 'app.user')$t$),
('app', 'oworail_app', 'create a table (no DDL)',               'DENIED', 'CREATE TABLE oworail.scratch (i int)'),
-- customer support ------------------------------------------------------------
('support', 'oworail_support', 'find a customer by phone',      'ALLOWED',
 $t$SELECT c.full_name FROM oworail.customer c JOIN oworail.customer_phone p USING (customer_id)
    WHERE p.phone_number = '+2348030000001'$t$),
('support', 'oworail_support', 'view a wallet statement',       'ALLOWED',
 $t$SELECT * FROM oworail.ledger_entry l JOIN oworail.transaction t USING (transaction_id)
    WHERE l.wallet_id = 4 ORDER BY t.created_at DESC$t$),
('support', 'oworail_support', 'view balances through v_wallet_balance', 'ALLOWED', 'SELECT * FROM oworail.v_wallet_balance'),
('support', 'oworail_support', 'read KYC identity data',        'DENIED', 'SELECT * FROM oworail.kyc_profile'),
('support', 'oworail_support', 'read the audit log',            'DENIED', 'SELECT * FROM oworail.audit_log'),
('support', 'oworail_support', 'edit a customer''s email',      'DENIED',
 'UPDATE oworail.customer SET email = ''x@example.com'' WHERE customer_id = 1'),
('support', 'oworail_support', 'post a transaction',            'DENIED',
 $t$SELECT oworail.post_transaction('00000000-0000-4000-8000-700000000001', 'TRANSFER', '3000000001', '3000000002', 1000, 'WEB')$t$),
('support', 'oworail_support', 'reverse a transaction',         'DENIED',
 $t$SELECT oworail.reverse_transaction('OWR000000000102', 'test', 'support.test', '00000000-0000-4000-8000-700000000001')$t$),
-- compliance ------------------------------------------------------------------
('compliance', 'oworail_compliance', 'read KYC profiles',       'ALLOWED', 'SELECT * FROM oworail.kyc_profile'),
('compliance', 'oworail_compliance', 'verify a KYC profile',    'ALLOWED',
 $t$SELECT oworail.review_kyc((SELECT customer_id FROM oworail.customer WHERE email = 'ibrahim.musa@example.com'),
                              'VERIFIED', 2::smallint, 'compliance.test')$t$),
('compliance', 'oworail_compliance', 'edit a KYC profile directly', 'DENIED',
 'UPDATE oworail.kyc_profile SET tier_level = 3'),
('compliance', 'oworail_compliance', 'read transactions',       'DENIED', 'SELECT * FROM oworail.transaction'),
('compliance', 'oworail_compliance', 'read the audit log',      'DENIED', 'SELECT * FROM oworail.audit_log'),
-- fraud / finance analysts ----------------------------------------------------
('analyst', 'oworail_analyst', 'velocity check over transactions', 'ALLOWED',
 $t$SELECT source_wallet_id, count(*) FROM oworail.transaction
    WHERE created_at >= '2026-11-02' GROUP BY source_wallet_id HAVING count(*) > 1$t$),
('analyst', 'oworail_analyst', 'reconcile balances against the ledger', 'ALLOWED',
 'SELECT * FROM oworail.v_wallet_balance WHERE difference_kobo <> 0'),
('analyst', 'oworail_analyst', 'read customer personal data',  'DENIED', 'SELECT full_name, email FROM oworail.customer'),
('analyst', 'oworail_analyst', 'read customer data through v_customer', 'DENIED', 'SELECT * FROM oworail.v_customer'),
('analyst', 'oworail_analyst', 'read KYC identity data',       'DENIED', 'SELECT * FROM oworail.kyc_profile'),
('analyst', 'oworail_analyst', 'change a fee rule',            'DENIED', 'UPDATE oworail.fee_rule SET flat_fee_kobo = 0'),
-- internal audit --------------------------------------------------------------
('auditor', 'oworail_auditor', 'read the audit log',           'ALLOWED', 'SELECT * FROM oworail.audit_log'),
('auditor', 'oworail_auditor', 'read KYC profiles',            'ALLOWED', 'SELECT * FROM oworail.kyc_profile'),
('auditor', 'oworail_auditor', 'read the ledger',              'ALLOWED', 'SELECT * FROM oworail.ledger_entry'),
('auditor', 'oworail_auditor', 'add an audit record',          'DENIED',
 'INSERT INTO oworail.audit_log (action, target_type, target_id) VALUES (''TEST'', ''role'', ''x'')'),
('auditor', 'oworail_auditor', 'delete audit records',         'DENIED', 'DELETE FROM oworail.audit_log'),
('auditor', 'oworail_auditor', 'change a transaction',         'DENIED',
 'UPDATE oworail.transaction SET narration = ''edited'' WHERE transaction_id = 1'),
('auditor', 'oworail_auditor', 'post a transaction',           'DENIED',
 $t$SELECT oworail.post_transaction('00000000-0000-4000-8000-700000000001', 'TRANSFER', '3000000001', '3000000002', 1000, 'WEB')$t$),
-- every role ------------------------------------------------------------------
('all roles', 'oworail_app', 'oworail_app updates the ledger', 'DENIED', 'UPDATE oworail.ledger_entry SET amount_kobo = 1'),
('all roles', 'oworail_support', 'oworail_support updates the ledger', 'DENIED', 'UPDATE oworail.ledger_entry SET amount_kobo = 1'),
('all roles', 'oworail_analyst', 'oworail_analyst updates the ledger', 'DENIED', 'UPDATE oworail.ledger_entry SET amount_kobo = 1'),
('all roles', 'oworail_auditor', 'oworail_auditor updates the ledger', 'DENIED', 'UPDATE oworail.ledger_entry SET amount_kobo = 1');

UPDATE test_case SET expected = 'NO ERROR' WHERE expected = 'ALLOWED';
UPDATE test_case SET expected = 'permission denied' WHERE expected = 'DENIED';

\ir _run.sql

-- Function EXECUTE rights as granted (PUBLIC has none)
SELECT p.proname AS function,
       string_agg(r.rolname, ', ' ORDER BY r.rolname) AS executable_by
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'oworail'
CROSS JOIN pg_roles r
WHERE r.rolname LIKE 'oworail\_%' AND r.rolname <> 'oworail_owner'
  AND has_function_privilege(r.oid, p.oid, 'EXECUTE')
  AND p.prorettype <> 'trigger'::regtype
GROUP BY p.proname
ORDER BY p.proname;
