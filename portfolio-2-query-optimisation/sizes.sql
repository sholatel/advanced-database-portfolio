-- Table and index sizes for the two large tables.
SET search_path = oworail, public;
\pset footer off
SELECT t.relname AS table_name, c.relname AS index_name,
       pg_size_pretty(pg_relation_size(c.oid)) AS size, pg_relation_size(c.oid) AS bytes
FROM pg_index i
JOIN pg_class c ON c.oid = i.indexrelid
JOIN pg_class t ON t.oid = i.indrelid
WHERE t.relnamespace = 'oworail'::regnamespace AND t.relname IN ('transaction', 'ledger_entry')
UNION ALL
SELECT t.relname, '(table)', pg_size_pretty(pg_table_size(t.oid)), pg_table_size(t.oid)
FROM pg_class t
WHERE t.relnamespace = 'oworail'::regnamespace AND t.relname IN ('transaction', 'ledger_entry')
ORDER BY 1, 4 DESC;
SELECT pg_size_pretty(sum(pg_relation_size(i.indexrelid))) AS total_index_size
FROM pg_index i JOIN pg_class t ON t.oid = i.indrelid
WHERE t.relnamespace = 'oworail'::regnamespace AND t.relname IN ('transaction', 'ledger_entry');
