# Benchmark results

Model: claude-opus-5-5. Medians per cell; token counts from the API usage in each transcript.

| Task | Setup | runs | pass | main ctx | total tokens | helper tokens | wall s | turns | delegations |
|---|---|---|---|---|---|---|---|---|---|
| modules | agents | 3 | 3/3 | 36,205 | 408,401 | 105,325 | 65.6 | 13 | 4 |
| modules | subagents | 3 | 3/3 | 35,063 | 191,323 | 72,039 | 50.4 | 7 | 4 |
| qa | agents | 3 | 3/3 | 45,560 | 564,516 | 197,583 | 116.4 | 21 | 3 |
| qa | subagents | 3 | 3/3 | 45,288 | 1,344,439 | 1,026,411 | 197.9 | 15 | 4 |

## Go / no-go (M6 rule fixed in README.md before the runs)

- **modules:** agents/subagents total tokens 213% (need ≤ 80%), wall 130% (≤ 120%), main ctx 103% (≤ 110%), all pass: yes → **no win**
- **qa:** agents/subagents total tokens 42% (need ≤ 80%), wall 59% (≤ 120%), main ctx 101% (≤ 110%), all pass: yes → **win**

**Verdict: NO-GO** (1 of 2 tasks won; go needs both).

## Runs

| Cell | grade | main ctx | total | helpers | wall s | turns | delegations | ToolSearch |
|---|---|---|---|---|---|---|---|---|
| modules.agents.1 | PASS | 42,608 | 615,979 | 109,405 | 160.2 | 19 | 4 | no |
| modules.agents.2 | PASS | 34,598 | 408,401 | 105,256 | 39 | 13 | 4 | no |
| modules.agents.3 | PASS | 36,205 | 376,901 | 105,325 | 65.6 | 12 | 4 | no |
| modules.subagents.1 | PASS | 46,920 | 844,815 | 237,787 | 222.6 | 19 | 4 | no |
| modules.subagents.2 | PASS | 33,913 | 189,359 | 71,991 | 45.2 | 7 | 4 | no |
| modules.subagents.3 | PASS | 35,063 | 191,323 | 72,039 | 50.4 | 7 | 4 | no |
| qa.agents.1 | PASS | 45,560 | 711,696 | 201,622 | 134 | 27 | 3 | no |
| qa.agents.2 | PASS | 37,938 | 553,493 | 197,583 | 116.4 | 18 | 4 | no |
| qa.agents.3 | PASS | 45,855 | 564,516 | 115,458 | 109 | 21 | 3 | no |
| qa.subagents.1 | PASS | 45,990 | 1,237,364 | 832,387 | 211 | 16 | 4 | no |
| qa.subagents.2 | PASS | 41,997 | 1,344,439 | 1,026,411 | 197.9 | 12 | 3 | no |
| qa.subagents.3 | PASS | 45,288 | 1,767,146 | 1,358,718 | 196.1 | 15 | 4 | no |
