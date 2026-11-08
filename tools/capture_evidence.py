#!/usr/bin/env python3
"""Run a command and save its output as a timestamped evidence file.

Every evidence file in this portfolio starts with the same header block
(capture time in Africa/Lagos and UTC, the exact command, exit code, duration,
host and tool versions, and optionally the database server version), followed
by the raw, unedited output of the command (stdout and stderr merged in order).

Run from anywhere; commands execute from the repository root.

  python tools/capture_evidence.py --db postgres \
      --out portfolio-1-database-design/evidence/m1_postgres_environment.txt \
      --title "PostgreSQL server version" -- \
      docker compose exec -T postgres psql -U postgres -d oworail -c "SELECT version();"

  # add another section to the same file
  python tools/capture_evidence.py --append --out <same file> --title "..." -- <command>

A non-zero exit code is recorded, not hidden: expected failures (e.g. constraint
violations) are evidence too. The script exits with the command's exit code.

Values of secret-looking keys in .env (names containing PASSWORD, SECRET, TOKEN
or URI) are redacted from the header and the output before anything is written.
"""
from __future__ import annotations

import argparse
import platform
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

REPO_ROOT = Path(__file__).resolve().parent.parent
LAGOS = ZoneInfo("Africa/Lagos")  # needs the tzdata package on Windows
SECRET_MARKERS = ("PASSWORD", "SECRET", "TOKEN", "URI")
RULE = "=" * 80


def run(cmd: list[str], timeout: float | None = None) -> tuple[int, str]:
    """Run cmd from the repo root; return (exit code, merged stdout+stderr)."""
    proc = subprocess.run(
        cmd,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    text = proc.stdout.decode("utf-8", errors="replace").replace("\r\n", "\n")
    return proc.returncode, text


def first_line(cmd: list[str]) -> str:
    """First line of a version command's output, or a short 'unavailable' note."""
    try:
        code, out = run(cmd, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return f"unavailable ({exc.__class__.__name__})"
    lines = out.strip().splitlines()
    return lines[0] if code == 0 and lines else f"unavailable (exit {code})"


def server_version(db: str, compose_file: str, service: str) -> str:
    """Version string of the database server running in a compose service."""
    exec_ = ["docker", "compose", "-f", compose_file, "exec", "-T", service]
    probe = ["postgres", "--version"] if db == "postgres" else ["mongod", "--version"]
    version = first_line(exec_ + probe)
    return f"{version}  [service '{service}' in {compose_file}]"


def load_secrets() -> list[str]:
    """Secret values from .env, longest first (so substrings redact cleanly)."""
    env_file = REPO_ROOT / ".env"
    found: list[str] = []
    if env_file.exists():
        for raw in env_file.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, value = line.partition("=")
            value = value.strip().strip('"').strip("'")
            if any(m in key.upper() for m in SECRET_MARKERS) and len(value) >= 4:
                found.append(value)
    return sorted(set(found), key=len, reverse=True)


def redact(text: str, secrets: list[str]) -> str:
    for value in secrets:
        text = text.replace(value, "***REDACTED***")
    return text


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Run a command and save its output as an evidence file."
    )
    parser.add_argument("--out", required=True, help="evidence file, relative to the repo root")
    parser.add_argument("--title", required=True, help="what this evidence shows")
    parser.add_argument("--db", choices=["postgres", "mongo"],
                        help="record this database server's version in the header")
    parser.add_argument("--service", help="compose service name (default: same as --db)")
    parser.add_argument("--compose-file", default="docker-compose.yml",
                        help="compose file used for the server-version probe")
    parser.add_argument("--append", action="store_true",
                        help="add a new section to an existing file instead of overwriting")
    parser.add_argument("--timeout", type=float, default=None, help="seconds before giving up")
    parser.add_argument("command", nargs=argparse.REMAINDER,
                        help="the command to run, after --")
    args = parser.parse_args(argv)

    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not cmd:
        parser.error("give the command to run after --")

    started_utc = datetime.now(timezone.utc)
    t0 = time.perf_counter()
    try:
        code, output = run(cmd, timeout=args.timeout)
    except FileNotFoundError as exc:
        code, output = 127, f"{exc}\n"
    except subprocess.TimeoutExpired:
        code, output = 124, f"Command timed out after {args.timeout} s\n"
    duration = time.perf_counter() - t0
    local = started_utc.astimezone(LAGOS)

    header = [
        RULE,
        "OwoRail Advanced Database Portfolio - evidence capture",
        f"Title       : {args.title}",
        f"Captured at : {local.isoformat(timespec='seconds')} (Africa/Lagos, {local.tzname()})"
        f" | {started_utc:%Y-%m-%dT%H:%M:%SZ} (UTC)",
        f"Command     : {shlex.join(cmd)}",
        "Working dir : <repository root>",
        f"Exit code   : {code}",
        f"Duration    : {duration:.3f} s",
        f"Host        : {platform.system()} {platform.release()} ({platform.version()})"
        f" | Python {platform.python_version()}",
        f"Tools       : {first_line(['docker', '--version'])}"
        f" | {first_line(['docker', 'compose', 'version'])}",
    ]
    if args.db:
        header.append(
            f"Server      : {server_version(args.db, args.compose_file, args.service or args.db)}"
        )
    header += [RULE, ""]

    secrets = load_secrets()
    body = redact("\n".join(header) + output.rstrip("\n") + "\n", secrets)

    out_path = (REPO_ROOT / args.out).resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if args.append and out_path.exists() and out_path.stat().st_size > 0:
        body = "\n" + body
    with out_path.open("a" if args.append else "w", encoding="utf-8", newline="\n") as fh:
        fh.write(body)

    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print(redact(output, secrets), end="" if output.endswith("\n") else "\n")
    print(f"[evidence] {'appended to' if args.append else 'wrote'} "
          f"{out_path.relative_to(REPO_ROOT).as_posix()} (exit {code})")
    return code


if __name__ == "__main__":
    sys.exit(main())
