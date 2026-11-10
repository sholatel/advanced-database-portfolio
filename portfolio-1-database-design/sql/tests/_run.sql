-- Runs every row of test_case through pg_temp.probe, prints the results and
-- fails the script (non-zero exit with ON_ERROR_STOP) if any test failed.

CREATE TEMP TABLE test_result AS
SELECT c.id, c.area, c.label, c.expected, r.actual,
       (r.actual = c.expected
        OR (c.expected LIKE 'error%' AND r.actual LIKE c.expected)) AS passed
FROM test_case c
CROSS JOIN LATERAL (SELECT pg_temp.probe(c.test_sql, c.check_sql, c.as_role) AS actual) r
ORDER BY c.id;

SELECT id AS "#", area, label, expected, actual,
       CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM test_result
ORDER BY id;

SELECT count(*)                         AS tests,
       count(*) FILTER (WHERE passed)     AS passed,
       count(*) FILTER (WHERE NOT passed) AS failed
FROM test_result;

DO $$
DECLARE
    v_failed integer;
BEGIN
    SELECT count(*) INTO v_failed FROM test_result WHERE NOT passed;
    IF v_failed > 0 THEN
        RAISE EXCEPTION '% test(s) failed', v_failed;
    END IF;
END
$$;
