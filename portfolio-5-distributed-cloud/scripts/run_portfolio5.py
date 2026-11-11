"""Portfolio 5 end to end from empty clusters, with every step captured into evidence/."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CAPTURE = REPO / "tools" / "capture_evidence.py"
EV = "portfolio-5-distributed-cloud/evidence"
SCRIPTS = "portfolio-5-distributed-cloud/scripts"
RS = ["docker", "compose", "-f", "portfolio-5-distributed-cloud/docker-compose.replicaset.yml", "--env-file", ".env"]
SH = ["docker", "compose", "-f", "portfolio-5-distributed-cloud/docker-compose.sharded.yml", "--env-file", ".env"]

STEPS = [
    ("m10_setup.txt", "Replica set containers", RS + ["up", "-d"], False),
    ("m10_setup.txt", "Replica set container status", RS + ["ps"], True),
    ("m10_replication.txt", "Replication, write concerns, failover, rollback, stale and causal reads",
     [sys.executable, f"{SCRIPTS}/replication.py"], False),
    ("m10_setup.txt", "Stop the replica set", RS + ["stop"], True),
    ("m10_setup.txt", "Sharded cluster containers", SH + ["up", "-d"], True),
    ("m10_setup.txt", "Sharded cluster container status", SH + ["ps"], True),
    ("m10_sharding.txt", "Sharding: hashed key, query targeting, hot spot, shard outage",
     [sys.executable, f"{SCRIPTS}/sharding.py"], False),
    ("m10_setup.txt", "Stop the sharded cluster", SH + ["stop"], True),
]


def main() -> int:
    subprocess.run(["docker", "compose", "stop", "mongo"], cwd=REPO)
    for stack in (RS, SH):
        subprocess.run(stack + ["down", "-v"], cwd=REPO)
    for out, title, cmd, append in STEPS:
        print(f"\n### {title}", flush=True)
        args = [sys.executable, str(CAPTURE), "--out", f"{EV}/{out}", "--title", title]
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
