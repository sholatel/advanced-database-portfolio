"""Lost update, row locks, deadlocks, and post_transaction under real concurrency."""
from __future__ import annotations

import sys
import threading
import time
import uuid

import psycopg

from lab import Checks, Session, connect, log, scalar, scenario, wait_until_blocked

LAB_BALANCE = "SELECT balance_kobo FROM lab.account WHERE account_id = {}"
STRESS = 16


def customer_wallet(i: int) -> str:
    return f"35{i:08d}"


def merchant_wallet(i: int) -> str:
    return f"36{i:08d}"


def setup_stress_wallets() -> None:
    conn = connect()
    if scalar(conn, "SELECT count(*) FROM wallet WHERE wallet_number LIKE '35%'") == 0:
        with conn.transaction():
            for i in range(1, STRESS + 1):
                conn.execute("SELECT onboard_customer(%s, %s, '1990-01-01', '1 Test St', 'Ikeja', 'Lagos', %s, %s)",
                             (f"Load Test {i}", f"load.test.{i}@example.com", [f"+23480770{i:05d}"], customer_wallet(i)))
                conn.execute("SELECT onboard_merchant(%s, %s, 'MERCHANT', 'RETAIL', %s)",
                             (f"MRC2{i:04d}", f"Load Test Shop {i}", merchant_wallet(i)))
                conn.execute("SELECT post_transaction(%s, 'WALLET_FUNDING', '9000000002', %s, %s, 'APP')",
                             (uuid.uuid4(), customer_wallet(i), 50000 if i == 15 else 5000000))
    conn.close()


def balance(conn, wallet: str) -> int:
    return scalar(conn, "SELECT balance_kobo FROM wallet WHERE wallet_number = %s", (wallet,))


def lost_update(c: Checks, level: str) -> None:
    scenario(f"L1  Lost update: read, compute in the application, write back ({level})")
    a, b = Session("A"), Session("B")
    a.run("SELECT lab.reset()")
    a.run(f"BEGIN ISOLATION LEVEL {level}")
    b.run(f"BEGIN ISOLATION LEVEL {level}")
    seen_a = a.value(LAB_BALANCE.format(3))
    seen_b = b.value(LAB_BALANCE.format(3))
    a.run(f"UPDATE lab.account SET balance_kobo = {seen_a - 30000} WHERE account_id = 3")
    pending = b.submit(f"UPDATE lab.account SET balance_kobo = {seen_b - 50000} WHERE account_id = 3")
    wait_until_blocked(b)
    a.run("COMMIT")
    result = pending.result()
    b.run("ROLLBACK" if isinstance(result, psycopg.Error) else "COMMIT")
    final = a.value(LAB_BALANCE.format(3))
    if level == "READ COMMITTED":
        c.check("READ COMMITTED: the 30,000 withdrawal is lost", final == 50000, f"final {final}, correct 20000")
    else:
        c.check("REPEATABLE READ: B's write is refused with 40001 instead of losing A's",
                isinstance(result, psycopg.Error) and result.sqlstate == "40001" and final == 70000, f"final {final}")
    a.close(), b.close()


def select_for_update(c: Checks) -> None:
    scenario("L2  SELECT ... FOR UPDATE: the second reader waits for the first to finish")
    a, b = Session("A"), Session("B")
    a.run("SELECT lab.reset()")
    a.run("BEGIN")
    seen_a = a.value(LAB_BALANCE.format(3) + " FOR UPDATE")
    b.run("BEGIN")
    pending = b.submit(LAB_BALANCE.format(3) + " FOR UPDATE")
    blockers = wait_until_blocked(b)
    a.run(f"UPDATE lab.account SET balance_kobo = {seen_a - 30000} WHERE account_id = 3")
    a.run("COMMIT")
    seen_b = pending.result()[0][0]
    b.run(f"UPDATE lab.account SET balance_kobo = {seen_b - 50000} WHERE account_id = 3")
    b.run("COMMIT")
    final = a.value(LAB_BALANCE.format(3))
    c.check("B was blocked by A's row lock", blockers == [a.pid], f"blocked by {blockers}, A is {a.pid}")
    c.check("B read the balance after A's withdrawal", seen_b == 70000, str(seen_b))
    c.check("both withdrawals count", final == 20000, f"final {final}")
    a.close(), b.close()


def deadlock(c: Checks) -> None:
    scenario("L3  Deadlock: two sessions lock the same two rows in opposite order")
    a, b = Session("A"), Session("B")
    a.run("SELECT lab.reset()")
    a.run("BEGIN")
    b.run("BEGIN")
    a.run("UPDATE lab.account SET balance_kobo = balance_kobo - 1000 WHERE account_id = 1")
    b.run("UPDATE lab.account SET balance_kobo = balance_kobo - 1000 WHERE account_id = 2")
    pending_a = a.submit("UPDATE lab.account SET balance_kobo = balance_kobo + 1000 WHERE account_id = 2")
    wait_until_blocked(a)
    pending_b = b.submit("UPDATE lab.account SET balance_kobo = balance_kobo + 1000 WHERE account_id = 1")
    results = {"A": pending_a.result(), "B": pending_b.result()}
    victims = [n for n, r in results.items() if isinstance(r, psycopg.Error) and r.sqlstate == "40P01"]
    for name, s in (("A", a), ("B", b)):
        s.run("ROLLBACK" if name in victims else "COMMIT")
    c.check("PostgreSQL detects the cycle and aborts exactly one session (40P01)", len(victims) == 1, str(victims))
    c.check("money is conserved", a.value("SELECT sum(balance_kobo) FROM lab.account WHERE account_id IN (1, 2)") == 200000)
    a.close(), b.close()


def hammer(fn: str, iterations: int) -> tuple[int, int]:
    deadlocks, done = [0], [0]

    def worker(src: int, dst: int):
        conn = connect()
        conn.execute("SET deadlock_timeout = '100ms'")
        for _ in range(iterations):
            try:
                conn.execute(f"SELECT lab.{fn}({src}, {dst}, 100)")
                done[0] += 1
            except psycopg.errors.DeadlockDetected:
                deadlocks[0] += 1
        conn.close()

    threads = [threading.Thread(target=worker, args=pair) for pair in ((1, 2), (2, 1))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return deadlocks[0], done[0]


def ordered_locking(c: Checks) -> None:
    scenario("L4  200 opposite transfers: unordered locking against locking in key order")
    conn = connect()
    conn.execute("SELECT lab.reset()")
    unordered = hammer("transfer_unordered", 100)
    log("sys", f"unordered: {unordered[0]} deadlocks, {unordered[1]} transfers completed")
    ordered = hammer("transfer_ordered", 100)
    log("sys", f"ordered:   {ordered[0]} deadlocks, {ordered[1]} transfers completed")
    total = scalar(conn, "SELECT sum(balance_kobo) FROM lab.account WHERE account_id IN (1, 2)")
    c.check("unordered locking deadlocks under load", unordered[0] > 0, f"{unordered[0]} of 200")
    c.check("locking both rows in key order first never deadlocks", ordered == (0, 200), str(ordered))
    c.check("money is conserved across all 400 attempts", total == 200000, str(total))
    conn.close()


def no_overspend(c: Checks) -> None:
    scenario("L5  post_transaction: two transfers that together overspend a wallet")
    sender, r1, r2 = customer_wallet(15), customer_wallet(1), customer_wallet(2)
    setup = connect()
    log("sys", f"wallet {sender} holds {balance(setup, sender)}")
    a, b = Session("A"), Session("B")
    a.run("BEGIN")
    a.run(f"SELECT post_transaction('{uuid.uuid4()}', 'TRANSFER', '{sender}', '{r1}', 40000, 'APP')")
    pending = b.submit(f"SELECT post_transaction('{uuid.uuid4()}', 'TRANSFER', '{sender}', '{r2}', 40000, 'APP')")
    blockers = wait_until_blocked(b)
    a.run("COMMIT")
    b_id = pending.result()[0][0]
    status, reason = setup.execute("""SELECT t.status, h.reason FROM transaction t
                                      JOIN transaction_status_history h ON h.transaction_id = t.transaction_id
                                      WHERE t.transaction_id = %s ORDER BY h.seq_no DESC LIMIT 1""", (b_id,)).fetchone()
    final = balance(setup, sender)
    c.check("B waits on A's lock on the sender's wallet", blockers == [a.pid], str(blockers))
    c.check("B re-reads the balance after A commits and fails cleanly", (status, reason) == ("FAILED", "insufficient funds"),
            f"{status}: {reason}")
    c.check("the wallet is never overdrawn", final == 9000, f"final {final}")
    a.close(), b.close(), setup.close()


def no_deadlock_posting(c: Checks) -> None:
    scenario("L6  post_transaction: 200 concurrent transfers in both directions between two wallets")
    x, y = customer_wallet(3), customer_wallet(4)
    errors, statuses = [], []

    def worker(src: str, dst: str):
        conn = connect()
        for _ in range(50):
            try:
                tid = scalar(conn, "SELECT post_transaction(%s, 'TRANSFER', %s, %s, 1000, 'APP')", (uuid.uuid4(), src, dst))
                statuses.append(scalar(conn, "SELECT status FROM transaction WHERE transaction_id = %s", (tid,)))
            except psycopg.Error as exc:
                errors.append(exc.sqlstate)
        conn.close()

    conn = connect()
    before = balance(conn, x) + balance(conn, y)
    t0 = time.perf_counter()
    threads = [threading.Thread(target=worker, args=p) for p in ((x, y), (y, x), (x, y), (y, x))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    log("sys", f"{len(statuses)} transfers in {time.perf_counter() - t0:.2f} s, errors: {errors or 'none'}")
    after = balance(conn, x) + balance(conn, y)
    c.check("no deadlocks or other errors", not errors, str(errors))
    c.check("all 200 transfers succeeded", statuses.count("SUCCESSFUL") == 200, str(len(statuses)))
    c.check("the pair lost exactly the 200 fees", before - after == 200 * 1000, f"{before} -> {after}")
    conn.close()


def idempotent_race(c: Checks) -> None:
    scenario("L7  The same request sent twice at the same moment, 20 times")
    src, dst = customer_wallet(5), customer_wallet(6)
    conn = connect()
    before = balance(conn, src)
    mismatched, duplicates = 0, 0
    for _ in range(20):
        key, ids, barrier = str(uuid.uuid4()), [], threading.Barrier(2)

        def worker():
            w = connect()
            barrier.wait()
            ids.append(scalar(w, "SELECT post_transaction(%s, 'TRANSFER', %s, %s, 1000, 'APP')", (key, src, dst)))
            w.close()

        threads = [threading.Thread(target=worker) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        mismatched += ids[0] != ids[1]
        duplicates += scalar(conn, "SELECT count(*) FROM transaction WHERE idempotency_key = %s", (key,)) != 1
    spent = before - balance(conn, src)
    log("sys", f"20 pairs: {mismatched} pairs got different ids, {duplicates} keys stored more than once")
    c.check("both calls in every pair got the same transaction id", mismatched == 0)
    c.check("each key was posted exactly once", duplicates == 0)
    c.check("the sender paid for 20 transfers, not 40", spent == 20 * 2000, f"spent {spent}")
    conn.close()


def throughput(kind: str, threads_n: int, per_thread: int) -> tuple[float, int]:
    waits = [0]
    stop = threading.Event()

    def observer():
        o = connect()
        while not stop.is_set():
            waits[0] += scalar(o, """SELECT count(*) FROM pg_stat_activity
                                    WHERE wait_event_type = 'Lock' AND query LIKE 'SELECT post_transaction%%'""")
            time.sleep(0.01)
        o.close()

    def worker(i: int):
        conn = connect()
        for _ in range(per_thread):
            if kind == "TRANSFER":
                conn.execute("SELECT post_transaction(%s, 'TRANSFER', %s, %s, 1000, 'APP')",
                             (uuid.uuid4(), customer_wallet(i), customer_wallet(i + 8)))
            else:
                conn.execute("SELECT post_transaction(%s, 'MERCHANT_PAYMENT', %s, %s, 1000, 'APP')",
                             (uuid.uuid4(), customer_wallet(i), merchant_wallet(i)))
        conn.close()

    obs = threading.Thread(target=observer)
    obs.start()
    t0 = time.perf_counter()
    workers = [threading.Thread(target=worker, args=(i,)) for i in range(1, threads_n + 1)]
    for t in workers:
        t.start()
    for t in workers:
        t.join()
    elapsed = time.perf_counter() - t0
    stop.set()
    obs.join()
    return threads_n * per_thread / elapsed, waits[0]


def hot_row(c: Checks) -> None:
    scenario("L8  A hot row: every transfer credits the single FEES wallet")
    rows = []
    for kind in ("MERCHANT_PAYMENT", "TRANSFER"):
        for n in (1, 8):
            rate, waits = throughput(kind, n, 400 // n)
            rows.append((kind, n, rate, waits))
            log("sys", f"{kind:<16} {n} session(s): {rate:6.0f} postings/s, lock waits sampled: {waits}")
    mp1, mp8, tr1, tr8 = (r[2] for r in rows)
    c.check("merchant payments (no shared row) speed up with 8 sessions", mp8 > mp1 * 1.5,
            f"{mp1:.0f} -> {mp8:.0f}/s")
    c.check("transfers wait on a lock with 8 sessions", rows[3][3] > 0, f"{rows[3][3]} waits sampled")
    log("sys", f"scaling with 8 sessions: merchant payments x{mp8 / mp1:.1f}, transfers x{tr8 / tr1:.1f}")


def main() -> int:
    setup_stress_wallets()
    c = Checks("Locking and concurrency demos")
    lost_update(c, "READ COMMITTED")
    lost_update(c, "REPEATABLE READ")
    select_for_update(c)
    deadlock(c)
    ordered_locking(c)
    no_overspend(c)
    no_deadlock_posting(c)
    idempotent_race(c)
    hot_row(c)
    return c.summary()


if __name__ == "__main__":
    sys.exit(main())
