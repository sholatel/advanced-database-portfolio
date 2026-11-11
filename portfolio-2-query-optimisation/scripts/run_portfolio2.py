#!/usr/bin/env python3
"""Portfolio 2 end to end: rebuild, load volume data, measure, optimise, measure again.

Every step is captured into evidence/ with tools/capture_evidence.py. Takes about
15-20 minutes, most of it the volume load. Stops at the first failing step.

  .venv/Scripts/python portfolio-2-query-optimisation/scripts/run_portfolio2.py
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CAPTURE = REPO / "tools" / "capture_evidence.py"
EV = "portfolio-2-query-optimisation/evidence"
P1 = "/workspace/portfolio-1-database-design/sql"
P2 = "/workspace/portfolio-2-query-optimisation"
PSQL = ["docker", "compose", "exec", "-T", "postgres",
        "psql", "-U", "postgres", "-d", "oworail", "-X", "-v", "ON_ERROR_STOP=1"]
PLANS = [sys.executable, "portfolio-2-query-optimisation/scripts/run_plans.py"]

STEPS = [
    ("m5_volume_load.txt", "Rebuild the database from scratch", PSQL + ["-q", "-f", f"{P1}/build.sql"], False),
    ("m5_volume_load.txt", "Load the volume dataset", PSQL + ["-f", f"{P2}/data/generate_volume.sql"], True),
    ("m5_volume_consistency.txt", "Business-rule consistency checks over the full volume",
     PSQL + ["-v", "brief=1", "-f", f"{P1}/tests/consistency_checks.sql"], False),
    ("m5_sizes_before.txt", "Table and index sizes before optimisation", PSQL + ["-f", f"{P2}/sizes.sql"], False),
    ("m5_write_cost_before.txt", "Posting cost before the workload indexes", PSQL + ["-f", f"{P2}/write_cost.sql"], False),
    ("m5_plans_before.txt", "Baseline: workload timings and plans",
     PLANS + ["--phase", "before", "--queries", "queries.sql"], False),
    ("m6_indexes.txt", "Create the workload indexes", PSQL + ["-f", f"{P2}/indexes.sql"], False),
    ("m6_write_cost_after.txt", "Posting cost after the workload indexes", PSQL + ["-f", f"{P2}/write_cost.sql"], False),
    ("m6_plans_indexes.txt", "After indexes: workload timings and plans",
     PLANS + ["--phase", "indexes", "--queries", "queries.sql"], False),
    ("m6_tuning.txt", "Statistics target and materialised view", PSQL + ["-f", f"{P2}/tuning.sql"], False),
    ("m6_plans_final.txt", "After indexes, statistics, materialised view and rewrites: timings and plans",
     PLANS + ["--phase", "final", "--queries", "queries_rewritten.sql"], False),
    ("m6_sizes_after.txt", "Table and index sizes after optimisation", PSQL + ["-f", f"{P2}/sizes.sql"], False),
    ("m6_experiments.txt", "Supporting experiments", PSQL + ["-f", f"{P2}/experiments.sql"], False),
    ("m6_comparison.txt", "Before and after comparison",
     PLANS + ["--compare", "before", "indexes", "final"], False),
]


def main() -> int:
    subprocess.run(["docker", "compose", "stop", "mongo"], cwd=REPO)   # not needed here; keeps CPU free
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
