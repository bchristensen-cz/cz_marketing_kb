# Cafe Zupas Marketing Knowledge Base

Shared repository of data dictionaries, skills, and SQL for interfacing with Cafe Zupas data via Claude. The goal: **the same question always gets the same answer**, no matter who asks.

## How to use with Claude

Point Claude (Cowork or Claude Code) at this folder. Before answering any data question, Claude should read the relevant skill in `claude_skills/` and the data dictionaries it references.

## Structure

```
claude_skills/        Skills — how to query each domain (canonical definitions, joins, gotchas)
  sales-ops-orders/   Order & sales data (order_customer, order_lines)
  braze-campaigns/    Marketing campaign activity & engagement (braze dataset)
data_dictionaries/    Column-level documentation per table
sql/                  Build scripts for data marts + validated query templates
LEARNINGS.md          How the learnings inbox works (format + consolidation rules)
learnings/            One file per proposed gotcha/fix, awaiting consolidation
```

## Ground rules

1. Only query tables documented here. Upstream raw datasets (`brink.*`, `pulse.*`, `sessionM.*`) contain voids, duplicates, and traps — the marts exist so nobody has to relearn them.
2. Always filter on the partition column (`BusinessDate`) — these tables are large.
3. Use the canonical metric definitions in the skills. Don't invent alternate logic.
4. Found a gap or a new gotcha? Update the dictionary/skill and push, so everyone benefits.

## Approved tables

| Table | Grain | Use for |
|---|---|---|
| `marketing-data-442316.sales_ops.order_customer` | 1 row per order | Sales, orders, channels, customers, loyalty |
| `marketing-data-442316.sales_ops.order_lines` | 1 row per line element | Menu mix, items, modifiers, combos |
| `marketing-data-442316.sales_ops.store_info` | 1 row per store | Store attributes (name, state, timezone) |
| `marketing-data-442316.braze.*` (69 tables) | 1 row per message event | Campaign activity & engagement — use the `braze-campaigns` skill's templates, don't hand-roll unions |

More marts are being added in the `claude` dataset — documented here as they land.
