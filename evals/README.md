# KB eval set

A fixed set of questions with expected answers, run against a commit of this repo, scored as a pass rate. It turns the retrieval-quality loop (query-log review, then fix a skill or dictionary) into something measurable: a KB change should not lower the score, and a fix for a reported mistake should come with a case that would have caught it.

Quote results as **`eval v<N> @ <commit>`**, e.g. `eval v1 @ e5f7420: 44/49 pass (89.8%)`. History is in [`RESULTS.md`](RESULTS.md).

## What a run does

1. `git archive` the ref into a temp folder, so the candidate sees exactly the public KB at that commit (no gitignored files, no local CLAUDE.md).
2. Asks each question with `claude -p` in that folder, tools limited to `Read,Grep,Glob`, no MCP servers, user settings only. It cannot query BigQuery and is told not to ask clarifying questions, only to state its assumptions.
3. Grades:
   - **rule** cases: every `must` regex matches the answer and no `must_not` does (case-insensitive).
   - **sql** cases: the answer's last ```` ```sql ```` block must match `sql_must` / avoid `sql_must_not`, then the harness runs it and the case's `reference_sql` in BigQuery and compares. First column is the key, last column the value, relative tolerance 0.5% (`tolerance` overrides). Keys must match exactly.
   - **ambiguity** cases (`a*`) are rule cases whose pass condition is naming the right scope fork.
4. Prints the pass rate and each failure's reason. Full answers, SQL and numbers go to `C:\dev\cz_outputs\reports\evals\`; a full run appends one line to `RESULTS.md`.

Expected numbers are never stored. The repo is public, and live reference SQL on a closed window also survives the 5am full-history restatement.

## Running

Needs a logged-in `claude` CLI and `bq` with access to `marketing-data-442316`.

```powershell
python evals\run.py                          # full run at HEAD, appends RESULTS.md
python evals\run.py --ref a95c283            # score an older commit
python evals\run.py --only r01-market,s08-mini-cup-units
python evals\run.py --selftest               # check the SQL grader and every reference query, no claude calls
```

`--jobs` (default 4) sets parallel `claude` calls; `--model` pins a model; `--max-bytes` caps each query (default 20 GB). BigQuery jobs carry the label `kb_eval:v<N>`, so the daily query-log review can filter them out.

A CLI or auth failure is reported as a harness error and nothing is recorded.

## Cases

[`cases.py`](cases.py) holds them as a Python list (the outputs hook blocks `.jsonl` in this repo by extension). Fields: `id`, `skill`, `type` (`rule` / `sql`), `source` (the `D-0NN` row or skill section the expected answer comes from), `question`, `must`, `must_not`, `sql_must`, `sql_must_not`, `reference_sql`, `tolerance`.

## Versioning

- Any change to `cases.py` bumps `EVAL_VERSION`. Pass rates are only comparable within a version.
- Never edit a case in place: delete it and add a new id. Ids are never reused.
- When a steward ruling supersedes a decision, retire the cases that cite it in the same commit.
- New cases come from real mistakes: a query-log review or `KB finding:` task that shows Claude answering wrong is the best source.

## Reading a failure

- `missing /regex/` on a rule case: the answer did not state the rule. Check the cited `source`; if the KB states it clearly, the problem is routing (the right file was not read), so look at the skill's router table and description.
- `keys differ` / `values off` on a sql case: open the results JSON for the candidate SQL. Usually a missing filter (catering, `customer_type`, line type) or the wrong table.
- `sql error`: the candidate wrote SQL that does not run, often a column name the dictionary gets wrong.
- If the regex is too strict for a correct answer, that is a case bug: retire and replace it, bump the version.
