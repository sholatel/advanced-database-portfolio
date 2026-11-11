# Replaying the scenarios by hand

The Python demos run these scenarios automatically. To see them with your own eyes, or to take screenshots, open two terminals side by side and start a psql session in each:

```bash
docker compose exec postgres psql -U postgres -d oworail
```

Then in **both** terminals:

```sql
SET search_path = oworail, lab, public;
SELECT lab.reset();      -- only once, in terminal A
```

Run the steps in the order shown. "A" and "B" are the two terminals.

## 1. Lost update (READ COMMITTED)

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `SELECT balance_kobo FROM lab.account WHERE account_id = 3;` → 100000 | |
| 3 | | `BEGIN;` |
| 4 | | `SELECT balance_kobo FROM lab.account WHERE account_id = 3;` → 100000 |
| 5 | `UPDATE lab.account SET balance_kobo = 70000 WHERE account_id = 3;` | |
| 6 | | `UPDATE lab.account SET balance_kobo = 50000 WHERE account_id = 3;` → **waits** |
| 7 | `COMMIT;` | the UPDATE now finishes |
| 8 | | `COMMIT;` |
| 9 | `SELECT balance_kobo FROM lab.account WHERE account_id = 3;` → **50000** | |

Both withdrawals (30,000 and 50,000) were accepted, but the balance shows only one: A's withdrawal is lost. Repeat with `BEGIN ISOLATION LEVEL REPEATABLE READ;` in both terminals. Step 7 then ends B's UPDATE with `ERROR: could not serialize access due to concurrent update`.

## 2. The fix: SELECT ... FOR UPDATE

`SELECT lab.reset();`, then:

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `SELECT balance_kobo FROM lab.account WHERE account_id = 3 FOR UPDATE;` → 100000 | |
| 3 | | `BEGIN;` |
| 4 | | `SELECT balance_kobo FROM lab.account WHERE account_id = 3 FOR UPDATE;` → **waits** |
| 5 | `UPDATE lab.account SET balance_kobo = 70000 WHERE account_id = 3;` | |
| 6 | `COMMIT;` | the SELECT now returns **70000** |
| 7 | | `UPDATE lab.account SET balance_kobo = 20000 WHERE account_id = 3; COMMIT;` |

While B waits at step 4, a third terminal shows who is blocking whom:

```sql
SELECT pid, state, wait_event_type, wait_event, pg_blocking_pids(pid), left(query, 60)
FROM pg_stat_activity WHERE datname = 'oworail' AND pid <> pg_backend_pid();
```

## 3. Deadlock

`SELECT lab.reset();`, then:

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN;` | `BEGIN;` |
| 2 | `UPDATE lab.account SET balance_kobo = balance_kobo - 1000 WHERE account_id = 1;` | |
| 3 | | `UPDATE lab.account SET balance_kobo = balance_kobo - 1000 WHERE account_id = 2;` |
| 4 | `UPDATE lab.account SET balance_kobo = balance_kobo + 1000 WHERE account_id = 2;` → waits | |
| 5 | | `UPDATE lab.account SET balance_kobo = balance_kobo + 1000 WHERE account_id = 1;` |
| 6 | after about 1 s, one terminal shows `ERROR: deadlock detected` | the other continues |
| 7 | `ROLLBACK;` in the one that failed, `COMMIT;` in the other | |

## 4. Non-repeatable read and REPEATABLE READ

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN;` (READ COMMITTED) | |
| 2 | `SELECT balance_kobo FROM wallet WHERE wallet_number = '3000000001';` | |
| 3 | | `SELECT post_transaction(gen_random_uuid(), 'TRANSFER', '3000000001', '3000000003', 5000, 'APP');` |
| 4 | the same SELECT → 6,000 less (amount + fee) | |
| 5 | `COMMIT;` | |

Repeat with `BEGIN ISOLATION LEVEL REPEATABLE READ;` at step 1: the second SELECT returns the same value as the first, until A commits.

## 5. Write skew and SERIALIZABLE

`SELECT lab.reset();`. Accounts 1 and 2 both belong to Adaeze, and the rule is that their **combined** balance must not go below zero.

| Step | Terminal A | Terminal B |
|---|---|---|
| 1 | `BEGIN ISOLATION LEVEL SERIALIZABLE;` | `BEGIN ISOLATION LEVEL SERIALIZABLE;` |
| 2 | `SELECT sum(balance_kobo) FROM lab.account WHERE owner = 'Adaeze Okafor';` → 200000 | the same → 200000 |
| 3 | `UPDATE lab.account SET balance_kobo = balance_kobo - 150000 WHERE account_id = 1;` | `UPDATE lab.account SET balance_kobo = balance_kobo - 150000 WHERE account_id = 2;` |
| 4 | `COMMIT;` | `COMMIT;` → `ERROR: could not serialize access due to read/write dependencies among transactions` |

With `REPEATABLE READ` instead, both commits succeed and the combined balance ends at −100,000.
