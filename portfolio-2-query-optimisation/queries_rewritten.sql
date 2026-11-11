-- OwoRail query workload after optimisation. Q2, Q7 and Q9 are rewritten; the rest are unchanged.
-- Each query starts with a "-- Qn: title" line; scripts/run_plans.py splits on it.
-- Fixed parameters and dates (the data ends on 31 October 2026) keep runs comparable.

-- Q1: Support: find a customer and their wallets by phone number (FR-01)
SELECT c.customer_id, c.full_name, c.status, w.wallet_number, w.balance_kobo, w.status AS wallet_status
FROM customer_phone p
JOIN customer c ON c.customer_id = p.customer_id
JOIN wallet w   ON w.customer_id = c.customer_id
WHERE p.phone_number = '+2349000013424'
ORDER BY w.wallet_number;

-- Q2: Wallet statement, first page: the 20 latest ledger lines of the busiest wallet (FR-07)
-- The 20 latest posted transactions where the wallet is the sender, and the 20
-- latest where it is the receiver, each read backwards from its index; the top 20
-- of those 40, then their ledger lines. Same rows as before for any customer or
-- merchant wallet (FEES lines aren't tied to a sender or receiver).
WITH recent AS (
    SELECT transaction_id, created_at FROM (
        (SELECT t.transaction_id, t.created_at FROM transaction t
         WHERE t.source_wallet_id = (SELECT wallet_id FROM wallet WHERE wallet_number = '3100000001')
           AND t.status IN ('SUCCESSFUL', 'REVERSED')
         ORDER BY t.created_at DESC, t.transaction_id DESC LIMIT 20)
        UNION ALL
        (SELECT t.transaction_id, t.created_at FROM transaction t
         WHERE t.destination_wallet_id = (SELECT wallet_id FROM wallet WHERE wallet_number = '3100000001')
           AND t.status IN ('SUCCESSFUL', 'REVERSED')
         ORDER BY t.created_at DESC, t.transaction_id DESC LIMIT 20)
    ) u
    ORDER BY created_at DESC, transaction_id DESC
    LIMIT 20
)
SELECT t.created_at, t.transaction_ref, t.transaction_type, l.entry_type, l.amount_kobo, t.status
FROM recent r
JOIN transaction t  ON t.transaction_id = r.transaction_id
JOIN ledger_entry l ON l.transaction_id = r.transaction_id
                   AND l.wallet_id = (SELECT wallet_id FROM wallet WHERE wallet_number = '3100000001')
ORDER BY r.created_at DESC, r.transaction_id DESC;

-- Q3: Support: a transaction and its status history by reference
SELECT t.transaction_ref, t.transaction_type, t.amount_kobo, t.fee_kobo, t.status,
       h.seq_no, h.status AS history_status, h.changed_at, h.reason
FROM transaction t
JOIN transaction_status_history h ON h.transaction_id = t.transaction_id
WHERE t.transaction_ref = 'OWR100000470468'
ORDER BY h.seq_no;

-- Q4: Posting: amount already sent today by the busiest wallet, for the daily KYC limit (BR-04)
SELECT coalesce(sum(t.amount_kobo + t.fee_kobo), 0) AS sent_today_kobo
FROM transaction t
WHERE t.source_wallet_id = (SELECT wallet_id FROM wallet WHERE wallet_number = '3100000001')
  AND t.status = 'SUCCESSFUL'
  AND t.transaction_type <> 'REVERSAL'
  AND t.created_at >= '2026-10-30 00:00:00+00' AND t.created_at < '2026-10-31 00:00:00+00';

-- Q5: Finance: reconcile every wallet's stored balance against the ledger (FR-08)
SELECT wallet_number, balance_kobo, ledger_balance_kobo, difference_kobo
FROM v_wallet_balance
WHERE difference_kobo <> 0;

-- Q6: Fraud: wallets with 5 or more outgoing payments in one day (FR-09)
SELECT w.wallet_number, count(*) AS outgoing, sum(t.amount_kobo) AS total_kobo
FROM transaction t
JOIN wallet w ON w.wallet_id = t.source_wallet_id
WHERE t.created_at >= '2026-10-30 00:00:00+00' AND t.created_at < '2026-10-31 00:00:00+00'
  AND t.transaction_type IN ('TRANSFER', 'MERCHANT_PAYMENT', 'BILL_PAYMENT')
GROUP BY w.wallet_number
HAVING count(*) >= 5
ORDER BY outgoing DESC, w.wallet_number;

-- Q7: Settlement: October 2026 takings per merchant and biller (FR-10)
-- read from the monthly settlement materialised view (tuning.sql)
SELECT m.merchant_code, m.business_name, m.category, s.payments, s.gross_kobo
FROM mv_merchant_monthly_settlement s
JOIN merchant m ON m.merchant_id = s.merchant_id
WHERE s.month = '2026-10-01 00:00:00+00'
ORDER BY s.gross_kobo DESC, m.merchant_code;

-- Q8: Operations: failed transactions in the last 7 days, by channel and reason
SELECT t.channel, h.reason, count(*) AS failures
FROM transaction t
JOIN transaction_status_history h ON h.transaction_id = t.transaction_id AND h.status = 'FAILED'
WHERE t.status = 'FAILED'
  AND t.created_at >= '2026-10-24 00:00:00+00' AND t.created_at < '2026-10-31 00:00:00+00'
GROUP BY t.channel, h.reason
ORDER BY failures DESC, t.channel;

-- Q9: Marketing: the 50 largest active customer wallets with no outgoing payment in 90 days
-- NOT EXISTS lets the planner use an anti-join; NOT IN can't, because of how it treats NULLs
SELECT w.wallet_number, w.balance_kobo
FROM wallet w
WHERE w.wallet_type = 'CUSTOMER' AND w.status = 'ACTIVE' AND w.balance_kobo > 0
  AND NOT EXISTS (SELECT 1 FROM transaction t
                  WHERE t.source_wallet_id = w.wallet_id
                    AND t.created_at >= '2026-08-02 00:00:00+00'
                    AND t.created_at <  '2026-10-31 00:00:00+00')
ORDER BY w.balance_kobo DESC, w.wallet_number
LIMIT 50;
