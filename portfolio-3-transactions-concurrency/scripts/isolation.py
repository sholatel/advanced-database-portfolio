"""Isolation levels: dirty, non-repeatable and phantom reads; write skew under REPEATABLE READ and SERIALIZABLE."""
from __future__ import annotations

import sys
import uuid

import psycopg

from lab import Checks, Session, log, scenario

ADAEZE, TUNDE, CHIAMAKA = "3000000001", "3000000002", "3000000003"
BALANCE = f"SELECT balance_kobo FROM wallet WHERE wallet_number = '{ADAEZE}'"
TUNDE_TODAY = (f"SELECT count(*) FROM transaction t JOIN wallet w ON w.wallet_id = t.destination_wallet_id "
               f"WHERE w.wallet_number = '{TUNDE}' AND t.created_at >= date_trunc('day', now(), 'UTC')")


def transfer(src: str, dst: str, amount: int) -> str:
    return f"SELECT post_transaction('{uuid.uuid4()}', 'TRANSFER', '{src}', '{dst}', {amount}, 'APP')"


def dirty_read(c: Checks) -> None:
    scenario("I1  No dirty reads, even when READ UNCOMMITTED is requested")
    a, b = Session("A"), Session("B")
    before = b.value(BALANCE)
    a.run("BEGIN")
    a.run(transfer(ADAEZE, TUNDE, 15000))
    b.run("BEGIN ISOLATION LEVEL READ UNCOMMITTED")
    seen = b.value(BALANCE)
    b.run("COMMIT")
    a.run("ROLLBACK")
    c.check("B never sees A's uncommitted debit", seen == before, f"saw {seen}, committed value {before}")
    a.close(), b.close()


def non_repeatable(c: Checks, level: str) -> None:
    scenario(f"I2  Re-reading a balance under {level}")
    a, b = Session("A"), Session("B")
    a.run(f"BEGIN ISOLATION LEVEL {level}")
    first = a.value(BALANCE)
    b.run(transfer(ADAEZE, CHIAMAKA, 5000))
    second = a.value(BALANCE)
    a.run("COMMIT")
    latest = a.value(BALANCE)
    if level == "READ COMMITTED":
        c.check("READ COMMITTED: the second read sees B's commit (non-repeatable read)",
                second == first - 6000, f"{first} then {second}")
    else:
        c.check("REPEATABLE READ: both reads see the same snapshot", second == first, f"{first} then {second}")
        c.check("after COMMIT, a new transaction sees B's change", latest == first - 6000, str(latest))
    a.close(), b.close()


def phantom(c: Checks, level: str) -> None:
    scenario(f"I3  Counting today's incoming transfers twice under {level}")
    a, b = Session("A"), Session("B")
    a.run(f"BEGIN ISOLATION LEVEL {level}")
    first = a.value(TUNDE_TODAY)
    b.run(transfer(CHIAMAKA, TUNDE, 7000))
    second = a.value(TUNDE_TODAY)
    a.run("COMMIT")
    if level == "READ COMMITTED":
        c.check("READ COMMITTED: a new row appears in the second count (phantom)", second == first + 1,
                f"{first} then {second}")
    else:
        c.check("REPEATABLE READ: no phantom row", second == first, f"{first} then {second}")
    a.close(), b.close()


def withdraw_if_covered(s: Session, account: int, amount: int) -> bool:
    total = s.value("SELECT sum(balance_kobo) FROM lab.account WHERE owner = 'Adaeze Okafor'")
    if total - amount < 0:
        log(s.name, f"  refused: combined balance {total} does not cover {amount}")
        return False
    s.run(f"UPDATE lab.account SET balance_kobo = balance_kobo - {amount} WHERE account_id = {account}")
    return True


def write_skew(c: Checks, level: str) -> None:
    scenario(f"I4  Write skew: two withdrawals each check the combined balance, under {level}")
    a, b = Session("A"), Session("B")
    a.run("SELECT lab.reset()")
    a.run(f"BEGIN ISOLATION LEVEL {level}")
    b.run(f"BEGIN ISOLATION LEVEL {level}")
    withdraw_if_covered(a, 1, 150000)
    withdraw_if_covered(b, 2, 150000)
    a.run("COMMIT")
    outcome = "committed"
    try:
        b.run("COMMIT")
    except psycopg.Error as exc:
        outcome = exc.sqlstate
    if outcome == "40001":
        b.run("ROLLBACK")
        b.run(f"BEGIN ISOLATION LEVEL {level}")
        retried = withdraw_if_covered(b, 2, 150000)
        b.run("COMMIT")
    total = a.value("SELECT sum(balance_kobo) FROM lab.account WHERE owner = 'Adaeze Okafor'")
    if level == "REPEATABLE READ":
        c.check("REPEATABLE READ: both withdrawals commit and the rule is broken", outcome == "committed" and total < 0,
                f"combined balance {total}")
    else:
        c.check("SERIALIZABLE: the second commit fails with a serialization error (40001)", outcome == "40001", outcome)
        c.check("on retry the withdrawal sees the first one and is refused", not retried)
        c.check("the combined balance never goes below zero", total >= 0, f"combined balance {total}")
    a.close(), b.close()


def main() -> int:
    c = Checks("Isolation demos")
    dirty_read(c)
    for level in ("READ COMMITTED", "REPEATABLE READ"):
        non_repeatable(c, level)
    for level in ("READ COMMITTED", "REPEATABLE READ"):
        phantom(c, level)
    for level in ("REPEATABLE READ", "SERIALIZABLE"):
        write_skew(c, level)
    return c.summary()


if __name__ == "__main__":
    sys.exit(main())
