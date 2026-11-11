-- Cost of writing: 1,800 merchant payments through post_transaction, rolled back.
-- Run before and after indexes.sql. Each payment uses a different customer and
-- merchant wallet, so the timing reflects index maintenance, not row contention.

\set ON_ERROR_STOP on
SET search_path = oworail, public;
\pset footer off

CREATE FUNCTION pg_temp.measure(p_run int, OUT run int, OUT payments int, OUT successful int, OUT ms numeric)
LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz;
BEGIN
    run := p_run;
    payments := 1800;
    BEGIN
        t0 := clock_timestamp();
        PERFORM post_transaction(md5('write-cost-' || p_run || '-' || g)::uuid, 'MERCHANT_PAYMENT',
                                 '31' || lpad((10000 + g)::text, 8, '0'), '32' || lpad(g::text, 8, '0'),
                                 10000, 'APP', p_at => '2026-11-05 12:00:00+00')
        FROM generate_series(1, payments) g;
        SET CONSTRAINTS ALL IMMEDIATE;                 -- include the deferred ledger checks
        ms := round(extract(epoch FROM clock_timestamp() - t0) * 1000, 1);
        SELECT count(*) INTO successful FROM transaction
        WHERE idempotency_key IN (SELECT md5('write-cost-' || p_run || '-' || g)::uuid
                                  FROM generate_series(1, payments) g)
          AND status = 'SUCCESSFUL';
        RAISE EXCEPTION 'rollback' USING ERRCODE = 'OWR00';
    EXCEPTION WHEN SQLSTATE 'OWR00' THEN
        NULL;                                          -- the work is undone; the OUT values are kept
    END;
END $$;

CREATE TEMP TABLE write_timing AS SELECT * FROM pg_temp.measure(1);
VACUUM transaction, ledger_entry, transaction_status_history, wallet;
INSERT INTO write_timing SELECT * FROM pg_temp.measure(2);
VACUUM transaction, ledger_entry, transaction_status_history, wallet;
INSERT INTO write_timing SELECT * FROM pg_temp.measure(3);
VACUUM transaction, ledger_entry, transaction_status_history, wallet;

SELECT run, payments, successful, ms, round(ms / payments, 3) AS ms_per_payment FROM write_timing ORDER BY run;
SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY ms))::numeric / 1800, 3) AS median_ms_per_payment
FROM write_timing;
