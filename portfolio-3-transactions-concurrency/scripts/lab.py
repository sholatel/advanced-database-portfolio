"""Shared helpers: named sessions, a timeline log and pass/fail checks."""
from __future__ import annotations

import time
from concurrent.futures import Future, ThreadPoolExecutor
from pathlib import Path

import psycopg

REPO = Path(__file__).resolve().parents[2]
T0 = time.perf_counter()


def read_env() -> dict[str, str]:
    env = {}
    for line in (REPO / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


ENV = read_env()


def connect(autocommit: bool = True) -> psycopg.Connection:
    conn = psycopg.connect(host="127.0.0.1", port=int(ENV.get("PG_HOST_PORT", "5433")),
                           user=ENV.get("POSTGRES_USER", "postgres"), password=ENV["POSTGRES_PASSWORD"],
                           dbname=ENV.get("POSTGRES_DB", "oworail"), autocommit=autocommit)
    conn.execute("SET search_path = oworail, lab, public")
    return conn


def log(who: str, text: str) -> None:
    ms = (time.perf_counter() - T0) * 1000
    print(f"{ms:9.0f} ms  {who:<3} {text}", flush=True)


def scalar(conn: psycopg.Connection, sql: str, params=None):
    return conn.execute(sql, params).fetchone()[0]


class Session:
    def __init__(self, name: str):
        self.name = name
        self.conn = connect(autocommit=True)
        self.pid = self.conn.info.backend_pid
        self.pool = ThreadPoolExecutor(max_workers=1)

    def run(self, sql: str, params=None, show: bool = True):
        if show:
            log(self.name, sql)
        try:
            cur = self.conn.execute(sql, params)
        except psycopg.Error as exc:
            log(self.name, f"  ERROR {exc.sqlstate}: {exc.diag.message_primary}")
            raise
        rows = cur.fetchall() if cur.description else None
        if show and rows is not None:
            log(self.name, "  -> " + (", ".join(str(v) for v in rows[0]) if len(rows) == 1 else f"{len(rows)} rows"))
        return rows

    def value(self, sql: str, params=None):
        return self.run(sql, params)[0][0]

    def submit(self, sql: str, params=None) -> Future:
        log(self.name, sql + "   (sent, waiting)")
        return self.pool.submit(self._run_quiet, sql, params)

    def _run_quiet(self, sql, params):
        try:
            cur = self.conn.execute(sql, params)
            rows = cur.fetchall() if cur.description else None
            log(self.name, "  -> " + (", ".join(str(v) for v in rows[0]) if rows else "done"))
            return rows
        except psycopg.Error as exc:
            log(self.name, f"  ERROR {exc.sqlstate}: {exc.diag.message_primary}")
            return exc

    def close(self) -> None:
        self.pool.shutdown()
        self.conn.close()


def wait_until_blocked(session: Session, timeout: float = 10) -> list[int]:
    observer = connect()
    end = time.time() + timeout
    try:
        while time.time() < end:
            row = observer.execute(
                "SELECT wait_event_type, wait_event, pg_blocking_pids(pid) FROM pg_stat_activity WHERE pid = %s",
                (session.pid,)).fetchone()
            if row and row[0] == "Lock":
                log("obs", f"{session.name} is waiting: {row[0]}/{row[1]}, blocked by pid {row[2]}")
                return row[2]
            time.sleep(0.02)
    finally:
        observer.close()
    raise TimeoutError(f"{session.name} never blocked")


class Checks:
    def __init__(self, title: str):
        self.title = title
        self.results: list[tuple[str, bool, str]] = []

    def check(self, label: str, ok: bool, detail: str = "") -> None:
        self.results.append((label, ok, detail))
        log("chk", f"{'PASS' if ok else 'FAIL'}  {label}" + (f"  ({detail})" if detail else ""))

    def summary(self) -> int:
        failed = [r for r in self.results if not r[1]]
        print(f"\n{self.title}: {len(self.results) - len(failed)} of {len(self.results)} checks passed")
        for label, _, detail in failed:
            print(f"  FAILED: {label} {detail}")
        return 1 if failed else 0


def scenario(title: str) -> None:
    print(f"\n=== {title}", flush=True)
