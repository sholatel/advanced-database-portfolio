-- Test harness shared by the test scripts (included with \ir).
--
-- pg_temp.probe(test_sql, check_sql, as_role) runs test_sql inside a
-- subtransaction and always rolls it back, so no test changes the database.
-- It returns:
--   * the name of the violated constraint or trigger, if test_sql failed on one;
--   * 'not null: table.column' for a NOT NULL violation;
--   * 'permission denied' for a privilege error;
--   * 'error <SQLSTATE>: <message>' for any other error;
--   * otherwise the result of check_sql (as text), or 'NO ERROR' if there is none.
-- If as_role is given, test_sql runs under SET LOCAL ROLE as_role.
--
-- A test passes when the result equals the expected value. An expected value
-- starting with 'error' is matched with LIKE, so it can end in a wildcard.

SET search_path = oworail, public;

CREATE FUNCTION pg_temp.probe(p_test_sql text, p_check_sql text DEFAULT NULL,
                              p_as_role text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    v_state  text;
    v_con    text;
    v_msg    text;
    v_table  text;
    v_column text;
    v_result text;
BEGIN
    BEGIN
        IF p_as_role IS NOT NULL THEN
            EXECUTE format('SET LOCAL ROLE %I', p_as_role);
        END IF;
        EXECUTE p_test_sql;
        IF p_as_role IS NOT NULL THEN
            RESET ROLE;            -- the check runs with full rights
        END IF;
        IF p_check_sql IS NULL THEN
            v_result := 'NO ERROR';
        ELSE
            EXECUTE p_check_sql INTO v_result;
        END IF;
        -- roll the test back on purpose; OWR00 marks "this was not a real error"
        RAISE EXCEPTION USING ERRCODE = 'OWR00', MESSAGE = coalesce(v_result, '<null>');
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS
            v_state  = RETURNED_SQLSTATE,
            v_con    = CONSTRAINT_NAME,
            v_msg    = MESSAGE_TEXT,
            v_table  = TABLE_NAME,
            v_column = COLUMN_NAME;
    END;

    RETURN CASE
        WHEN v_state = 'OWR00' THEN v_msg
        WHEN v_con <> ''       THEN v_con
        WHEN v_state = '23502' THEN format('not null: %s.%s', v_table, v_column)
        WHEN v_state = '42501' THEN 'permission denied'
        ELSE format('error %s: %s', v_state, v_msg)
    END;
END
$$;

-- Short lookups from natural keys to surrogate keys, to keep the tests readable.
CREATE FUNCTION pg_temp.w(p_wallet_number text) RETURNS bigint LANGUAGE sql STABLE
AS $$ SELECT wallet_id FROM oworail.wallet WHERE wallet_number = p_wallet_number $$;
CREATE FUNCTION pg_temp.c(p_email text) RETURNS bigint LANGUAGE sql STABLE
AS $$ SELECT customer_id FROM oworail.customer WHERE email = p_email $$;
CREATE FUNCTION pg_temp.m(p_merchant_code text) RETURNS bigint LANGUAGE sql STABLE
AS $$ SELECT merchant_id FROM oworail.merchant WHERE merchant_code = p_merchant_code $$;
CREATE FUNCTION pg_temp.t(p_transaction_ref text) RETURNS bigint LANGUAGE sql STABLE
AS $$ SELECT transaction_id FROM oworail.transaction WHERE transaction_ref = p_transaction_ref $$;

CREATE TEMP TABLE test_case (
    id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    area       text NOT NULL,
    label      text NOT NULL,
    expected   text NOT NULL,
    test_sql   text NOT NULL,
    check_sql  text,
    as_role    text
);
