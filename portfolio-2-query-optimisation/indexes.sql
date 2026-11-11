-- Workload indexes for Portfolio 2. Run as postgres after the volume load.

\set ON_ERROR_STOP on
SET search_path = oworail, public;
SET ROLE oworail_owner;

-- Q2, Q4: a wallet's outgoing transactions in time order. The key ends in
-- transaction_id so ORDER BY created_at DESC, transaction_id DESC needs no sort;
-- INCLUDE lets Q4 answer from the index alone. Replaces the plain FK index.
CREATE INDEX ix_transaction_source_created
    ON transaction (source_wallet_id, created_at, transaction_id)
    INCLUDE (status, transaction_type, amount_kobo, fee_kobo);
DROP INDEX ix_transaction_source_wallet;

-- Q2, Q7: the same for incoming transactions. Replaces the plain FK index.
CREATE INDEX ix_transaction_destination_created
    ON transaction (destination_wallet_id, created_at, transaction_id)
    INCLUDE (status, transaction_type, amount_kobo);
DROP INDEX ix_transaction_destination_wallet;

-- Q6: one day of transactions out of six months.
CREATE INDEX ix_transaction_created
    ON transaction (created_at)
    INCLUDE (source_wallet_id, transaction_type, amount_kobo);

-- Q8: failed transactions are 3 % of the table; a partial index holds only them.
CREATE INDEX ix_transaction_failed_created
    ON transaction (created_at)
    WHERE status = 'FAILED';

-- Q5, Q2: a wallet's ledger lines with the columns needed to sum them.
-- Replaces the plain FK index.
CREATE INDEX ix_ledger_entry_wallet_amount
    ON ledger_entry (wallet_id)
    INCLUDE (entry_type, amount_kobo);
DROP INDEX ix_ledger_entry_wallet;

RESET ROLE;
ANALYZE transaction, ledger_entry;

\pset footer off
SELECT c.relname AS index_name, t.relname AS table_name,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
WHERE t.relnamespace = 'oworail'::regnamespace AND t.relname IN ('transaction', 'ledger_entry')
ORDER BY t.relname, pg_relation_size(c.oid) DESC;
