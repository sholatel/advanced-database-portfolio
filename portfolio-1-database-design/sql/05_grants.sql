-- OwoRail physical design, step 5: privileges (BR-18, NFR-04).
--
-- Each role gets only what its users need (requirements, section 2):
--
--   role                 reads                                         can do
--   oworail_app          operational and ledger tables, not KYC        onboarding, posting, reversal
--                        identity data or the audit log                functions; manage beneficiaries
--   oworail_support      customers, phones, wallets, transactions,     nothing
--                        ledger; no KYC identity data, no audit log
--   oworail_compliance   customers, phones, KYC profiles and tiers     review_kyc
--   oworail_analyst      wallets, merchants, transactions, ledger,     nothing
--                        fees (no customer personal data)
--   oworail_auditor      every table and view, including the audit     nothing
--                        log and KYC profiles
--
-- No role has UPDATE or DELETE on the ledger, the status history or the audit
-- log, and no role has DDL rights. Writes to financial tables happen only
-- inside the SECURITY DEFINER functions.

SET ROLE oworail_owner;
SET search_path = oworail, public;

-- Functions are executable by PUBLIC by default; take that away first.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA oworail FROM PUBLIC;

GRANT USAGE ON SCHEMA oworail
    TO oworail_app, oworail_support, oworail_compliance, oworail_analyst, oworail_auditor;

-- payments application
GRANT SELECT ON customer, customer_phone, kyc_tier, merchant, wallet, saved_beneficiary,
                fee_rule, transaction, ledger_entry, transaction_status_history, reversal,
                v_customer, v_wallet_balance, v_transaction
    TO oworail_app;
GRANT INSERT, UPDATE (nickname), DELETE ON saved_beneficiary TO oworail_app;   -- FR-11
GRANT EXECUTE ON FUNCTION
    onboard_customer(text, text, date, text, text, text, text[], text, timestamptz),
    onboard_merchant(text, text, text, text, text, timestamptz),
    submit_kyc(bigint, text, text, timestamptz),
    post_transaction(uuid, text, text, text, bigint, text, text, text, text, timestamptz),
    reverse_transaction(text, text, text, uuid, text, timestamptz),
    fee_for(text, bigint, timestamptz)
    TO oworail_app;

-- customer support: read-only, no KYC identity data
GRANT SELECT ON customer, customer_phone, kyc_tier, merchant, wallet, saved_beneficiary,
                transaction, ledger_entry, transaction_status_history, reversal,
                v_customer, v_wallet_balance, v_transaction
    TO oworail_support;

-- compliance / KYC
GRANT SELECT ON customer, customer_phone, kyc_tier, kyc_profile, v_customer
    TO oworail_compliance;
GRANT EXECUTE ON FUNCTION review_kyc(bigint, text, smallint, text, timestamptz)
    TO oworail_compliance;

-- fraud and finance analysts: financial data only
GRANT SELECT ON kyc_tier, merchant, wallet, fee_rule, transaction, ledger_entry,
                transaction_status_history, reversal, v_wallet_balance, v_transaction
    TO oworail_analyst;
GRANT EXECUTE ON FUNCTION fee_for(text, bigint, timestamptz) TO oworail_analyst;

-- internal audit: read everything
GRANT SELECT ON ALL TABLES IN SCHEMA oworail TO oworail_auditor;   -- includes the views

-- BR-17: privilege changes are audited
INSERT INTO audit_log (actor, action, target_type, target_id, details)
SELECT session_user, 'PRIVILEGES_GRANTED', 'role', r, jsonb_build_object('script', '05_grants.sql')
FROM unnest(ARRAY['oworail_app', 'oworail_support', 'oworail_compliance',
                  'oworail_analyst', 'oworail_auditor']) AS r;

RESET ROLE;

-- Privilege matrix as granted (r = SELECT, a = INSERT, w = UPDATE, d = DELETE)
SELECT c.relname AS object,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' END AS kind,
       concat(CASE WHEN has_table_privilege('oworail_app', c.oid, 'SELECT') THEN 'r' END,
              CASE WHEN has_table_privilege('oworail_app', c.oid, 'INSERT') THEN 'a' END,
              CASE WHEN has_any_column_privilege('oworail_app', c.oid, 'UPDATE') THEN 'w' END,
              CASE WHEN has_table_privilege('oworail_app', c.oid, 'DELETE') THEN 'd' END) AS app,
       CASE WHEN has_table_privilege('oworail_support',    c.oid, 'SELECT') THEN 'r' ELSE '' END AS support,
       CASE WHEN has_table_privilege('oworail_compliance', c.oid, 'SELECT') THEN 'r' ELSE '' END AS compliance,
       CASE WHEN has_table_privilege('oworail_analyst',    c.oid, 'SELECT') THEN 'r' ELSE '' END AS analyst,
       CASE WHEN has_table_privilege('oworail_auditor',    c.oid, 'SELECT') THEN 'r' ELSE '' END AS auditor
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'oworail' AND c.relkind IN ('r', 'v')
ORDER BY c.relkind, c.relname;
