#!/usr/bin/env python3
"""Run the query workload and record execution plans and timings for one phase.

  run_plans.py --phase before  --queries queries.sql
  run_plans.py --compare before indexes final
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
import sys
from pathlib import Path

import psycopg
from psycopg import errors
from tabulate import tabulate

REPO = Path(__file__).resolve().parents[2]
P2 = REPO / "portfolio-2-query-optimisation"
SCAN = re.compile(r"((?:Parallel )?(?:Seq Scan|Index Only Scan|Index Scan|Bitmap Index Scan|Bitmap Heap Scan)"
                  r"(?: Backward)?)(?: using (\S+))? on (\S+)")
SETTINGS = ["server_version", "shared_buffers", "work_mem", "effective_cache_size", "random_page_cost",
            "max_parallel_workers_per_gather", "jit"]


def read_env() -> dict[str, str]:
    env = {}
    for line in (REPO / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


def connect() -> psycopg.Connection:
    env = read_env()
    conn = psycopg.connect(host="127.0.0.1", port=int(env.get("PG_HOST_PORT", "5433")),
                           user=env.get("POSTGRES_USER", "postgres"), password=env["POSTGRES_PASSWORD"],
                           dbname=env.get("POSTGRES_DB", "oworail"), autocommit=True)
    conn.execute("SET search_path = oworail, public")
    return conn


def load_queries(path: Path) -> list[tuple[str, str, str]]:
    """[(id, title, sql)] from '-- Qn: title' blocks."""
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"^-- (Q\d+): (.*)$", text, flags=re.M)
    return [(parts[i], parts[i + 1].strip(), parts[i + 2].strip().rstrip(";"))
            for i in range(1, len(parts), 3)]


def top_buffers(plan: str) -> int | None:
    """Shared buffers (hit + read) of the whole plan: the first Buffers line."""
    m = re.search(r"Buffers: shared( hit=(\d+))?( read=(\d+))?", plan)
    return int(m.group(2) or 0) + int(m.group(4) or 0) if m else None


def access_paths(plan: str) -> list[str]:
    seen = []
    for m in SCAN.finditer(plan):
        item = f"{m.group(1)} {m.group(3)}" + (f" ({m.group(2)})" if m.group(2) else "")
        if item not in seen:
            seen.append(item)
    return seen


def run_phase(phase: str, queries_file: Path, runs: int, timeout_s: int) -> None:
    conn = connect()
    settings = {s: conn.execute(f"SHOW {s}").fetchone()[0] for s in SETTINGS}
    plan_dir, result_dir = P2 / "plans" / phase, P2 / "results" / phase
    plan_dir.mkdir(parents=True, exist_ok=True)
    result_dir.mkdir(parents=True, exist_ok=True)
    summary = []

    for qid, title, sql in load_queries(queries_file):
        conn.execute(f"SET statement_timeout = '{timeout_s}s'")
        entry = {"query": qid, "title": title}
        try:
            cur = conn.execute(sql)                       # warm-up run, also the result
            cols = [d.name for d in cur.description]
            rows = cur.fetchall()
            entry["rows"] = len(rows)
            entry["result_md5"] = hashlib.md5(repr(rows).encode()).hexdigest()
            (result_dir / f"{qid}.txt").write_text(
                f"{qid}: {title}\n{len(rows)} rows (first 25 shown)\n\n"
                + tabulate(rows[:25], headers=cols, tablefmt="psql") + "\n", encoding="utf-8", newline="\n")

            times, plans = [], []
            for _ in range(runs):
                plan = "\n".join(r[0] for r in conn.execute(
                    "EXPLAIN (ANALYZE, BUFFERS) " + sql).fetchall())
                times.append(float(re.search(r"Execution Time: ([\d.]+) ms", plan).group(1)))
                plans.append(plan)
            median = statistics.median(times)
            plan = plans[times.index(min(times, key=lambda t: abs(t - median)))]
            entry.update(median_ms=round(median, 3), min_ms=round(min(times), 3), max_ms=round(max(times), 3),
                         planning_ms=float(re.search(r"Planning Time: ([\d.]+) ms", plan).group(1)),
                         top_node=plan.splitlines()[0].split("  (")[0].strip(),
                         buffers=top_buffers(plan), access=access_paths(plan), timed_out=False)
        except errors.QueryCanceled:
            conn.execute("SET statement_timeout = 0")
            plan = "\n".join(r[0] for r in conn.execute("EXPLAIN " + sql).fetchall())
            plan = f"-- cancelled after {timeout_s} s; plan without ANALYZE:\n{plan}"
            entry.update(median_ms=None, timed_out=True, top_node=plan.splitlines()[1].split("  (")[0].strip(),
                         access=access_paths(plan), rows=None, result_md5=None, buffers=None)
        (plan_dir / f"{qid}.txt").write_text(
            f"{qid}: {title}\nphase: {phase}\n\n{sql};\n\n{plan}\n", encoding="utf-8", newline="\n")
        summary.append(entry)
        shown = "TIMEOUT" if entry["timed_out"] else f"{entry['median_ms']} ms"
        print(f"{qid:4} {shown:>14}  {title}")

    conn.execute("SET statement_timeout = 0")
    (P2 / "results" / f"timings_{phase}.json").write_text(
        json.dumps({"phase": phase, "queries_file": queries_file.name, "runs": runs, "timeout_s": timeout_s,
                    "settings": settings, "queries": summary}, indent=2), encoding="utf-8", newline="\n")
    table = [[e["query"], e["title"], "timeout" if e["timed_out"] else e["median_ms"],
              e.get("buffers"), e.get("rows"), "; ".join(e["access"])] for e in summary]
    md = (f"# Timings: {phase}\n\nQueries: `{queries_file.name}`. Median of {runs} runs of "
          f"`EXPLAIN (ANALYZE, BUFFERS)` after one warm-up run; timeout {timeout_s} s.\n\n"
          + "Settings: " + ", ".join(f"{k} = {v}" for k, v in settings.items()) + "\n\n"
          + tabulate(table, headers=["query", "title", "median ms", "buffers", "rows", "access paths"], tablefmt="github")
          + "\n")
    (P2 / "results" / f"timings_{phase}.md").write_text(md, encoding="utf-8", newline="\n")
    conn.close()


def compare(phases: list[str]) -> int:
    data = [json.loads((P2 / "results" / f"timings_{p}.json").read_text(encoding="utf-8")) for p in phases]
    by_phase = [{e["query"]: e for e in d["queries"]} for d in data]
    rows, mismatches = [], 0
    for qid, first in by_phase[0].items():
        cells = [qid, first["title"]]
        for b in by_phase:
            e = b[qid]
            cells.append("timeout" if e["timed_out"] else e["median_ms"])
        for b in by_phase:
            cells.append(b[qid].get("buffers") if b[qid].get("buffers") is not None else "-")
        first_ms = next((b[qid]["median_ms"] for b in by_phase if not b[qid]["timed_out"]), None)
        last = by_phase[-1][qid]
        if last["timed_out"]:
            cells.append("-")
        elif by_phase[0][qid]["timed_out"]:      # lower bound: the baseline never finished
            cells.append(f">{data[0]['timeout_s'] * 1000 / last['median_ms']:,.0f}x")
        else:
            cells.append(f"{first_ms / last['median_ms']:,.1f}x")
        hashes = {b[qid]["result_md5"] for b in by_phase if b[qid]["result_md5"]}
        same = len(hashes) == 1
        mismatches += not same
        cells.append("yes" if same else "NO")
        rows.append(cells)
    md = ("# Before and after\n\nMedian execution time in ms (`EXPLAIN ANALYZE`). "
          "Buffers are the shared pages each plan touched (hit + read); unlike time, they don't depend on "
          "what else the machine is doing. 'Same result' compares a hash of every row returned in each "
          "phase that finished.\n\n"
          + tabulate(rows, headers=["query", "title", *(f"{p} ms" for p in phases),
                                *(f"{p} buffers" for p in phases), "speed-up", "same result"], tablefmt="github")
          + "\n")
    (P2 / "results" / "comparison.md").write_text(md, encoding="utf-8", newline="\n")
    print(md)
    return 1 if mismatches else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--phase")
    ap.add_argument("--queries", default="queries.sql")
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--timeout", type=int, default=30, help="seconds per statement")
    ap.add_argument("--compare", nargs="+")
    args = ap.parse_args()
    if args.compare:
        return compare(args.compare)
    if not args.phase:
        ap.error("--phase or --compare is required")
    run_phase(args.phase, P2 / args.queries, args.runs, args.timeout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
