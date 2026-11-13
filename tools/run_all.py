#!/usr/bin/env python3
"""Run every portfolio's end-to-end pipeline in order: python tools/run_all.py [portfolio numbers]."""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PIPELINES = {
    1: "portfolio-1-database-design/scripts/build_and_test.py",
    2: "portfolio-2-query-optimisation/scripts/run_portfolio2.py",
    3: "portfolio-3-transactions-concurrency/scripts/run_portfolio3.py",
    4: "portfolio-4-nosql/scripts/run_portfolio4.py",
    5: "portfolio-5-distributed-cloud/scripts/run_portfolio5.py",
}


def main() -> int:
    selected = [int(a) for a in sys.argv[1:]] or list(PIPELINES)
    if any(p < 5 for p in selected):
        subprocess.run(["docker", "compose", "up", "-d", "--wait"], cwd=REPO, check=True)
    results = []
    for p in selected:
        print(f"\n######## Portfolio {p}: {PIPELINES[p]}", flush=True)
        t0 = time.perf_counter()
        code = subprocess.run([sys.executable, PIPELINES[p]], cwd=REPO).returncode
        results.append((p, code, time.perf_counter() - t0))
        if code != 0:
            break
    print("\nportfolio  exit  minutes")
    for p, code, seconds in results:
        print(f"{p:>9}  {code:>4}  {seconds / 60:7.1f}")
    return max(code for _, code, _ in results)


if __name__ == "__main__":
    sys.exit(main())
