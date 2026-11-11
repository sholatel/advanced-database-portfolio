-- Supporting experiments for performance.md. Run after tuning.sql.

\set ON_ERROR_STOP on
SET search_path = oworail, public;
\pset footer off

\echo '== 1. planner statistics for the columns the workload filters on'
SELECT tablename, attname, n_distinct, round(correlation::numeric, 3) AS correlation,
       (most_common_vals::text::text[])[1:3] AS top_values,
       (most_common_freqs)[1:3] AS top_freqs
FROM pg_stats
WHERE schemaname = 'oworail'
  AND (tablename, attname) IN (('transaction', 'source_wallet_id'), ('transaction', 'destination_wallet_id'),
                               ('transaction', 'status'), ('transaction', 'transaction_type'),
                               ('transaction', 'created_at'), ('ledger_entry', 'wallet_id'))
ORDER BY tablename, attname;

\echo
\echo '== 2. estimated against actual rows: the busiest wallet (a most-common value) and a typical one'
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM transaction
WHERE source_wallet_id = (SELECT wallet_id FROM wallet WHERE wallet_number = '3100000001');
SELECT wallet_id AS busiest_wallet_id FROM wallet WHERE wallet_number = '3100000001' \gset
SELECT wallet_id AS typical_wallet_id FROM wallet WHERE wallet_number = '3100025000' \gset
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM transaction WHERE source_wallet_id = :busiest_wallet_id;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF) SELECT count(*) FROM transaction WHERE source_wallet_id = :typical_wallet_id;

\echo
\echo '== 3. Q9: NOT IN finishes once its subquery fits in work_mem as a hash table; same rows as NOT EXISTS'
SET work_mem = '64MB';
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT w.wallet_number, w.balance_kobo FROM wallet w
WHERE w.wallet_type = 'CUSTOMER' AND w.status = 'ACTIVE' AND w.balance_kobo > 0
  AND w.wallet_id NOT IN (SELECT t.source_wallet_id FROM transaction t
                          WHERE t.created_at >= '2026-08-02 00:00:00+00' AND t.created_at < '2026-10-31 00:00:00+00')
ORDER BY w.balance_kobo DESC, w.wallet_number LIMIT 50;
SELECT (SELECT md5(string_agg(wallet_number || ':' || balance_kobo, ',' ORDER BY balance_kobo DESC, wallet_number))
        FROM (SELECT w.wallet_number, w.balance_kobo FROM wallet w
              WHERE w.wallet_type = 'CUSTOMER' AND w.status = 'ACTIVE' AND w.balance_kobo > 0
                AND w.wallet_id NOT IN (SELECT t.source_wallet_id FROM transaction t
                                        WHERE t.created_at >= '2026-08-02 00:00:00+00' AND t.created_at < '2026-10-31 00:00:00+00')
              ORDER BY w.balance_kobo DESC, w.wallet_number LIMIT 50) a)
     = (SELECT md5(string_agg(wallet_number || ':' || balance_kobo, ',' ORDER BY balance_kobo DESC, wallet_number))
        FROM (SELECT w.wallet_number, w.balance_kobo FROM wallet w
              WHERE w.wallet_type = 'CUSTOMER' AND w.status = 'ACTIVE' AND w.balance_kobo > 0
                AND NOT EXISTS (SELECT 1 FROM transaction t WHERE t.source_wallet_id = w.wallet_id
                                  AND t.created_at >= '2026-08-02 00:00:00+00' AND t.created_at < '2026-10-31 00:00:00+00')
              ORDER BY w.balance_kobo DESC, w.wallet_number LIMIT 50) b) AS not_in_equals_not_exists;

\echo
\echo '== 4. Q5 with more memory instead of better statistics (work_mem 64MB)'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT wallet_number, balance_kobo, ledger_balance_kobo, difference_kobo
FROM v_wallet_balance WHERE difference_kobo <> 0;
RESET work_mem;

\echo
\echo '== 5. Q7 rewritten to aggregate before joining (kept for comparison; not adopted)'
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT m.merchant_code, m.business_name, m.category, s.payments, s.gross_kobo
FROM (SELECT destination_wallet_id, count(*) AS payments, sum(amount_kobo) AS gross_kobo
      FROM transaction
      WHERE transaction_type IN ('MERCHANT_PAYMENT', 'BILL_PAYMENT') AND status = 'SUCCESSFUL'
        AND created_at >= '2026-10-01 00:00:00+00' AND created_at < '2026-11-01 00:00:00+00'
      GROUP BY destination_wallet_id) s
JOIN wallet w   ON w.wallet_id = s.destination_wallet_id
JOIN merchant m ON m.merchant_id = w.merchant_id
ORDER BY s.gross_kobo DESC, m.merchant_code;

\echo
\echo '== 6. cost of keeping the materialised view current'
\timing on
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_merchant_monthly_settlement;
\timing off

\echo
\echo '== 7. Q8 with ix_transaction_created set aside (inside a rolled-back transaction): the partial index alone'
BEGIN;
DROP INDEX ix_transaction_created;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT t.channel, h.reason, count(*) AS failures
FROM transaction t
JOIN transaction_status_history h ON h.transaction_id = t.transaction_id AND h.status = 'FAILED'
WHERE t.status = 'FAILED'
  AND t.created_at >= '2026-10-24 00:00:00+00' AND t.created_at < '2026-10-31 00:00:00+00'
GROUP BY t.channel, h.reason
ORDER BY failures DESC, t.channel;
ROLLBACK;

\echo
\echo '== 8. how often each index on transaction and ledger_entry has been used since the load'
SELECT relname AS table_name, indexrelname AS index_name, idx_scan,
       pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'oworail' AND relname IN ('transaction', 'ledger_entry')
ORDER BY relname, idx_scan DESC;
