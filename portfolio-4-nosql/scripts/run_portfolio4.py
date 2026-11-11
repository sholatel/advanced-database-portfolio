"""Portfolio 4 end to end, with every step captured into evidence/. --from N restarts at step N."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CAPTURE = REPO / "tools" / "capture_evidence.py"
EV = "portfolio-4-nosql/evidence"
SCRIPTS = "portfolio-4-nosql/scripts"
PSQL = ["docker", "compose", "exec", "-T", "postgres",
        "psql", "-U", "postgres", "-d", "oworail", "-X", "-v", "ON_ERROR_STOP=1"]

STEPS = [
    ("m9_source_data.txt", "postgres", "Fresh PostgreSQL build",
     PSQL + ["-q", "-f", "/workspace/portfolio-1-database-design/sql/build.sql"], False),
    ("m9_source_data.txt", "postgres", "Volume data in PostgreSQL (the source for MongoDB)",
     PSQL + ["-f", "/workspace/portfolio-2-query-optimisation/data/generate_volume.sql"], True),
    ("m9_schema.txt", "mongo", "MongoDB collections, validators and integrity indexes",
     [sys.executable, f"{SCRIPTS}/schema.py"], False),
    ("m9_load.txt", "mongo", "Load from PostgreSQL into documents", [sys.executable, f"{SCRIPTS}/load.py"], False),
    ("m9_queries.txt", "mongo", "Workload before and after indexes, checked against PostgreSQL",
     [sys.executable, f"{SCRIPTS}/queries.py"], False),
    ("m9_validation.txt", "mongo", "Schema validation, unique indexes and a least-privilege view",
     [sys.executable, f"{SCRIPTS}/validation.py"], False),
    ("m9_transactions.txt", "mongo", "Multi-document transactions", [sys.executable, f"{SCRIPTS}/transfers.py"], False),
]


def main() -> int:
    start = int(sys.argv[sys.argv.index("--from") + 1]) if "--from" in sys.argv else 1
    subprocess.run(["docker", "compose", "up", "-d", "--wait", "postgres", "mongo"], cwd=REPO)
    for out, db, title, cmd, append in STEPS[start - 1:]:
        print(f"\n### {title}", flush=True)
        args = [sys.executable, str(CAPTURE), "--db", db, "--out", f"{EV}/{out}", "--title", title]
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
