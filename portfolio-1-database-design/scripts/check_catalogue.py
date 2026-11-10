#!/usr/bin/env python3
"""Check that the built database matches the logical design in schema.md.

Reads the PostgreSQL system catalogue and compares it with the design document:

  1. every named constraint in schema.md exists in the database, and no other;
  2. constraint counts by kind (13 PK, 11 UNIQUE, 15 FK, 54 CHECK, 1 EXCLUDE);
  3. each table has exactly the columns of the text notation, in that order
     (89 columns), and normalisation.md ends with the same relations;
  4. ON DELETE rules: CASCADE only for phones and saved beneficiaries;
  5. the balanced-ledger triggers are DEFERRABLE INITIALLY DEFERRED;
  6. every foreign key is covered by an index;
  7. no role except the owner can UPDATE, DELETE or TRUNCATE the append-only
     tables, and PUBLIC cannot execute any function.

Connection settings come from .env (the same file docker compose uses).
Exit code 0 when every check passes, 1 otherwise.

  .venv/Scripts/python portfolio-1-database-design/scripts/check_catalogue.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import psycopg
from tabulate import tabulate

REPO = Path(__file__).resolve().parents[2]
P1 = REPO / "portfolio-1-database-design"
SCHEMA = "oworail"

EXPECTED_COUNTS = {"p": 13, "u": 11, "f": 15, "c": 54, "x": 1}
KIND = {"p": "PRIMARY KEY", "u": "UNIQUE", "f": "FOREIGN KEY", "c": "CHECK", "x": "EXCLUDE"}
CASCADE_FKS = {"fk_customer_phone_customer", "fk_saved_beneficiary_customer",
               "fk_saved_beneficiary_wallet"}
APPEND_ONLY = ["ledger_entry", "transaction_status_history", "audit_log"]
DEFERRED_TRIGGERS = {"trg_ledger_entry_balanced", "trg_transaction_balanced"}

results: list[tuple[str, str, str]] = []


def record(check: str, ok: bool, detail: str) -> None:
    results.append((check, "PASS" if ok else "FAIL", detail))


def read_env() -> dict[str, str]:
    env = {}
    for line in (REPO / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, _, value = line.partition("=")
            env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def text_notation(md: str, after_heading: str) -> dict[str, list[str]]:
    """Relations from the first ```text block after a heading: {table: [columns]}."""
    start = md.index(after_heading)
    block = re.search(r"```text\n(.*?)```", md[start:], re.S).group(1)
    relations = {}
    for line in block.strip().splitlines():
        m = re.match(r"(\w+)\s*\((.*)\)\s*$", line.strip())
        cols = [c.strip().lstrip("#").split("→")[0].strip() for c in m.group(2).split(",")]
        relations[m.group(1)] = cols
    return relations


def main() -> int:
    schema_md = (P1 / "schema.md").read_text(encoding="utf-8")
    norm_md = (P1 / "normalisation.md").read_text(encoding="utf-8")
    env = read_env()

    conn = psycopg.connect(
        host="127.0.0.1",
        port=int(env.get("PG_HOST_PORT", "5433")),
        user=env.get("POSTGRES_USER", "postgres"),
        password=env["POSTGRES_PASSWORD"],
        dbname=env.get("POSTGRES_DB", "oworail"),
    )
    cur = conn.cursor()

    # 1-2. constraints -----------------------------------------------------------
    doc_names = set(re.findall(r"`((?:pk|fk|uq|chk|excl)_[a-z0-9_]+)`", schema_md))
    cur.execute("""
        SELECT con.conname, con.contype, cl.relname, con.confdeltype
        FROM pg_constraint con
        JOIN pg_class cl ON cl.oid = con.conrelid
        JOIN pg_namespace n ON n.oid = cl.relnamespace
        WHERE n.nspname = %s AND con.contype IN ('p', 'u', 'f', 'c', 'x')
    """, (SCHEMA,))
    rows = cur.fetchall()
    db_names = {r[0] for r in rows}
    missing, extra = sorted(doc_names - db_names), sorted(db_names - doc_names)
    record("constraint names: schema.md vs database", not missing and not extra,
           f"{len(doc_names)} in schema.md, {len(db_names)} in database"
           + (f"; missing: {missing}" if missing else "")
           + (f"; not documented: {extra}" if extra else ""))

    counts = {k: sum(1 for r in rows if r[1] == k) for k in EXPECTED_COUNTS}
    record("constraint counts by kind", counts == EXPECTED_COUNTS,
           ", ".join(f"{KIND[k]} {counts[k]}/{EXPECTED_COUNTS[k]}" for k in EXPECTED_COUNTS)
           + f"; total {sum(counts.values())}")

    # 3. columns -------------------------------------------------------------------
    design = text_notation(schema_md, "## 2. Relational schema")
    final = text_notation(norm_md, "### Final relations")
    record("normalisation.md final relations = schema.md", design == final,
           f"{len(final)} relations compared")

    cur.execute("""
        SELECT table_name, array_agg(column_name::text ORDER BY ordinal_position)
        FROM information_schema.columns
        WHERE table_schema = %s
          AND table_name IN (SELECT table_name FROM information_schema.tables
                             WHERE table_schema = %s AND table_type = 'BASE TABLE')
        GROUP BY table_name
    """, (SCHEMA, SCHEMA))
    actual = dict(cur.fetchall())
    diffs = [t for t in sorted(set(design) | set(actual)) if design.get(t) != actual.get(t)]
    total_cols = sum(len(c) for c in actual.values())
    record("tables and columns match the text notation", not diffs and total_cols == 89,
           f"{len(actual)} tables, {total_cols} columns" + (f"; differ: {diffs}" if diffs else ""))

    # 4. delete rules --------------------------------------------------------------
    wrong = [f"{r[0]}={r[3]}" for r in rows if r[1] == "f"
             and r[3] != ("c" if r[0] in CASCADE_FKS else "r")]
    record("ON DELETE: CASCADE for 3 FKs, RESTRICT for the other 12", not wrong,
           "all as designed" if not wrong else f"unexpected: {wrong}")

    # 5. deferred constraint triggers ------------------------------------------------
    cur.execute("""
        SELECT t.tgname, t.tgdeferrable, t.tginitdeferred
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = %s AND t.tgconstraint <> 0 AND NOT t.tgisinternal
    """, (SCHEMA,))
    trig = {r[0]: (r[1], r[2]) for r in cur.fetchall()}
    ok = set(trig) == DEFERRED_TRIGGERS and all(v == (True, True) for v in trig.values())
    record("balanced-ledger triggers DEFERRABLE INITIALLY DEFERRED", ok,
           ", ".join(sorted(trig)) or "none found")

    # 6. FK index coverage -----------------------------------------------------------
    cur.execute("""
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_namespace n ON n.oid = con.connamespace
        WHERE n.nspname = %s AND con.contype = 'f'
          AND NOT EXISTS (
              SELECT 1 FROM pg_index i
              WHERE i.indrelid = con.conrelid
                AND (i.indkey::int2[])[0:cardinality(con.conkey) - 1] = con.conkey)
    """, (SCHEMA,))
    uncovered = [r[0] for r in cur.fetchall()]
    record("every foreign key has a supporting index", not uncovered,
           "15 of 15 covered" if not uncovered else f"no index: {uncovered}")

    # 7. privileges ------------------------------------------------------------------
    cur.execute("""
        SELECT r.rolname, c.relname, p.priv
        FROM pg_roles r
        CROSS JOIN (SELECT oid, relname FROM pg_class
                    WHERE relnamespace = %s::regnamespace AND relname = ANY(%s)) c
        CROSS JOIN unnest(ARRAY['UPDATE', 'DELETE', 'TRUNCATE']) AS p(priv)
        WHERE r.rolname LIKE 'oworail\\_%%' AND r.rolname <> 'oworail_owner'
          AND has_table_privilege(r.oid, c.oid, p.priv)
    """, (SCHEMA, APPEND_ONLY))
    leaks = [f"{r[0]}:{r[2]} {r[1]}" for r in cur.fetchall()]
    record("no role can UPDATE/DELETE/TRUNCATE append-only tables", not leaks,
           f"{', '.join(APPEND_ONLY)}" if not leaks else f"granted: {leaks}")

    cur.execute("""
        SELECT p.proname FROM pg_proc p
        WHERE p.pronamespace = %s::regnamespace
          AND has_function_privilege('public', p.oid, 'EXECUTE')
          AND p.prorettype <> 'trigger'::regtype
    """, (SCHEMA,))
    public_exec = [r[0] for r in cur.fetchall()]
    record("PUBLIC cannot execute any function", not public_exec,
           "revoked" if not public_exec else f"executable: {public_exec}")

    # report -------------------------------------------------------------------------
    cur.execute("""
        SELECT c.relname AS table_name, i.relname AS index_name,
               pg_get_indexdef(i.oid) AS definition
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        JOIN pg_class c ON c.oid = x.indrelid
        WHERE c.relnamespace = %s::regnamespace
        ORDER BY c.relname, i.relname
    """, (SCHEMA,))
    indexes = cur.fetchall()
    conn.close()

    print("Catalogue check: database 'oworail', schema 'oworail' vs schema.md\n")
    print(tabulate(results, headers=["check", "result", "detail"], tablefmt="github"))
    print("\nConstraints by table and kind:\n")
    per_table: dict[str, dict[str, int]] = {}
    for name, kind, table, _ in rows:
        per_table.setdefault(table, dict.fromkeys(EXPECTED_COUNTS, 0))[kind] += 1
    table_rows = [[t, *(v[k] for k in EXPECTED_COUNTS), sum(v.values())]
                  for t, v in sorted(per_table.items())]
    table_rows.append(["total", *(counts[k] for k in EXPECTED_COUNTS), sum(counts.values())])
    print(tabulate(table_rows, headers=["table", "PK", "UNIQUE", "FK", "CHECK", "EXCLUDE", "total"],
                   tablefmt="github"))
    print(f"\nIndexes ({len(indexes)}):\n")
    print(tabulate(indexes, headers=["table", "index", "definition"], tablefmt="github"))

    failed = sum(1 for r in results if r[1] == "FAIL")
    print(f"\n{len(results) - failed} of {len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
