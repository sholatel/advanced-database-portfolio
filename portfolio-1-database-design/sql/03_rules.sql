

SET ROLE oworail_owner;
SET search_path = oworail, public;


CREATE FUNCTION fee_for(p_transaction_type text, p_amount_kobo bigint, p_at timestamptz,
                        OUT fee_rule_id bigint, OUT fee_kobo bigint)
LANGUAGE sql STABLE
SET search_path = oworail, pg_temp
AS $$
    SELECT r.fee_rule_id,
           CASE WHEN r.cap_kobo IS NULL THEN f.raw_fee
                ELSE least(f.raw_fee, r.cap_kobo) END
    FROM fee_rule r
    CROSS JOIN LATERAL (
        -- integer division of non-negative numbers rounds down (customer's favour)
        SELECT r.flat_fee_kobo + (p_amount_kobo * r.percent_bps) / 10000 AS raw_fee
    ) f
    WHERE r.transaction_type = p_transaction_type
      AND int8range(r.min_amount_kobo, r.max_amount_kobo, '[]') @> p_amount_kobo
      AND tstzrange(r.effective_from, r.effective_to, '[)') @> p_at
$$;
COMMENT ON FUNCTION fee_for(text, bigint, timestamptz) IS
    'BR-12: fee rule and fee for a transaction type, amount and moment';


CREATE FUNCTION check_transaction_balanced() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oworail, pg_temp
AS $$
DECLARE
    v_status  text;
    v_lines   integer;
    v_debits  bigint;
    v_credits bigint;
BEGIN
    SELECT t.status INTO v_status
    FROM transaction t WHERE t.transaction_id = NEW.transaction_id;

    SELECT count(*),
           coalesce(sum(l.amount_kobo) FILTER (WHERE l.entry_type = 'DEBIT'), 0),
           coalesce(sum(l.amount_kobo) FILTER (WHERE l.entry_type = 'CREDIT'), 0)
    INTO v_lines, v_debits, v_credits
    FROM ledger_entry l WHERE l.transaction_id = NEW.transaction_id;

    IF v_status IN ('SUCCESSFUL', 'REVERSED') THEN
        IF v_lines < 2 OR v_debits <> v_credits THEN
            RAISE EXCEPTION USING
                ERRCODE    = 'check_violation',
                CONSTRAINT = TG_NAME,
                MESSAGE    = format('transaction %s (%s) is not balanced: %s lines, debits %s, credits %s',
                                    NEW.transaction_id, v_status, v_lines, v_debits, v_credits),
                HINT       = 'BR-13: a posted transaction needs at least two lines and debits = credits';
        END IF;
    ELSIF v_lines > 0 THEN
        RAISE EXCEPTION USING
            ERRCODE    = 'check_violation',
            CONSTRAINT = TG_NAME,
            MESSAGE    = format('transaction %s has status %s but %s ledger lines',
                                NEW.transaction_id, v_status, v_lines),
            HINT       = 'BR-13: only SUCCESSFUL or REVERSED transactions have ledger entries';
    END IF;
    RETURN NULL;
END
$$;

CREATE CONSTRAINT TRIGGER trg_ledger_entry_balanced
    AFTER INSERT ON ledger_entry
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();

CREATE CONSTRAINT TRIGGER trg_transaction_balanced
    AFTER INSERT OR UPDATE OF status ON transaction
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_transaction_balanced();


CREATE FUNCTION reject_change() RETURNS trigger
LANGUAGE plpgsql
SET search_path = oworail, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION USING
        ERRCODE    = 'object_not_in_prerequisite_state',
        CONSTRAINT = TG_NAME,
        MESSAGE    = format('%s is append-only: %s is not allowed', TG_TABLE_NAME, TG_OP),
        HINT       = 'correct it with a new compensating record instead';
END
$$;

CREATE TRIGGER trg_ledger_entry_append_only
    BEFORE UPDATE OR DELETE ON ledger_entry
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER trg_ledger_entry_no_truncate
    BEFORE TRUNCATE ON ledger_entry
    FOR EACH STATEMENT EXECUTE FUNCTION reject_change();

CREATE TRIGGER trg_transaction_status_history_append_only
    BEFORE UPDATE OR DELETE ON transaction_status_history
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER trg_transaction_status_history_no_truncate
    BEFORE TRUNCATE ON transaction_status_history
    FOR EACH STATEMENT EXECUTE FUNCTION reject_change();

CREATE TRIGGER trg_audit_log_append_only
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION reject_change();
CREATE TRIGGER trg_audit_log_no_truncate
    BEFORE TRUNCATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION reject_change();


CREATE VIEW v_customer WITH (security_invoker = true) AS
SELECT c.customer_id, c.full_name, c.email, c.date_of_birth,
       c.address_street, c.address_city, c.address_state, c.status, c.created_at,
       extract(year FROM age(current_date, c.date_of_birth))::integer AS age_years
FROM customer c;
COMMENT ON VIEW v_customer IS 'CUSTOMER with the derived attribute age';

CREATE VIEW v_wallet_balance WITH (security_invoker = true) AS
SELECT w.wallet_id, w.wallet_number, w.wallet_type, w.status,
       w.balance_kobo,
       coalesce(l.ledger_balance_kobo, 0)                  AS ledger_balance_kobo,
       w.balance_kobo - coalesce(l.ledger_balance_kobo, 0) AS difference_kobo
FROM wallet w
LEFT JOIN (
    SELECT wallet_id,
           sum(CASE entry_type WHEN 'CREDIT' THEN amount_kobo ELSE -amount_kobo END)
               AS ledger_balance_kobo
    FROM ledger_entry
    GROUP BY wallet_id
) l ON l.wallet_id = w.wallet_id;
COMMENT ON VIEW v_wallet_balance IS
    'BR-14 / FR-08: stored balance against the ledger balance (credits - debits)';

CREATE VIEW v_transaction WITH (security_invoker = true) AS
SELECT t.transaction_id, t.transaction_ref, t.transaction_type,
       t.source_wallet_id, t.destination_wallet_id,
       t.amount_kobo, t.fee_kobo,
       t.amount_kobo + t.fee_kobo AS total_debit_kobo,
       t.fee_rule_id, t.status, t.channel, t.bill_reference, t.narration, t.created_at
FROM transaction t;
COMMENT ON VIEW v_transaction IS 'TRANSACTION with the derived attribute total_debit_kobo';

RESET ROLE;
