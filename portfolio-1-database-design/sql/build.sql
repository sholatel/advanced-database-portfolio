-- Builds the OwoRail database from scratch: roles, schema, rules, procedures,
-- privileges and seed data. Safe to re-run; the oworail schema is rebuilt.
--
--   docker compose exec -T postgres psql -U postgres -d oworail -X \
--       -v ON_ERROR_STOP=1 -f /workspace/portfolio-1-database-design/sql/build.sql

\set ON_ERROR_STOP on
\pset footer off
SET client_min_messages = warning;

\echo '== 01 roles'
\ir 01_roles.sql
\echo '== 02 schema, constraints, indexes'
\ir 02_schema.sql
\echo '== 03 rules: fee function, ledger triggers, views'
\ir 03_rules.sql
\echo '== 04 procedures'
\ir 04_procedures.sql
\echo '== 05 privileges'
\ir 05_grants.sql
\echo '== 06 seed data'
\pset tuples_only on
\o /dev/null
\ir 06_seed.sql
\o
\pset tuples_only off
\echo '== row counts'
SELECT 'customer' AS table_name, count(*) AS rows FROM oworail.customer
UNION ALL SELECT 'customer_phone', count(*) FROM oworail.customer_phone
UNION ALL SELECT 'kyc_tier', count(*) FROM oworail.kyc_tier
UNION ALL SELECT 'kyc_profile', count(*) FROM oworail.kyc_profile
UNION ALL SELECT 'merchant', count(*) FROM oworail.merchant
UNION ALL SELECT 'wallet', count(*) FROM oworail.wallet
UNION ALL SELECT 'saved_beneficiary', count(*) FROM oworail.saved_beneficiary
UNION ALL SELECT 'fee_rule', count(*) FROM oworail.fee_rule
UNION ALL SELECT 'transaction', count(*) FROM oworail.transaction
UNION ALL SELECT 'ledger_entry', count(*) FROM oworail.ledger_entry
UNION ALL SELECT 'transaction_status_history', count(*) FROM oworail.transaction_status_history
UNION ALL SELECT 'reversal', count(*) FROM oworail.reversal
UNION ALL SELECT 'audit_log', count(*) FROM oworail.audit_log;
\echo '== build complete'
