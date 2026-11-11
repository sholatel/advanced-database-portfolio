"""Helpers for the Portfolio 5 clusters: compose, mongosh, clients, a timeline log and checks."""
from __future__ import annotations

import subprocess
import time
from pathlib import Path

from pymongo import MongoClient, ReadPreference

REPO = Path(__file__).resolve().parents[2]
P5 = REPO / "portfolio-5-distributed-cloud"
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
USER, PASSWORD = ENV.get("MONGO_ROOT_USER", "root"), ENV["MONGO_ROOT_PASSWORD"]


def compose(file: str, *args: str) -> str:
    cmd = ["docker", "compose", "-f", str(P5 / file), "--env-file", str(REPO / ".env"), *args]
    return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True).stdout


def mongosh(file: str, service: str, port: int, js: str) -> str:
    cmd = ["docker", "compose", "-f", str(P5 / file), "--env-file", str(REPO / ".env"), "exec", "-T",
           "-e", f"OWR_USER={USER}", "-e", f"OWR_PW={PASSWORD}", service,
           "mongosh", "--port", str(port), "--quiet", "--eval", js]
    result = subprocess.run(cmd, cwd=REPO, capture_output=True, text=True)
    return (result.stdout + result.stderr).strip()


def client(hosts: list[int], replica_set: str | None = None, **kwargs) -> MongoClient:
    options = {"replicaSet": replica_set} if replica_set else {"directConnection": True}
    return MongoClient([f"127.0.0.1:{p}" for p in hosts], username=USER, password=PASSWORD, authSource="admin",
                       tz_aware=True, **options, **kwargs)


def node(port: int, **kwargs) -> MongoClient:
    return client([port], read_preference=ReadPreference.SECONDARY_PREFERRED, serverSelectionTimeoutMS=3000,
                  connectTimeoutMS=2000, socketTimeoutMS=5000, **kwargs)


def log(who: str, text: str) -> None:
    print(f"{(time.perf_counter() - T0) * 1000:9.0f} ms  {who:<4} {text}", flush=True)


def scenario(title: str) -> None:
    print(f"\n=== {title}", flush=True)


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
