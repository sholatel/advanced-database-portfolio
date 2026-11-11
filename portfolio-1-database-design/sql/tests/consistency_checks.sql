-- Consistency checks: the multi-row business rules that no single constraint
-- can enforce (schema.md, "Integrity rules outside declarative constraints"),
-- written as queries that count violations. Every count must be 0. The
-- reconciliation query is FR-08. Run after the build and again after the
-- tests, to show the tests left the data unchanged.
--
-- The last query rebuilds the 2 November transaction report from
-- normalisation.md by joining the normalised tables, showing that the
-- decomposition lost no information.
--
--   docker compose exec -T postgres psql -U postgres -d oworail -X \
--       -v ON_ERROR_STOP=1 -f /workspace/portfolio-1-database-design/sql/tests/consistency_checks.sql

\set ON_ERROR_STOP on
\pset footer off
SET search_path = oworail, public;

CREATE TEMP TABLE check_result AS
SELECT * FROM (VALUES
  ('BR-14 / FR-08', 'stored balance equals ledger balance for every wallet',
   (SELECT count(*) FROM v_wallet_balance WHERE difference_kobo <> 0)),

  ('BR-13', 'every posted transaction has 2+ lines and debits = credits',
   (SELECT count(*) FROM transaction t
    WHERE t.status IN ('SUCCESSFUL', 'REVERSED')
      AND (SELECT count(*) < 2
                  OR coalesce(sum(CASE l.entry_type WHEN 'DEBIT' THEN l.amount_kobo END), 0)
                  <> coalesce(sum(CASE l.entry_type WHEN 'CREDIT' THEN l.amount_kobo END), 0)
           FROM ledger_entry l WHERE l.transaction_id = t.transaction_id))),

  ('BR-13', 'FAILED and PENDING transactions have no ledger lines',
   (SELECT count(*) FROM transaction t
    WHERE t.status IN ('FAILED', 'PENDING')
      AND EXISTS (SELECT 1 FROM ledger_entry l WHERE l.transaction_id = t.transaction_id))),

  ('BR-13', 'the whole ledger balances (sum of all wallet balances is 0)',
   (SELECT CASE WHEN sum(balance_kobo) = 0 THEN 0 ELSE 1 END FROM wallet)),

  ('BR-15', 'current status equals the latest status-history row',
   (SELECT count(*) FROM transaction t
    WHERE t.status IS DISTINCT FROM (SELECT h.status FROM transaction_status_history h
                                     WHERE h.transaction_id = t.transaction_id
                                     ORDER BY h.seq_no DESC LIMIT 1))),

  ('BR-15', 'status history starts with PENDING and has no gaps',
   (SELECT count(*) FROM (
        SELECT h.transaction_id
        FROM transaction_status_history h
        GROUP BY h.transaction_id
        HAVING min(h.seq_no) <> 1 OR max(h.seq_no) <> count(*)
            OR min(CASE WHEN h.seq_no = 1 THEN h.status END) <> 'PENDING') x)),

  ('BR-16', 'every reversal: original REVERSED, reversal SUCCESSFUL, same amount, mirrored ledger',
   (SELECT count(*) FROM reversal r
    JOIN transaction o ON o.transaction_id = r.original_transaction_id
    JOIN transaction v ON v.transaction_id = r.reversal_transaction_id
    WHERE o.status <> 'REVERSED' OR v.status <> 'SUCCESSFUL' OR v.transaction_type <> 'REVERSAL'
       OR v.amount_kobo <> o.amount_kobo
       OR v.source_wallet_id <> o.destination_wallet_id OR v.destination_wallet_id <> o.source_wallet_id
       OR EXISTS (   -- net effect per wallet of original + reversal must be zero
            SELECT 1 FROM ledger_entry l
            WHERE l.transaction_id IN (o.transaction_id, v.transaction_id)
            GROUP BY l.wallet_id
            HAVING sum(CASE l.entry_type WHEN 'CREDIT' THEN l.amount_kobo ELSE -l.amount_kobo END) <> 0))),

  ('BR-16', 'every REVERSED transaction has a reversal record',
   (SELECT count(*) FROM transaction t
    WHERE t.status = 'REVERSED'
      AND NOT EXISTS (SELECT 1 FROM reversal r WHERE r.original_transaction_id = t.transaction_id))),

  ('BR-02 / BR-06', 'every customer has at least one phone and one wallet',
   (SELECT count(*) FROM customer c
    WHERE NOT EXISTS (SELECT 1 FROM customer_phone p WHERE p.customer_id = c.customer_id)
       OR NOT EXISTS (SELECT 1 FROM wallet w WHERE w.customer_id = c.customer_id))),

  ('BR-06', 'every merchant has exactly one wallet',
   (SELECT count(*) FROM merchant m
    WHERE (SELECT count(*) FROM wallet w WHERE w.merchant_id = m.merchant_id) <> 1)),

  ('BR-10', 'wallet types match the transaction type',
   (SELECT count(*) FROM transaction t
    JOIN wallet s ON s.wallet_id = t.source_wallet_id
    JOIN wallet d ON d.wallet_id = t.destination_wallet_id
    LEFT JOIN merchant m ON m.merchant_id = d.merchant_id
    WHERE NOT CASE t.transaction_type
        WHEN 'WALLET_FUNDING'   THEN s.system_purpose IS NOT DISTINCT FROM 'SETTLEMENT' AND d.wallet_type = 'CUSTOMER'
        WHEN 'TRANSFER'         THEN s.wallet_type = 'CUSTOMER' AND d.wallet_type = 'CUSTOMER'
        WHEN 'MERCHANT_PAYMENT' THEN s.wallet_type = 'CUSTOMER' AND m.merchant_type IS NOT DISTINCT FROM 'MERCHANT'
        WHEN 'BILL_PAYMENT'     THEN s.wallet_type = 'CUSTOMER' AND m.merchant_type IS NOT DISTINCT FROM 'BILLER'
        WHEN 'REVERSAL'         THEN true
    END)),

  ('BR-12', 'stored fee and rule match fee_for() at the time of the transaction',
   (SELECT count(*) FROM transaction t
    CROSS JOIN LATERAL fee_for(t.transaction_type, t.amount_kobo, t.created_at) f
    WHERE t.transaction_type <> 'REVERSAL'
      AND (t.fee_kobo <> coalesce(f.fee_kobo, 0) OR t.fee_rule_id IS DISTINCT FROM f.fee_rule_id))),

  ('BR-17', 'every reversal and KYC decision has an audit record',
   (SELECT (SELECT count(*) FROM reversal r
            WHERE NOT EXISTS (SELECT 1 FROM audit_log a
                              WHERE a.action = 'TXN_REVERSED' AND a.target_type = 'transaction'
                                AND a.target_id = r.original_transaction_id::text))
         + (SELECT count(*) FROM kyc_profile k
            WHERE k.verification_status <> 'PENDING'
              AND NOT EXISTS (SELECT 1 FROM audit_log a
                              WHERE a.action = 'KYC_' || k.verification_status
                                AND a.target_type = 'kyc_profile'
                                AND a.target_id = k.kyc_profile_id::text))))
) AS c (rule, check_description, violations);

SELECT rule, check_description, violations,
       CASE WHEN violations = 0 THEN 'PASS' ELSE 'FAIL' END AS result
FROM check_result;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM check_result WHERE violations <> 0) THEN
        RAISE EXCEPTION 'consistency check failed';
    END IF;
END
$$;

\echo
\echo '== wallet balances (FR-08 reconciliation)'
-- with -v brief=1 (large datasets) only the seed wallets are listed
SELECT wallet_number, wallet_type, status, balance_kobo, ledger_balance_kobo, difference_kobo
FROM v_wallet_balance
\if :{?brief}
WHERE wallet_number LIKE '30%' OR wallet_number LIKE '90%'
\endif
ORDER BY wallet_number;

\echo
\echo '== the 2 November 2026 report from normalisation.md, rebuilt by joins'
SELECT t.transaction_ref,
       to_char(t.created_at AT TIME ZONE 'UTC', 'HH24:MI:SS') || ' ' || t.transaction_type || ' ' || t.channel AS "time / type / channel",
       t.amount_kobo || ' / ' || t.fee_kobo || ' / ' || coalesce('rule ' || t.fee_rule_id, '-') AS "amount / fee / rule",
       sc.full_name || ', Tier ' || coalesce(kt.tier_level::text, '-')
           || ', daily ' || coalesce(kt.daily_limit_kobo::text, '-') AS "sender, tier, daily limit",
       (SELECT string_agg(p.phone_number, ' ' ORDER BY p.phone_number)
        FROM customer_phone p WHERE p.customer_id = sc.customer_id) AS sender_phones,
       sw.wallet_number || ' (' || sw.balance_kobo || ')' AS "source wallet (balance)",
       dw.wallet_number || ' ' || coalesce(dc.full_name, dm.business_name)
           || coalesce(' ' || dm.merchant_code || ' ' || dm.category, '') AS destination,
       coalesce((SELECT string_agg(l.line_no || ' ' || lw.wallet_number || ' ' || left(l.entry_type, 1) || ' ' || l.amount_kobo,
                                   '; ' ORDER BY l.line_no)
                 FROM ledger_entry l JOIN wallet lw ON lw.wallet_id = l.wallet_id
                 WHERE l.transaction_id = t.transaction_id), '(none)') AS ledger_lines,
       (SELECT string_agg(h.seq_no || ' ' || h.status || coalesce(' "' || h.reason || '"', ''), '; ' ORDER BY h.seq_no)
        FROM transaction_status_history h WHERE h.transaction_id = t.transaction_id) AS status_history,
       coalesce(o.transaction_ref || ' "' || r.reason || '" ' || r.requested_by, '-') AS reversal_of
FROM transaction t
JOIN wallet sw         ON sw.wallet_id = t.source_wallet_id
JOIN wallet dw         ON dw.wallet_id = t.destination_wallet_id
LEFT JOIN customer sc  ON sc.customer_id = sw.customer_id
LEFT JOIN kyc_profile k ON k.customer_id = sc.customer_id
LEFT JOIN kyc_tier kt  ON kt.tier_level = k.tier_level
LEFT JOIN customer dc  ON dc.customer_id = dw.customer_id
LEFT JOIN merchant dm  ON dm.merchant_id = dw.merchant_id
LEFT JOIN reversal r   ON r.reversal_transaction_id = t.transaction_id
LEFT JOIN transaction o ON o.transaction_id = r.original_transaction_id
WHERE t.created_at >= '2026-11-02 00:00:00+00' AND t.created_at < '2026-11-03 00:00:00+00'
ORDER BY t.transaction_ref;
