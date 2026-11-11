"""Commit, rollback, errors, savepoints, atomic reversal and durability."""
from __future__ import annotations

import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

import psycopg

from lab import REPO, Checks, Session, connect, log, scalar, scenario

ADAEZE, TUNDE, CHIAMAKA = "3000000001", "3000000002", "3000000003"
MAMA_PUT, STARVIEW = "3000000042", "3000000102"
BALANCE = "SELECT balance_kobo FROM wallet WHERE wallet_number = '{}'"


def post(kind: str, src: str, dst: str, amount: int, key: str | None = None, extra: str = "") -> str:
    key = key or str(uuid.uuid4())
    return f"SELECT post_transaction('{key}', '{kind}', '{src}', '{dst}', {amount}, 'APP'{extra})"


def counts(conn) -> tuple:
    return conn.execute("""SELECT (SELECT count(*) FROM transaction), (SELECT count(*) FROM ledger_entry),
                                  (SELECT count(*) FROM transaction_status_history), (SELECT count(*) FROM reversal),
                                  (SELECT count(*) FROM audit_log)""").fetchone()


def commit_and_isolation(c: Checks) -> None:
    scenario("T1  COMMIT: a transfer becomes visible to others only when it commits")
    a, b = Session("A"), Session("B")
    before = b.value(BALANCE.format(TUNDE))
    a.run("BEGIN")
    a.run(post("TRANSFER", ADAEZE, TUNDE, 10000))
    inside = a.value(BALANCE.format(TUNDE))
    seen_by_b = b.value(BALANCE.format(TUNDE))
    a.run("COMMIT")
    after = b.value(BALANCE.format(TUNDE))
    c.check("A sees its own uncommitted change", inside == before + 10000, f"{before} -> {inside}")
    c.check("B does not see A's change before COMMIT", seen_by_b == before, str(seen_by_b))
    c.check("B sees the change after COMMIT", after == before + 10000, str(after))
    a.close(), b.close()


def rollback(c: Checks) -> None:
    scenario("T2  ROLLBACK: everything the transaction did is undone")
    a = Session("A")
    key = str(uuid.uuid4())
    before_bal, before_counts = a.value(BALANCE.format(ADAEZE)), counts(a.conn)
    a.run("BEGIN")
    a.run(post("TRANSFER", ADAEZE, TUNDE, 20000, key))
    inside = a.value(BALANCE.format(ADAEZE))
    a.run("ROLLBACK")
    after_bal, after_counts = a.value(BALANCE.format(ADAEZE)), counts(a.conn)
    c.check("balance changed inside the transaction", inside == before_bal - 21000, f"{before_bal} -> {inside}")
    c.check("balance restored after ROLLBACK", after_bal == before_bal, str(after_bal))
    c.check("no transaction, ledger, history or audit rows left", after_counts == before_counts, str(after_counts))
    c.check("the idempotency key is unused", scalar(a.conn, "SELECT count(*) FROM transaction WHERE idempotency_key = %s",
                                                    (key,)) == 0)
    a.close()


def error_aborts(c: Checks) -> None:
    scenario("T3  An error inside a transaction aborts all of it")
    a = Session("A")
    before_bal, before_counts = a.value(BALANCE.format(CHIAMAKA)), counts(a.conn)
    a.run("BEGIN")
    a.run(post("MERCHANT_PAYMENT", CHIAMAKA, MAMA_PUT, 50000))
    try:
        a.run(post("MERCHANT_PAYMENT", CHIAMAKA, STARVIEW, 50000))
        failed = False
    except psycopg.Error:
        failed = True
    try:
        a.run(BALANCE.format(CHIAMAKA))
        state = "accepted"
    except psycopg.Error as exc:
        state = exc.sqlstate
    a.run("ROLLBACK")
    c.check("paying a biller as a merchant is rejected (BR-10)", failed)
    c.check("the transaction refuses further statements (25P02)", state == "25P02", state)
    c.check("the first, valid payment is undone too",
            a.value(BALANCE.format(CHIAMAKA)) == before_bal and counts(a.conn) == before_counts)
    a.close()


def savepoints(c: Checks) -> None:
    scenario("T4  SAVEPOINT: one bad payment in a batch is undone, the rest commit")
    a = Session("A")
    before_bal, before_tx = a.value(BALANCE.format(CHIAMAKA)), scalar(a.conn, "SELECT count(*) FROM transaction")
    a.run("BEGIN")
    a.run("SAVEPOINT payment_1")
    a.run(post("MERCHANT_PAYMENT", CHIAMAKA, MAMA_PUT, 30000))
    a.run("RELEASE SAVEPOINT payment_1")
    a.run("SAVEPOINT payment_2")
    try:
        a.run(post("MERCHANT_PAYMENT", CHIAMAKA, STARVIEW, 40000))
    except psycopg.Error:
        a.run("ROLLBACK TO SAVEPOINT payment_2")
    a.run("SAVEPOINT payment_3")
    a.run(post("BILL_PAYMENT", CHIAMAKA, STARVIEW, 40000, extra=", p_bill_reference => 'SVC-2026110001'"))
    a.run("RELEASE SAVEPOINT payment_3")
    a.run("COMMIT")
    fee = scalar(a.conn, "SELECT fee_kobo FROM fee_for('BILL_PAYMENT', 40000, now())")
    after_bal, after_tx = a.value(BALANCE.format(CHIAMAKA)), scalar(a.conn, "SELECT count(*) FROM transaction")
    c.check("two of the three payments committed", after_tx - before_tx == 2, f"{after_tx - before_tx} new")
    c.check("balance reflects exactly those two", after_bal == before_bal - 30000 - 40000 - fee,
            f"{before_bal} -> {after_bal}")
    a.close()


def atomic_reversal(c: Checks) -> None:
    scenario("T5  Statement atomicity: a reversal that fails halfway leaves nothing behind")
    a = Session("A")
    a.run(post("TRANSFER", ADAEZE, TUNDE, 100000, extra=", p_transaction_ref => 'OWR700000000001'"))
    a.run(post("MERCHANT_PAYMENT", TUNDE, MAMA_PUT, a.value(BALANCE.format(TUNDE)) - 1000))
    before = counts(a.conn)
    try:
        a.run(f"SELECT reverse_transaction('OWR700000000001', 'customer dispute', 'support.test', '{uuid.uuid4()}')")
        failed = False
    except psycopg.Error:
        failed = True
    c.check("the reversal is refused: the receiver spent the money", failed)
    c.check("no partial reversal rows in any of the five tables", counts(a.conn) == before, str(counts(a.conn)))
    c.check("the original is still SUCCESSFUL",
            scalar(a.conn, "SELECT status FROM transaction WHERE transaction_ref = 'OWR700000000001'") == "SUCCESSFUL")
    a.close()


def compose(*args: str) -> str:
    return subprocess.run(["docker", "compose", *args], cwd=REPO, capture_output=True, text=True).stdout


def durability(c: Checks) -> None:
    scenario("T6  Durability: a committed transfer survives the server being killed")
    a = Session("A")
    key = str(uuid.uuid4())
    a.run(post("TRANSFER", CHIAMAKA, ADAEZE, 25000, key))
    ref = scalar(a.conn, "SELECT transaction_ref FROM transaction WHERE idempotency_key = %s", (key,))
    a.run("BEGIN")
    a.run(post("TRANSFER", CHIAMAKA, ADAEZE, 99000, extra=", p_transaction_ref => 'OWR700000000002'"))
    log("A", "(left uncommitted)")
    log("sys", "docker compose kill postgres   (SIGKILL, no clean shutdown)")
    killed_at = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    compose("kill", "postgres")
    a.pool.shutdown()
    compose("start", "postgres")
    for _ in range(120):
        if "healthy" in compose("ps", "postgres"):
            break
        time.sleep(1)
    log("sys", "postgres restarted")
    for line in compose("logs", "postgres", "--since", killed_at).splitlines():
        if any(w in line for w in ("not properly shut down", "redo starts", "redo done", "ready to accept")):
            log("log", line.split("|", 1)[-1].strip())
    conn = connect()
    c.check("the committed transfer is still there", scalar(
        conn, "SELECT status FROM transaction WHERE transaction_ref = %s", (ref,)) == "SUCCESSFUL", ref)
    c.check("the uncommitted transfer is gone", scalar(
        conn, "SELECT count(*) FROM transaction WHERE transaction_ref = 'OWR700000000002'") == 0)
    c.check("balances still match the ledger after recovery",
            scalar(conn, "SELECT count(*) FROM v_wallet_balance WHERE difference_kobo <> 0") == 0)
    conn.close()


def main() -> int:
    c = Checks("Transaction demos")
    for demo in (commit_and_isolation, rollback, error_aborts, savepoints, atomic_reversal, durability):
        demo(c)
    return c.summary()


if __name__ == "__main__":
    sys.exit(main())
