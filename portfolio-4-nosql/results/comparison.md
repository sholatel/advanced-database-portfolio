# MongoDB workload before and after indexes

Median of 5 runs (ms, wall clock from the client). Docs and keys examined come from `explain("executionStats")`; a timeout is 30 s (120 s for Q5).

| query   | title                                                           | before ms   |   after ms | docs examined before   |   docs examined after |   keys examined after | plan                 | speed-up   |
|---------|-----------------------------------------------------------------|-------------|------------|------------------------|-----------------------|-----------------------|----------------------|------------|
| Q1      | customer and wallets by phone                                   | 79.14       |       3.15 | 102013                 |                     2 |                     2 | COLLSCAN -> IXSCAN   | 25.1x      |
| Q2      | statement: 20 latest entries of the busiest wallet              | 2357.21     |       2.86 | 1101109                |                    20 |                    20 | COLLSCAN -> IXSCAN   | 824.2x     |
| Q3      | transaction with its status history by reference                | 3.01        |       2.8  | 1                      |                     1 |                     1 | IXSCAN -> IXSCAN     | 1.1x       |
| Q4      | amount sent today by the busiest wallet (KYC limit)             | 1797.66     |       2.66 | 1101109                |                    20 |                    20 | COLLSCAN -> IXSCAN   | 675.8x     |
| Q5      | reconcile stored balances against the entries                   | 34061.28    |   30890.3  | 1203119                |               1203119 |                102010 | COLLSCAN -> COLLSCAN | 1.1x       |
| Q6      | wallets with 5+ outgoing payments in one day                    | 2306.23     |      54.64 | 1101109                |                  5562 |                  5562 | COLLSCAN -> IXSCAN   | 42.2x      |
| Q7      | October settlement per merchant and biller                      | 3110.47     |     555.47 | 1103109                |                 67282 |                 67285 | COLLSCAN -> IXSCAN   | 5.6x       |
| Q8      | failed transactions in the last 7 days by channel and reason    | 1990.81     |      13.76 | 1101109                |                  1151 |                  1151 | COLLSCAN -> IXSCAN   | 144.7x     |
| Q9      | 50 largest customer wallets with no outgoing payment in 90 days | timeout     |     645.64 | -                      |                 29928 |                 29928 | COLLSCAN -> IXSCAN   | >46x       |
