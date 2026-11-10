#!/usr/bin/env python3
"""Rebuild the OwoRail database, run every test and save the outputs as evidence.

Steps (each captured by tools/capture_evidence.py into evidence/):
  1. sql/build.sql                 roles, schema, rules, procedures, grants, seed
  2. sql/build.sql again           shows the build is safe to re-run
  3. tests/constraint_tests.sql    every named constraint, the triggers, ON DELETE rules
  4. tests/procedure_tests.sql     fees, limits, idempotency, reversals, onboarding, KYC
  5. tests/role_tests.sql          least-privilege roles
  6. tests/consistency_checks.sql  multi-row rules and reconciliation, after the tests
  7. scripts/check_catalogue.py    database catalogue against schema.md

Stops at the first failing step. Needs the containers running (docker compose up -d).

  .venv/Scripts/python portfolio-1-database-design/scripts/build_and_test.py
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CAPTURE = REPO / "tools" / "capture_evidence.py"
EVIDENCE = "portfolio-1-database-design/evidence"
SQL = "/workspace/portfolio-1-database-design/sql"
PSQL = ["docker", "compose", "exec", "-T", "postgres",
        "psql", "-U", "postgres", "-d", "oworail", "-X", "-v", "ON_ERROR_STOP=1", "-f"]

STEPS = [
    # (evidence file, title, command, append)
    ("m4_build.txt", "Build the OwoRail database from scratch",
     PSQL + [f"{SQL}/build.sql"], False),
    ("m4_build.txt", "Build again on top of the first build (safe to re-run)",
     PSQL + [f"{SQL}/build.sql"], True),
    ("m4_constraint_tests.txt", "Constraint, trigger and ON DELETE tests",
     PSQL + [f"{SQL}/tests/constraint_tests.sql"], False),
    ("m4_procedure_tests.txt", "Procedure tests: fees, limits, idempotency, reversals, onboarding, KYC",
     PSQL + [f"{SQL}/tests/procedure_tests.sql"], False),
    ("m4_role_tests.txt", "Role and privilege tests (least privilege)",
     PSQL + [f"{SQL}/tests/role_tests.sql"], False),
    ("m4_consistency.txt", "Consistency checks and reconciliation, run after all tests",
     PSQL + [f"{SQL}/tests/consistency_checks.sql"], False),
    ("m4_catalogue_check.txt", "Database catalogue compared with schema.md",
     [sys.executable, "portfolio-1-database-design/scripts/check_catalogue.py"], False),
]


def main() -> int:
    for out, title, cmd, append in STEPS:
        print(f"\n### {title}")
        args = [sys.executable, str(CAPTURE), "--db", "postgres",
                "--out", f"{EVIDENCE}/{out}", "--title", title]
        if append:
            args.append("--append")
        code = subprocess.run(args + ["--"] + cmd, cwd=REPO).returncode
        if code != 0:
            print(f"\nstopped: '{title}' exited with {code}")
            return code
    print("\nall steps passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
