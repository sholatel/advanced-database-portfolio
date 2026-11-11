"""Connections to MongoDB and PostgreSQL, and shared output helpers."""
from __future__ import annotations

import time
from pathlib import Path

import psycopg
from pymongo import MongoClient
from pymongo.errors import OperationFailure

REPO = Path(__file__).resolve().parents[2]


def read_env() -> dict[str, str]:
    env = {}
    for line in (REPO / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, _, v = line.partition("=")
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env


ENV = read_env()


def mongo_client(user: str | None = None, password: str | None = None) -> MongoClient:
    return MongoClient(host="127.0.0.1", port=int(ENV.get("MONGO_HOST_PORT", "27018")),
                       username=user or ENV.get("MONGO_ROOT_USER", "root"),
                       password=password or ENV["MONGO_ROOT_PASSWORD"],
                       authSource="admin" if user is None else "oworail",
                       directConnection=True, tz_aware=True)


def ensure_replica_set(client: MongoClient) -> None:
    try:
        client.admin.command("replSetGetStatus")
    except OperationFailure as exc:
        if exc.code != 94:
            raise
        client.admin.command("replSetInitiate", {"_id": "rs0", "members": [{"_id": 0, "host": "localhost:27017"}]})
        print("replica set rs0 initiated")
    for _ in range(60):
        if client.admin.command("hello").get("isWritablePrimary"):
            return
        time.sleep(1)
    raise TimeoutError("node did not become primary")


def pg_connect() -> psycopg.Connection:
    return psycopg.connect(host="127.0.0.1", port=int(ENV.get("PG_HOST_PORT", "5433")),
                           user=ENV.get("POSTGRES_USER", "postgres"), password=ENV["POSTGRES_PASSWORD"],
                           dbname=ENV.get("POSTGRES_DB", "oworail"))


def section(title: str) -> None:
    print(f"\n=== {title}", flush=True)


class Checks:
    def __init__(self, title: str):
        self.title = title
        self.results: list[tuple[str, bool, str]] = []

    def check(self, label: str, ok: bool, detail: str = "") -> None:
        self.results.append((label, ok, detail))
        print(f"  {'PASS' if ok else 'FAIL'}  {label}" + (f"  ({detail})" if detail else ""), flush=True)

    def summary(self) -> int:
        failed = [r for r in self.results if not r[1]]
        print(f"\n{self.title}: {len(self.results) - len(failed)} of {len(self.results)} checks passed")
        return 1 if failed else 0
