# Benchmark results

Model: claude-opus-5-5. Medians per cell; token counts from the API usage in each transcript.

| Task | Setup | runs | pass | main ctx | total tokens | wall s | turns |
|---|---|---|---|---|---|---|---|
| dbchecks | baseline | 3 | 3/3 | 27,871 | 107,863 | 16.5 | 4 |
| dbchecks | universe | 3 | 3/3 | 30,299 | 174,077 | 26.1 | 7 |
| edits | baseline | 3 | 3/3 | 27,972 | 109,254 | 8.3 | 4 |
| edits | universe | 3 | 3/3 | 30,475 | 172,943 | 14 | 6 |
| summarize | baseline | 3 | 3/3 | 31,173 | 113,451 | 12.7 | 4 |
| summarize | universe | 3 | 3/3 | 34,455 | 238,878 | 18.2 | 8 |

## Go / no-go (rule fixed in README.md before the runs)

- **dbchecks:** main-context cut -9%, faster or cheaper: no, all runs pass: yes → **no win**
- **edits:** main-context cut -9%, faster or cheaper: no, all runs pass: yes → **no win**
- **summarize:** main-context cut -11%, faster or cheaper: no, all runs pass: yes → **no win**

**Verdict: NO-GO** (0 of 3 tasks won; go needs 2).

## Runs

| Cell | grade | main ctx | total | wall s | turns | ToolSearch |
|---|---|---|---|---|---|---|
| dbchecks.baseline.1 | PASS | 27,859 | 107,600 | 16.7 | 4 | no |
| dbchecks.baseline.2 | PASS | 28,332 | 136,957 | 15 | 6 | no |
| dbchecks.baseline.3 | PASS | 27,871 | 107,863 | 16.5 | 4 | no |
| dbchecks.universe.1 | PASS | 30,299 | 173,909 | 17.8 | 7 | no |
| dbchecks.universe.2 | PASS | 30,271 | 174,077 | 26.6 | 7 | no |
| dbchecks.universe.3 | PASS | 31,615 | 207,234 | 26.1 | 8 | no |
| edits.baseline.1 | PASS | 27,972 | 109,254 | 8.3 | 4 | no |
| edits.baseline.2 | PASS | 29,359 | 111,717 | 9.6 | 4 | no |
| edits.baseline.3 | PASS | 27,716 | 81,290 | 6.7 | 3 | no |
| edits.universe.1 | PASS | 30,530 | 172,943 | 14 | 6 | no |
| edits.universe.2 | PASS | 30,475 | 203,046 | 17.3 | 7 | no |
| edits.universe.3 | PASS | 29,771 | 143,731 | 9.5 | 5 | no |
| summarize.baseline.1 | PASS | 30,898 | 143,776 | 15.7 | 5 | no |
| summarize.baseline.2 | PASS | 31,431 | 113,451 | 12.7 | 4 | no |
| summarize.baseline.3 | PASS | 31,173 | 113,181 | 12.2 | 4 | no |
| summarize.universe.1 | PASS | 34,455 | 238,627 | 17.8 | 8 | no |
| summarize.universe.2 | PASS | 34,800 | 239,128 | 19.1 | 8 | no |
| summarize.universe.3 | PASS | 34,429 | 238,878 | 18.2 | 8 | no |

**Validity note (added Oct 11, 2026):** the universe/agents setups never
loaded the plugin's skill. `Skill` was missing from `--allowedTools`, so each
run's attempt to load it was denied (one `permission_denied` per transcript)
and the model worked from the tick description and SessionStart hook alone.
Fixed in `run.py` for later runs; these results were not rerun.
