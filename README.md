# Cafe Zupas Marketing Knowledge Base

Shared repository of data dictionaries, skills, and SQL for interfacing with Cafe Zupas data via Claude. The goal: **the same question always gets the same answer**, no matter who asks.

## How to use with Claude — session protocol (required)

This KB is **pull-based**: every Claude session works from a fresh clone of `main`, pulled at the start of that session. No installed skill packages, no forks, no saved local copies.

1. **Fresh clone, every session** (the repo is public; a shallow clone takes seconds):
   ```
   git clone --depth 1 https://github.com/bchristensen-cz/cz_marketing_kb
   ```
   Clone into the session's temporary working area. If an older copy exists, delete it first.
2. Read this README, then the relevant skill in `claude_skills/`, then the data dictionaries it references — from the fresh clone only.
3. **State the KB version** in the first data answer of the session (`git log -1 --format='%h %ad'`), so stale copies are visible.
4. Users never push, fork, or edit this repo. Findings go to the steward via Asana (see Ground rules).

The one-time setup each user needs is the project-instructions snippet in `CLIENT_SETUP.md` — it's deliberately tiny and never changes, so it can't go stale.

## Structure

```
claude_skills/        Skills — how to query each domain (canonical definitions, joins, gotchas)
  sales-ops-orders/   Order & sales data (order_customer, order_lines)
  braze-campaigns/    Marketing campaign activity & engagement (braze dataset)
data_dictionaries/    Column-level documentation per table
sql/                  Build scripts for data marts + validated query templates
```

## Ground rules

1. Only query tables documented here. Upstream raw datasets (`brink.*`, `pulse.*`, `sessionM.*`) contain voids, duplicates, and traps — the marts exist so nobody has to relearn them.
2. Always filter on the partition column (`BusinessDate`) — these tables are large.
3. Use the canonical metric definitions in the skills. Don't invent alternate logic.
4. Found a gap or a new gotcha? **Don't edit the repo** — only the data steward (Brent) commits. Log it as an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`), titled `KB finding: <short title>`, with what you observed (including the query) and the proposed change. The steward reviews, merges vetted findings into the repo, and pushes — the next session's clone picks it up automatically.

## Approved tables

| Table | Grain | Use for |
|---|---|---|
| `marketing-data-442316.sales_ops.order_customer` | 1 row per order | Sales, orders, channels, customers, loyalty |
| `marketing-data-442316.sales_ops.order_lines` | 1 row per line element | Menu mix, items, modifiers, combos |
| `marketing-data-442316.sales_ops.store_info` | 1 row per store | Store attributes (name, state, timezone) |
| `marketing-data-442316.braze.*` (69 tables) | 1 row per message event | Campaign activity & engagement — use the `braze-campaigns` skill's templates, don't hand-roll unions |

More marts are being added in the `claude` dataset — documented here as they land.
