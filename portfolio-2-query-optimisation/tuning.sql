-- Final optimisation step: better statistics for ledger_entry.wallet_id and a
-- materialised view for the monthly settlement report. Run after indexes.sql.

\set ON_ERROR_STOP on
SET search_path = oworail, public;
SET ROLE oworail_owner;

-- The default sample (100 x 300 rows) puts wallet_id at ~32k distinct values;
-- there are ~102k. A larger sample fixes the estimate used to size Q5's aggregate.
ALTER TABLE ledger_entry ALTER COLUMN wallet_id SET STATISTICS 1000;
ANALYZE ledger_entry;

-- Q7: settlement totals per merchant per month (UTC). Refreshed at month end,
-- after late reversals; CONCURRENTLY keeps it readable during the refresh.
CREATE MATERIALIZED VIEW mv_merchant_monthly_settlement AS
SELECT date_trunc('month', t.created_at, 'UTC') AS month,
       w.merchant_id,
       count(*)           AS payments,
       sum(t.amount_kobo) AS gross_kobo
FROM transaction t
JOIN wallet w ON w.wallet_id = t.destination_wallet_id
WHERE t.transaction_type IN ('MERCHANT_PAYMENT', 'BILL_PAYMENT')
  AND t.status = 'SUCCESSFUL'
  AND w.wallet_type = 'MERCHANT'
GROUP BY 1, 2;

CREATE UNIQUE INDEX uq_mv_merchant_monthly_settlement
    ON mv_merchant_monthly_settlement (month, merchant_id);

GRANT SELECT ON mv_merchant_monthly_settlement TO oworail_analyst, oworail_auditor;

RESET ROLE;
ANALYZE mv_merchant_monthly_settlement;

\pset footer off
SELECT attname, n_distinct FROM pg_stats
WHERE schemaname = 'oworail' AND tablename = 'ledger_entry' AND attname = 'wallet_id';
SELECT count(*) AS mv_rows, pg_size_pretty(pg_total_relation_size('mv_merchant_monthly_settlement')) AS mv_size
FROM mv_merchant_monthly_settlement;
