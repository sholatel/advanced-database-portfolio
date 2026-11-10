
DO $$
DECLARE
    r text;
BEGIN
    FOREACH r IN ARRAY ARRAY[
        'oworail_owner',       -- schema owner (DBA work runs as this role)
        'oworail_app',         -- payments application service account
        'oworail_support',     -- customer-support agents
        'oworail_compliance',  -- KYC / compliance analysts
        'oworail_analyst',     -- fraud and finance / reconciliation analysts
        'oworail_auditor'      -- internal auditors
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
            RAISE NOTICE 'created role %', r;
        END IF;
    END LOOP;
END
$$;

SELECT rolname, rolcanlogin, rolsuper, rolinherit
FROM pg_roles
WHERE rolname LIKE 'oworail\_%'
ORDER BY rolname;
