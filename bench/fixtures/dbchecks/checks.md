# Checks

Answer each check against the SQLite database `data/app.db` (table `events`: id, kind, amount).
Write `report.md` with exactly one line per check, in the form `N. VALUE` (for example `3. 241`).

1. Number of events with kind 'click'.
2. Number of events with kind 'view'.
3. Number of events with kind 'buy'.
4. Number of events with kind 'error'.
5. Total number of events.
6. Number of events with amount > 50.
7. Number of events with amount < 10.
8. Number of events with amount between 25 and 75 inclusive.
9. Average amount of 'click' events, rounded to 2 decimals.
10. Average amount of 'view' events, rounded to 2 decimals.
11. Average amount of 'buy' events, rounded to 2 decimals.
12. Average amount of 'error' events, rounded to 2 decimals.
13. Largest amount.
14. Smallest amount.
15. Sum of amounts of 'buy' events, rounded to 2 decimals.
16. Number of distinct kinds.
17. id of the event with the largest amount.
18. Number of 'buy' events with amount > 90.
19. Number of 'error' events with amount < 5.
20. Average amount over all events, rounded to 2 decimals.
