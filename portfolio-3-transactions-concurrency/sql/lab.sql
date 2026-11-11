-- Scratch tables for the deliberately unsafe patterns; never part of the OwoRail schema.

\set ON_ERROR_STOP on
SET client_min_messages = warning;
DROP SCHEMA IF EXISTS lab CASCADE;
RESET client_min_messages;
CREATE SCHEMA lab;

CREATE TABLE lab.account (
    account_id    integer PRIMARY KEY,
    owner         text    NOT NULL,
    kind          text    NOT NULL,
    balance_kobo  bigint  NOT NULL
);

CREATE FUNCTION lab.reset() RETURNS void LANGUAGE sql AS $$
    DELETE FROM lab.account;
    INSERT INTO lab.account VALUES
        (1, 'Adaeze Okafor', 'MAIN',    100000),
        (2, 'Adaeze Okafor', 'SAVINGS', 100000),
        (3, 'Tunde Bakare',  'MAIN',    100000);
$$;

CREATE FUNCTION lab.transfer_unordered(p_from integer, p_to integer, p_amount bigint)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE lab.account SET balance_kobo = balance_kobo - p_amount WHERE account_id = p_from;
    PERFORM pg_sleep(0.005);
    UPDATE lab.account SET balance_kobo = balance_kobo + p_amount WHERE account_id = p_to;
END $$;

CREATE FUNCTION lab.transfer_ordered(p_from integer, p_to integer, p_amount bigint)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM lab.account WHERE account_id IN (p_from, p_to) ORDER BY account_id FOR UPDATE;
    UPDATE lab.account SET balance_kobo = balance_kobo - p_amount WHERE account_id = p_from;
    PERFORM pg_sleep(0.005);
    UPDATE lab.account SET balance_kobo = balance_kobo + p_amount WHERE account_id = p_to;
END $$;

SELECT lab.reset();
SELECT * FROM lab.account ORDER BY account_id;
