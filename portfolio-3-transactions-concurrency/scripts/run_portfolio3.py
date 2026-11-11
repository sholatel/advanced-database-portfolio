"""Portfolio 3 end to end, with every step captured into evidence/."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CAPTURE = REPO / "tools" / "capture_evidence.py"
EV = "portfolio-3-transactions-concurrency/evidence"
SCRIPTS = "portfolio-3-transactions-concurrency/scripts"
PSQL = ["docker", "compose", "exec", "-T", "postgres",
        "psql", "-U", "postgres", "-d", "oworail", "-X", "-v", "ON_ERROR_STOP=1"]

STEPS = [
    ("m7_setup.txt", "Fresh build of the database", PSQL + ["-q", "-f", "/workspace/portfolio-1-database-design/sql/build.sql"], False),
    ("m7_setup.txt", "Lab schema for the unsafe patterns",
     PSQL + ["-f", "/workspace/portfolio-3-transactions-concurrency/sql/lab.sql"], True),
    ("m7_transactions.txt", "Commit, rollback, errors, savepoints, atomicity and durability",
     [sys.executable, f"{SCRIPTS}/transactions.py"], False),
    ("m8_isolation.txt", "Isolation levels and read anomalies", [sys.executable, f"{SCRIPTS}/isolation.py"], False),
    ("m8_locking.txt", "Lost update, row locks, deadlocks and post_transaction under concurrency",
     [sys.executable, f"{SCRIPTS}/locking.py"], False),
    ("m8_consistency_after.txt", "Business-rule consistency checks after all concurrency tests",
     PSQL + ["-v", "brief=1", "-f", "/workspace/portfolio-1-database-design/sql/tests/consistency_checks.sql"], False),
]


def main() -> int:
    for out, title, cmd, append in STEPS:
        print(f"\n### {title}", flush=True)
        args = [sys.executable, str(CAPTURE), "--db", "postgres", "--out", f"{EV}/{out}", "--title", title]
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
